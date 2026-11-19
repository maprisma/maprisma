import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'adapters.dart';
import 'ai_activity_log.dart';
import 'history_topic.dart';
import 'posix_ffi.dart';
import 'protocol.dart';
import 'reports_sqlite.dart';
import 'scan_files.dart';
import 'session_readers.dart' show epoch, projectFolder;
import 'sqlite_numbers.dart' show committedImage, maxDatabaseBytes;
import 'trajectory_activity.dart' show trajectoryText;

const historyForms = {
  'claude-files',
  'codex-jsonl',
  'trajectory-sqlite',
  'pi-files',
};
String historyForm(Adapter a) =>
    '${a.table('sessions')['activity_reader'] ?? a.table('sessions')['reader'] ?? ''}';

String? historyRoot(Adapter a, ScanFiles files) {
  final configured = a.table('sessions')['activity_dir'];
  if (configured is String) return files.expand(configured);
  for (final entry in a.facts['activity'] as List? ?? const []) {
    if (entry is String && files.exists(entry)) return files.expand(entry);
  }
  return null;
}

List<Map<String, dynamic>> historySources(
  Iterable<Adapter> adapters,
  ScanFiles files,
  Set<String> installed,
) => [
  for (final a in adapters)
    if (a.table('sessions').isNotEmpty &&
        (installed.contains(a.command) ||
            historyRoot(a, files) != null &&
                files.exists(historyRoot(a, files)!)))
      {
        'source': 'agent:${a.command}',
        'name': a.name,
        'supported': historyForms.contains(historyForm(a)),
      },
];

/// Open a committed image in memory, with typed failures and no source-side
/// SQLite connection. A changing source is retried by a later import.
({String status, ReportsSqlite? database}) openHistoryDatabase(
  ScanFiles files,
  String path, {
  ReportsSqlite Function(Uint8List)? open,
  Duration budget = const Duration(seconds: 60),
}) {
  if (!files.exists(path)) return (status: 'missing', database: null);
  String stamp(String file) => '${files.posix.lstatFull(file)?.signature}';
  final before = stamp(path);
  final walBefore = stamp('$path-wal');
  try {
    final base = files.bytes(path, limit: maxDatabaseBytes);
    final wal = files.exists('$path-wal')
        ? files.bytes('$path-wal', limit: maxDatabaseBytes)
        : null;
    if (base == null || files.exists('$path-wal') && wal == null) {
      return (status: 'unavailable', database: null);
    }
    if (before != stamp(path) || walBefore != stamp('$path-wal')) {
      return (status: 'unavailable', database: null);
    }
    final image = committedImage(
      Uint8List.fromList(base),
      wal == null ? null : Uint8List.fromList(wal),
    );
    final db = (open ?? ReportsSqlite.snapshot)(image);
    try {
      db.restrictReads(budget);
      return (status: 'ok', database: db);
    } catch (_) {
      db.close();
      rethrow;
    }
  } on FormatException {
    return (status: 'corrupt', database: null);
  } on ServiceError catch (e) {
    return (
      status: e.code == 'reports_db_corrupt' ? 'corrupt' : 'unavailable',
      database: null,
    );
  } on ArgumentError {
    return (status: 'unavailable', database: null);
  } on FileSystemException {
    return (status: 'unavailable', database: null);
  }
}

/// Import owns only ai-log/. Agent files are opened without following their
/// final symlink and are never handed to a writable SQLite connection.
final class HistoryImporter {
  HistoryImporter(this.log, this.adapters, this.installed, {DateTime? now})
    : now = now ?? DateTime.now();
  final AiActivityLog log;
  final List<Adapter> adapters;
  final Set<String> installed;
  final DateTime now;
  ScanFiles get files => log.files;
  static const maxSessions = 2000, wholeBytes = 64 << 20, tailBytes = 8 << 20;
  final _overall = Stopwatch();
  late Stopwatch _source;
  bool get _expired =>
      _overall.elapsedMilliseconds >= 180000 ||
      _source.elapsedMilliseconds >= 60000;

