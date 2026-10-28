import 'dart:convert';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'activity_readers.dart' show metaText;
import 'py_time.dart';
import 'py_values.dart';
import 'scan_files.dart';
import 'sqlite_numbers.dart';

/// Python subagents.py and subagent_readers.py: delegated sessions of an
/// agent, from metadata only (no task text, transcript or answer leaves here).
const subagentRunning = 60.0;
const maxSubagents = 40, maxSessions = 2000, maxMeta = 16 * 1024;
const maxTask = 200, maxKind = 60;
const _maxFiles = 2000, _maxEntries = 8000, _maxHead = 512 * 1024;
const _maxTail = 128 * 1024, _maxEvents = 4 * 1024 * 1024;
const _maxTotal = 32 * 1024 * 1024, _tail = 256 * 1024, _maxLine = 64 * 1024;
const _handback = 'SubagentHandback';
final _session = RegExp(r'^[A-Za-z0-9-]{1,80}$');
final _metaName = RegExp(r'^(agent-[A-Za-z0-9_-]{1,80})\.meta\.json$');

final class Subagent {
  Subagent(this.key, this.kind, this.task, this.folder, this.running, this.age);
  final String key, kind, task, folder;
  final bool running;
  final double age;
}

typedef _Row = (dynamic, dynamic, dynamic, dynamic, dynamic, bool);

/// subagent_readers.epoch: a number as seconds, an ISO text through
/// fromisoformat (Z as UTC, naive as local), else 0.
double saEpoch(dynamic value) {
  if (value is num && value is! bool) {
    return value.isFinite && value >= 0 ? value.toDouble() : 0.0;
  }
  if (value is String && value.length <= 40) {
    final date = pyFromIsoformat(value.replaceAll('Z', '+00:00'));
    if (date != null) return saEpoch(date.microsecondsSinceEpoch / 1e6);
  }
  return 0.0;
}

/// subagent_readers.entries: JSON objects of the lines (bytes.splitlines).
Iterable<Map> _entries(List<int> data) sync* {
  var start = 0;
  for (var i = 0; i <= data.length; i++) {
    final end = i == data.length || data[i] == 10 || data[i] == 13;
    if (!end) continue;
    if (i > start) {
      try {
        final item = jsonDecode(
          utf8.decode(data.sublist(start, i), allowMalformed: true),
        );
        if (item is Map) yield item;
      } on FormatException {
        // not a JSON line
      }
    }
    if (i < data.length &&
        data[i] == 13 &&
        i + 1 < data.length &&
        data[i + 1] == 10) {
      i++;
    }
    start = i + 1;
  }
}

final class SubagentReaders {
  SubagentReaders(this.files, this.proc) : sqlite = SqliteNumbers(files);
  final ScanFiles files;
  final String proc;
  final SqliteNumbers sqlite;
  final _cache = <(String, String), (List<int>, List<_Row>)>{};

  String get _home => files.identity.home;
  String _text(dynamic value, int limit) => metaText(value, limit);
  String _tilde(String path) => path == _home || path.startsWith('$_home/')
      ? '~${path.substring(_home.length)}'
      : path;

  ({int sec, int nsec, int mode, int uid, List<int> signature})? _lstat(
    String path,
  ) => files.posix.lstatFull(path);

  bool _ownDir(String path) {
    final info = _lstat(path);
    return info != null &&
        info.mode & 0xf000 == 0x4000 &&
        info.uid == files.posix.uid;
  }

  double? _written(String path) {
    final info = _lstat(path);
    return info != null &&
            info.mode & 0xf000 == 0x8000 &&
            info.uid == files.posix.uid
        ? pyTimestamp(info.sec, info.nsec)
        : null;
  }

  /// A home-relative root with the home folder resolved, as the reference does.
  String resolveRoot(String root) {
    if (root == _home || root.startsWith('$_home/')) {
      try {
        return Directory(_home).resolveSymbolicLinksSync() +
            root.substring(_home.length);
      } on FileSystemException {
        return root;
      }
    }
    return root;
  }

