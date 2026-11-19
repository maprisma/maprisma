import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'agent_activity_report.dart' show activityTimeline;
import 'scan_files.dart';
import 'posix_ffi.dart';
import 'settings.dart';

String activityDay(DateTime at) =>
    '${at.year.toString().padLeft(4, '0')}-'
    '${at.month.toString().padLeft(2, '0')}-'
    '${at.day.toString().padLeft(2, '0')}';

DateTime _date(DateTime at, int offset) =>
    DateTime(at.year, at.month, at.day + offset);

typedef _Totals = (int, int, int, int, int);

typedef ActivityUsage = ({
  String session,
  String? model,
  int input,
  int output,
});

final class AiActivityLog {
  AiActivityLog(this.files, this.settings);
  final ScanFiles files;
  final SettingsStore settings;
  final _active = <String, (DateTime, String?, ActivityUsage?)>{};
  String get _directory => p.join(files.identity.dataDir, 'ai-log');
  static const _maxFile = 2 << 20;
  static const _pageSize = 100;
  static final _day = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  static final _source = RegExp(r'^(agent|runtime):[a-z0-9][a-z0-9_.-]{0,63}$');
  static final _flock = DynamicLibrary.open(
    'libc.so.6',
  ).lookupFunction<Int Function(Int, Int), int Function(int, int)>('flock');

  void observe(
    Set<String> active, {
    Map<String, String> workingDirectories = const {},
    ActivityUsage? Function(String source)? usageFor,
    DateTime? observedAt,
  }) {
    final now = observedAt ?? DateTime.now();
    final options = settings.load();
    final keep = settings.value(options, 'ai_activity_log_days') as int;
    final cutoff = activityDay(_date(now.toLocal(), 1 - keep));
    final enabled = settings.value(options, 'ai_activity_log') == true;
    if (!enabled) _active.clear();
    final completed = <Map<String, dynamic>>[];
    if (enabled) {
      for (final source in _active.keys.toList()) {
        if (active.contains(source)) continue;
        final (start, cwd, usage) = _active.remove(source)!;
        final lastUsage = usage == null ? null : usageFor?.call(source);
        final sameUsage =
            lastUsage != null &&
            lastUsage.session == usage!.session &&
            lastUsage.input >= usage.input &&
            lastUsage.output >= usage.output;
        if (now.isBefore(start)) continue;
        final project = cwd == null ? null : _label(p.basename(cwd));
        final timeline = cwd == null
            ? <Map<String, dynamic>>[]
            : activityTimeline(
                {cwd},
                files,
                start.millisecondsSinceEpoch / 1000,
              );
        final changed = <String>{
          for (final group in timeline)
            for (final file in group['files'] as List)
              if (DateTime.parse(file['at'] as String).isBefore(now))
                ?_label(p.basename(file['path'] as String)),
        };
        final topic = timeline.isEmpty
            ? null
            : timeline.any((group) => group['kind'] == 'testing')
            ? 'testing'
            : 'editing';
        completed.add({
          'version': 1,
          'id': '$source:${start.microsecondsSinceEpoch}',
          'source_kind': source.split(':').first,
          'source': source.split(':').last,
          'model': sameUsage ? _label(lastUsage.model) : null,
          'project': project,
          'topic': topic,
          'started_at': start.toUtc().toIso8601String(),
          'ended_at': now.toUtc().toIso8601String(),
          'duration_ms': now.difference(start).inMilliseconds,
          'files': changed.take(30).toList(),
          'helpers': <String>[],
          'tokens_in': sameUsage ? lastUsage.input - usage.input : null,
          'tokens_out': sameUsage ? lastUsage.output - usage.output : null,
          'cost': null,
          'outcome': 'unknown',
        });
      }
      for (final source in active.where(_source.hasMatch)) {
        _active.putIfAbsent(
          source,
          () => (now, workingDirectories[source], usageFor?.call(source)),
        );
      }
    }
    if (completed.isEmpty && !Directory(_directory).existsSync()) return;
    final io = files.posix;
    int? directory;
    int? lock;
    try {
      directory = io.privateDirectory(_directory);
      lock = io.openAt(
        directory,
        '.lock',
        2 | 0x40 | Posix.noFollow | Posix.nonBlock,
        0x180,
      );
      if (io.stat(lock).uid != io.uid || _flock(lock, 6) != 0) return;
      for (final path in files.list(_directory, limit: 1024)) {
        final name = p.basename(path);
        if (!name.endsWith('.jsonl')) continue;
        final day = p.basenameWithoutExtension(name);
        if (_day.hasMatch(day) &&
            day.compareTo(cutoff) < 0 &&
            io.lstatFull(path, follow: false)?.uid == io.uid &&
            FileSystemEntity.typeSync(path, followLinks: false) ==
                FileSystemEntityType.file) {
          io.unlinkAt(directory, name);
        }
      }
      if (completed.isEmpty ||
          settings.value(settings.load(), 'ai_activity_log') != true) {
        return;
      }
      final path = p.join(_directory, '${activityDay(now.toLocal())}.jsonl');
      final previous = files.text(path, limit: _maxFile) ?? '';
      final known = _rows(previous).map((e) => e['id']).toSet();
      final lines = completed
          .where((e) => !known.contains(e['id']))
          .map(jsonEncode);
      final records = [..._rows(previous).map(jsonEncode), ...lines];
      final body = utf8.encode("${records.join('\n')}\n");
      if (body.length <= _maxFile) io.atomicWrite(path, body);
    } on FileSystemException {
      // A missing or unavailable local log never interrupts the map.
    } finally {
      if (lock != null) io.close(lock);
      if (directory != null) io.close(directory);
    }
  }