  void validate() {
    if (!log.enabled) throw ServiceError('log_off');
    if (log.settings.value(log.settings.load(), 'ai_activity_import') != true) {
      throw ServiceError('import_off');
    }
  }

  void _raiseStatus(Map<String, dynamic> result, String status) {
    const severity = {'ok': 0, 'partial': 1, 'unavailable': 2, 'corrupt': 3};
    if (severity[status]! > severity[result['status']]!) {
      result['status'] = status;
    }
  }

  bool throttled() {
    final data = files.json(p.join(log.directory, '.import-state.json'));
    final at = DateTime.tryParse('${data['completed_at']}');
    final elapsed = at == null ? null : now.difference(at);
    return elapsed != null &&
        !elapsed.isNegative &&
        elapsed < const Duration(hours: 1);
  }

  Future<Map<String, dynamic>> run({
    int? days,
    bool auto = false,
    void Function(String)? progress,
  }) async {
    validate();
    final keep =
        log.settings.value(log.settings.load(), 'ai_activity_log_days') as int;
    if (days != null && (days < 1 || days > keep)) {
      throw ServiceError('invalid_request');
    }
    final io = files.posix;
    final dir = io.privateDirectory(log.directory);
    int? lock;
    try {
      lock = io.openAt(
        dir,
        '.import.lock',
        2 | 0x40 | Posix.noFollow | Posix.nonBlock,
        0x180,
      );
      if (io.stat(lock).uid != io.uid) throw ServiceError('operation_failed');
      if (!io.tryLockExclusive(lock)) throw ServiceError('import_running');
      validate();
      if (auto && throttled()) return {'skipped': 'throttled'};
      _overall.start();
      final local = now.toLocal();
      final cutoff = DateTime(
        local.year,
        local.month,
        local.day + 1 - (days ?? keep),
      );
      final results = <Map<String, dynamic>>[];
      for (final source in historySources(adapters, files, installed)) {
        _source = Stopwatch()..start();
        progress?.call(source['name'] as String);
        final a = adapters.firstWhere(
          (a) => 'agent:${a.command}' == source['source'],
        );
        final result = <String, dynamic>{
          ...source,
          'sessions': 0,
          'added': 0,
          'updated': 0,
          'skipped': 0,
          'status': 'ok',
        }..remove('supported');
        results.add(result);
        if (source['supported'] != true) {
          result['status'] = 'unsupported';
          continue;
        }
        final root = historyRoot(a, files);
        if (root == null || !files.exists(root)) {
          _raiseStatus(result, 'unavailable');
          continue;
        }
        final candidates = _candidates(root, historyForm(a), cutoff);
        if (candidates.$2) _raiseStatus(result, 'partial');
        for (final path in candidates.$1) {
          if (_expired) {
            _raiseStatus(result, 'partial');
            break;
          }
          validate();
          try {
            final parsed = historyForm(a) == 'trajectory-sqlite'
                ? _trajectory(path)
                : _json(path, historyForm(a));
            if (parsed.subagent) {
              result['skipped']++;
              continue;
            }
            result['sessions']++;
            if (parsed.partial) _raiseStatus(result, 'partial');
            for (final span in parsed.spans) {
              if (_expired) {
                _raiseStatus(result, 'partial');
                break;
              }
              if (span.start.toLocal().isBefore(cutoff) ||
                  now.difference(span.end) < const Duration(minutes: 2)) {
                result['skipped']++;
                continue;
              }
              final session = historySession(parsed.session);
              final row = <String, dynamic>{
                'version': 1,
                'id':
                    'history:agent:${a.command}:$session:${span.start.microsecondsSinceEpoch}',
                'origin': 'history',
                'session': session,
                'superseded_by': null,
                'source_kind': 'agent',
                'source': a.command,
                'project': _short(projectFolder(parsed.cwd)),
                'model': AiActivityLog.label(span.model),
                'topic': log.importTopics
                    ? sanitizeTopic(span.request) ?? span.heuristic
                    : span.heuristic,
                'started_at': span.start.toUtc().toIso8601String(),
                'ended_at': span.end.toUtc().toIso8601String(),
                'duration_ms': span.end.difference(span.start).inMilliseconds,
                'files': span.edits
                    .map((f) => _short(f))
                    .whereType<String>()
                    .toSet()
                    .take(30)
                    .toList(),
                'helpers': <String>[],
                'tokens_in': span.input,
                'tokens_out': span.output,
                'cost': null,
                'outcome': 'unknown',
              };
              final merged = await log.mergeHistory(
                row,
                leadingPartial: span.leadingPartial,
                earliestStart: cutoff,
                now: now,
              );
              switch (merged.status) {
                case 'added':
                  result['added']++;
                case 'updated':
                  result['updated']++;
                case 'skipped':
                  result['skipped']++;
                  _raiseStatus(result, 'partial');
              }
            }
          } on ServiceError catch (e) {
            if (['log_off', 'import_off', 'import_running'].contains(e.code)) {
              rethrow;
            }
            _raiseStatus(
              result,
              _expired
                  ? 'partial'
                  : e.code == 'reports_db_corrupt'
                  ? 'corrupt'
                  : 'unavailable',
            );
          } on FormatException {
            _raiseStatus(result, 'corrupt');
          } on FileSystemException {
            _raiseStatus(result, 'unavailable');
          } on ArgumentError {
            _raiseStatus(result, 'unavailable');
          }
          await Future<void>.delayed(Duration.zero);
        }
      }
      validate();
      io.atomicWrite(
        p.join(log.directory, '.import-state.json'),
        utf8.encode(
          jsonEncode({'completed_at': now.toUtc().toIso8601String()}),
        ),
      );
      return {
        'sources': results,
        for (final key in ['added', 'updated', 'skipped'])
          key: results.fold<int>(0, (n, r) => n + (r[key] as int)),
      };
    } finally {
      if (lock != null) io.close(lock);
      io.close(dir);
    }
  }

