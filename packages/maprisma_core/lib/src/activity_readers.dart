import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'agent_catalog.dart';
import 'agent_details.dart';
import 'provider_scans.dart';
import 'scan_files.dart';
import 'session_readers.dart';
import 'sqlite_numbers.dart';
import 'subagent_readers.dart';
import 'usage_box.dart';

String metaText(dynamic value, [int most = 200]) => value is String
    ? String.fromCharCodes(
            value.runes.map((r) => r < 32 || r >= 0x7f && r < 0xa0 ? 32 : r),
          )
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .join(' ')
          .runes
          .take(most)
          .map(String.fromCharCode)
          .join()
    : '';

final class ActivityReaders {
  ActivityReaders(this.files, this.details)
    : provider = ProviderScans(files),
      sessions = SessionReaders(files),
      sqlite = SqliteNumbers(files),
      subagentReaders = SubagentReaders(files, ProviderScans(files).proc);
  final SubagentReaders subagentReaders;
  final ScanFiles files;
  final DetailReaders details;
  final ProviderScans provider;
  final SessionReaders sessions;
  final SqliteNumbers sqlite;
  final previous = <int, (int, double)>{};
  final _sessionCache =
      <
        String,
        ({double at, double activityMtime, List<(String, double)> files})
      >{};
  final elapsed = Stopwatch()..start();
  static final ticks = DynamicLibrary.open(
    'libc.so.6',
  ).lookupFunction<IntPtr Function(Int), int Function(int)>('sysconf')(2);
  double? written(String path) {
    final data = files.bytes(path, limit: 1, portion: 'head');
    if (data == null) return null;
    return File(files.expand(path)).statSync().modified.microsecondsSinceEpoch /
        1e6;
  }

  static final _codexTurnMarkers = RegExp(
    r'"type"\s*:\s*"(task_started|task_complete|turn_aborted)"',
  );

