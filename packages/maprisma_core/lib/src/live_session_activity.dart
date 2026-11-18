import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'agent_halt.dart';
import 'jsonl_session_activity.dart';
import 'provider_scans.dart';
import 'pty_sessions.dart' show processIdentity;
import 'sqlite_numbers.dart';
import 'trajectory_activity.dart';

Map<String, dynamic> unavailableSessionActivity() => {
  'status': 'unavailable',
  'session_id': null,
  'request': null,
  'answers': [],
  'tool_calls': [],
  'edited_files': [],
};

/// Instance IDs pair the PID with its kernel start ticks. Check both agent
/// membership and ownership before following procfs links.
Map<String, dynamic> liveSessionActivity(
  ProviderScans scans,
  String command,
  String instance,
  Map<String, dynamic> sessionFacts,
) {
  final match = RegExp(
    r'^([1-9][0-9]{0,9}):([0-9]{1,20})$',
  ).firstMatch(instance);
  final directory = sessionFacts['activity_dir'];
  final reader = sessionFacts['activity_reader'] ?? sessionFacts['reader'];
  if (match == null ||
      !{
        'trajectory-sqlite',
        'pi-files',
        'claude-files',
        'codex-jsonl',
      }.contains(reader) ||
      directory is! String ||
      !directory.startsWith('~/')) {
    return unavailableSessionActivity();
  }
  final pid = int.parse(match[1]!);
  final start = match[2];
  final files = scans.files;
  final root = p.normalize(files.expand(directory));
  if (!p.isWithin(files.identity.home, root) ||
      !aliveSince(pid, 0, files.posix) ||
      processIdentity(pid)?.$3 != start ||
      !(agentInstancePids(scans, {command})[command]?.contains(pid) ?? false)) {
    return unavailableSessionActivity();
  }
  final cwd = cwdOf(pid, files.posix);
  if (reader != 'trajectory-sqlite' && !p.isAbsolute(cwd)) {
    return unavailableSessionActivity();
  }
  final folder = switch (reader) {
    'pi-files' => p.join(root, '--${cwd.substring(1).replaceAll('/', '-')}--'),
    'claude-files' => p.join(
      root,
      cwd.replaceAll(RegExp(r'[^A-Za-z0-9]'), '-'),
    ),
    _ => root,
  };
  final rollout = reader == 'codex-jsonl';
  final candidates = <String>{};
  final names = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.db$',
  );
  bool matches(String path) =>
      (rollout
          ? p.isWithin(root, path) &&
                RegExp(
                  r'^\d{4}/\d{2}/\d{2}/rollout-[^/]+\.jsonl$',
                ).hasMatch(p.relative(path, from: root))
          : p.dirname(path) == folder) &&
      (reader == 'trajectory-sqlite'
          ? names.hasMatch(p.basename(path))
          : path.endsWith('.jsonl') && !p.basename(path).startsWith('.'));
  final own = agentInstancePids(scans, {command})[command] ?? const <int>[];
  for (final entry in files.list('/proc/$pid/fd', limit: 512)) {
    try {
      final target = Link(entry).targetSync();
      if (matches(target)) candidates.add(target);
    } on FileSystemException {
      // The process may close an FD between enumeration and readlink.
    }
  }
  if (candidates.isEmpty &&
      reader != 'trajectory-sqlite' &&
      !own.any((other) => other != pid && cwdOf(other, files.posix) == cwd)) {
    final since = startedAt(pid, files.posix);
    if (since > 0) {
      String two(int number) => number.toString().padLeft(2, '0');
      final now = DateTime.now();
      final directories = rollout
          ? [
              for (final offset in [0, 1])
                if (DateTime(now.year, now.month, now.day - offset)
                    case final day)
                  p.join(root, '${day.year}', two(day.month), two(day.day)),
            ]
          : [folder];
      for (final path in directories.expand(
        (dir) => files.list(dir, limit: 128),
      )) {
        if (!matches(path) ||
            FileSystemEntity.typeSync(path, followLinks: false) !=
                FileSystemEntityType.file) {
          continue;
        }
        final head = files.text(path, limit: 8192, portion: 'head');
        if (head == null) continue;
        String? stamp;
        if (rollout) {
          try {
            final line = const LineSplitter().convert(head).firstOrNull;
            final record = line == null ? null : jsonDecode(line);
            final meta = record is Map ? record['payload'] : null;
            if (record is! Map ||
                record['type'] != 'session_meta' ||
                meta is! Map ||
                meta['cwd'] != cwd ||
                meta['source'] is Map) {
              continue;
            }
            if (record['timestamp'] is String) {
              stamp = record['timestamp'] as String;
            }
          } on FormatException {
            continue;
          }
        } else {
          stamp = RegExp(r'"timestamp"\s*:\s*"([^"]+)"').firstMatch(head)?[1];
        }
        final began = stamp == null ? null : DateTime.tryParse(stamp);
        if (began != null &&
            began.millisecondsSinceEpoch >= (since - 2) * 1000) {
          candidates.add(path);
        }
      }
    }
  }
  if (candidates.length != 1 || processIdentity(pid)?.$3 != start) {
    return unavailableSessionActivity();
  }
  final path = candidates.single;
  final sessionId = p.basenameWithoutExtension(path);
  final Map<String, dynamic> activity;
  if (reader == 'trajectory-sqlite') {
    activity = trajectoryActivity(SqliteNumbers(files), path, sessionId);
  } else {
    final tail = files.text(path, limit: 512 * 1024, portion: 'tail');
    activity = tail == null
        ? unavailableSessionActivity()
        : jsonlSessionActivity(tail, sessionId, rollout: rollout);
  }
  return processIdentity(pid)?.$3 == start
      ? activity
      : unavailableSessionActivity();
}