  static String? _label(dynamic value) {
    if (value is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$').hasMatch(value) ||
        RegExp(
          r'(^[a-f0-9]{24,}$|(?:^|[._-])(?:secret|token|credentials?|auth|password|apikey|key)(?:[._-]|$)|^sk-[A-Za-z0-9_-]+)',
          caseSensitive: false,
        ).hasMatch(value)) {
      return null;
    }
    return value;
  }

  static int? _tokens(dynamic value) =>
      value is int && value >= 0 && value <= 1 << 45 ? value : null;

  Iterable<Map<String, dynamic>> _rows(String text) sync* {
    for (final line in const LineSplitter().convert(text)) {
      try {
        final row = jsonDecode(line);
        if (row is! Map<String, dynamic> || row['version'] != 1) continue;
        final kind = row['source_kind'];
        final source = row['source'];
        final start = row['started_at'];
        final end = row['ended_at'];
        final duration = row['duration_ms'];
        if (kind is! String ||
            source is! String ||
            !_source.hasMatch('$kind:$source') ||
            start is! String ||
            end is! String ||
            duration is! int ||
            duration < 0) {
          continue;
        }
        final started = DateTime.tryParse(start);
        final ended = DateTime.tryParse(end);
        if (started == null || ended == null || ended.isBefore(started)) {
          continue;
        }
        yield {
          'version': 1,
          'id': '$kind:$source:${started.microsecondsSinceEpoch}',
          'source_kind': kind,
          'source': source,
          'model': _label(row['model']),
          'project': _label(row['project']),
          'topic': {'editing', 'testing'}.contains(row['topic'])
              ? row['topic']
              : null,
          'started_at': started.toUtc().toIso8601String(),
          'ended_at': ended.toUtc().toIso8601String(),
          'duration_ms': ended.difference(started).inMilliseconds,
          'files': [
            for (final value
                in (row['files'] is List ? row['files'] as List : const [])
                    .take(30))
              ?_label(value),
          ],
          'helpers': <String>[],
          'tokens_in': _tokens(row['tokens_in']),
          'tokens_out': _tokens(row['tokens_out']),
          'cost': null,
          'outcome': 'unknown',
        };
      } on FormatException {
        // Ignore a partial or invalid line and continue with the next one.
      }
    }
  }

  bool get enabled =>
      settings.value(settings.load(), 'ai_activity_log') == true;

  (DateTime, int, String, String) range(
    Map<String, dynamic> params, {
    DateTime? now,
  }) {
    final today = (now ?? DateTime.now()).toLocal();
    final keep = settings.value(settings.load(), 'ai_activity_log_days') as int;
    final oldest = activityDay(_date(today, 1 - keep));
    final latest = activityDay(today);
    String day(String name, String fallback) {
      final value = params[name] ?? fallback;
      if (value is! String ||
          !_day.hasMatch(value) ||
          DateTime.tryParse(value) == null ||
          activityDay(DateTime.parse(value)) != value) {
        throw const FormatException('Expected a calendar day');
      }
      return value;
    }

    final from = day('from_day', oldest);
    final through = day('through_day', latest);
    if (from.compareTo(through) > 0) {
      throw const FormatException('Invalid activity range');
    }
    return (today, keep, from, through);
  }

