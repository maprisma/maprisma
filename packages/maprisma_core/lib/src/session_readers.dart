import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'adapters.dart';
import 'claude_sessions.dart';
import 'agent_details.dart';
import 'scan_files.dart';
import 'sqlite_numbers.dart';

int tokenNumber(dynamic value) =>
    value is int && value >= 0 && value < 10000000000000 ? value : 0;
double safeMoney(dynamic value) {
  final n = value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
  return n.isFinite && n >= 0 && n < 10000000 ? n : 0;
}

double? epoch(dynamic value) {
  if (value is num && value.isFinite) {
    return value > 1e11 ? value / 1000 : value.toDouble();
  }
  if (value is String && value.length <= 40) {
    final date = DateTime.tryParse(value);
    return date == null ? null : date.microsecondsSinceEpoch / 1000000;
  }
  return null;
}

String projectFolder(dynamic value) =>
    value is String &&
        value.startsWith('/') &&
        value.runes.length <= 1024 &&
        !value.runes.any((n) => n < 32)
    ? value
    : '';
String sessionModel(dynamic value) {
  var text = boundedText(value, 2000);
  if (text.startsWith('{')) {
    try {
      text = boundedText(mapOf(jsonDecode(text))['id'], 100);
    } on FormatException {
      return 'unknown';
    }
  }
  return text.isEmpty ? 'unknown' : boundedText(text, 100);
}

double scanNow(ScanFiles files) =>
    double.tryParse(files.identity.environment['MAPRISMA_SCAN_NOW'] ?? '') ??
    DateTime.now().microsecondsSinceEpoch / 1000000;

final class NumericSession {
  String cwd = '';
  double first = 0, last = 0, active = 0, cost = 0;

  /// [cost] is only the agent's estimate of the API value, not a charge it
  /// was told of (Hermes' estimated_cost_usd without actual_cost_usd).
  bool estimated = false;
  int replies = 0, linesAdded = 0, linesRemoved = 0, apiMs = 0;
  final tokens = <String, List<int>>{},
      hours = <String, int>{},
      subagents = <String, List<num>>{};
  void seen(double? when) {
    if (when == null || !when.isFinite) return;
    first = first == 0 ? when : math.min(first, when);
    last = math.max(last, when);
  }

  void add(String model, List<int> counts) {
    final target = tokens.putIfAbsent(
      model.isEmpty ? 'unknown' : model,
      () => [0, 0, 0, 0],
    );
    for (var i = 0; i < 4; i++) {
      target[i] += counts[i];
    }
  }

  void times(List<double> stamps) {
    stamps = stamps.where((v) => v != 0 && v.isFinite).toList()..sort();
    double? previous;
    for (final when in stamps) {
      if (previous != null && when - previous > 0 && when - previous <= 300) {
        active += when - previous;
      }
      previous = when;
      seen(when);
      replies++;
      final date = DateTime.fromMicrosecondsSinceEpoch(
        (when * 1000000).round(),
      );
      final slot = '${(date.weekday - 1) * 24 + date.hour}';
      hours[slot] = (hours[slot] ?? 0) + 1;
    }
  }

  void run(String kind, NumericSession child) {
    final target = subagents.putIfAbsent(
      kind.isEmpty ? '?' : kind,
      () => [0, 0, 0.0],
    );
    target[0] += 1;
    target[1] += child.tokens.values.fold<int>(
      0,
      (n, c) => n + c[0] + c[1] + c[3],
    );
    target[2] += child.active;
  }

  Map<String, dynamic> toJson() => {
    'cwd': cwd,
    'first': first,
    'last': last,
    'active': active,
    'replies': replies,
    'tokens': tokens,
    'hours': hours,
    'lines_added': linesAdded,
    'lines_removed': linesRemoved,
    'cost': cost,
    'estimated': estimated,
    'api_ms': apiMs,
    'subagents': subagents,
  };
}

