import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'agent_halt.dart';
import 'agent_progress.dart';
import 'hyprland.dart' show hyprlandWindowTitle;
import 'live_session_activity.dart';
import 'provider_scans.dart';
import 'scan_files.dart';
import 'pty_sessions.dart' show processIdentity;

Map<String, dynamic> agentActivityReport(
  ProviderScans scans,
  String command,
  String? selected,
  Map<String, dynamic> sessionFacts, {
  ActivityIdle? monitor,
}) {
  final now = DateTime.now().toUtc();
  final posix = scans.files.posix;
  final instances = <Map<String, dynamic>>[];
  for (final pid in agentInstancePids(scans, {command})[command] ?? <int>[]) {
    final start = processIdentity(pid)?.$3;
    if (start != null && aliveSince(pid, 0, posix)) {
      instances.add({
        'id': '$pid:$start',
        'pid': pid,
        'label': '$command · $pid',
      });
    }
  }
  final instance = selected == null
      ? instances.length == 1
            ? instances.single
            : null
      : instances.where((e) => e['id'] == selected).firstOrNull;
  final result = <String, dynamic>{
    'observed_at': now.toIso8601String(),
    'instances': instances,
    'status': instance != null
        ? 'available'
        : selected == null && instances.length > 1
        ? 'choose_instance'
        : 'unavailable',
    'report': null,
  };
  if (instance == null) return result;
  final pid = instance['pid'] as int;
  final id = instance['id'] as String;
  final since = startedAt(pid, posix);
  final rows = scans.processes();
  final byPid = {for (final row in rows) row.pid: row};
  final origin = ancestors(pid, posix);
  final terminal = origin
      .where(
        (ancestor) => RegExp(
          r'^(alacritty|kitty|foot|wezterm|konsole|ghostty|kgx|gnome-terminal)',
        ).hasMatch(byPid[ancestor]?.comm ?? ''),
      )
      .firstOrNull;
  final terminalBirth = terminal == null ? null : processIdentity(terminal);
  final title = terminal == null || terminalBirth == null
      ? null
      : hyprlandWindowTitle(scans.files.identity.environment, terminal);
  final verifiedTitle =
      terminal != null && processIdentity(terminal) == terminalBirth
      ? title
      : null;
  final helpers = <Map<String, dynamic>>[];
  for (final row in rows) {
    if (row.pid == pid || !ancestors(row.pid, posix).contains(pid)) continue;
    final started = startedAt(row.pid, posix);
    if (started < since) continue;
    final executable = p.basename(row.argv.firstOrNull ?? row.comm);
    final test =
        (executable == 'dart' || executable == 'flutter') &&
        row.argv.skip(1).take(3).contains('test');
    helpers.add({
      'pid': row.pid,
      'label': test ? '$executable test' : row.comm,
      'elapsed_ms': (now.millisecondsSinceEpoch - started * 1000).round().clamp(
        0,
        1 << 52,
      ),
    });
  }
  final cwd = cwdOf(pid, posix);
  final directories = {cwd};
  final option = sessionFacts['extra_dir_option'];
  final args = byPid[pid]?.argv ?? const <String>[];
  if (option is String && option.isNotEmpty) {
    for (var i = 1; i < args.length; i++) {
      final value = args[i] == option && i + 1 < args.length
          ? args[++i]
          : args[i].startsWith('$option=')
          ? args[i].substring(option.length + 1)
          : '';
      if (value.isNotEmpty) directories.add(p.normalize(p.join(cwd, value)));
    }
  }
  final timeline = activityTimeline(directories, scans.files, since);
  final details = liveSessionActivity(scans, command, id, sessionFacts);
  final progress = AgentProgress(scans).read(command, id);
  if ('$pid:${processIdentity(pid)?.$3}' != id) {
    result['status'] = 'unavailable';
    return result;
  }
  final phase = activityPhase(
    request: details['request'] != null,
    progress: progress,
    timeline: timeline,
    testing: helpers.any(
      (helper) =>
          helper['label'] == 'dart test' || helper['label'] == 'flutter test',
    ),
  );
  final idle = monitor?.observe(
    id,
    evidence: jsonEncode([
      details,
      progress,
      timeline,
      helpers.map((h) => h['pid']).toList(),
    ]),
    ticks: [
      pid,
      ...helpers.map((helper) => helper['pid'] as int),
    ].map((process) => _cpu(scans.files, process)).toList(),
    active:
        phase != 'finished' &&
        (progress != null ||
            details['request'] != null && (details['answers'] as List).isEmpty),
  );
  result['report'] = {
    'instance': instance,
    'details': details,
    'progress': progress,
    'timeline': timeline,
    'helpers': helpers,
    'origin': {
      'ancestors': [
        for (final parent in origin)
          if (byPid.containsKey(parent))
            {'pid': parent, 'label': byPid[parent]!.comm},
      ],
      'terminal_title': verifiedTitle,
      'close_risk': verifiedTitle == null ? 'unknown' : 'possible',
    },
    'phase': phase,
    'stuck': idle == null ? null : {'idle_ms': idle},
  };
  return result;
}

