import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'posix_ffi.dart';
import 'py_values.dart' show pyJsonDumps;

/// system_map_cache: the saved System Map, private and bounded. Loading
/// never detects or runs anything.
const mapCacheMaxBytes = 900 * 1024;
const maxMapNodes = 256;

bool _str(Map m, String key) => m[key] is String;
bool _num(dynamic v) =>
    (v is int || v is double) && (v is! double || v.isFinite);

/// valid_view: a saved zoom and pan (a 4x4 matrix of scale and offset only).
bool validView(dynamic view) {
  if (view is! Map ||
      (view['selected'] != null && view['selected'] is! String)) {
    return false;
  }
  final m = view['transform'];
  if (m is! List ||
      m.length != 16 ||
      m.any((x) => !_num(x) || (x as num).abs() > 1e6)) {
    return false;
  }
  final n = [for (final x in m) (x as num).toDouble()];
  return 0.05 <= n[0] &&
      n[0] <= 20 &&
      (n[0] - n[5]).abs() < 1e-6 &&
      n[10] == 1 &&
      n[15] == 1 &&
      [1, 2, 3, 4, 6, 7, 8, 9, 11, 14].every((i) => n[i] == 0);
}

/// load: the cache when it is this account's private file of the expected
/// form, else {}.
Map<String, dynamic> loadMapCache(String path, Posix posix) {
  try {
    final raw = posix.readRegular(path, mapCacheMaxBytes + 1);
    final st = posix.lstatOwn(path);
    if (st == null ||
        st.uid != posix.uid ||
        st.mode & 0x3f != 0 ||
        raw.length > mapCacheMaxBytes) {
      return {};
    }
    final data = jsonDecode(utf8.decode(raw));
    if (data is! Map<String, dynamic> || data['version'] != 1) return {};
    final nodes = data['nodes'], edges = data['edges'];
    if (nodes is! List || edges is! List || nodes.length > maxMapNodes) {
      return {};
    }
    for (final row in nodes) {
      if (row is! Map ||
          ![
            'id',
            'path',
            'kind',
            'label',
            'status',
            'detail',
            'info',
          ].every((k) => _str(row, k)) ||
          row['column'] is! int ||
          (row['column'] as int) < 0 ||
          (row['column'] as int) > 4) {
        return {};
      }
    }
    final checked = data['checked_at'];
    if (!_num(checked) || (checked as num) < 0 || checked >= 1e11) return {};
    if (data['search_done'] is! bool) return {};
    if (edges.any(
      (e) => e is! Map || !_str(e, 'source') || !_str(e, 'target'),
    )) {
      return {};
    }
    bool mountOk(dynamic m) =>
        m is Map && ['path', 'filesystem', 'identity'].every((k) => _str(m, k));
    final mounts = data['mounts'];
    if (mounts is! List || !mounts.every(mountOk)) return {};
    final records = data['records'];
    if (records is! List || records.length > 128) return {};
    for (final r in records) {
      if (r is! Map ||
          !['path', 'provider', 'kind', 'name'].every((k) => _str(r, k)) ||
          !const {'runtime', 'models', 'store'}.contains(r['kind']) ||
          !mountOk(r['mount']) ||
          r['count'] is! int ||
          r['stamps'] is! Map ||
          r['dependencies'] is! List ||
          r['environment'] is! Map) {
        return {};
      }
    }
    final notes = data['notes'];
    if (notes is! List || notes.any((n) => n is! String)) return {};
    for (final optional in ['health', 'scan_limits']) {
      if (data[optional] is! List) data[optional] = [];
    }
    data['health'] = [
      for (final f in data['health'] as List)
        if (f is Map &&
            ['node', 'level', 'title', 'text'].every((k) => _str(f, k)))
          f,
    ];
    data['scan_limits'] = [
      for (final s in data['scan_limits'] as List)
        if (s is Map &&
            _str(s, 'path') &&
            ['limits', 'notices', 'foreign'].every((k) => (s[k] ?? []) is List))
          s,
    ];
    for (final n in nodes.cast<Map>()) {
      if (n.containsKey('size') &&
          (!_num(n['size']) || (n['size'] as num) < 0)) {
        n.remove('size');
      }
      final stack = n['stack'];
      if (n.containsKey('stack') &&
          stack != null &&
          (stack is! Map ||
              stack['torch'] is! List ||
              stack['missing'] is! List)) {
        n.remove('stack');
      }
    }
    if (data['view'] != null && !validView(data['view'])) data['view'] = null;
    final analysis = data['analysis'];
    if (analysis != null) {
      if (analysis is! Map ||
          !['summary', 'when', 'agent'].every((k) => _str(analysis, k)) ||
          analysis['findings'] is! List) {
        data['analysis'] = null;
      } else if ((analysis['findings'] as List).any(
        (f) =>
            f is! Map ||
            ![
              'id',
              'node',
              'level',
              'title',
              'detail',
            ].every((k) => _str(f, k)) ||
            !const {'problem', 'tip', 'good'}.contains(f['level']),
      )) {
        data['analysis'] = null;
      }
    }
    final helpers = data['helpers'] ?? [];
    if (helpers is! List ||
        helpers.any(
          (h) => h is! Map || !_str(h, 'command') || !_str(h, 'name'),
        )) {
      return {};
    }
    return data;
  } catch (_) {
    return {};
  }
}