  /// flutter_activity: link-based storage is unavailable, not zero activity.
  bool linkFree(String root) {
    var current = resolveRoot(files.expand(root));
    while (true) {
      if (FileSystemEntity.typeSync(current, followLinks: false) ==
          FileSystemEntityType.link) {
        return false;
      }
      final parent = p.dirname(current);
      if (parent == current) return true;
      current = parent;
    }
  }

  /// subagents.of: every working one, and the `kept` newest finished ones.
  List<Subagent> of(
    String agent,
    String form,
    String path,
    List<int> pids, {
    required double now,
    required double recent,
    required int kept,
  }) {
    final root = files.expand(path);
    final List<Subagent> subs;
    if (form == 'claude-projects') {
      subs = claudeProjects(agent, pids, now, root, recent);
    } else if (form == 'opencode-db') {
      subs = opencodeDb(agent, now, root, recent);
    } else if (form == 'codex-rollouts' || form == 'copilot-events') {
      subs = fromFiles(form, agent, now, resolveRoot(root), recent);
    } else if (form == 'goose-db') {
      subs = gooseDb(agent, now, resolveRoot(root), recent);
    } else {
      subs = [];
    }
    final result = [
      ...subs.where((s) => s.running),
      ...subs.where((s) => !s.running).take(kept < 0 ? 0 : kept),
    ];
    mergeSort(result, compare: (a, b) => a.age.compareTo(b.age));
    return result;
  }

  String? _ownCwd(int pid) {
    final info = files.posix.lstatFull('$proc/$pid', follow: true);
    if (info == null || info.uid != files.posix.uid) return null;
    try {
      return Link('$proc/$pid/cwd').targetSync();
    } on FileSystemException {
      return null;
    }
  }

  bool _handedBack(String transcript) {
    final data = files.bytes(transcript, limit: _tail, portion: 'tail');
    if (data == null) return false;
    final size = _size(transcript);
    var lines = _split(data, 10);
    if (size > data.length) lines = lines.skip(1).toList();
    lines = [
      for (final l in lines)
        if (l.isNotEmpty && l.length <= _maxLine) l,
    ];
    final last = lines.length > 4 ? lines.sublist(lines.length - 4) : lines;
    for (final line in last.reversed) {
      try {
        final entry = jsonDecode(utf8.decode(line, allowMalformed: true));
        final content = entry is Map && entry['message'] is Map
            ? (entry['message'] as Map)['content']
            : null;
        if (content is List &&
            content.any(
              (c) =>
                  c is Map && c['type'] == 'tool_use' && c['name'] == _handback,
            )) {
          return true;
        }
      } on FormatException {
        continue;
      }
    }
    return false;
  }

  int _size(String path) {
    try {
      return File(path).lengthSync();
    } on FileSystemException {
      return 0;
    }
  }

  static List<List<int>> _split(List<int> data, int byte) {
    final out = <List<int>>[];
    var start = 0;
    for (var i = 0; i < data.length; i++) {
      if (data[i] == byte) {
        out.add(data.sublist(start, i));
        start = i + 1;
      }
    }
    out.add(data.sublist(start));
    return out;
  }

  Map _meta(String path) {
    final data = files.bytes(path, limit: maxMeta);
    if (data == null) return {};
    try {
      final found = jsonDecode(utf8.decode(data, allowMalformed: true));
      return found is Map ? found : {};
    } on FormatException {
      return {};
    }
  }

