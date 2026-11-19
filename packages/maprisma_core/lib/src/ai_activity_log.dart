import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'agent_activity_report.dart' show activityTimeline;
import 'scan_files.dart';
import 'posix_ffi.dart';
import 'settings.dart';
import 'history_topic.dart';
import 'protocol.dart';

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
  final _pending = <Map<String, dynamic>>[];
  final _active = <String, (DateTime, String?, ActivityUsage?)>{};
  String get _directory => p.join(files.identity.dataDir, 'ai-log');
  static const _maxFile = 2 << 20;
  String get directory => _directory;
  bool get importTopics =>
      settings.value(settings.load(), 'ai_activity_import_topics') == true;
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
    if (!enabled) {
      _active.clear();
      _pending.clear();
    }
    final completed = <Map<String, dynamic>>[..._pending];
    _pending.clear();
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
        final project = cwd == null ? null : label(p.basename(cwd));
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
                ?label(p.basename(file['path'] as String)),
        };
        final topic = timeline.isEmpty
            ? null
            : timeline.any((group) => group['kind'] == 'testing')
            ? 'testing'
            : 'editing';
        completed.add({
          'version': 1,
          'origin': 'live',
          'session': null,
          'superseded_by': null,
          'id': '$source:${start.microsecondsSinceEpoch}',
          'source_kind': source.split(':').first,
          'source': source.split(':').last,
          'model': sameUsage ? label(lastUsage.model) : null,
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
      if (io.stat(lock).uid != io.uid || _flock(lock, 6) != 0) {
        _pending.addAll(completed);
        return;
      }
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
      final grouped = <String, List<Map<String, dynamic>>>{};
      for (final row in completed) {
        final day = activityDay(DateTime.parse(row['started_at']).toLocal());
        if (day.compareTo(cutoff) >= 0) {
          grouped.putIfAbsent(day, () => []).add(row);
        }
      }
      for (final entry in grouped.entries) {
        final path = p.join(_directory, '${entry.key}.jsonl');
        final rows = _rows(files.text(path, limit: _maxFile) ?? '').toList();
        var changed = false;
        for (final row in entry.value) {
          if (rows.any((r) => r['id'] == row['id'])) continue;
          final priorDay = activityDay(
            _date(DateTime.parse(row['started_at']).toLocal(), -1),
          );
          final history = [
            ...rows,
            ..._rows(
              files.text(
                    p.join(_directory, '$priorDay.jsonl'),
                    limit: _maxFile,
                  ) ??
                  '',
            ),
          ];
          for (final old in history) {
            if (_overlaps(row, old)) {
              row['superseded_by'] = old['id'];
              break;
            }
          }
          rows.add(row);
          if (utf8.encode(rows.map(jsonEncode).join('\n')).length + 1 >
              _maxFile) {
            rows.removeLast();
            // The daily storage cap is terminal for this entry, unlike lock
            // contention. Retrying cannot make space before retention pruning.
          } else {
            changed = true;
          }
        }
        if (changed) _writeRows(path, rows);
      }
    } on FileSystemException {
      _pending.addAll(completed.where((r) => !_pending.contains(r)));
      // Retry on the next observation.
    } finally {
      if (lock != null) io.close(lock);
      if (directory != null) io.close(directory);
    }
  }

  static String? label(dynamic value) {
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
        final history = row['origin'] == 'history';
        final session = row['session'] is String
            ? historySession(row['session'])
            : null;
        if (history && session == null) continue;
        final id = history
            ? 'history:$kind:$source:$session:${started.microsecondsSinceEpoch}'
            : '$kind:$source:${started.microsecondsSinceEpoch}';
        yield {
          'version': 1,
          'id': id,
          'origin': history ? 'history' : 'live',
          'session': session,
          'superseded_by':
              row['superseded_by'] is String &&
                  (row['superseded_by'] as String).startsWith('history:')
              ? row['superseded_by']
              : null,
          'source_kind': kind,
          'source': source,
          'model': label(row['model']),
          'project': label(row['project']),
          'topic': sanitizeTopic(row['topic']),
          'started_at': started.toUtc().toIso8601String(),
          'ended_at': ended.toUtc().toIso8601String(),
          'duration_ms': ended.difference(started).inMilliseconds,
          'files': [
            for (final value
                in (row['files'] is List ? row['files'] as List : const [])
                    .take(30))
              ?label(value),
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

  int? _larger(int? old, int? incoming) => old == null
      ? incoming
      : incoming == null || old > incoming
      ? old
      : incoming;

  bool _overlaps(Map live, Map history) {
    if (live['origin'] == 'history' ||
        history['origin'] != 'history' ||
        live['source'] != history['source'] ||
        live['source_kind'] != history['source_kind'] ||
        live['project'] != null &&
            history['project'] != null &&
            live['project'] != history['project']) {
      return false;
    }
    final a = DateTime.parse(live['started_at']),
        b = DateTime.parse(live['ended_at']);
    final hStart = DateTime.parse(history['started_at']),
        hEnd = DateTime.parse(history['ended_at']);
    final left = a.isAfter(hStart) ? a : hStart,
        right = b.isBefore(hEnd) ? b : hEnd;
    final duration = b.difference(a).inMicroseconds;
    return duration == 0
        ? !a.isBefore(hStart) && !a.isAfter(hEnd)
        : right.difference(left).inMicroseconds * 2 > duration;
  }

  void _writeRows(String path, List<Map<String, dynamic>> rows) {
    rows.sort(
      (a, b) =>
          (a['started_at'] as String).compareTo(b['started_at'] as String),
    );
    files.posix.atomicWrite(
      path,
      utf8.encode('${rows.map(jsonEncode).join('\n')}\n'),
    );
  }

  /// Merge only while holding the short day-file lock. Never hold it while
  /// reading agent history. Return written row for cross-day superseding.
  Future<({String status, Map<String, dynamic>? row})> mergeHistory(
    Map<String, dynamic> row, {
    bool leadingPartial = false,
    DateTime? earliestStart,
    DateTime? now,
  }) async {
    final normalized = _rows(jsonEncode(row)).toList();
    if (normalized.isEmpty) return (status: 'skipped', row: null);
    row = normalized.single;
    var targetDay = activityDay(DateTime.parse(row['started_at']).toLocal());
    if (leadingPartial) {
      final (today, keep, from, through) = range({}, now: now);
      Map<String, dynamic>? prior;
      for (final (_, candidate) in retainedRows(today, keep, from, through)) {
        if (candidate['origin'] == 'history' &&
            candidate['source'] == row['source'] &&
            candidate['source_kind'] == row['source_kind'] &&
            candidate['session'] == row['session'] &&
            !DateTime.parse(
              candidate['ended_at'],
            ).isBefore(DateTime.parse(row['started_at'])) &&
            !DateTime.parse(
              candidate['started_at'],
            ).isAfter(DateTime.parse(row['ended_at']))) {
          prior = candidate;
          break;
        }
      }
      if (prior == null ||
          earliestStart != null &&
              DateTime.parse(
                prior['started_at'],
              ).toLocal().isBefore(earliestStart)) {
        return (status: 'skipped', row: null);
      }
      targetDay = activityDay(DateTime.parse(prior['started_at']).toLocal());
    }
    final io = files.posix;
    final dir = io.privateDirectory(_directory);
    int? lock;
    try {
      lock = io.openAt(
        dir,
        '.lock',
        2 | 0x40 | Posix.noFollow | Posix.nonBlock,
        0x180,
      );
      if (io.stat(lock).uid != io.uid) throw ServiceError('operation_failed');
      final waiting = Stopwatch()..start();
      while (!io.tryLockExclusive(lock)) {
        if (waiting.elapsedMilliseconds > 5000) {
          throw ServiceError('import_running');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (!enabled) throw ServiceError('log_off');
      final start = DateTime.parse(row['started_at'] as String).toLocal();
      final end = DateTime.parse(row['ended_at'] as String).toLocal();
      final startDay = targetDay, endDay = activityDay(end);
      final path = p.join(_directory, '$startDay.jsonl');
      final rows = _rows(files.text(path, limit: _maxFile) ?? '').toList();
      final match = rows.indexWhere(
        (r) =>
            r['id'] == row['id'] ||
            leadingPartial &&
                r['origin'] == 'history' &&
                r['source'] == row['source'] &&
                r['session'] == row['session'] &&
                !DateTime.parse(r['ended_at']).isBefore(start) &&
                !DateTime.parse(r['started_at']).isAfter(end),
      );
      String result = 'added';
      if (match >= 0) {
        final old = rows[match];
        final mergedFiles = {
          ...old['files'] as List,
          ...row['files'] as List,
        }.take(30).toList();
        final grows =
            end.isAfter(DateTime.parse(old['ended_at'])) ||
            !leadingPartial &&
                (row['tokens_in'] as int? ?? 0) >
                    (old['tokens_in'] as int? ?? 0) ||
            !leadingPartial &&
                (row['tokens_out'] as int? ?? 0) >
                    (old['tokens_out'] as int? ?? 0) ||
            mergedFiles.length > (old['files'] as List).length;
        if (!grows) return (status: 'unchanged', row: old);
        row = {
          ...row,
          'id': old['id'],
          'started_at': old['started_at'],
          'ended_at': DateTime.parse(old['ended_at']).isAfter(end)
              ? old['ended_at']
              : row['ended_at'],
          'tokens_in': leadingPartial
              ? old['tokens_in']
              : _larger(old['tokens_in'] as int?, row['tokens_in'] as int?),
          'tokens_out': leadingPartial
              ? old['tokens_out']
              : _larger(old['tokens_out'] as int?, row['tokens_out'] as int?),
          for (final field in ['topic', 'model', 'project'])
            field: leadingPartial ? old[field] : row[field] ?? old[field],
          'files': mergedFiles,
        };
        row['duration_ms'] = DateTime.parse(
          row['ended_at'],
        ).difference(DateTime.parse(row['started_at'])).inMilliseconds;
        rows[match] = row;
        result = 'updated';
      } else {
        if (leadingPartial) return (status: 'skipped', row: null);
        rows.add(row);
      }
      if (utf8.encode(rows.map(jsonEncode).join('\n')).length + 1 > _maxFile) {
        return (status: 'skipped', row: null);
      }
      bool supersede(List<Map<String, dynamic>> target) {
        var changed = false;
        for (final live in target) {
          if (_overlaps(live, row) && live['superseded_by'] != row['id']) {
            live['superseded_by'] = row['id'];
            changed = true;
          }
        }
        return changed;
      }

      supersede(rows);
      if (utf8.encode(rows.map(jsonEncode).join('\n')).length + 1 > _maxFile) {
        return (status: 'skipped', row: null);
      }
      _writeRows(path, rows);
      if (endDay != startDay) {
        final other = p.join(_directory, '$endDay.jsonl');
        final otherRows = _rows(
          files.text(other, limit: _maxFile) ?? '',
        ).toList();
        if (supersede(otherRows) &&
            utf8.encode(otherRows.map(jsonEncode).join('\n')).length + 1 <=
                _maxFile) {
          _writeRows(other, otherRows);
        }
      }
      return (status: result, row: row);
    } finally {
      if (lock != null) io.close(lock);
      io.close(dir);
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
        if (row['superseded_by'] == null) yield (local, row);
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