/// transact: under the cache's lock, transform the loaded cache and save it.
Map<String, dynamic> transactMapCache(
  String path,
  Posix posix,
  Map<String, dynamic> Function(Map<String, dynamic>) transform,
) {
  Directory(p.dirname(path)).createSync(recursive: true);
  final lockPath = '${p.withoutExtension(path)}.lock';
  final fd = posix.openAt(
    -100,
    lockPath,
    1 | 0x40 | Posix.noFollow | Posix.cloexec,
    0x180,
  );
  try {
    final st = posix.stat(fd);
    if (st.mode & 0xf000 != 0x8000 ||
        st.uid != posix.uid ||
        st.mode & 0x3f != 0) {
      throw const FormatException('Invalid System Map lock');
    }
    posix.lockExclusive(fd);
    final data = transform(loadMapCache(path, posix));
    if (data.isEmpty) return {};
    final body = pyJsonDumps(data);
    if (utf8.encode(body).length > mapCacheMaxBytes) {
      throw const FormatException('System Map cache too large');
    }
    posix.atomicWrite(path, utf8.encode(body));
    return data;
  } finally {
    posix.close(fd);
  }
}

String _when(dynamic analysis) =>
    analysis is Map ? '${analysis['when'] ?? ''}' : '';

/// save: a new map; a newer analysis and the Undo of a move and the view stay.
void saveMapCache(
  String path,
  Posix posix,
  Map<String, dynamic> data, {
  bool preserveActions = true,
}) {
  transactMapCache(path, posix, (previous) {
    if (_when(previous['analysis']).compareTo(_when(data['analysis'])) > 0) {
      data['analysis'] = previous['analysis'];
    }
    if (preserveActions) {
      for (final key in ['move_undo', 'view']) {
        if (previous.containsKey(key)) data[key] = previous[key];
      }
    }
    return data;
  });
}

/// update: values merged into an existing cache (an older analysis never wins).
Map<String, dynamic> updateMapCache(
  String path,
  Posix posix,
  Map<String, dynamic> values,
) => transactMapCache(path, posix, (previous) {
  if (previous.isEmpty) return {};
  if (values.containsKey('analysis') &&
      _when(previous['analysis']).compareTo(_when(values['analysis'])) > 0) {
    return previous;
  }
  return {...previous, ...values};
});

/// flutter_system_map.bounded: at most 256 nodes, 512 edges and 700 KiB.
Map<String, dynamic> boundedMap(Map<String, dynamic> result) {
  result['nodes'] = (result['nodes'] as List).take(maxMapNodes).toList();
  result['edges'] = (result['edges'] as List).take(512).toList();
  while (utf8.encode(pyJsonDumps(result)).length > 700 * 1024 &&
      (result['nodes'] as List).length > 1) {
    final records = result['records'];
    if (records is List && records.isNotEmpty) {
      records.removeLast();
    } else {
      (result['nodes'] as List).removeLast();
    }
    result['limited'] = true;
    final ids = {for (final n in result['nodes'] as List) n['id']};
    result['edges'] = [
      for (final e in result['edges'] as List)
        if (ids.contains(e['source']) && ids.contains(e['target'])) e,
    ];
  }
  return result;
}

/// flutter_system_map.discovery_node.
Map<String, dynamic> discoveryNode(Map row) {
  final launch = (row['launch_path'] ?? row['path']) as String;
  return {
    'id': 'found:${row['path']}',
    'label': row['name'],
    'detail': launch,
    'column': row['kind'] == 'runtime' ? 2 : 4,
    'kind': row['kind'],
    'path': row['path'],
    'launch_path': launch,
    'status': 'found',
    'info': launch != row['path'] ? row['path'] : '',
    'mount_path': (row['mount'] as Map)['path'],
  };
}

/// SystemMap.register: discoveries added as nodes, bounded, saved.
Map<String, dynamic> registerMap(
  String cachePath,
  Posix posix,
  Map<String, dynamic> result, [
  List discoveries = const [],
]) {
  final nodes = result['nodes'] as List;
  final ids = {for (final n in nodes) n['id']};
  for (final row in discoveries.take(128).cast<Map>()) {
    if (nodes.length >= maxMapNodes) {
      result['limited'] = true;
      break;
    }
    if (nodes.any(
      (n) =>
          '${n['path']}'.isNotEmpty && _realpath('${n['path']}') == row['path'],
    )) {
      continue;
    }
    final ident = 'found:${row['path']}';
    if (ids.contains(ident)) continue;
    nodes.add(discoveryNode(row));
    ids.add(ident);
    final disk = 'disk:${(row['mount'] as Map)['path']}';
    (result['edges'] as List).add({
      'source': ids.contains(disk) ? disk : 'pc',
      'target': ident,
    });
  }
  final bounded = boundedMap(result);
  if (bounded['version'] == 1) saveMapCache(cachePath, posix, bounded);
  return bounded;
}

String _realpath(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return p.normalize(p.absolute(path));
  }
}
