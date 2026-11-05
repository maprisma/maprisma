import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'posix_ffi.dart';
import 'session_readers.dart' show NumericSession, epoch, projectFolder;

/// claude_sessions: Claude Code's work per session as numbers only (tokens,
/// working time, lines changed, cost) from its session files, bounded and
/// incremental: own regular files only, at most [maxLine] bytes per line
/// (longer lines are skipped), [maxFiles] files, [maxBytes] per run; each
/// file is read on from where the last run stopped (same inode, grown), the
/// results cached owner-only. Only "assistant" and "cost-state" lines are
/// parsed; no message text is kept.

const maxLine = 8 * 1024 * 1024, maxFiles = 5000, maxDirs = 500;
const maxBytes = 2 * 1024 * 1024 * 1024, maxCache = 16 * 1024 * 1024;
const _gap = 5 * 60, _maxMeta = 64 * 1024, _maxDepth = 3, cacheVersion = 2;
final _model = RegExp(r'^[A-Za-z0-9._:/-]{1,100}$');
final _sid = RegExp(r'^[A-Za-z0-9-]{1,64}$');
final _agentType = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._:-]{0,63}$');
final _assistant = utf8.encode('"assistant"'),
    _cost = utf8.encode('"cost-state"');

int _number(dynamic v) => v is int && v >= 0 && v < 10000000000000 ? v : 0;