  /// Whether the tail of a session JSONL file indicates an in-flight turn
  /// (waiting on the model or tool execution, before turn completion).
  static bool isJsonlTurnActive(String format, String source) {
    if (source.isEmpty) return false;
    if (format == 'codex-jsonl') {
      final markers = _codexTurnMarkers.allMatches(source).toList();
      return markers.isNotEmpty && markers.last[1] == 'task_started';
    }
    if (format == 'claude-jsonl') {
      bool? active;
      final lines = const LineSplitter().convert(source);
      // Skip index 0 when the tail slice likely began mid-line (jsonDecode fails safely anyway).
      for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty || !line.startsWith('{')) continue;
        final Object? decoded;
        try {
          decoded = jsonDecode(line);
        } on FormatException {
          continue;
        }
        if (decoded is! Map) continue;
        final type = decoded['type'];
        if (type == 'system' && decoded['subtype'] == 'turn_duration') {
          active = false;
        } else if (type == 'assistant') {
          final msg = decoded['message'];
          final stop = msg is Map ? msg['stop_reason'] : null;
          active = stop != 'end_turn';
        } else if (type == 'user' ||
            type == 'api-request' ||
            type == 'api-request-blob' ||
            type == 'progress') {
          active = true;
        }
      }
      return active == true;
    }
    return false;
  }

  bool inTurn(int pid, double now) {
    for (final fd in files.list('${provider.proc}/$pid/fd', limit: 512)) {
      try {
        final path = Link(fd).targetSync();
        if (!path.endsWith('.jsonl')) continue;
        final stamp = written(path);
        if (stamp == null || now - stamp > 1800) continue;
        final source =
            files.text(path, limit: 64 * 1024, portion: 'tail') ?? '';
        if (isJsonlTurnActive('codex-jsonl', source)) {
          return true;
        }
      } on FileSystemException {
        /* closed or unavailable descriptor */
      }
    }
    return false;
  }

  /// Top [keep] newest `*.jsonl` files at [depth] below [root] modified after
  /// [since] (symlinks not followed, bounded by [maxEntries]).
  List<(String, double)> _recentSessionFiles(
    String root,
    int depth,
    double since, {
    int keep = 3,
  }) {
    final posix = files.posix;
    final found = <(String, double)>[];
    var seen = 0;
    final stack = [(root, 0)];
    while (stack.isNotEmpty && seen < maxEntries) {
      final (folder, level) = stack.removeLast();
      List<FileSystemEntity> entries;
      try {
        entries = Directory(folder).listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }
      for (final e in entries) {
        seen++;
        if (seen >= maxEntries) break;
        final st = posix.lstatFull(e.path);
        if (st == null) continue;
        final type = st.mode & 0xf000;
        final mtime = st.sec + st.nsec / 1e9;
        if (level < depth && type == 0x4000) {
          stack.add((e.path, level + 1));
        } else if (level == depth &&
            type == 0x8000 &&
            e.path.endsWith('.jsonl') &&
            mtime > since) {
          found.add((e.path, mtime));
        }
      }
    }
    found.sort((a, b) => b.$2.compareTo(a.$2));
    return found.take(keep).toList();
  }

  double? _earliestProcStart(List<int> owned) {
    double? earliest;
    for (final pid in owned.take(32)) {
      final info = files.posix.lstatTime('${provider.proc}/$pid');
      if (info == null) continue;
      final t = info.sec + info.nsec / 1e9;
      if (earliest == null || t < earliest) earliest = t;
    }
    return earliest;
  }

  /// Checks up to 3 newest recent session files (`[replies]` folder/depth/format)
  /// for an in-flight turn so long model-thinking pauses (>8 s) stay marked active
  /// even when the agent does not hold the `.jsonl` open as an FD.
  ///
  /// Requires file mtime >= earliest live PID start time (with 2 s slack) so a
  /// stale interrupted transcript cannot keep a newly started idle instance lit,
  /// and caches the directory walk for 15 s (invalidated on newer activity mtime).
  bool inSessionTurn(
    AgentRecord agent,
    List<int> owned,
    double now,
    double clock, {
    double activityMtime = 0,
    double window = 90,
  }) {
    final replies = agent.adapter.table('replies');
    final folder = replies['folder'];
    final format = replies['format'];
    if (folder is! String ||
        format is! String ||
        (format != 'claude-jsonl' && format != 'codex-jsonl')) {
      return false;
    }
    final depth = (replies['depth'] as num?)?.toInt() ?? 1;
    final root = repliesFolder(folder, files.identity.home);
    final cached = _sessionCache[agent.command];
    final List<(String, double)> candidates;
    if (cached != null &&
        clock - cached.at < 15.0 &&
        activityMtime <= cached.activityMtime) {
      candidates = cached.files;
    } else {
      candidates = _recentSessionFiles(root, depth, now - window);
      _sessionCache[agent.command] = (
        at: clock,
        activityMtime: activityMtime,
        files: candidates,
      );
    }
    if (candidates.isEmpty) return false;
    final earliestStart = _earliestProcStart(owned);
    for (final (path, _) in candidates) {
      final stamp = written(path);
      if (stamp == null || now - stamp > window) continue;
      if (earliestStart != null && stamp < earliestStart - 2.0) continue;
      final source = files.text(path, limit: 64 * 1024, portion: 'tail') ?? '';
      if (isJsonlTurnActive(format, source)) return true;
    }
    return false;
  }

  (Map<String, List<String>>, Map<String, dynamic>) snapshot(
    List<AgentRecord> catalog, {
    double recent = 1800,
    int kept = 10,
  }) {
    final names = {
          for (final a in catalog.where((a) => a.installed)) a.command: a,
        },
        pids = <String, List<int>>{},
        running = <String, List<String>>{};
    String bare(String value) => value.replaceFirst(RegExp(r'\.exe$'), '');
    bool interpreter(String value) =>
        ['node', 'bun', 'deno', 'python', 'python3'].any(value.startsWith);
    for (final process in provider.processes()) {
      final comm = bare(process.comm), argv = process.argv;
      if (!names.containsKey(comm) && !interpreter(comm) && comm.length < 15 ||
          argv.isEmpty) {
        continue;
      }
      var name = bare(p.basename(argv[0])), args = argv.skip(1).toList();
      if (!names.containsKey(name) && interpreter(name) && argv.length > 1) {
        name = bare(p.basename(argv[1]));
        args = argv.skip(2).toList();
      }
      if (!names.containsKey(name) && names.containsKey(comm)) name = comm;
      if (!names.containsKey(name) ||
          args
              .take(3)
              .any(
                (a) => {
                  'serve',
                  'server',
                  'daemon',
                  '--service',
                  '--daemon',
                }.contains(a),
              ) ||
          args.contains('--chrome-native-host')) {
        continue;
      }
      if (provider.processEnv(process.pid, {
            'MAPRISMA_NO_PROVIDERS',
          })['MAPRISMA_NO_PROVIDERS'] ==
          '1') {
        continue;
      }
      var model = provider.arg(args, ['--model']);
      if (model.isEmpty &&
          names[name]!.adapter.facts['short_model_flag'] == true) {
        model = provider.arg(args, ['-m']);
      }
      running.putIfAbsent(name, () => []).add(boundedText(model, 200));
      pids.putIfAbsent(name, () => []).add(process.pid);
    }
    // subagents.agents_using_agents: an agent that started another one (directly
    // or through a shell, a script, a tool) and uses it: the map's arrows.
    final using = agentsUsingAgents(pids, (pid) {
      final stat = files.text('${provider.proc}/$pid/stat', limit: 1024);
      if (stat == null || !stat.contains(')')) return 0;
      final fields = stat
          .substring(stat.lastIndexOf(')') + 1)
          .trim()
          .split(RegExp(r'\s+'));
      return fields.length > 1 ? int.tryParse(fields[1]) ?? 0 : 0;
    });
    final now = scanNow(files),
        clock = elapsed.elapsedMicroseconds / 1e6,
        seen = <int, (int, double)>{},
        activity = <String, dynamic>{};
    for (final agent in names.values) {
      final owned = pids[agent.command] ?? [];
      var cpu = 0.0;
      for (final pid in owned.take(32)) {
        final stat = files.text('${provider.proc}/$pid/stat', limit: 4096);
        if (stat == null || !stat.contains(')')) continue;
        final parts = stat
            .substring(stat.lastIndexOf(')') + 2)
            .trim()
            .split(RegExp(r'\s+'));
        if (parts.length < 15) continue;
        final value = parts
            .sublist(11, 15)
            .fold<int>(0, (n, v) => n + (int.tryParse(v) ?? 0));
        seen[pid] = (value, clock);
        final before = previous[pid];
        if (before != null && clock > before.$2) {
          cpu +=
              (value - before.$1).clamp(0, 1 << 62) /
              (ticks > 0 ? ticks : 100) /
              (clock - before.$2);
        }
      }
      final stamp = agent.adapter.facts['activity'] as List? ?? [];
      final newest = owned.isEmpty
          ? null
          : details.newestMtime([for (final path in stamp) path as String]);
      final activityMtime = newest == null
          ? 0.0
          : newest.microsecondsSinceEpoch / 1e6;
      final justWritten = newest != null && now - activityMtime <= 8;
      final busy =
          cpu >= 0.02 ||
          justWritten ||
          owned.take(8).any((pid) => inTurn(pid, now)) ||
          (owned.isNotEmpty &&
              inSessionTurn(
                agent,
                owned,
                now,
                clock,
                activityMtime: activityMtime,
              ));
      final spec = agent.adapter.table('subagents');
      final supported =
          [
            'claude-projects',
            'opencode-db',
            'codex-rollouts',
            'copilot-events',
            'goose-db',
          ].contains(spec['format']) &&
          spec['path'] is String &&
          subagentReaders.linkFree(spec['path'] as String);
      final children = supported
          ? [
              for (final s in subagentReaders.of(
                agent.command,
                spec['format'] as String,
                spec['path'] as String,
                owned,
                now: now,
                recent: recent,
                kept: kept,
              ))
                {
                  'key': s.key,
                  'kind': s.kind,
                  'folder': s.folder,
                  'age': s.age,
                  'running': s.running,
                },
            ]
          : <Map<String, dynamic>>[];
      for (final child in children) {
        child['running'] = owned.isNotEmpty && child['running'] == true;
      }
      activity[agent.command] = {
        'instances': running[agent.command]?.length ?? 0,
        'working': busy,
        'subagents_supported': supported,
        'active_subagents': supported
            ? children.where((c) => c['running'] == true).length
            : null,
        'children': children,
        'uses': [
          for (final (user, used) in using)
            if (user == agent.command) used,
        ]..sort(),
      };
    }
    previous
      ..clear()
      ..addAll(seen);
    return (running, activity);
  }
}

/// subagents.agents_using_agents: {(user, used)} where a running instance of
/// `used` was started by one of `user`, up to [depth] parents up; an agent
/// inside another instance of itself does not count.
Set<(String, String)> agentsUsingAgents(
  Map<String, List<int>> pidsByAgent,
  int Function(int pid) parent, {
  int depth = 12,
}) {
  final owner = <int, String>{
    for (final e in pidsByAgent.entries)
      for (final pid in e.value.take(64)) pid: e.key,
  };
  final found = <(String, String)>{};
  for (final e in pidsByAgent.entries) {
    for (final pid in e.value.take(64)) {
      var current = pid;
      for (var step = 0; step < depth; step++) {
        current = parent(current);
        if (current <= 1) break;
        final user = owner[current];
        if (user != null) {
          if (user != e.key) found.add((user, e.key));
          break;
        }
      }
    }
  }
  return found;
}