  List<Subagent> claudeProjects(
    String agent,
    List<int> pids,
    double now,
    String root,
    double recent,
  ) {
    final found = <Subagent>[], folders = <String, String>{};
    for (final pid in pids.take(64)) {
      final cwd = _ownCwd(pid);
      if (cwd != null && cwd.isNotEmpty) {
        folders.putIfAbsent(
          cwd.replaceAll(RegExp(r'[^A-Za-z0-9]'), '-'),
          () => cwd,
        );
      }
    }
    for (final MapEntry(key: name, value: cwd) in folders.entries) {
      final project = p.join(root, name);
      if (!_ownDir(project)) continue;
      final sessions = [
        for (final entry in files.list(project, limit: maxSessions))
          if (_session.hasMatch(p.basename(entry)) &&
              (_lstat(entry)?.mode ?? 0) & 0xf000 == 0x4000)
            p.basename(entry),
      ];
      for (final session in sessions) {
        final folder = p.join(project, session, 'subagents');
        if (!_ownDir(folder)) continue;
        final names = [
          for (final e in files.list(folder, limit: 1 << 20)) p.basename(e),
        ]..sort();
        for (final metaName in names.take(maxSessions)) {
          final match = _metaName.firstMatch(metaName);
          if (match == null) continue;
          final transcript = p.join(folder, '${match[1]}.jsonl');
          var written = _written(transcript);
          if (written == null || written == 0) {
            written = _written(p.join(folder, metaName));
          }
          if (written == null || now - written > recent) continue;
          final meta = _meta(p.join(folder, metaName));
          final running =
              now - written <= subagentRunning && !_handedBack(transcript);
          final kind = _text(meta['agentType'], maxKind);
          found.add(
            Subagent(
              '$agent:$session:${match[1]}',
              kind.isEmpty ? 'general-purpose' : kind,
              _text(meta['description'], maxTask),
              _tilde(cwd),
              running,
              now - written < 0 ? 0.0 : now - written,
            ),
          );
        }
      }
    }
    mergeSort(found, compare: (a, b) => a.age.compareTo(b.age));
    return found.take(maxSubagents).toList();
  }

  List<Subagent> opencodeDb(
    String agent,
    double now,
    String db,
    double recent,
  ) {
    final info = _lstat(db);
    if (info == null ||
        info.mode & 0xf000 != 0x8000 ||
        info.uid != files.posix.uid) {
      return [];
    }
    final since = ((now - recent) * 1000).truncate();
    final found = <Subagent>[];
    for (final row in sqlite.select(
      db,
      'SELECT id, title, agent, directory, time_updated, time_idle FROM session_v2'
      ' WHERE parent_id IS NOT NULL AND time_updated >= $since'
      ' ORDER BY time_updated DESC LIMIT $maxSubagents',
      maxRows: maxSubagents,
    )) {
      final updated = row[4];
      if (updated is! num) continue;
      final age = now - updated / 1000 < 0 ? 0.0 : now - updated / 1000;
      final idle = row[5];
      final finished = idle is num && idle >= updated;
      final kind = _text(row[2], maxKind);
      found.add(
        Subagent(
          '$agent:${_text(row[0], 80)}',
          kind.isEmpty ? 'subagent' : kind,
          _text(row[1], maxTask),
          _tilde(_text(row[3], 4096)),
          !finished && age <= subagentRunning,
          age,
        ),
      );
    }
    return found;
  }

  Subagent? _row(String agent, _Row row, double now, double recent) {
    final (sid, kind, task, folder, written, finished) = row;
    final when = saEpoch(written), id = _text(sid, 160);
    if (when == 0 || now - when > recent || id.isEmpty) return null;
    final age = now - when < 0 ? 0.0 : now - when;
    final type = _text(kind, maxKind);
    return Subagent(
      '$agent:$id',
      type.isEmpty ? 'subagent' : type,
      _text(task, maxTask),
      _tilde(_text(folder, 4096)),
      !finished && age <= subagentRunning,
      age,
    );
  }

  List<Subagent> gooseDb(String agent, double now, String db, double recent) {
    if (files.credential(db) ||
        !linkFree(p.dirname(db)) ||
        _written(db) == null ||
        !_ownDir(p.dirname(db))) {
      return [];
    }
    final rows = sqlite.select(
      db,
      "SELECT substr(id,1,80), substr(session_type,1,60), '', substr(working_dir,1,4096), "
      "CASE WHEN typeof(updated_at) IN ('integer','real') THEN updated_at ELSE substr(updated_at,1,40) END, 0 FROM sessions "
      "WHERE session_type = 'sub_agent' AND parent_session_id IS NOT NULL "
      'ORDER BY updated_at DESC LIMIT $_maxFiles',
      maxRows: _maxFiles,
    );
    final found = [
      for (final r in rows)
        ?_row(agent, (r[0], r[1], r[2], r[3], r[4], false), now, recent),
    ];
    mergeSort(found, compare: (a, b) => a.age.compareTo(b.age));
    return found.take(maxSubagents).toList();
  }

