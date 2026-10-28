import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'py_time.dart';
import 'py_values.dart';
import 'scan_files.dart';

/// Python existing_ai.mounts: local data disks from mountinfo, without the
/// system folders, the last entry of a mount point winning in first order.
const _localFilesystems = {
  'ext4', 'ext3', 'ext2', 'btrfs', 'xfs', 'f2fs', 'zfs', 'ntfs3', 'exfat', //
  'vfat',
};
const _excluded = [
  '/boot', '/proc', '/sys', '/dev', '/run', '/tmp', '/var', '/usr', '/etc', //
];

List<Map<String, String>> localMounts(String text) {
  final result = <String, Map<String, String>>{};
  for (final line in const LineSplitter().convert(text)) {
    final fields = line
        .split(RegExp(r'\s+'))
        .where((f) => f.isNotEmpty)
        .toList();
    final sep = fields.indexOf('-');
    if (sep < 0 || sep + 1 >= fields.length || fields.length < 5) continue;
    final kind = fields[sep + 1];
    final path = fields[4].replaceAllMapped(
      RegExp(r'\\([0-7]{3})'),
      (m) => String.fromCharCode(int.parse(m[1]!, radix: 8)),
    );
    if (!_localFilesystems.contains(kind) ||
        path == '/' ||
        !path.startsWith('/') ||
        _excluded.any((e) => path == e || p.isWithin(e, path))) {
      continue;
    }
    result[path] = {
      'path': path,
      'filesystem': kind,
      'identity': '${fields[0]}:${fields[2]}',
    };
  }
  return result.values.toList();
}

/// The System Map's mount signature, json.dumps(sorted((path, identity))).
String mountSignature(List<Map<String, String>> mounts) {
  final rows = [for (final m in mounts) (m['path']!, m['identity']!)]
    ..sort((a, b) {
      final c = pyCompare(a.$1, b.$1);
      return c != 0 ? c : pyCompare(a.$2, b.$2);
    });
  return pyJsonDumps([
    for (final r in rows) [r.$1, r.$2],
  ]);
}

/// Python smart_check.categories over plugin_ai's shared run log: the runs of
/// the last 30 days per (plugin, task), the most recently used group first.
final class UsageReader {
  UsageReader(this.files);
  final ScanFiles files;
  static const days = 30, maxCategories = 30, maxLog = 2 * 1024 * 1024;
  static const tasks = {
    'mcp-updates': 'MCP server updates',
    'agent-setup': 'Looking up new agents',
    'setup-analysis': 'Setup analysis',
    'mcp-update': 'MCP server update tasks',
    'fix': 'Fixes after a failed install',
    'smart-fix': 'Fixes from Smart Check',
    'model-advice': 'Model advice',
    'setup-help': 'Setup help from an agent',
  };

  String get logFile =>
      '${files.identity.root('XDG_STATE_HOME', '.local/state')}/omarchy-plugin-ai/runs.json';

  List<Map> runs() {
    final data = files.bytes(logFile, limit: maxLog);
    if (data == null) return [];
    try {
      final value = jsonDecode(utf8.decode(data, allowMalformed: true));
      final found = value is Map ? value['runs'] : null;
      return found is List ? found.whereType<Map>().toList() : [];
    } on FormatException {
      return [];
    }
  }

  /// plugin_ai._when: datetime.fromisoformat(str(run["when"])), local naive.
  static DateTime? when(dynamic value) => pyFromIsoformat(pyStr(value));

  /// str(run.get(key, "")): a present null is "None", a missing key "".
  static String _get(Map run, String key) =>
      run.containsKey(key) ? pyStr(run[key]) : '';

  static int _int(dynamic v) => v is int && v > 0 ? v : 0;
  static int? tokensOf(Map run) => run.containsKey('input')
      ? _int(run['input']) + _int(run['cached']) + _int(run['output'])
      : null;

  Map<String, dynamic> snapshot({DateTime? now}) {
    now ??= DateTime.now();
    final groups = <(String, String), List<Map>>{};
    for (final run in runs()) {
      final at = when(run['when']);
      if (at == null || now.difference(at) > const Duration(days: days)) {
        continue;
      }
      groups
          .putIfAbsent((_get(run, 'plugin'), _get(run, 'task')), () => [])
          .add(run);
    }
    final found = [
      for (final e in groups.entries)
        (e.key, e.value.reversed.toList(), e.value),
    ];
    mergeSort(
      found,
      compare: (a, b) =>
          pyCompare(pyStr(b.$2.first['when']), pyStr(a.$2.first['when'])),
    );
    return {
      'categories': [
        for (final (key, newest, runs) in found.take(maxCategories))
          {
            'plugin': key.$1,
            'task': tasks[key.$2] ?? key.$2,
            'runs': newest.length,
            'entries': [
              for (final r in newest.take(100))
                {
                  'when': _get(r, 'when'),
                  'agent': _get(r, 'agent'),
                  'ok': r['ok'] == true,
                  'tokens': tokensOf(r),
                },
            ],
            'totals': _totals(runs, now),
          },
      ],
    };
  }

  Map<String, dynamic> _totals(List<Map> runs, DateTime now) {
    var count = 0, ok = 0, today = 0, tokens = 0, unknown = 0;
    var cost = 0.0;
    for (final run in runs) {
      final at = when(run['when']);
      if (at == null || now.difference(at) > const Duration(days: days)) {
        continue;
      }
      count++;
      if (pyTruthy(run['ok'])) ok++;
      final used = tokensOf(run);
      if (used == null) {
        unknown++;
        continue;
      }
      tokens += used;
      if (at.year == now.year && at.month == now.month && at.day == now.day) {
        today += used;
      }
      final value = run['cost'];
      if (value is num) cost += value.toDouble();
      if (value is bool) cost += value ? 1.0 : 0.0;
    }
    return {
      'runs': count,
      'ok': ok,
      'tokens_today': today,
      'tokens': tokens,
      'cost': cost,
      'unknown': unknown,
    };
  }
}