  String? _short(String path) {
    if (path.isEmpty) return null;
    return AiActivityLog.label(p.basename(path));
  }

  (List<String>, bool) _candidates(String root, String form, DateTime cutoff) {
    final found = <String>[];
    var partial = false, visited = 0;
    void walk(String path, int depth) {
      if (_expired || visited++ >= 20000) {
        partial = true;
        return;
      }
      final info = files.posix.lstatFull(path);
      if (info == null || info.uid != files.posix.uid) return;
      if (info.mode & 0xf000 == 0x4000) {
        if (depth > (form == 'claude-files' ? 1 : 12)) return;
        for (final child in files.list(path, limit: 4000)) {
          if (p.basename(child) == 'subagents') continue;
          walk(child, depth + 1);
        }
      } else if (info.mode & 0xf000 == 0x8000) {
        final wal = form == 'trajectory-sqlite'
            ? files.posix.lstatFull('$path-wal')
            : null;
        final modified = wal != null && wal.sec > info.sec ? wal.sec : info.sec;
        if (DateTime.fromMillisecondsSinceEpoch(
          modified * 1000,
        ).isBefore(cutoff)) {
          return;
        }
        final name = p.basename(path);
        final eligible = form == 'trajectory-sqlite'
            ? name.endsWith('.db')
            : name.endsWith('.jsonl') &&
                  !name.startsWith('agent-') &&
                  (form != 'codex-jsonl' || name.startsWith('rollout-'));
        if (eligible) {
          if (found.length < maxSessions) {
            found.add(path);
          } else {
            partial = true;
          }
        }
      }
    }

    walk(root, 0);
    found.sort(
      (a, b) => (files.posix.lstatFull(b)?.sec ?? 0).compareTo(
        files.posix.lstatFull(a)?.sec ?? 0,
      ),
    );
    return (found, partial);
  }