final class SessionReaders {
  SessionReaders(this.files) : sqlite = SqliteNumbers(files);
  final ScanFiles files;
  final SqliteNumbers sqlite;
  static const maxFileBytes = 64 * 1024 * 1024, maxLine = 8 * 1024 * 1024;
  List<String> matching(String root, String pattern, {int limit = 2000}) {
    root = files.expand(root);
    final output = <String>[];
    var budget = 8000;
    bool matches(String value, String glob) => RegExp(
      '^${RegExp.escape(glob).replaceAll(r'\*', '.*').replaceAll(r'\?', '.')}\$',
    ).hasMatch(value);
    void walk(String dir, List<String> parts, int depth) {
      if (budget <= 0 ||
          depth > 12 ||
          parts.isEmpty ||
          FileSystemEntity.typeSync(dir, followLinks: false) !=
              FileSystemEntityType.directory) {
        return;
      }
      final children = files.list(dir, limit: budget.clamp(0, 4000));
      for (final entry in children) {
        if (--budget < 0) break;
        final type = FileSystemEntity.typeSync(entry, followLinks: false);
        if (parts.first == '**') {
          if (type == FileSystemEntityType.directory) {
            walk(entry, parts, depth + 1);
          }
          if (parts.length > 1 &&
              matches(p.basename(entry), parts[1]) &&
              parts.length == 2 &&
              type == FileSystemEntityType.file) {
            output.add(entry);
          }
        } else if (matches(p.basename(entry), parts.first)) {
          if (parts.length == 1 && type == FileSystemEntityType.file) {
            output.add(entry);
          } else if (type == FileSystemEntityType.directory) {
            walk(entry, parts.skip(1).toList(), depth + 1);
          }
        }
      }
    }

    walk(root, pattern.split('/'), 0);
    final now = scanNow(files);
    final recent = output
        .where(
          (path) =>
              now -
                  File(path).statSync().modified.microsecondsSinceEpoch / 1e6 <=
              30 * 86400,
        )
        .toList();
    recent.sort(
      (a, b) =>
          File(b).statSync().modified.compareTo(File(a).statSync().modified),
    );
    return recent.take(limit).toList();
  }

