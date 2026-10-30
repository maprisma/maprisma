import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:path/path.dart' as p;
import 'posix_ffi.dart';
import 'py_values.dart' show pyFixedExact, pyRound;

/// usage_box: the usage statistics box while an agent works — how fast its
/// model answers (output tokens per second of its latest reply), its
/// context size and how much of it is in use. Read from the agent's own
/// session files ([replies] of its adapter: folder, depth, format,
/// contexts), numbers, times and model names only, never message text.
/// Only the newest session file written in the last [recent] seconds is
/// read, and of it only the last [tail] bytes (own regular files, no
/// links).

const recent = 60, rescan = 10, tail = 256 * 1024, maxLine = 64 * 1024;
const maxEntries = 20000, maxRate = 100000.0;
const usageItems = ['rate', 'context', 'used'];
const usageSizes = [7, 8, 9, 10, 12];

final class Reading {
  Reading(this.rate, this.used, this.window, this.model);
  final double? rate;
  final int used, window;
  final String model;

  double? get share =>
      used != 0 && window != 0 ? math.min(1.0, used / window) : null;

  Map<String, dynamic> toJson() => {
    'rate': rate,
    'used': used,
    'window': window,
    'model': model,
  };
}

final class Event {
  Event(
    this.when,
    this.kind, {
    this.key = '',
    this.tokens = 0,
    this.used = 0,
    this.window = 0,
    this.model = '',
  });
  final double when;
  final String kind, key, model;
  final int tokens, used, window;
}

double? _time(dynamic value) {
  if (value is num && value is! bool) {
    return value > 1e11 ? value / 1000 : value.toDouble();
  }
  if (value is! String || value.length > 40) return null;
  final t = DateTime.tryParse(value);
  return t == null ? null : t.microsecondsSinceEpoch / 1e6;
}

int _tokens(dynamic v) => v is int && v >= 0 && v < 1000000000 ? v : 0;

bool _printable(String s) => !s.runes.any(
  (c) => c < 0x20 || c >= 0x7f && c < 0xa0 || c == 0x2028 || c == 0x2029,
);

String _model(dynamic v) =>
    v is String && _printable(v) ? String.fromCharCodes(v.runes.take(100)) : '';

String _clip(String s) => String.fromCharCodes(s.runes.take(100));

Event? claudeEvent(Map entry) {
  final kind = entry['type'];
  final when = _time(entry['timestamp']);
  if (when == null) return null;
  if (kind == 'assistant') {
    final message = entry['message'];
    if (message is! Map || message['usage'] is! Map) return null;
    final usage = message['usage'] as Map;
    final key = message['id'] is String ? message['id'] : entry['uuid'];
    final used = [
      'input_tokens',
      'cache_read_input_tokens',
      'cache_creation_input_tokens',
      'output_tokens',
    ].fold<int>(0, (n, k) => n + _tokens(usage[k]));
    return Event(
      when,
      'out',
      key: _clip(pyStrOf(key)),
      tokens: _tokens(usage['output_tokens']),
      used: used,
      model: _model(message['model']),
    );
  }
  if (kind == 'user') return Event(when, 'in');
  return null;
}

/// Python's str() of a JSON value.
String pyStrOf(dynamic v) => switch (v) {
  null => 'None',
  true => 'True',
  false => 'False',
  final String s => s,
  final double d =>
    d == d.truncateToDouble() && d.abs() < 1e16 ? '${d.toInt()}.0' : '$d',
  _ => '$v',
};

const _codexInput = {
  'function_call_output',
  'custom_tool_call_output',
  'user_message',
  'task_started',
};

Event? codexEvent(Map entry) {
  final when = _time(entry['timestamp']);
  final payload = entry['payload'];
  if (when == null || payload is! Map) return null;
  final kind = payload['type'] ?? entry['type'];
  if (kind == 'token_count') {
    final info = payload['info'];
    final last = info is Map ? info['last_token_usage'] : null;
    if (last is! Map) return null;
    return Event(
      when,
      'out',
      key: 'codex:${pyStrOf(when)}',
      tokens: _tokens(last['output_tokens']),
      used: _tokens(last['total_tokens']),
      window: _tokens((info as Map)['model_context_window']),
    );
  }
  if (kind == 'turn_context') {
    return Event(when, 'model', model: _model(payload['model']));
  }
  if (_codexInput.contains(kind) ||
      kind == 'message' && payload['role'] == 'user') {
    return Event(when, 'in');
  }
  return null;
}

