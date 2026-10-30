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

  bool inTurn(int pid, double now) {
    for (final fd in files.list('${provider.proc}/$pid/fd', limit: 512)) {
      try {
        final path = Link(fd).targetSync();
        if (!path.endsWith('.jsonl')) continue;
        final stamp = written(path);
        if (stamp == null || now - stamp > 1800) continue;
        final source =
            files.text(path, limit: 64 * 1024, portion: 'tail') ?? '';
        final markers = RegExp(
          r'"type"\s*:\s*"(task_started|task_complete|turn_aborted)"',
        ).allMatches(source).toList();
        if (markers.isNotEmpty && markers.last[1] == 'task_started') {
          return true;
        }
      } on FileSystemException {
        /* closed or unavailable descriptor */
      }
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
              )) {
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
      final justWritten =
          newest != null && now - newest.microsecondsSinceEpoch / 1e6 <= 8;
      final busy =
          cpu >= 0.02 ||
          justWritten ||
          owned.take(8).any((pid) => inTurn(pid, now));
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