  /// subagent_readers.files: own folders, bounded, newest files first.
  List<
    (
      String,
      ({int sec, int nsec, int mode, int uid, List<int> signature}),
      List<int>,
    )
  >
  _files(String root, String suffix, int depth, double now, double recent) {
    if (!root.startsWith('/') || !linkFree(root)) return [];
    final pending = [(root, 0)],
        found =
            <
              (
                String,
                ({int sec, int nsec, int mode, int uid, List<int> signature}),
                List<int>,
              )
            >[];
    var inspected = 0;
    while (pending.isNotEmpty && inspected < _maxEntries) {
      final (folder, level) = pending.removeLast();
      if (!_ownDir(folder)) continue;
      final children = files.list(folder, limit: _maxEntries - inspected);
      inspected += children.length;
      for (final child in children.toList()..sort()) {
        final info = _lstat(child);
        if (info == null) continue;
        if (info.mode & 0xf000 == 0x4000 && level < depth) {
          pending.add((child, level + 1));
        } else if (p.basename(child).endsWith(suffix) &&
            info.mode & 0xf000 == 0x8000 &&
            info.uid == files.posix.uid &&
            now - pyTimestamp(info.sec, info.nsec) <= recent) {
          found.add((child, info, files.posix.signature(child) ?? const []));
        }
      }
    }
    mergeSort(
      found,
      compare: (a, b) => pyTimestamp(
        b.$2.sec,
        b.$2.nsec,
      ).compareTo(pyTimestamp(a.$2.sec, a.$2.nsec)),
    );
    return found.take(_maxFiles).toList();
  }

  List<Subagent> fromFiles(
    String form,
    String agent,
    double now,
    String root,
    double recent,
  ) {
    final whole = form == 'copilot-events';
    final suffix = whole ? 'events.jsonl' : '.jsonl', depth = whole ? 1 : 3;
    final found = <Subagent>[], used = <(String, String)>{};
    var budget = _maxTotal;
    for (final (path, info, signature) in _files(
      root,
      suffix,
      depth,
      now,
      recent,
    )) {
      final key = (form, path);
      used.add(key);
      final cached = _cache[key];
      List<_Row> rows;
      if (cached != null &&
          signature.isNotEmpty &&
          const ListEquality<int>().equals(cached.$1, signature)) {
        rows = cached.$2;
      } else {
        final size = signature.length > 3 ? signature[3] : 0;
        final amount = [
          size,
          whole ? _maxEvents + _maxHead + 1 : _maxHead + _maxTail + 1,
        ].min;
        if (amount > budget) continue;
        budget -= amount;
        final written = pyTimestamp(info.sec, info.nsec);
        rows = whole
            ? _copilot(path, signature, written)
            : _rollout(path, signature, written);
        mergeSort(
          rows,
          compare: (a, b) => saEpoch(b.$5).compareTo(saEpoch(a.$5)),
        );
        rows = rows.take(maxSubagents).toList();
        _cache[key] = (signature, rows);
      }
      for (final row in rows) {
        final sub = _row(agent, row, now, recent);
        if (sub != null) found.add(sub);
      }
    }
    _cache.removeWhere((key, _) => key.$1 == form && !used.contains(key));
    mergeSort(found, compare: (a, b) => a.age.compareTo(b.age));
    final unique = <String, Subagent>{};
    for (final s in found) {
      unique.putIfAbsent(s.key, () => s);
    }
    return unique.values.take(maxSubagents).toList();
  }