  _Parsed _json(String path, String form) {
    final io = files.posix;
    final fd = io.openAt(-100, path, Posix.noFollow | Posix.nonBlock);
    try {
      final info = io.stat(fd);
      if (info.uid != io.uid || info.mode & 0xf000 != 0x8000) {
        throw const FormatException('Unsafe history file');
      }
      final size = io.statFull(fd).size;
      final partial = size > wholeBytes;
      final head = partial
          ? io.readAt(fd, 0, 65536)
          : io.readDescriptor(fd, wholeBytes);
      final tail = partial ? io.readAt(fd, size - tailBytes, tailBytes) : null;
      final parsed = _Parsed(
        p.basenameWithoutExtension(path),
        partial: partial,
      );
      List<Map<String, dynamic>> records(List<int> bytes, {bool cut = false}) {
        var text = utf8.decode(bytes, allowMalformed: true);
        if (cut) {
          final newline = text.indexOf('\n');
          text = newline < 0 ? '' : text.substring(newline + 1);
        }
        final result = <Map<String, dynamic>>[];
        for (final line in const LineSplitter().convert(text)) {
          if (_expired) {
            parsed.partial = true;
            break;
          }
          if (line.length > 4 << 20) {
            parsed.partial = true;
            continue;
          }
          try {
            final r = jsonDecode(line);
            if (r is Map<String, dynamic>) result.add(r);
          } on FormatException {
            parsed.partial = true;
          }
        }
        return result;
      }

      final headRows = records(head);
      for (final r in headRows) {
        if (r['type'] == 'session_meta') {
          final meta = r['payload'];
          if (meta is Map) {
            if (meta['source'] is Map) parsed.subagent = true;
            parsed.cwd = '${meta['cwd'] ?? ''}';
            parsed.session = '${meta['id'] ?? parsed.session}';
          }
        }
        if (r['type'] == 'session') {
          parsed.cwd = '${r['cwd'] ?? ''}';
          parsed.session = '${r['id'] ?? parsed.session}';
          if (r['parentSession'] != null) parsed.subagent = true;
        }
      }
      if (parsed.subagent) return parsed;
      // A cut Codex header cannot establish whether this is a subagent.
      // Keep it partial and wait for a readable metadata header.
      if (partial &&
          form == 'codex-jsonl' &&
          !headRows.any(
            (r) => r['type'] == 'session_meta' && r['payload'] is Map,
          )) {
        return parsed;
      }
      final rows = tail == null ? headRows : records(tail, cut: true);
      _Span? current;
      int? previousIn, previousOut;
      var first = true;
      String? pendingModel;
      final seenMessages = <String, (int, int)>{};
      for (final r in rows) {
        if (_expired) {
          parsed.partial = true;
          break;
        }
        final payload = r['payload'] is Map ? r['payload'] as Map : const {};
        final message = r['message'] is Map ? r['message'] as Map : const {};
        final timestamp = r['timestamp'] ?? message['timestamp'];
        final at = epoch(timestamp);
        if (at == null) {
          if (timestamp != null) parsed.partial = true;
          continue;
        }
        // Seconds since 1970, through the four-digit ISO year range. This
        // rejects mis-scaled nanoseconds and keeps conversion safely bounded.
        if (at < 0 || at >= 253402300800) {
          parsed.partial = true;
          continue;
        }
        final time = DateTime.fromMicrosecondsSinceEpoch(
          (at * 1000000).round(),
          isUtc: true,
        );
        if (r['type'] == 'turn_context' && payload['model'] is String) {
          pendingModel = payload['model'] as String;
          continue;
        }
        final user = form == 'codex-jsonl'
            ? r['type'] == 'event_msg' && payload['type'] == 'user_message'
            : (r['type'] == 'user' || message['role'] == 'user');
        final assistant = form == 'codex-jsonl'
            ? r['type'] == 'event_msg' && payload['type'] == 'agent_message' ||
                  r['type'] == 'response_item' && payload['role'] == 'assistant'
            : r['type'] == 'assistant' || message['role'] == 'assistant';
        final token = form == 'codex-jsonl' && payload['type'] == 'token_count';
        if (!user &&
            !assistant &&
            !token &&
            !(form == 'codex-jsonl' && r['type'] == 'response_item')) {
          continue;
        }
        if (current == null ||
            time.difference(current.end) > const Duration(minutes: 30)) {
          current = _Span(time, leadingPartial: partial && first);
          parsed.spans.add(current);
          first = false;
        }
        if (time.isBefore(current.start)) current.start = time;
        if (time.isAfter(current.end)) current.end = time;
        current.model = pendingModel ?? current.model;
        if (parsed.cwd.isEmpty && r['cwd'] is String) {
          parsed.cwd = r['cwd'] as String;
        }
        if (user && current.request == null) {
          final content = form == 'codex-jsonl'
              ? payload['message']
              : message['content'] ?? r['content'];
          current.request = _request(content);
        }
        if (message['model'] is String) {
          current.model = message['model'] as String;
        }
        if (token) {
          final info = payload['info'];
          final total = info is Map ? info['total_token_usage'] : null;
          if (total is Map) {
            final incoming = total['input_tokens'],
                outgoing = total['output_tokens'];
            if (incoming is int &&
                outgoing is int &&
                incoming >= 0 &&
                outgoing >= 0) {
              if (!current.leadingPartial && (previousIn != null || !partial)) {
                final di = incoming - (previousIn ?? 0),
                    dO = outgoing - (previousOut ?? 0);
                if (di >= 0 && dO >= 0) {
                  current.input = (current.input ?? 0) + di;
                  current.output = (current.output ?? 0) + dO;
                }
              }
              previousIn = incoming;
              previousOut = outgoing;
            }
          }
        } else if (assistant && message['usage'] is Map) {
          final id =
              '${message['id'] ?? r['uuid'] ?? r['id'] ?? time.microsecondsSinceEpoch}';
          final usage = message['usage'] as Map;
          final incoming = usage['input_tokens'] ?? usage['input'];
          final outgoing = usage['output_tokens'] ?? usage['output'];
          if (incoming is int &&
              outgoing is int &&
              incoming >= 0 &&
              outgoing >= 0) {
            final previous = seenMessages[id] ?? (0, 0);
            final incomingDelta = incoming > previous.$1
                ? incoming - previous.$1
                : 0;
            final outgoingDelta = outgoing > previous.$2
                ? outgoing - previous.$2
                : 0;
            current.input = (current.input ?? 0) + incomingDelta;
            current.output = (current.output ?? 0) + outgoingDelta;
            seenMessages[id] = (
              incoming > previous.$1 ? incoming : previous.$1,
              outgoing > previous.$2 ? outgoing : previous.$2,
            );
          }
        }
        final content = message['content'];
        if (content is List) {
          for (final block in content.whereType<Map>()) {
            final name = block['name'];
            final input = block['input'] ?? block['arguments'];
            if ([
                  'Edit',
                  'Write',
                  'edit',
                  'write',
                  'write_file',
                ].contains(name) &&
                input is Map) {
              final target = input['file_path'] ?? input['path'];
              if (target is String) current.edits.add(target);
            }
          }
        }
        final patch = payload['input'] ?? payload['arguments'];
        if (patch is String &&
            (payload['name'] == 'apply_patch' ||
                patch.contains('*** Begin Patch'))) {
          for (final m in RegExp(
            r'^\*\*\* (?:Add|Update|Delete) File: (.+)$',
            multiLine: true,
          ).allMatches(patch)) {
            current.edits.add(m[1]!);
          }
        }
        if (current.leadingPartial) {
          current.input = null;
          current.output = null;
        }
      }
      if (headRows.isEmpty && !partial) {
        throw const FormatException('No readable session records');
      }
      return parsed;
    } finally {
      io.close(fd);
    }
  }