  Iterable<Map<String, dynamic>> entries(
    List<int> data, {
    bool completeLines = false,
  }) sync* {
    final source = utf8.decode(data, allowMalformed: true);
    final lines = source.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.isEmpty ||
          utf8.encode(line).length > maxLine ||
          completeLines && i == lines.length - 1) {
        continue;
      }
      try {
        final value = jsonDecode(line);
        if (value is Map<String, dynamic>) yield value;
      } on FormatException {
        /* no partial records */
      }
    }
  }

  NumericSession? parse(String form, List<int> data) {
    final session = NumericSession();
    String model = '';
    Map? totals;
    final source = form == 'dsh-files' ? decompress(data) : data;
    if (source == null) return null;
    final rows = form == 'gemini-files' ? geminiRows(source) : entries(source);
    for (final entry in rows) {
      switch (form) {
        case 'codex-files':
          final payload = mapOf(entry['payload']);
          session.seen(epoch(entry['timestamp']));
          if (entry['type'] == 'session_meta') {
            session.cwd = boundedText(payload['cwd'], 4096);
          }
          if (entry['type'] == 'turn_context') {
            model = boundedText(payload['model']).isEmpty
                ? model
                : boundedText(payload['model']);
          }
          if (entry['type'] == 'event_msg' &&
              payload['type'] == 'token_count' &&
              dig(payload, 'info.total_token_usage') is Map) {
            totals = dig(payload, 'info.total_token_usage') as Map;
            session.replies++;
          }
        case 'pi-files':
          if (entry['type'] == 'session') {
            session.cwd = boundedText(entry['cwd'], 4096);
          }
          final message = mapOf(entry['message']),
              usage = mapOf(mapOf(entry['message'])['usage']);
          if (entry['type'] == 'message' &&
              message['role'] == 'assistant' &&
              message['usage'] is Map) {
            session.seen(epoch(entry['timestamp']));
            session.replies++;
            session.add(boundedText(message['model']), [
              for (final key in ['input', 'output', 'cacheRead', 'cacheWrite'])
                tokenNumber(usage[key]),
            ]);
          }
        case 'dsh-files':
          final body = mapOf(entry['data']);
          if (entry['type'] == 'session') {
            session.cwd = boundedText(body['cwd'] ?? body['workspace'], 4096);
          }
          if (entry['type'] == 'assistant/message' && body['usage'] is Map) {
            session.seen(epoch(entry['time']));
            session.replies++;
            final usage = body['usage'] as Map;
            session.add(
              boundedText(body['model']).isNotEmpty
                  ? boundedText(body['model'])
                  : boundedText(dig(body, 'message.source.model')),
              [
                for (final key in [
                  'inputTokens',
                  'outputTokens',
                  'cacheReadTokens',
                  'cacheWriteTokens',
                ])
                  tokenNumber(usage[key]),
              ],
            );
          }
        case 'gemini-files':
          final usage = entry['tokens'];
          if (usage is! Map || entry['type'] == 'user') continue;
          final cached = tokenNumber(usage['cached']);
          session.seen(epoch(entry['timestamp']));
          session.replies++;
          session.add(boundedText(entry['model']), [
            math.max(0, tokenNumber(usage['input']) - cached) +
                tokenNumber(usage['tool']),
            tokenNumber(usage['output']) + tokenNumber(usage['thoughts']),
            cached,
            0,
          ]);
        case 'openclaw-files':
          addOpenclaw(session, entry);
      }
    }
    if (form == 'codex-files') {
      if (totals == null) return null;
      final read = tokenNumber(totals['cached_input_tokens']);
      session.add(model, [
        math.max(0, tokenNumber(totals['input_tokens']) - read),
        tokenNumber(totals['output_tokens']),
        read,
        tokenNumber(totals['cache_write_input_tokens']),
      ]);
    }
    return session.replies > 0 ? session : null;
  }

  Iterable<Map<String, dynamic>> geminiRows(List<int> data) {
    List<dynamic>? rows;
    try {
      final value = jsonDecode(utf8.decode(data, allowMalformed: true));
      if (value is Map && value['messages'] is List) {
        rows = value['messages'] as List;
      }
    } on FormatException {
      /* JSONL below */
    }
    final kept = <String, Map<String, dynamic>>{};
    for (final entry
        in rows?.take(100000).whereType<Map<String, dynamic>>() ??
            entries(data)) {
      if (entry['tokens'] is! Map || entry['type'] == 'user') continue;
      kept[boundedText('${entry['id'] ?? kept.length}', 200)] = entry;
    }
    return kept.values;
  }

  void addOpenclaw(NumericSession session, Map entry) {
    final message = entry['message'] is Map ? entry['message'] as Map : entry;
    final usage = message['usage'] is Map ? message['usage'] : entry['usage'];
    if (message['role'] != 'assistant' ||
        usage is! Map ||
        dig(entry, 'usageReport.state') == 'unavailable') {
      return;
    }
    session.seen(epoch(message['timestamp']) ?? epoch(entry['timestamp']));
    session.replies++;
    session.add(boundedText(message['model']), [
      for (final key in ['input', 'output', 'cacheRead', 'cacheWrite'])
        tokenNumber(usage[key]),
    ]);
  }

  List<int>? decompress(List<int> data) {
    if (data.isEmpty) return [];
    final lib = DynamicLibrary.open('libzstd.so.1');
    final size = lib
        .lookupFunction<
          Uint64 Function(Pointer<Uint8>, IntPtr),
          int Function(Pointer<Uint8>, int)
        >('ZSTD_getFrameContentSize');
    final frameSize = lib
        .lookupFunction<
          IntPtr Function(Pointer<Uint8>, IntPtr),
          int Function(Pointer<Uint8>, int)
        >('ZSTD_findFrameCompressedSize');
    final decode = lib
        .lookupFunction<
          IntPtr Function(Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr),
          int Function(Pointer<Uint8>, int, Pointer<Uint8>, int)
        >('ZSTD_decompress');
    final error = lib
        .lookupFunction<Uint32 Function(IntPtr), int Function(int)>(
          'ZSTD_isError',
        );
    final input = calloc<Uint8>(data.length);
    Pointer<Uint8> output = nullptr;
    try {
      input.asTypedList(data.length).setAll(0, data);
      var at = 0, total = 0, unknown = false;
      final frames = <(int, int)>[];
      while (at < data.length) {
        final length = frameSize(input + at, data.length - at);
        if (error(length) != 0 || length <= 0 || length > data.length - at) {
          return null;
        }
        final wanted = size(input + at, length);
        if (wanted < 0) {
          unknown = true;
        } else {
          total += wanted;
        }
        if (total > maxFileBytes) return null;
        frames.add((at, length));
        at += length;
      }
      final capacity = unknown ? maxFileBytes : total;
      output = calloc<Uint8>(capacity + 1);
      var used = 0;
      for (final (start, length) in frames) {
        final count = decode(
          output + used,
          capacity - used,
          input + start,
          length,
        );
        if (error(count) != 0 || count > capacity - used) return null;
        used += count;
      }
      return Uint8List.fromList(output.asTypedList(used));
    } finally {
      calloc.free(input);
      if (output != nullptr) calloc.free(output);
    }
  }

  Map<String, NumericSession> fileSessions(String form) {
    final specs = {
      'codex-files': ['~/.codex/sessions', '*/*/*/rollout-*.jsonl'],
      'pi-files': ['~/.pi/agent/sessions', '*/*.jsonl'],
      'dsh-files': ['~/.dsh/sessions', '*/session-*/session.v4.jsonl.zstd'],
      'gemini-files': ['~/.gemini/tmp', '*/chats/**/*.json*'],
      'openclaw-files': ['~/.openclaw/agents', '*/sessions/*.jsonl'],
    };
    final spec = specs[form];
    if (spec == null) return {};
    final result = <String, NumericSession>{};
    for (final path in matching(spec[0], spec[1])) {
      final data = files.bytes(path, limit: maxFileBytes);
      if (data == null) continue;
      final session = parse(form, data);
      if (session != null) result[path] = session;
    }
    return result;
  }

  Map<String, NumericSession> databaseSessions(String reader) {
    if (reader == 'hermes' || reader == 'opencode') return hookSessions(reader);
    final result = <String, NumericSession>{};
    final now = scanNow(files);
    if (reader == 'omp-db') {
      for (final row in sqlite.select(
        '~/.omp/agent/agent.db',
        'SELECT id, recorded_at, model, requests, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens FROM client_usage ORDER BY id DESC LIMIT 100000',
        maxRows: 100000,
      )) {
        final when = epoch(row[1]);
        if (when == null || now - when > 30 * 86400) continue;
        final session = NumericSession()
          ..first = when
          ..last = when
          ..replies = tokenNumber(row[3]);
        session.add(boundedText(row[2]), row.skip(4).map(tokenNumber).toList());
        result['omp:${tokenNumber(row[0])}'] = session;
      }
    } else if (reader == 'goose-db') {
      final columns = sqlite
          .select(
            '~/.local/share/goose/sessions/sessions.db',
            "SELECT name FROM pragma_table_info('sessions')",
          )
          .map((r) => r[0])
          .toSet();
      const desired = [
        'id',
        'working_dir',
        'created_at',
        'updated_at',
        'model_config_json',
        'accumulated_input_tokens',
        'accumulated_output_tokens',
        'accumulated_cache_read_tokens',
        'accumulated_cache_write_tokens',
      ];
      final selected = desired.where(columns.contains).toList();
      if (!selected.contains('updated_at')) return {};
      for (final values in sqlite.select(
        '~/.local/share/goose/sessions/sessions.db',
        'SELECT ${selected.join(', ')} FROM sessions ORDER BY updated_at DESC LIMIT 100000',
        maxRows: 100000,
      )) {
        final row = {
          for (var i = 0; i < selected.length; i++) selected[i]: values[i],
        };
        final when = epoch(row['updated_at']);
        if (when == null || now - when > 30 * 86400) continue;
        Map config = {};
        try {
          config = mapOf(
            jsonDecode(row['model_config_json'] as String? ?? '{}'),
          );
        } on FormatException {
          /* unknown model */
        }
        final read = tokenNumber(row['accumulated_cache_read_tokens']),
            write = tokenNumber(row['accumulated_cache_write_tokens']);
        final session = NumericSession()
          ..cwd = boundedText(row['working_dir'], 4096)
          ..first = epoch(row['created_at']) ?? when
          ..last = when;
        session.add(boundedText(config['model_name']), [
          math.max(
            0,
            tokenNumber(row['accumulated_input_tokens']) - read - write,
          ),
          tokenNumber(row['accumulated_output_tokens']),
          read,
          write,
        ]);
        result['goose:${boundedText('${row['id']}', 80)}'] = session;
      }
    } else if (reader == 'crush-db') {
      final projects = files.json(
        '~/.local/share/crush/projects.json',
      )['projects'];
      if (projects is! List) return {};
      for (var i = 0; i < projects.length.clamp(0, 200); i++) {
        if (projects[i] is! Map) break;
        final project = projects[i] as Map;
        final data = boundedText(project['data_dir'], 4096),
            folder = boundedText(project['path'], 4096);
        final path = data.isEmpty ? '$folder/.crush' : data;
        if (!path.startsWith('/')) continue;
        for (final row in sqlite.select(
          '$path/crush.db',
          'SELECT id, cost, created_at, updated_at FROM sessions ORDER BY updated_at DESC LIMIT 100000',
          maxRows: 100000,
        )) {
          final when = epoch(row[3]);
          if (when == null ||
              now - when > 30 * 86400 ||
              row[1] is! num ||
              (row[1] as num) <= 0) {
            continue;
          }
          result['crush:$i:${boundedText('${row[0]}', 80)}'] = NumericSession()
            ..cwd = folder
            ..first = epoch(row[2]) ?? when
            ..last = when
            ..cost = math.min((row[1] as num).toDouble(), 1000000);
        }
      }
    }
    if (reader == 'openclaw-db') {
      String extract(String key) => "json_extract(event_json, '\$.$key')";
      String usage(String key) =>
          "json_object('input',${extract('$key.input')},'output',${extract('$key.output')},'cacheRead',${extract('$key.cacheRead')},'cacheWrite',${extract('$key.cacheWrite')})";
      final projection =
          "json_object('message',json_object('role',${extract('message.role')},'timestamp',${extract('message.timestamp')},'model',${extract('message.model')},'usage',${usage('message.usage')}),'role',${extract('role')},'timestamp',${extract('timestamp')},'model',${extract('model')},'usage',${usage('usage')},'usageReport',json_object('state',${extract('usageReport.state')}))";
      for (final db in matching(
        '~/.openclaw/agents',
        '*/agent/openclaw-agent.sqlite',
      )) {
        final rows = sqlite.select(
          db,
          "SELECT session_id, CASE WHEN json_valid(event_json) THEN $projection ELSE NULL END, CASE WHEN length(event_zstd)<=1048576 THEN event_zstd ELSE NULL END FROM transcript_events WHERE length(event_json)<=1048576 OR length(event_zstd)<=1048576 ORDER BY rowid DESC LIMIT 20000",
          maxRows: 20000,
          maxText: 8192,
          blobs: true,
        );
        for (final row in rows) {
          final bytes = row[1] is String
              ? utf8.encode(row[1])
              : row[2] is List<int>
              ? decompress(row[2] as List<int>)
              : null;
          if (bytes == null) continue;
          try {
            final entry = jsonDecode(utf8.decode(bytes));
            if (entry is! Map) continue;
            final session = result.putIfAbsent(
              'openclaw:${boundedText('${row[0]}', 80)}',
              NumericSession.new,
            );
            addOpenclaw(session, entry);
            if (session.last != 0 && session.last < now - 30 * 86400) {
              session.replies = 0;
            }
          } on FormatException {
            /* unavailable event */
          }
        }
      }
      result.removeWhere((key, s) => s.replies == 0);
      result.addAll({
        for (final e in fileSessions('openclaw-files').entries)
          'openclaw-file:${e.key}': e.value,
      });
    }
    return result;
  }

  Map<String, NumericSession> hookSessions(String reader) {
    final hermes = reader == 'hermes';
    final path = hermes
        ? '~/.hermes/state.db'
        : '~/.local/share/opencode/opencode.db';
    final query = hermes
        ? 'SELECT id, parent_session_id, cwd, started_at, COALESCE(last_activity_at, ended_at, started_at), model, input_tokens, COALESCE(output_tokens, 0) + COALESCE(reasoning_tokens, 0), cache_read_tokens, cache_write_tokens, COALESCE(actual_cost_usd, estimated_cost_usd), actual_cost_usd FROM sessions ORDER BY started_at DESC LIMIT 20000'
        : 'SELECT id, parent_id, agent, directory, time_created, time_updated, model, tokens_input, COALESCE(tokens_output, 0) + COALESCE(tokens_reasoning, 0), tokens_cache_read, tokens_cache_write, cost, summary_additions, summary_deletions FROM session_v2 ORDER BY time_created DESC LIMIT 20000';
    final rows = sqlite.select(path, query);
    if (rows.isEmpty) return {};
    final times = <String, List<double>>{};
    final stamps = sqlite.select(
      path,
      hermes
          ? 'SELECT session_id, timestamp FROM messages ORDER BY timestamp DESC LIMIT 400000'
          : 'SELECT session_id, time_created FROM session_message ORDER BY time_created DESC LIMIT 400000',
      maxRows: 400000,
    );
    for (final row in stamps) {
      final value = row[1] is num
          ? (row[1] as num).toDouble()
          : double.tryParse('${row[1]}');
      if (value != null) {
        times
            .putIfAbsent('${row[0]}', () => [])
            .add(hermes ? value : value / 1000);
      }
    }
    final result = <String, NumericSession>{},
        runs = <(String, String, NumericSession)>[];
    for (final raw in rows) {
      final row = List<dynamic>.from(raw);
      var kind = '?';
      if (!hermes) {
        final a = row.removeAt(2);
        if (a is String &&
            RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._:\-]{0,63}$').hasMatch(a)) {
          kind = a;
        }
      }
      final sid = '${row[0]}',
          session = NumericSession()..cwd = projectFolder(row[2]);
      session.add(sessionModel(row[5]), [
        for (final n in row.sublist(6, 10)) tokenNumber(n),
      ]);
      session.times(
        times[sid] ??
            [
              for (final n in row.sublist(3, 5))
                if (n is num) (hermes ? n.toDouble() : tokenNumber(n) / 1000),
            ],
      );
      session.cost = safeMoney(row[10]);
      // Hermes keeps an estimate beside what was charged: only the latter is
      // a bill (usage_readers' billed).
      if (hermes) {
        session.estimated = session.cost > 0 && safeMoney(row[11]) <= 0;
      } else {
        session.linesAdded = tokenNumber(row[11]);
        session.linesRemoved = tokenNumber(row[12]);
      }
      if (row[1] != null && row[1] != 0 && row[1] != '') {
        runs.add(('${row[1]}', kind, session));
      } else {
        result[sid] = session;
      }
    }
    for (final (parent, kind, run) in runs) {
      result[parent]?.run(kind, run);
    }
    return result;
  }

  /// claude_sessions.collect_by_id: incremental, cached per file.
  Map<String, NumericSession> claudeSessions() {
    final env = files.identity.environment['CLAUDE_CONFIG_DIR'] ?? '';
    final root = p.join(
      env.isNotEmpty ? env : files.expand('~/.claude'),
      'projects',
    );
    return ClaudeSessions(
      root,
      p.join(files.identity.cacheDir, 'claude-sessions.json'),
    ).collect();
  }

  /// The readers whose store keeps what each session cost in money, as the
  /// agent itself was told (NumericSession.cost): none for a plan's use.
  static const costReaders = {'hermes', 'opencode', 'crush-db'};

  static bool keepsCosts(Adapter adapter) {
    final session = adapter.table('sessions');
    return costReaders.contains(
      session['reader'] ?? (session['hook'] == true ? adapter.command : ''),
    );
  }

  Map<String, NumericSession> read(Adapter adapter) {
    final session = adapter.table('sessions');
    final reader =
        session['reader'] ?? (session['hook'] == true ? adapter.command : '');
    if (reader == 'claude-files') return claudeSessions();
    if ([
      'hermes',
      'opencode',
      'omp-db',
      'goose-db',
      'crush-db',
      'openclaw-db',
    ].contains(reader)) {
      return databaseSessions(reader);
    }
    return fileSessions(reader);
  }
}
