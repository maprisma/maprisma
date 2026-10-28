import 'dart:ffi';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'adapters.dart';
import 'agent_catalog.dart';
import 'agent_details.dart';
import 'provider_scans.dart';
import 'scan_files.dart';
import 'session_readers.dart';
import 'sqlite_numbers.dart';

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
      sqlite = SqliteNumbers(files);
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
  bool ownDirectory(String path) {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return false;
    }
    int? fd;
    try {
      fd = files.posix.openAt(-100, path, 0x10000 | 0x20000);
      return files.posix.stat(fd).uid == files.posix.uid;
    } on FileSystemException {
      return false;
    } finally {
      if (fd != null) files.posix.close(fd);
    }
  }

  bool noLinks(String path) {
    var current = files.expand(path);
    while (true) {
      if (FileSystemEntity.typeSync(current, followLinks: false) ==
          FileSystemEntityType.link) {
        return false;
      }
      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }
    return true;
  }

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
            'AI_AGENTS_MAP_NO_PROVIDERS',
          })['AI_AGENTS_MAP_NO_PROVIDERS'] ==
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
          noLinks(spec['path']);
      final children = supported
          ? subagents(
              agent.adapter,
              owned,
              now: now,
              recent: recent,
              kept: kept,
            )
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
      };
    }
    previous
      ..clear()
      ..addAll(seen);
    return (running, activity);
  }

  List<Map<String, dynamic>> subagents(
    Adapter adapter,
    List<int> pids, {
    required double now,
    double recent = 1800,
    int kept = 10,
  }) {
    final spec = adapter.table('subagents'),
        form = spec['format'],
        root = files.expand(spec['path'] as String? ?? '');
    if (root.isEmpty || !noLinks(root)) return [];
    final found = <Map<String, dynamic>>[];
    void add(
      dynamic sid,
      dynamic kind,
      dynamic folder,
      dynamic stamp,
      bool finished,
    ) {
      final when = epoch(stamp), id = metaText(sid, 160);
      if (when == null || when == 0 || now - when > recent || id.isEmpty) {
        return;
      }
      final age = (now - when).clamp(0.0, double.infinity);
      found.add({
        'key': '${adapter.command}:$id',
        'kind': metaText(kind, 60).isEmpty ? 'subagent' : metaText(kind, 60),
        'folder': tilde(files, metaText(folder, 4096)),
        'age': age,
        'running': !finished && age <= 90,
      });
    }

    if (form == 'opencode-db') {
      final since = ((now - recent) * 1000).toInt();
      for (final row in sqlite.select(
        root,
        'SELECT id, agent, directory, time_updated, time_idle FROM session_v2 WHERE parent_id IS NOT NULL AND time_updated >= $since ORDER BY time_updated DESC LIMIT 40',
        maxRows: 40,
      )) {
        if (row[3] is! num) continue;
        add(
          boundedText(row[0], 80),
          metaText(row[1], 60).isEmpty ? 'subagent' : row[1],
          row[2],
          (row[3] as num) / 1000,
          row[4] is num && row[4] >= row[3],
        );
      }
    } else if (form == 'goose-db') {
      for (final row in sqlite.select(
        root,
        "SELECT substr(id,1,80), substr(session_type,1,60), substr(working_dir,1,4096), CASE WHEN typeof(updated_at) IN ('integer','real') THEN updated_at ELSE substr(updated_at,1,40) END FROM sessions WHERE session_type = 'sub_agent' AND parent_session_id IS NOT NULL ORDER BY updated_at DESC LIMIT 2000",
        maxRows: 2000,
      )) {
        add(row[0], row[1], row[2], row[3], false);
      }
    } else if (form == 'claude-projects') {
      final projects = <String, String>{};
      for (final pid in pids.take(64)) {
        try {
          final cwd = Link('${provider.proc}/$pid/cwd').targetSync();
          projects[cwd.replaceAll(RegExp(r'[^A-Za-z0-9]'), '-')] = cwd;
        } on FileSystemException {
          /* process ended */
        }
      }
      for (final project in projects.entries) {
        final dir = p.join(root, project.key);
        if (!ownDirectory(dir)) continue;
        for (final session in files.list(dir, limit: 2000)) {
          if (!RegExp(r'^[A-Za-z0-9\-]{1,80}$').hasMatch(p.basename(session)) ||
              !ownDirectory(session)) {
            continue;
          }
          final directory = '$session/subagents';
          if (!ownDirectory(directory)) continue;
          final meta = files.list(directory, limit: 2000)..sort();
          for (final file in meta) {
            final match = RegExp(
              r'^(agent-[A-Za-z0-9_\-]{1,80})\.meta\.json$',
            ).firstMatch(p.basename(file));
            if (match == null) continue;
            final path = '$directory/${match[1]}.jsonl',
                stamp = written(path) ?? written(file);
            if (stamp == null) continue;
            final info = files.json(file, limit: 16 * 1024, comments: false),
                text =
                    files.text(path, limit: 64 * 1024, portion: 'tail') ?? '';
            final handback = text
                .split('\n')
                .reversed
                .take(5)
                .any((line) => line.contains('SubagentHandback'));
            add(
              '${p.basename(session)}:${match[1]}',
              metaText(info['agentType'], 60).isEmpty
                  ? 'general-purpose'
                  : info['agentType'],
              project.value,
              stamp,
              handback,
            );
          }
        }
      }
    } else if (form == 'codex-rollouts' || form == 'copilot-events') {
      final pattern = form == 'codex-rollouts'
          ? '*/*/*/*.jsonl'
          : '*/events.jsonl';
      final paths = sessions.matching(root, pattern);
      for (final path in paths) {
        final stamp = written(path);
        if (stamp == null || now - stamp > recent) continue;
        final head =
                files.bytes(path, limit: 512 * 1024, portion: 'head') ?? [],
            tail = files.bytes(path, limit: 128 * 1024, portion: 'tail') ?? [];
        if (form == 'codex-rollouts') {
          final meta = sessions.entries(head).firstOrNull;
          if (meta?['type'] != 'session_meta' || meta?['payload'] is! Map) {
            continue;
          }
          final payload = meta!['payload'] as Map,
              sub = dig(meta, 'payload.source.subagent'),
              spawn = mapOf(dig(meta, 'payload.source.subagent.thread_spawn'));
          final parent =
              payload['parent_thread_id'] ?? spawn['parent_thread_id'];
          if (!(sub is String && sub.isNotEmpty ||
                  sub is Map && sub.isNotEmpty) ||
              parent is! String ||
              !RegExp(r'^[A-Za-z0-9\-]{1,80}$').hasMatch(parent)) {
            continue;
          }
          final name =
              payload['agent_path'] ??
              spawn['agent_path'] ??
              payload['agent_nickname'] ??
              spawn['agent_nickname'];
          var role = payload['agent_role'] ?? spawn['agent_role'] ?? name;
          if (name is String && role is String && name != role) {
            role = '$role · $name';
          }
          var finished = false;
          for (final event in sessions.entries(tail)) {
            if (event['type'] != 'event_msg') continue;
            final kind = dig(event, 'payload.type');
            if (['task_complete', 'turn_aborted'].contains(kind)) {
              finished = true;
            }
            if (['task_started', 'turn_started'].contains(kind)) {
              finished = false;
            }
          }
          add(payload['id'], role, payload['cwd'], stamp, finished);
        } else {
          final bytes = files.bytes(path, limit: 4 * 1024 * 1024);
          if (bytes == null) continue;
          final rows = <String, List<dynamic>>{};
          var cwd = '';
          for (final event in sessions.entries(bytes, completeLines: true)) {
            final data = mapOf(event['data']);
            if (event['type'] == 'session.start') {
              cwd = metaText(dig(data, 'context.cwd'), 4096);
            }
            final key = metaText(data['toolCallId'], 100);
            if (key.isEmpty) continue;
            if (event['type'] == 'subagent.started') {
              rows[key] = [
                data['agentName'],
                epoch(event['timestamp']) ?? stamp,
                false,
              ];
            } else if ([
              'subagent.completed',
              'subagent.failed',
            ].contains(event['type'])) {
              rows.putIfAbsent(key, () => [data['agentName'], stamp, true]);
              rows[key]![1] = epoch(event['timestamp']) ?? stamp;
              rows[key]![2] = true;
            }
          }
          for (final e in rows.entries) {
            add(
              '${p.basename(p.dirname(path))}:${e.key}',
              e.value[0],
              cwd,
              e.value[1],
              e.value[2] as bool,
            );
          }
        }
      }
    }
    found.sort((a, b) => (a['age'] as num).compareTo(b['age'] as num));
    final limited = found.take(40).toList(),
        result = [
          ...limited.where((s) => s['running'] == true),
          ...limited.where((s) => s['running'] != true).take(kept.clamp(0, 40)),
        ];
    result.sort((a, b) => (a['age'] as num).compareTo(b['age'] as num));
    return result;
  }
}