  String? _request(Object? content) {
    if (content is String) return content;
    if (content is List) {
      final text = content
          .whereType<Map>()
          .where((b) => b['type'] == 'text' || b['type'] == 'input_text')
          .map((b) => b['text'] ?? '')
          .join(' ');
      return text.isEmpty ? null : text;
    }
    return null;
  }

  _Parsed _trajectory(String path) {
    final io = files.posix;
    final sourceLeft = 60000 - _source.elapsedMilliseconds;
    final totalLeft = 180000 - _overall.elapsedMilliseconds;
    final opened = openHistoryDatabase(
      files,
      path,
      budget: Duration(
        milliseconds: sourceLeft < totalLeft ? sourceLeft : totalLeft,
      ),
    );
    if (opened.status != 'ok') {
      throw ServiceError(
        opened.status == 'corrupt'
            ? 'reports_db_corrupt'
            : 'reports_db_unavailable',
      );
    }
    final db = opened.database!;
    try {
      final meta = io.lstatFull(path);
      if (meta == null) throw ServiceError('reports_db_unavailable');
      final walMeta = io.lstatFull('$path-wal');
      final last = walMeta != null && walMeta.sec > meta.sec ? walMeta : meta;
      final end = DateTime.fromMillisecondsSinceEpoch(
        last.sec * 1000,
        isUtc: true,
      );
      final start = io.birthTime(path) ?? end;
      final parsed = _Parsed(p.basenameWithoutExtension(path), partial: true);
      final span = _Span(start)..end = end.isBefore(start) ? start : end;
      parsed.spans.add(span);
      final rows = db.query(
        'SELECT hex(step_payload) FROM steps WHERE step_type=14 AND step_format=0 AND length(step_payload)<=65536 ORDER BY idx LIMIT 1',
      );
      try {
        if (rows.isNotEmpty) {
          span.request = trajectoryText(_unhex(rows.single.single as String), [
            19,
            2,
          ]);
        }
      } on FormatException {
        // Keep the fallback timing span when payload text cannot be decoded.
      }
      for (final row in db.query(
        'SELECT hex(step_payload) FROM steps WHERE step_type=132 AND status=3 AND step_format=0 AND length(step_payload)<=65536 ORDER BY idx LIMIT 2000',
      )) {
        if (_expired) break;
        try {
          final data = _unhex(row.single as String);
          if (trajectoryText(data, [5, 4, 2]) == 'write_file') {
            final target = trajectoryText(data, [140, 1, 2]);
            if (target.startsWith('/')) span.edits.add(target);
          }
        } on FormatException {
          // An undecodable step cannot establish an edit.
        }
      }
      return parsed;
    } finally {
      db.close();
    }
  }

  Uint8List _unhex(String value) => Uint8List.fromList([
    for (var i = 0; i + 1 < value.length; i += 2)
      int.parse(value.substring(i, i + 2), radix: 16),
  ]);
}

final class _Parsed {
  _Parsed(this.session, {this.partial = false});
  String session, cwd = '';
  bool partial, subagent = false;
  final spans = <_Span>[];
}

final class _Span {
  _Span(this.start, {this.leadingPartial = false}) : end = start;
  DateTime start, end;
  final bool leadingPartial;
  String? request, model;
  int? input, output;
  final edits = <String>{};
  String? get heuristic => edits.isEmpty
      ? null
      : edits.any(
          (f) => RegExp(
            r'(^|[/_.-])tests?([/_.-]|$)',
            caseSensitive: false,
          ).hasMatch(f),
        )
      ? 'testing'
      : 'editing';
}