Event? piEvent(Map entry) {
  final when = _time(entry['timestamp']);
  if (when == null) return null;
  if (entry['type'] == 'model_change') {
    return Event(when, 'model', model: _model(entry['modelId']));
  }
  final message = entry['message'];
  if (entry['type'] != 'message' || message is! Map) return null;
  if (message['role'] == 'assistant') {
    final usage = message['usage'];
    if (usage is! Map) return null;
    return Event(
      when,
      'out',
      key: _clip(pyStrOf(entry.containsKey('id') ? entry['id'] : when)),
      tokens: _tokens(usage['output']),
      used: _tokens(usage['totalTokens']),
      model: _model(message['model']),
    );
  }
  return Event(when, 'in');
}

final formats = <String, Event? Function(Map)>{
  'claude-jsonl': claudeEvent,
  'codex-jsonl': codexEvent,
  'pi-jsonl': piEvent,
};

/// last_reply: (tokens per second, end) of the newest reply with a
/// measurable time, among the events in file order.
(double, double)? lastReply(List<Event> events) {
  double? start;
  final replies = <String, List<dynamic>>{};
  final order = <String>[];
  for (final e in events) {
    if (e.kind == 'in') {
      start = e.when;
      continue;
    }
    if (e.kind != 'out') continue;
    var reply = replies[e.key];
    if (reply == null) {
      reply = replies[e.key] = [start, e.when, 0];
      order.add(e.key);
    }
    reply[1] = math.max(reply[1] as double, e.when);
    reply[2] = math.max(reply[2] as int, e.tokens);
    start = e.when;
  }
  for (final key in order.reversed) {
    final [begun, end, tokens] = replies[key]!;
    if (begun != null &&
        (tokens as int) > 0 &&
        (end as double) - (begun as double) >= 0.3 &&
        end - begun <= 600) {
      return (math.min(maxRate, tokens / (end - begun)), end);
    }
  }
  return null;
}

/// window_for: the adapter's context size for the model (longest prefix).
int windowFor(String model, Map contexts) {
  String? best;
  for (final k in contexts.keys) {
    final key = '$k';
    if (model.startsWith(key) && (best == null || key.length > best.length)) {
      best = key;
    }
  }
  return best == null ? 0 : _tokens(contexts[best]);
}

final class UsageBox {
  UsageBox({Posix? posix}) : posix = posix ?? Posix();
  final Posix posix;