  Iterable<(DateTime, Map<String, dynamic>)> retainedRows(
    DateTime today,
    int keep,
    String from,
    String through,
  ) sync* {
    for (var offset = 0; offset < keep; offset++) {
      final local = _date(today, -offset);
      final date = activityDay(local);
      if (date.compareTo(from) < 0 || date.compareTo(through) > 0) continue;
      final text =
          files.text(p.join(_directory, '$date.jsonl'), limit: _maxFile) ?? '';
      for (final row in _rows(text).toList().reversed) {
        yield (local, row);
      }
    }
  }

  Map<String, dynamic> report(Map<String, dynamic> params, {DateTime? now}) {
    final (today, keep, from, through) = range(params, now: now);
    final cursor = params['cursor'] ?? 0;
    if (cursor is! int || cursor < 0) {
      throw const FormatException('Invalid activity range');
    }
    final page = <Map<String, dynamic>>[];
    final sources = <String, _Totals>{};
    final projects = <String, _Totals>{};
    final days = <String, _Totals>{};
    final weeks = <String, _Totals>{};
    void add(
      Map<String, _Totals> totals,
      String key,
      Map<String, dynamic> row,
    ) {
      final (count, elapsed, input, output, unknown) =
          totals[key] ?? (0, 0, 0, 0, 0);
      final incoming = row['tokens_in'] as int?;
      final outgoing = row['tokens_out'] as int?;
      totals[key] = (
        count + 1,
        elapsed + (row['duration_ms'] as int),
        input + (incoming ?? 0),
        output + (outgoing ?? 0),
        unknown + (incoming == null || outgoing == null ? 1 : 0),
      );
    }

    var count = 0;
    for (final (local, row) in retainedRows(today, keep, from, through)) {
      final date = activityDay(local);
      add(sources, '${row['source_kind']}:${row['source']}', row);
      final project = row['project'];
      if (project is String) add(projects, project, row);
      add(days, date, row);
      add(weeks, activityDay(_date(local, 1 - local.weekday)), row);
      if (count >= cursor && page.length < _pageSize) page.add(row);
      count++;
    }
    List<Map<String, dynamic>> totals(Map<String, _Totals> values) => [
      for (final e in values.entries)
        {
          'key': e.key,
          'count': e.value.$1,
          'duration_ms': e.value.$2,
          'tokens_in': e.value.$5 == e.value.$1 ? null : e.value.$3,
          'tokens_out': e.value.$5 == e.value.$1 ? null : e.value.$4,
          'usage_unknown': e.value.$5,
        },
    ];
    return {
      'from_day': from,
      'through_day': through,
      'entries': page,
      'next_cursor': count > cursor + page.length ? cursor + page.length : null,
      'by_source': totals(sources),
      'by_project': totals(projects),
      'by_day': totals(days),
      'by_week': totals(weeks),
    };
  }
}

/// Standalone history output. JSON preserves all fields and the page cursor.
String formatActivityLog(Map<String, dynamic> report, {required bool json}) {
  if (json) return const JsonEncoder.withIndent('  ').convert(report);
  String duration(Map row) =>
      Duration(milliseconds: row['duration_ms'] as int).toString();
  return [
    "${report['from_day']} – ${report['through_day']}",
    for (final row in report['entries'] as List)
      [
        "${row['started_at']}",
        "${row['source_kind']}:${row['source']}",
        if (row['project'] is String) "${row['project']}",
        if (row['topic'] is String) "${row['topic']}",
        duration(row as Map),
      ].join(' · '),
    for (final (key, label) in const [
      ('by_source', 'By agent or runtime'),
      ('by_project', 'By project'),
      ('by_day', 'By day'),
      ('by_week', 'By week'),
    ]) ...[
      '',
      label,
      for (final row in report[key] as List)
        "${row['key']} · ${row['count']} · ${duration(row as Map)} · "
            "tokens ${row['tokens_in'] ?? '?'}/${row['tokens_out'] ?? '?'} "
            "(${row['usage_unknown']} unknown)",
    ],
    if (report['next_cursor'] != null) "Next cursor: ${report['next_cursor']}",
  ].join('\n');
}