  /// subagent_readers.read: the opened file checked again (same device and
  /// inode); the metadata line and the lifecycle tail, or bounded events.
  (List<int>, List<int>) _read(String path, List<int> signature, bool whole) =>
      files.posix.readChecked(path, (fd, size) {
        if (whole) {
          if (size <= _maxEvents) {
            return (files.posix.readAt(fd, 0, _maxEvents + 1), const <int>[]);
          }
          final head = files.posix.readAt(fd, 0, _maxHead);
          final from = size - _maxEvents > head.length
              ? size - _maxEvents
              : head.length;
          return (head, files.posix.readAt(fd, from, _maxEvents));
        }
        final first = files.posix.readAt(fd, 0, _maxHead + 1);
        final newline = first.indexOf(10);
        final head = newline < 0 ? first : first.sublist(0, newline + 1);
        if (head.length > _maxHead) return (const <int>[], const <int>[]);
        final from = size - _maxTail > head.length
            ? size - _maxTail
            : head.length;
        return (head, files.posix.readAt(fd, from, _maxTail));
      }, expected: signature) ??
      (const <int>[], const <int>[]);

  List<_Row> _rollout(String path, List<int> signature, double written) {
    final (head, tail) = _read(path, signature, false);
    final meta = _entries(head).firstOrNull ?? {};
    if (meta['type'] != 'session_meta' || meta['payload'] is! Map) return [];
    final payload = meta['payload'] as Map;
    final source = payload['source'];
    final sub = source is Map ? source['subagent'] : null;
    final spawnRaw = sub is Map ? sub['thread_spawn'] : null;
    final spawn = spawnRaw is Map ? spawnRaw : const {};
    final parent = _or(payload['parent_thread_id'], spawn['parent_thread_id']);
    final delegated =
        (sub is String && sub.isNotEmpty) || (sub is Map && sub.isNotEmpty);
    if (!delegated || parent is! String || !_session.hasMatch(parent)) {
      return [];
    }
    final name = _or(
      _or(
        _or(payload['agent_path'], spawn['agent_path']),
        payload['agent_nickname'],
      ),
      spawn['agent_nickname'],
    );
    var role = _or(_or(payload['agent_role'], spawn['agent_role']), name);
    if (name is String && role is String && name != role) {
      role = '$role · $name';
    }
    var finished = false;
    for (final event in _entries(tail)) {
      final body = event['payload'];
      if (event['type'] == 'event_msg' && body is Map) {
        final kind = body['type'];
        if (kind == 'task_complete' || kind == 'turn_aborted') {
          finished = true;
        } else if (kind == 'task_started' || kind == 'turn_started') {
          finished = false;
        }
      }
    }
    return [(payload['id'], role, name, payload['cwd'], written, finished)];
  }

  List<_Row> _copilot(String path, List<int> signature, double written) {
    final (head, tail) = _read(path, signature, true);
    final data = [...head, ...tail];
    final end = data.lastIndexOf(10) + 1;
    final events = _entries(data.sublist(0, end)).toList();
    // The reference first takes the session's last folder, then walks again.
    dynamic cwd = '';
    for (final event in events) {
      final body = event['data'];
      if (event['type'] == 'session.start' && body is Map) {
        final context = body['context'] ?? {};
        if (context is Map) cwd = _text(context['cwd'], 4096);
      }
    }
    final runs = <String, List<dynamic>>{};
    final folder = p.basename(p.dirname(path));
    for (final event in events) {
      final body = event['data'];
      if (body is! Map) continue;
      final kind = event['type'];
      if (kind == 'session.start') {
        final context = body['context'];
        if (context is Map) {
          cwd = context.containsKey('cwd') ? context['cwd'] : '';
        }
      }
      final key = _text(body['toolCallId'], 100);
      if (key.isEmpty) continue;
      final at = saEpoch(event['timestamp']);
      if (kind == 'subagent.started') {
        runs[key] = [
          '$folder:$key',
          body['agentName'],
          pyTruthy(body['agentDisplayName']) ? body['agentDisplayName'] : '',
          cwd,
          at == 0 ? written : at,
          false,
        ];
      } else if (kind == 'subagent.completed' || kind == 'subagent.failed') {
        runs.putIfAbsent(
          key,
          () => ['$folder:$key', body['agentName'], '', cwd, written, true],
        );
        runs[key]![4] = at == 0 ? written : at;
        runs[key]![5] = true;
      }
    }
    return [
      for (final r in runs.values) (r[0], r[1], r[2], r[3], r[4], r[5] as bool),
    ];
  }

  static dynamic _or(dynamic a, dynamic b) => pyTruthy(a) ? a : b;
}