bool _contains(Uint8List data, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= data.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (data[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// add_reply: one model reply's model, tokens, time and project folder.
void addReply(NumericSession s, Map entry) {
  final message = entry['message'];
  if (message is! Map || message['usage'] is! Map) return;
  final usage = message['usage'] as Map;
  final model = message['model'];
  s.add(model is String && _model.hasMatch(model) ? model : 'unknown', [
    for (final key in [
      'input_tokens',
      'output_tokens',
      'cache_read_input_tokens',
      'cache_creation_input_tokens',
    ])
      _number(usage[key]),
  ]);
  if (s.cwd.isEmpty) s.cwd = projectFolder(entry['cwd']);
  final stamp = entry['timestamp'];
  final when = stamp is String ? epoch(stamp) : null;
  s.replies++;
  if (when == null) return;
  if (s.last != 0 && when - s.last > 0 && when - s.last <= _gap) {
    s.active += when - s.last;
  }
  s.first = s.first != 0 ? math.min(s.first, when) : when;
  s.last = math.max(s.last, when);
  final local = DateTime.fromMicrosecondsSinceEpoch((when * 1e6).round());
  final slot = '${(local.weekday - 1) * 24 + local.hour}';
  s.hours[slot] = (s.hours[slot] ?? 0) + 1;
}

/// add_cost: a session's cost summary (the latest one counts).
void addCost(NumericSession s, Map entry) {
  s.linesAdded = _number(entry['totalLinesAdded']);
  s.linesRemoved = _number(entry['totalLinesRemoved']);
  final cost = entry['totalCostUSD'];
  s.cost = cost is num && cost >= 0 && cost < 10000000 ? cost.toDouble() : 0;
  s.apiMs = _number(entry['totalAPIDuration']);
}

NumericSession? sessionFrom(dynamic data) {
  if (data is! Map) return null;
  try {
    final s = NumericSession()
      ..cwd = data['cwd'] as String? ?? ''
      ..first = (data['first'] as num? ?? 0).toDouble()
      ..last = (data['last'] as num? ?? 0).toDouble()
      ..active = (data['active'] as num? ?? 0).toDouble()
      ..replies = data['replies'] as int? ?? 0
      ..linesAdded = data['lines_added'] as int? ?? 0
      ..linesRemoved = data['lines_removed'] as int? ?? 0
      ..cost = (data['cost'] as num? ?? 0).toDouble()
      ..estimated = data['estimated'] == true
      ..apiMs = data['api_ms'] as int? ?? 0;
    for (final e in (data['tokens'] as Map? ?? const {}).entries) {
      s.tokens['${e.key}'] = [for (final n in e.value as List) n as int];
    }
    for (final e in (data['hours'] as Map? ?? const {}).entries) {
      s.hours['${e.key}'] = e.value as int;
    }
    return s;
  } on TypeError {
    return null;
  }
}

Map<String, dynamic> _plain(NumericSession s) => {
  ...s.toJson(),
  'subagents': <String, dynamic>{},
};

final class ClaudeSessions {
  ClaudeSessions(this.root, this.cacheFile, {Posix? posix})
    : posix = posix ?? Posix();
  final String root;
  final String? cacheFile;
  final Posix posix;

  /// read_file: the file read on from state's offset into its sessions;
  /// returns the bytes read.
  int readFile(String path, Map<String, dynamic> state, int budget) {
    final int fd;
    try {
      fd = posix.openAt(-100, path, Posix.noFollow | Posix.nonBlock);
    } on Object {
      return 0;
    }
    try {
      final st = posix.statFull(fd);
      if (st.mode & 0xf000 != 0x8000 || st.uid != posix.uid) return 0;
      final inode = st.identity[2];
      if (state['inode'] != inode || st.size < (state['offset'] as int? ?? 0)) {
        state.clear(); // a new or rewritten file: from the start
      }
      state['inode'] = inode;
      final sessions =
          (state['sessions'] ??= <String, dynamic>{}) as Map<String, dynamic>;
      var offset = state['offset'] as int? ?? 0;
      var read = 0;
      // Buffered lines from [offset]: what readline(maxLine + 1) gives.
      var buffer = Uint8List(0);
      var at = 0, filePos = offset, eof = false;
      void fill() {
        if (eof) return;
        final chunk = posix.readAt(fd, filePos, 4 * 1024 * 1024);
        if (chunk.isEmpty) {
          eof = true;
          return;
        }
        filePos += chunk.length;
        final rest = buffer.length - at;
        final next = Uint8List(rest + chunk.length)
          ..setRange(0, rest, buffer, at)
          ..setRange(rest, rest + chunk.length, chunk);
        buffer = next;
        at = 0;
      }

      Uint8List readline() {
        while (true) {
          final end = math.min(buffer.length, at + maxLine + 1);
          for (var i = at; i < end; i++) {
            if (buffer[i] == 10) {
              final line = Uint8List.sublistView(buffer, at, i + 1);
              at = i + 1;
              return line;
            }
          }
          if (end - at >= maxLine + 1 || eof) {
            final line = Uint8List.sublistView(buffer, at, end);
            at = end;
            return line;
          }
          fill();
        }
      }

      while (read < budget) {
        var line = readline();
        if (line.isEmpty) break;
        if (line.last != 10) {
          if (line.length <= maxLine) break; // still being written
          // Longer than maxLine: skip to its end and keep nothing of it.
          var skipped = line.length, done = false;
          while (true) {
            final more = readline();
            if (more.isEmpty) break;
            skipped += more.length;
            if (more.last == 10) {
              done = true;
              break;
            }
          }
          if (!done) break;
          read += skipped;
          offset += skipped;
          continue;
        }
        read += line.length;
        offset += line.length;
        if (!_contains(line, _assistant) && !_contains(line, _cost)) continue;
        dynamic entry;
        try {
          entry = jsonDecode(utf8.decode(line));
        } on FormatException {
          continue;
        }
        if (entry is! Map ||
            !const {'assistant', 'cost-state'}.contains(entry['type'])) {
          continue;
        }
        final raw = entry['sessionId'];
        final sid = raw is String && _sid.hasMatch(raw) ? raw : '?';
        final data = sessions[sid];
        final session = data is NumericSession
            ? data
            : sessionFrom(data) ?? NumericSession();
        sessions[sid] = session;
        if (entry['type'] == 'assistant') {
          addReply(session, entry);
        } else {
          addCost(session, entry);
        }
      }
      state['offset'] = offset;
      return read;
    } finally {
      posix.close(fd);
    }
  }

  Map<String, dynamic> _loadCache() {
    final path = cacheFile;
    if (path == null) return {};
    try {
      final fd = posix.openAt(-100, path, Posix.noFollow | Posix.nonBlock);
      try {
        if (posix.statFull(fd).uid != posix.uid) return {};
        // Over maxCache it is cut, so it no longer parses: none.
        final bytes = posix.readAt(fd, 0, maxCache + 1);
        final data = jsonDecode(
          utf8.decode(
            bytes.length > maxCache ? bytes.sublist(0, maxCache) : bytes,
          ),
        );
        if (data is! Map ||
            data['version'] != cacheVersion ||
            data['files'] is! Map) {
          return {};
        }
        return Map<String, dynamic>.from(data['files'] as Map);
      } finally {
        posix.close(fd);
      }
    } on Object {
      return {};
    }
  }

  void _saveCache(Map<String, Map<String, dynamic>> files) {
    final path = cacheFile;
    if (path == null) return;
    final plain = {
      for (final e in files.entries)
        e.key: {
          'inode': e.value['inode'],
          'offset': e.value['offset'] ?? 0,
          if (e.value['type'] is String) 'type': e.value['type'],
          'sessions': {
            for (final s in (e.value['sessions'] as Map? ?? const {}).entries)
              s.key: s.value is NumericSession
                  ? _plain(s.value as NumericSession)
                  : s.value,
          },
        },
    };
    try {
      final folder = p.dirname(path);
      if (!Directory(folder).existsSync()) {
        Directory(folder).createSync(recursive: true);
        posix.chmodPath(folder, 0x1c0);
      }
      posix.atomicWrite(
        path,
        utf8.encode(jsonEncode({'version': cacheVersion, 'files': plain})),
      );
    } on Object {
      // read again next time
    }
  }

  static bool _isDir(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.directory;

  List<String> _sorted(String folder) {
    final names = [
      for (final e in Directory(folder).listSync(followLinks: false)) e.path,
    ]..sort();
    return names;
  }

  /// _subagent_files: agent-*.jsonl below a session's subagents/ (own
  /// folders only, no links, bounded).
  List<String> subagentFiles(String sessionDir, int limit) {
    final found = <String>[];
    final stack = [(p.join(sessionDir, 'subagents'), 0)];
    while (stack.isNotEmpty && found.length < limit) {
      final (folder, depth) = stack.removeLast();
      List<String> items;
      try {
        items = _sorted(folder).take(maxDirs).toList();
      } on FileSystemException {
        continue;
      }
      for (final item in items) {
        final type = FileSystemEntity.typeSync(item, followLinks: false);
        if (type == FileSystemEntityType.link) continue;
        final name = p.basename(item);
        if (type == FileSystemEntityType.directory) {
          if (depth < _maxDepth) stack.add((item, depth + 1));
        } else if (name.startsWith('agent-') && name.endsWith('.jsonl')) {
          found.add(item);
        }
      }
    }
    return found.take(limit).toList();
  }

  /// agent_type: the run's agent type from its `agent-<id>.meta.json`.
  String agentType(String transcript) {
    final meta =
        '${transcript.substring(0, transcript.length - '.jsonl'.length)}.meta.json';
    try {
      final fd = posix.openAt(-100, meta, Posix.noFollow | Posix.nonBlock);
      try {
        final st = posix.statFull(fd);
        if (st.mode & 0xf000 != 0x8000 ||
            st.uid != posix.uid ||
            st.size > _maxMeta) {
          return '';
        }
        final data = jsonDecode(utf8.decode(posix.readAt(fd, 0, _maxMeta)));
        final kind = data is Map ? data['agentType'] : null;
        return kind is String && _agentType.hasMatch(kind) ? kind : '';
      } finally {
        posix.close(fd);
      }
    } on Object {
      return '';
    }
  }

  /// collect_by_id: {session id: its numbers} for every session with
  /// replies, its subagent runs counted in.
  Map<String, NumericSession> collect() {
    final cached = _loadCache();
    final seen = <String, Map<String, dynamic>>{};
    var budget = maxBytes;
    List<String> dirs;
    try {
      dirs = [
        for (final d in _sorted(root))
          if (_isDir(d)) d,
      ].take(maxDirs).toList();
    } on FileSystemException {
      dirs = [];
    }
    final paths = <String>[];
    final runs = <(String, String?)>[];
    for (final folder in dirs) {
      List<String> sessionDirs;
      try {
        for (final path in _sorted(folder)) {
          if (!path.endsWith('.jsonl')) continue;
          // Older Claude Code versions kept subagent runs next to sessions.
          if (p.basename(path).startsWith('agent-')) {
            runs.add((path, null));
          } else {
            paths.add(path);
          }
        }
        sessionDirs = [
          for (final d in _sorted(folder))
            if (_isDir(d) && _sid.hasMatch(p.basename(d))) d,
        ].take(maxFiles).toList();
      } on FileSystemException {
        continue;
      }
      for (final sessionDir in sessionDirs) {
        if (paths.length + runs.length >= maxFiles) break;
        runs.addAll([
          for (final path in subagentFiles(
            sessionDir,
            maxFiles - paths.length - runs.length,
          ))
            (path, p.basename(sessionDir)),
        ]);
      }
      if (paths.length + runs.length >= maxFiles) break;
    }
    for (final path in [...paths.take(maxFiles), for (final r in runs) r.$1]) {
      final old = cached[path];
      final state = old is Map
          ? Map<String, dynamic>.from(old)
          : <String, dynamic>{};
      if (state['sessions'] is Map) {
        state['sessions'] = Map<String, dynamic>.from(state['sessions'] as Map);
      }
      if (budget > 0) budget -= readFile(path, state, budget);
      seen[path] = state;
    }
    for (final (path, _) in runs) {
      final state = seen[path]!;
      if (!state.containsKey('type')) state['type'] = agentType(path);
    }
    _saveCache(seen);
    final sessions = <String, NumericSession>{};
    final runKeys = {for (final (path, sid) in runs) path: sid};
    for (final e in seen.entries) {
      if (runKeys.containsKey(e.key)) continue;
      for (final s in (e.value['sessions'] as Map? ?? const {}).entries) {
        final session = s.value is NumericSession
            ? s.value as NumericSession
            : sessionFrom(s.value);
        if (session != null && session.replies > 0) {
          sessions['${s.key}'] = session;
        }
      }
    }
    for (final e in runKeys.entries) {
      final state = seen[e.key]!;
      for (final s in (state['sessions'] as Map? ?? const {}).entries) {
        final parent = sessions[e.value ?? '${s.key}'];
        final run = s.value is NumericSession
            ? s.value as NumericSession
            : sessionFrom(s.value);
        if (parent == null || run == null || run.replies == 0) continue;
        final kind =
            state['type'] is String && (state['type'] as String).isNotEmpty
            ? state['type'] as String
            : '?';
        parent.run(kind, run);
      }
    }
    return sessions;
  }
}