  /// newest_file: the newest *.jsonl at that depth below root written
  /// after [since] (own walk, links not followed, bounded).
  String? newestFile(String root, int depth, double since) {
    String? best;
    var bestTime = since, seen = 0;
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
            mtime > bestTime) {
          best = e.path;
          bestTime = mtime;
        }
      }
    }
    return best;
  }

  List<List<int>> _lines(String path, {required bool fromEnd}) {
    final int fd;
    try {
      fd = posix.openAt(-100, path, Posix.noFollow | Posix.nonBlock);
    } on Object {
      return [];
    }
    try {
      final st = posix.statFull(fd);
      if (st.mode & 0xf000 != 0x8000 || st.uid != posix.uid) return [];
      final start = fromEnd ? math.max(0, st.size - tail) : 0;
      final data = posix.readAt(fd, start, tail);
      final lines = <List<int>>[];
      var from = 0;
      for (var i = 0; i < data.length; i++) {
        if (data[i] == 10) {
          lines.add(data.sublist(from, i));
          from = i + 1;
        }
      }
      if (fromEnd) {
        lines.add(data.sublist(from)); // the last (maybe partial) line
        if (start > 0) lines.removeAt(0); // cut in the middle
        return [
          for (final l in lines)
            if (l.isNotEmpty && l.length <= maxLine) l,
        ];
      }
      return [
        for (final l in lines)
          if (l.isNotEmpty && l.length <= maxLine) l,
      ]; // complete lines only
    } finally {
      posix.close(fd);
    }
  }

  /// tail_lines: the lines in the last [tail] bytes.
  List<List<int>> tailLines(String path) => _lines(path, fromEnd: true);

  static Map? _entry(List<int> line) {
    try {
      final v = jsonDecode(utf8.decode(line));
      return v is Map ? v : null;
    } on FormatException {
      return null;
    }
  }

  /// read: (Reading, time of its latest reply) from one session file.
  (Reading, double)? read(String form, String path, Map contexts) {
    final reader = formats[form];
    if (reader == null) return null;
    final events = <Event>[];
    for (final line in tailLines(path)) {
      final entry = _entry(line);
      final event = entry == null ? null : reader(entry);
      if (event != null) events.add(event);
    }
    final outs = events.where((e) => e.kind == 'out').toList();
    if (outs.isEmpty) return null;
    final last = outs.last;
    final model = last.model.isNotEmpty
        ? last.model
        : events.reversed
              .firstWhere((e) => e.model.isNotEmpty, orElse: () => Event(0, ''))
              .model;
    final window = last.window != 0 ? last.window : windowFor(model, contexts);
    final rate = lastReply(events);
    return (Reading(rate?.$1, last.used, window, model), last.when);
  }

  /// head_model: the last model named in the first [tail] bytes.
  String headModel(String form, String path) {
    final reader = formats[form];
    if (reader == null) return '';
    var model = '';
    for (final line in _lines(path, fromEnd: false)) {
      final entry = _entry(line);
      final event = entry == null ? null : reader(entry);
      if (event != null && event.model.isNotEmpty) model = event.model;
    }
    return model;
  }

  final _files = <String, (String?, double)>{};

  /// Rates.readings: the latest reply of each of these (working) agents.
  /// where: command → (folder, depth, format, contexts).
  Map<String, Reading> readings(
    Map<String, (String, int, String, Map)> where,
    double now,
    double wall,
  ) {
    final found = <String, Reading>{};
    for (final e in where.entries) {
      final (folder, depth, form, contexts) = e.value;
      if (!formats.containsKey(form)) continue;
      var (path, looked) = _files[e.key] ?? (null, -rescan.toDouble());
      if (path == null || now - looked >= rescan) {
        path = newestFile(folder, depth, wall - recent);
        _files[e.key] = (path, now);
      }
      if (path == null) continue;
      final result = read(form, path, contexts);
      if (result != null && wall - result.$2 <= recent) {
        found[e.key] = result.$1;
      }
    }
    return found;
  }
}

String rateText(double rate) =>
    rate < 10 ? '${pyFixedExact(rate, 1)} t/s' : '${pyFixedExact(rate, 0)} t/s';

/// size_text: 1M, 272k, 32k.
String sizeText(int tokens) {
  if (tokens >= 1000000) {
    var t = pyFixedExact(tokens / 1000000, 1);
    t = t.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    return '${t}M';
  }
  return tokens >= 1000 ? '${pyRound(tokens / 1000)}k' : '$tokens';
}

String shareColour(double share) => share > 0.9
    ? 'red'
    : share >= 0.75
    ? 'yellow'
    : 'line';

/// parts: [(text, colour)] the box shows, in [usageItems] order.
List<List<String>> usageParts(Reading r, List items) => [
  if (items.contains('rate') && r.rate != null) [rateText(r.rate!), 'line'],
  if (items.contains('context') && r.window != 0) [sizeText(r.window), 'line'],
  if (items.contains('used') && r.share != null)
    ['${pyFixedExact(r.share! * 100, 0)}%', shareColour(r.share!)],
];

/// The folder of an adapter's [replies] with ~ expanded.
String repliesFolder(String folder, String home) => folder == '~'
    ? home
    : folder.startsWith('~/')
    ? p.join(home, folder.substring(2))
    : folder;