String activityPhase({
  required bool request,
  required Map<String, dynamic>? progress,
  required List<Map<String, dynamic>> timeline,
  required bool testing,
}) {
  if (progress != null && progress['done'] == progress['total']) {
    return 'finished';
  }
  if (testing) return 'testing';
  if (timeline.isNotEmpty) return timeline.last['kind'] as String;
  return request || progress != null ? 'planning' : 'unknown';
}

int? _cpu(ScanFiles files, int pid) {
  final stat = files.text('/proc/$pid/stat', limit: 4096);
  if (stat == null || !stat.contains(')')) return null;
  final fields = stat
      .substring(stat.lastIndexOf(')') + 1)
      .trim()
      .split(RegExp(r'\s+'));
  if (fields.length < 15) return null;
  final ticks = fields.sublist(11, 15).map(int.tryParse).toList();
  if (ticks.any((tick) => tick == null)) return null;
  return ticks.fold(0, (sum, tick) => sum! + tick!);
}

final class ActivityIdle {
  final _clock = Stopwatch()..start();
  final _samples = <String, (int, int, List<int?>, String)>{};

  int? observe(
    String instance, {
    required String evidence,
    required List<int?> ticks,
    required bool active,
    int? elapsedMs,
  }) {
    final now = elapsedMs ?? _clock.elapsedMilliseconds;
    final previous = _samples.remove(instance);
    _samples.removeWhere((_, sample) => now - sample.$1 > 600000);
    if (!active || ticks.any((tick) => tick == null)) return null;
    final unchanged =
        previous != null &&
        now - previous.$1 <= 15000 &&
        previous.$4 == evidence &&
        previous.$3.length == ticks.length &&
        List.generate(
          ticks.length,
          (i) => ticks[i] == previous.$3[i],
        ).every((v) => v);
    final since = unchanged ? previous.$2 : now;
    _samples[instance] = (now, since, ticks, evidence);
    if (_samples.length > 128) _samples.remove(_samples.keys.first);
    return now - since >= 600000 ? now - since : null;
  }
}

List<Map<String, dynamic>> activityTimeline(
  Set<String> roots,
  ScanFiles scan,
  double since,
) {
  if (since == 0) return [];
  final watch = Stopwatch()..start();
  final files = <String, DateTime>{};
  var visited = 0;
  bool inBudget() => visited < 4000 && watch.elapsedMilliseconds < 250;
  const excluded = {
    '.git',
    'build',
    '.dart_tool',
    '__pycache__',
    'node_modules',
  };
  void walk(Directory directory, int depth) {
    if (depth > 8 || !inBudget()) return;
    try {
      for (final path in scan.list(directory.path, limit: 4000 - visited)) {
        if (!inBudget()) break;
        visited++;
        final name = p.basename(path);
        if (name.startsWith('.') ||
            excluded.contains(name) ||
            name == 'auth.json' ||
            name == 'credentials.json') {
          continue;
        }
        final type = FileSystemEntity.typeSync(path, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          walk(Directory(path), depth + 1);
        } else if (type == FileSystemEntityType.file) {
          final stat = File(path).statSync();
          if (stat.type == FileSystemEntityType.file &&
              stat.modified.millisecondsSinceEpoch >= since * 1000) {
            files[path] = stat.modified.toUtc();
          }
        }
      }
    } on FileSystemException {
      // The project may have disappeared during inspection.
    }
  }

  for (final root in roots.take(16)) {
    if (!p.isAbsolute(root) || root == '/' || root == scan.identity.home) {
      continue;
    }
    try {
      if (Directory(root).resolveSymbolicLinksSync() == root) {
        walk(Directory(root), 0);
      }
    } on FileSystemException {
      // Missing or inaccessible root.
    }
  }
  final entries = files.entries.toList()
    ..sort((a, b) => a.value.compareTo(b.value));
  final groups = <Map<String, dynamic>>[];
  DateTime? last;
  for (final file in entries.skip(
    (entries.length - 120).clamp(0, entries.length),
  )) {
    final basename = p.basename(file.key);
    final kind =
        RegExp(r'(^test_|_test\.|\.test\.|\.spec\.)').hasMatch(basename)
        ? 'testing'
        : 'editing';
    final at = file.value.toIso8601String();
    if (last == null ||
        file.value.difference(last).inMinutes >= 5 ||
        groups.last['kind'] != kind) {
      groups.add({
        'from': at,
        'to': at,
        'kind': kind,
        'files': <Map<String, dynamic>>[],
      });
    }
    groups.last['to'] = at;
    (groups.last['files'] as List).add({
      'path': file.key,
      'at': at,
      'attribution': 'observed',
    });
    last = file.value;
  }
  return groups;
}
