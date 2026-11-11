import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'process_group.dart' show ProcessGroup;
import 'package:path/path.dart' as p;
import 'connect_apply.dart';
import 'desktop.dart' show shellJoin, shellQuote;
import 'posix_ffi.dart';
import 'py_values.dart' show pyJsonDumps, pyTruthy;
import 'system_reads.dart' show localMounts;

/// existing_ai: bounded, user-requested discovery of AI programs and models on
/// mounted local data disks (another distro's Ollama or llama.cpp). Nothing
/// found is run; reconnecting writes new connecting files only.

const maxEntries = 12000, maxDepth = 5, maxResults = 128;
const maxSeconds = 5.0;
const existingMaxBytes = 256 * 1024;

/// A stat as Python's os.stat gives it (st_dev made the glibc way).
typedef StatInfo = ({
  int dev,
  int ino,
  int size,
  int mtimeNs,
  int mode,
  int uid,
});

final _posix = Posix();

int _makedev(int major, int minor) =>
    ((major & 0xfffff000) << 32) |
    ((major & 0xfff) << 8) |
    ((minor & 0xffffff00) << 12) |
    (minor & 0xff);

StatInfo? statOf(String path, {bool follow = true}) {
  final st = _posix.lstatFull(path, follow: follow);
  if (st == null) return null;
  final s = st.signature;
  return (
    dev: _makedev(s[0], s[1]),
    ino: s[2],
    size: s[3],
    mtimeNs: s[4] * 1000000000 + s[5],
    mode: st.mode,
    uid: st.uid,
  );
}

bool _isDir(int mode) => mode & 0xf000 == 0x4000;
bool _isReg(int mode) => mode & 0xf000 == 0x8000;
bool _isLink(String path) => FileSystemEntity.isLinkSync(path);
bool _within(String path, String root) =>
    path == root || p.isWithin(root, path);

List<Map<String, String>> mounts([String? text]) =>
    localMounts(text ?? File('/proc/self/mountinfo').readAsStringSync());

/// root_for: a real absolute folder on one of the mounts (the innermost).
Map<String, String> rootFor(String path, List<Map<String, String>> available) {
  if (path.isEmpty || path.length > 4096 || path.codeUnits.any((c) => c < 32)) {
    throw const FormatException('Choose a mounted data folder');
  }
  String? real;
  try {
    real = p.isAbsolute(path)
        ? Directory(path).resolveSymbolicLinksSync()
        : null;
  } on FileSystemException {
    real = p.isAbsolute(path) ? _resolveLoose(path) : null;
  }
  if (real == null || real != path) {
    throw const FormatException('Choose a real absolute folder');
  }
  final found = available.where((row) => _within(path, row['path']!)).toList();
  if (found.isEmpty || !FileSystemEntity.isDirectorySync(path)) {
    throw const FormatException(
      'Folder is not on a supported mounted local disk',
    );
  }
  return found.reduce((a, b) => b['path']!.length > a['path']!.length ? b : a);
}

String _resolveLoose(String path) {
  // Path.resolve() for a path that does not exist: its existing part resolved.
  var head = path, tail = <String>[];
  while (FileSystemEntity.typeSync(head) == FileSystemEntityType.notFound &&
      head != '/') {
    tail.insert(0, p.basename(head));
    head = p.dirname(head);
  }
  final base = Directory(head).resolveSymbolicLinksSync();
  return tail.isEmpty ? base : p.joinAll([base, ...tail]);
}

/// stamp: st_dev, st_ino, st_size, st_mtime_ns (links followed).
List<int> stamp(String path) {
  final st = statOf(path);
  if (st == null) throw FileSystemException('cannot be read', path);
  return [st.dev, st.ino, st.size, st.mtimeNs];
}

/// safe: where path leads, when that is this account's, on this disk, of the
/// asked kind (a native program, a regular file, a folder); else null.
String? safe(
  String path,
  String mount,
  int device, {
  bool executable = false,
  bool regular = false,
}) {
  try {
    final resolved = File(path).resolveSymbolicLinksSync();
    if (!_within(resolved, mount)) return null;
    final st = statOf(resolved);
    if (st == null || st.dev != device || st.uid != _posix.uid) return null;
    if (executable) {
      final base = p.basename(resolved).toLowerCase();
      if (p.extension(base) == '.json' || base.contains('credentials')) {
        return null;
      }
      if (!_isReg(st.mode) || st.mode & 0x40 == 0) return null;
      final fd = _posix.openAt(
        -100,
        resolved,
        Posix.noFollow | Posix.nonBlock | Posix.cloexec,
      );
      try {
        if (!_isReg(_posix.stat(fd).mode)) return null;
        final head = _posix.readAt(fd, 0, 4);
        if (head.length != 4 ||
            head[0] != 0x7f ||
            head[1] != 0x45 ||
            head[2] != 0x4c ||
            head[3] != 0x46) {
          return null;
        }
      } finally {
        _posix.close(fd);
      }
    } else if (regular && !_isReg(st.mode)) {
      return null;
    } else if (!regular && !_isDir(st.mode)) {
      return null;
    }
    return resolved;
  } on FileSystemException {
    return null;
  }
}

/// link_stamp: lstat's st_dev, st_ino, st_size, st_mtime_ns and its target.
List<dynamic> linkStamp(String path) {
  final st = statOf(path, follow: false)!;
  return [st.dev, st.ino, st.size, st.mtimeNs, Link(path).targetSync()];
}

/// program: a native program reached through links that all stay on the
/// mount and are this account's (each link remembered).
Map<String, dynamic>? program(String path, String mount, int device) {
  final target = safe(path, mount, device, executable: true);
  if (target == null) return null;
  final links = <String, dynamic>{};
  try {
    final pending = Queue<String>.of(p.split(p.relative(path, from: mount)));
    var current = mount;
    var followed = 0;
    while (pending.isNotEmpty) {
      final name = pending.removeFirst();
      if (name == '..') {
        current = p.dirname(current);
        if (!_within(current, mount)) return null;
        continue;
      }
      if (name == '.') continue;
      final part = p.join(current, name);
      if (_isLink(part)) {
        final st = statOf(part, follow: false)!;
        followed++;
        if (st.uid != _posix.uid || st.dev != device || followed > 40) {
          return null;
        }
        links[part] = linkStamp(part);
        final direct = Link(part).targetSync();
        List<String> parts;
        if (p.isAbsolute(direct)) {
          if (!_within(direct, mount)) return null;
          current = mount;
          parts = direct == mount
              ? []
              : p.split(p.relative(direct, from: mount));
        } else {
          parts = p.split(direct);
        }
        for (final x in parts.reversed) {
          pending.addFirst(x);
        }
      } else {
        current = part;
      }
    }
    if (current != target) return null;
  } on FileSystemException {
    return null;
  }
  return {'path': target, 'launch_path': path, 'links': links};
}

/// The built-in local LLMs that know their own installs (providers'
/// discover_existing / reconnect_existing): Ollama and llama.cpp.
const providerPrograms = {
  'ollama': ['ollama'],
  'llamacpp': ['llama-server'],
};

List<Map<String, dynamic>> discover(
  String key,
  String folder,
  List<String> names,
  String mount,
  int device,
) {
  if (key == 'ollama') {
    final rows = <Map<String, dynamic>>[];
    Map<String, dynamic>? candidate;
    for (final relative in ['current/bin/ollama', 'current/ollama', 'ollama']) {
      if (names.contains(relative.split('/').first)) {
        candidate = program(p.join(folder, relative), mount, device);
        if (candidate != null) break;
      }
    }
    if (candidate != null) {
      rows.add({
        'kind': 'runtime',
        'provider': 'ollama',
        'name': 'Ollama',
        ...candidate,
        'models': '',
        'count': 0,
        'environment': <String, String>{},
        'dependencies': <String>[],
      });
    }
    if ((names.contains('manifests') || names.contains('manifests-v2')) &&
        names.contains('blobs')) {
      if (safe(p.join(folder, 'blobs'), mount, device) != null &&
          [
            'manifests',
            'manifests-v2',
          ].any((n) => safe(p.join(folder, n), mount, device) != null)) {
        rows.add({
          'kind': 'store',
          'provider': 'ollama',
          'name': 'Ollama',
          'path': folder,
          'models': '',
          'count': 0,
          'environment': <String, String>{},
          'dependencies': <String>[],
        });
      }
    }
    return rows;
  }
  // llama.cpp
  if (p
      .split(folder)
      .any(
        (part) => const {'ollama', '.lmstudio'}.contains(part.toLowerCase()),
      )) {
    return [];
  }
  Map<String, dynamic>? candidate;
  for (final relative in ['current/llama-server', 'llama-server']) {
    if (names.contains(relative.split('/').first)) {
      candidate = program(p.join(folder, relative), mount, device);
      if (candidate != null) break;
    }
  }
  if (candidate == null) return [];
  var environment = <String, String>{};
  var dependencies = <String>[];
  // Portable ROCm trees often sit beside the program, outside the distro root.
  final parents = <String>[];
  for (var d = p.dirname(folder); parents.length < 4; d = p.dirname(d)) {
    parents.add(d);
    if (d == p.dirname(d)) break;
  }
  for (final parent in parents) {
    if (!_within(parent, mount)) break;
    final runtime = p.join(parent, 'rocm-runtime/root');
    final rocm = safe(p.join(runtime, 'opt/rocm'), mount, device);
    final libs = safe(p.join(runtime, 'usr/lib'), mount, device);
    if (rocm != null && libs != null) {
      final valid = [
        libs,
        p.join(rocm, 'lib'),
        p.join(rocm, 'lib/llvm/lib'),
      ].map((x) => safe(x, mount, device));
      environment = {
        'ROCM_PATH': rocm,
        'HIP_PATH': rocm,
        'LD_LIBRARY_PATH': valid.whereType<String>().join(':'),
        'ROCBLAS_TENSILE_LIBPATH': p.join(rocm, 'lib/rocblas/library'),
      };
      dependencies = [rocm, libs];
      break;
    }
  }
  return [
    {
      'kind': 'runtime',
      'provider': 'llamacpp',
      'name': 'llama.cpp',
      ...candidate,
      'models': '',
      'count': 0,
      'notes': [
        'GPU selection uses runtime defaults. Review device selection before loading a model.',
        'A new model preset starts with GPU layers set to all. Existing tuning is not copied.',
      ],
      'environment': environment,
      'dependencies': dependencies,
    },
  ];
}

/// scan: the folder's tree breadth first, bounded in entries, depth, results
/// and time; GGUF folders and the providers' own installs.
Map<String, dynamic> scan(String path, void Function(double, String) progress) {
  final available = mounts();
  final mounted = rootFor(path, available);
  final mount = mounted['path']!;
  final device = statOf(mount)!.dev;
  final programNames = {for (final v in providerPrograms.values) ...v};
  final started = DateTime.now();
  bool late() =>
      DateTime.now().difference(started).inMicroseconds >= maxSeconds * 1e6;
  final pending = Queue<(String, int)>.of([(path, 0)]);
  final visited = <String>{};
  var count = 0;
  final results = <String, Map<String, dynamic>>{};
  var limited = false;
  final limits = <String>{}, notices = <String>{}, foreign = <String>{};
  while (pending.isNotEmpty) {
    if (count >= maxEntries || late() || results.length >= maxResults) {
      limits.add(
        count >= maxEntries
            ? 'entries'
            : late()
            ? 'time'
            : 'results',
      );
      limited = true;
      break;
    }
    final (folder, depth) = pending.removeFirst();
    if (!visited.add(folder)) continue;
    if (folder != mount && safe(folder, mount, device) == null) {
      final st = statOf(folder);
      if (st != null) {
        if (st.uid != _posix.uid) notices.add('ownership');
        if (st.dev != device) notices.add('filesystem');
      }
      continue;
    }
    final names = <String>[];
    try {
      for (final entry in Directory(folder).listSync(followLinks: false)) {
        count++;
        if (count >= maxEntries || late()) {
          limits.add(count >= maxEntries ? 'entries' : 'time');
          limited = true;
          break;
        }
        final name = p.basename(entry.path);
        names.add(name);
        if (programNames.contains(name) ||
            name.toLowerCase().endsWith('.gguf')) {
          final st = statOf(entry.path);
          if (st != null && st.uid != _posix.uid) foreign.add(entry.path);
        }
        final isDir =
            !name.startsWith('.') &&
            FileSystemEntity.isDirectorySync(entry.path);
        if (depth >= maxDepth && isDir) {
          limits.add('depth');
          limited = true;
        }
        if (depth < maxDepth && isDir) {
          final info = statOf(entry.path);
          if (info == null) continue;
          if (info.uid != _posix.uid) notices.add('ownership');
          if (info.dev != device) notices.add('filesystem');
          final target = safe(entry.path, mount, device);
          // Mounted subtrees are scanned on their own, never walked into.
          if (target != null &&
              !available.any(
                (row) => row['path'] != mount && _within(target, row['path']!),
              )) {
            pending.add((target, depth + 1));
          } else if (target != null) {
            notices.add('filesystem');
          }
        }
      }
    } on FileSystemException {
      continue;
    }
    final ggufs = <String>[], targets = <String>[];
    for (final name in names) {
      if (!name.toLowerCase().endsWith('.gguf')) continue;
      final item = p.join(folder, name);
      final st = statOf(item, follow: false);
      final target = safe(item, mount, device, regular: true);
      if (st != null &&
          target != null &&
          st.uid == _posix.uid &&
          st.dev == device) {
        ggufs.add(name);
        targets.add(target);
      }
    }
    if (ggufs.isNotEmpty) {
      results['models\x00$folder'] = {
        'kind': 'models',
        'provider': '',
        'name': 'GGUF',
        'path': folder,
        'count': ggufs.length,
        'models': '',
        'environment': <String, String>{},
        'dependencies': (targets.toSet().toList()..sort()),
      };
    }
    for (final key in providerPrograms.keys) {
      for (final row in discover(key, folder, names, mount, device)) {
        final ident = 'runtime\x00${row['provider']}\x00${row['path']}';
        final previous = results[ident];
        if (previous == null ||
            ((row['links'] as Map?)?.isNotEmpty == true &&
                (previous['links'] as Map?)?.isNotEmpty != true)) {
          results[ident] = row;
        }
      }
    }
    progress(count / maxEntries < 0.95 ? count / maxEntries : 0.95, folder);
  }
  final records = <Map<String, dynamic>>[];
  var size = 0;
  for (final row in results.values.take(maxResults)) {
    try {
      final tracked = [
        row['path'] as String,
        ...(row['dependencies'] as List).cast<String>(),
      ];
      row['mount'] = mounted;
      row['stamps'] = {for (final x in tracked) x: stamp(x)};
      size += utf8.encode(pyJsonDumps(row)).length;
      if (size > 700 * 1024) {
        limits.add('response');
        limited = true;
        break;
      }
      records.add(row);
    } on FileSystemException {
      continue;
    }
  }
  return {
    'records': records,
    'limited': limited,
    'visited': count,
    'limits': limits.toList()..sort(),
    'depth': maxDepth,
    'notices': notices.toList()..sort(),
    'foreign': (foreign.toList()..sort()).take(16).toList(),
  };
}

bool _sameJson(dynamic a, dynamic b) => jsonEncode(a) == jsonEncode(b);

/// validate: the record is still what the scan found (mount, program, links,
/// environment and every stamp).
void validate(Map record) {
  final kind = record['kind'];
  final mounted = rootFor(
    kind == 'runtime'
        ? p.dirname(record['path'] as String)
        : record['path'] as String,
    mounts(),
  );
  if (!_sameJson(mounted, record['mount'])) {
    throw const FormatException('The mount changed; scan again');
  }
  final mount = mounted['path']!;
  final device = statOf(mount)!.dev;
  if (kind == 'runtime') {
    final provider = record['provider'];
    final launchPath = (record['launch_path'] ?? record['path']) as String;
    if (provider is! String ||
        !(providerPrograms[provider]?.contains(p.basename(launchPath)) ??
            false)) {
      throw const FormatException('Unknown runtime launch path');
    }
    final fresh =
        discover(
              provider,
              p.dirname(launchPath),
              [p.basename(launchPath)],
              mount,
              device,
            )
            .where((r) => r['kind'] == 'runtime' && r['path'] == record['path'])
            .firstOrNull;
    if (fresh == null ||
        !_sameJson(fresh['environment'], record['environment']) ||
        !_sameJson(fresh['dependencies'], record['dependencies'])) {
      throw const FormatException('Runtime environment changed; scan again');
    }
    final launch = program(launchPath, mount, device);
    if (launch == null ||
        launch['path'] != record['path'] ||
        !_sameJson(launch['links'], record['links'] ?? {})) {
      throw const FormatException('The launch link changed; scan again');
    }
  }
  for (final MapEntry(key: path, value: identity)
      in (record['stamps'] as Map).entries) {
    final isProgram = path == record['path'] && kind == 'runtime';
    List<int> now;
    try {
      now = stamp(path as String);
    } on FileSystemException {
      throw const FormatException(
        'The discovered installation changed; scan again',
      );
    }
    if (!_sameJson(now, identity) ||
        safe(
              path,
              mount,
              device,
              executable: isProgram,
              regular: !isProgram && FileSystemEntity.isFileSync(path),
            ) ==
            null) {
      throw const FormatException(
        'The discovered installation changed; scan again',
      );
    }
  }
}

// --- reconnecting -------------------------------------------------------------------------------

/// flutter_existing.wrapper: the program with its environment, as a script.
String wrapper(
  Map record,
  List<String> defaultArgs, [
  List<String> homeArguments = const [],
]) {
  final launch = (record['launch_path'] ?? record['path']) as String;
  return [
    '#!/bin/sh',
    '# Connected by Maprisma',
    'set -eu',
    for (final e in (record['environment'] as Map).entries)
      'export ${e.key}=${shellQuote('${e.value}')}',
    'if [ "\$#" -gt 0 ]; then exec ${shellQuote(launch)} "\$@"; fi',
    'exec ${shellJoin([launch, ...defaultArgs])}${homeArguments.map((x) => ' "\$HOME"/${shellQuote(x)}').join()}',
    '',
  ].join('\n');
}

/// flutter_existing.unit_arg: one quoted systemd argument.
String unitArg(String value, {bool executable = false, bool home = false}) {
  if (value.codeUnits.any((c) => c < 32)) {
    throw const FormatException(
      'Control characters in a path are not supported',
    );
  }
  var v = value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('%', '%%');
  if (executable) v = v.replaceAll(r'$', r'$$');
  if (home) v = '%h/$v';
  return '"$v"';
}

/// flutter_existing.service_files: the wrapper, its user unit and its
/// settings, all new files under HOME (never through a link).
List<(String, List<int>, bool)> serviceFiles(
  String home,
  Map record,
  String command,
  String text,
  List<String> mountPaths,
  List<(String, String)> extra,
) {
  final unit =
      '[Unit]\nDescription=Maprisma connected local AI: ${record['name']}\nRequiresMountsFor='
      '${mountPaths.toSet().map(unitArg).join(' ')}\n\n[Service]\nType=simple\nExecStart='
      '${unitArg('.local/bin/$command', executable: true, home: true)}\nEnvironmentFile=%h/${extra.first.$1}\n'
      'Restart=on-failure\nRestartSec=5\n\n[Install]\nWantedBy=default.target\n';
  final files = <(String, List<int>, bool)>[
    ('$home/.local/bin/$command', utf8.encode(text), true),
    ('$home/.config/systemd/user/$command.service', utf8.encode(unit), false),
    for (final (path, content) in extra)
      ('$home/$path', utf8.encode(content), false),
  ];
  for (final (path, _, _) in files) {
    if (!_within(path, home)) {
      throw const FormatException('A connecting path is a symbolic link');
    }
    for (var d = path; _within(d, home); d = p.dirname(d)) {
      if (_isLink(d)) {
        throw const FormatException('A connecting path is a symbolic link');
      }
      if (d == home) break;
    }
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw FormatException('A connecting file already exists: $path');
    }
  }
  return files;
}

List<(String, List<int>, bool)> reconnect(
  String home,
  Map record,
  Map? models,
) {
  final mountPaths = [
    (record['mount'] as Map)['path'] as String,
    if (models != null) (models['mount'] as Map)['path'] as String,
  ];
  if (record['provider'] == 'ollama') {
    if (models == null ||
        models['kind'] != 'store' ||
        models['provider'] != 'ollama') {
      throw const FormatException(
        'Choose a discovered model store for this provider',
      );
    }
    final withEnv = {
      ...record,
      'environment': {
        ...(record['environment'] as Map),
        'OLLAMA_MODELS': models['path'],
        'OLLAMA_HOST': '127.0.0.1:11434',
      },
    };
    final env =
        'OLLAMA_MODELS="${models['path']}"\nOLLAMA_HOST=127.0.0.1:11434\n';
    return serviceFiles(
      home,
      withEnv,
      'ollama',
      wrapper(withEnv, ['serve']),
      mountPaths,
      [('.config/ollama/server.env', env)],
    );
  }
  if (models == null || models['kind'] != 'models') {
    throw const FormatException('Choose a discovered GGUF folder');
  }
  final args = [
    '--models-dir',
    models['path'] as String,
    '--host',
    '127.0.0.1',
    '--port',
    '8080',
    '--models-max',
    '1',
    '--models-preset',
  ];
  final text = wrapper(record, args, ['.config/llama.cpp/models.ini']);
  final env = 'LLAMA_ARG_MODELS_DIR="${models['path']}"\n';
  // No old presets are copied: they may hold paths into the other distro's home.
  return serviceFiles(home, record, 'llama-server', text, mountPaths, [
    ('.config/llama.cpp/server.env', env),
    ('.config/llama.cpp/models.ini', '[*]\ngpu-layers = all\n'),
  ]);
}

/// flutter_existing.build_plan.
Plan buildPlan(
  Map record,
  Map? models,
  String settingsPath,
  String home,
  ConfigFiles config,
) {
  validate(record);
  if (models != null) validate(models);
  final kind = record['kind'];
  if (kind == 'models') {
    for (var d = settingsPath; ; d = p.dirname(d)) {
      if (_isLink(d)) {
        throw const FormatException('Settings path is a symbolic link');
      }
      if (d == p.dirname(d)) break;
    }
    final st = statOf(settingsPath, follow: false);
    if (st != null && (!_isReg(st.mode) || st.size > 1024 * 1024)) {
      throw const FormatException('Invalid settings file');
    }
    final before = config.read(settingsPath);
    final saved = before.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(before);
    if (saved is! Map) throw const FormatException('Invalid settings file');
    final folders = saved['model_folders'] ?? [];
    if (folders is! List || folders.any((x) => x is! String)) {
      throw const FormatException('Invalid saved model folders');
    }
    final plan = Plan('existing-ai', '', '');
    if (!folders.contains(record['path'])) {
      saved['model_folders'] = [...folders, record['path']];
      plan.changes.add(
        Change(
          settingsPath,
          before,
          '${pyJsonDumps(saved, indent: 2, ensureAscii: false)}\n',
        ),
      );
    }
    return plan;
  }
  if (kind != 'runtime') {
    throw const FormatException('Connect the model store through its runtime');
  }
  for (final x in [
    record['path'],
    record['launch_path'] ?? record['path'],
    models?['path'] ?? '',
  ]) {
    if (const ['\\', '"', '\n', '\r'].any((c) => (x as String).contains(c))) {
      throw const FormatException(
        'A runtime path contains unsupported quoting characters',
      );
    }
  }
  if (!providerPrograms.containsKey(record['provider'])) {
    throw const FormatException('Provider cannot reconnect this installation');
  }
  return Plan(
    'existing-ai',
    '',
    '',
    filesAdd: reconnect(home, record, models),
    notes: [for (final n in (record['notes'] as List? ?? const [])) '$n'],
  );
}

Map<String, dynamic> planSignature(Plan plan) => {
  'changes': [
    for (final c in plan.changes) [c.path, c.old, c.next],
  ],
  'files': [
    for (final (path, data, executable) in plan.filesAdd)
      [path, utf8.decode(data), executable],
  ],
};

/// flutter_existing.Existing: discovery handles and reviewed reconnect plans.
final class ExistingRecords {
  ExistingRecords(this.newToken);
  final String Function() newToken;
  var records = <String, (DateTime, Map<String, dynamic>)>{};
  final plans = <String, (DateTime, Map<String, dynamic>)>{};

  Map<String, dynamic> register(Map<String, dynamic> result) {
    records = {}; // a new scan replaces old selections, not reviewed plans
    final public = <Map<String, dynamic>>[];
    for (final record
        in (result['records'] as List)
            .take(maxResults)
            .cast<Map<String, dynamic>>()) {
      final ident = newToken();
      records[ident] = (DateTime.now(), record);
      public.add({
        for (final key in ['kind', 'provider', 'name', 'path', 'count'])
          key: record[key],
        'found': ident,
        'environment':
            ((record['environment'] as Map).keys.cast<String>().toList()
              ..sort()),
        'checked': false,
      });
    }
    return {
      'items': public,
      'limited': result['limited'] == true,
      'visited': result['visited'],
      'limits': result['limits'] ?? [],
      'depth': result['depth'] ?? maxDepth,
      'notices': result['notices'] ?? [],
      'foreign': result['foreign'] ?? [],
    };
  }

  Map<String, dynamic> get(dynamic ident) {
    final kept = ident is String ? records[ident] : null;
    if (kept == null) throw const FormatException('Unknown discovery handle');
    if (DateTime.now().difference(kept.$1).inSeconds >= 600) {
      throw const FormatException('Discovery expired; scan again');
    }
    return kept.$2;
  }

  Map<String, dynamic> preview(
    Map<String, dynamic> params,
    String settingsPath,
    String backupRoot,
    String home,
    ConfigFiles config,
  ) {
    if (params.length != 2 ||
        !params.containsKey('found') ||
        !params.containsKey('models') ||
        (params['models'] != null && params['models'] is! String)) {
      throw const FormatException('Invalid reconnect selection');
    }
    final record = get(params['found']);
    final models = pyTruthy(params['models']) ? get(params['models']) : null;
    final plan = buildPlan(record, models, settingsPath, home, config);
    final body = {
      'record': record,
      'models': models,
      'settings_path': settingsPath,
      'backup_root': backupRoot,
      'signature': planSignature(plan),
    };
    if (utf8.encode(jsonEncode(body)).length > existingMaxBytes) {
      throw const FormatException('Reconnect plan too large');
    }
    final now = DateTime.now();
    plans.removeWhere((_, v) => now.difference(v.$1).inSeconds >= 600);
    while (plans.length >= 8) {
      plans.remove(plans.keys.first);
    }
    final token = newToken();
    plans[token] = (now, body);
    // Only the new connecting files are shown; settings values stay private.
    return {
      'plan': token,
      'empty': plan.empty,
      'notes': plan.notes,
      'files': [
        for (final (path, data, _) in plan.filesAdd)
          {'path': path, 'text': utf8.decode(data)},
        for (final c in plan.changes) {'path': c.path, 'text': ''},
      ],
    };
  }

  Map<String, dynamic> apply(
    dynamic token,
    Map<String, dynamic> Function(Map<String, dynamic>) queue,
  ) {
    final kept = token is String ? plans[token] : null;
    if (kept == null) throw const FormatException('Unknown reconnect plan');
    if (DateTime.now().difference(kept.$1).inSeconds >= 600) {
      throw const FormatException('Reconnect preview expired');
    }
    final result = queue(kept.$2);
    plans.remove(token);
    return result;
  }
}

/// flutter_existing.execute (worker, under the installers' lock).
String executeReconnect(List<int> body, String home, ConfigFiles config) {
  if (body.length > existingMaxBytes) {
    throw const FormatException('Reconnect plan too large');
  }
  final data = jsonDecode(utf8.decode(body)) as Map;
  Plan plan() => buildPlan(
    data['record'] as Map,
    data['models'] as Map?,
    data['settings_path'] as String,
    home,
    config,
  );
  if (!_sameJson(planSignature(plan()), data['signature'])) {
    throw const FormatException('Reconnect preview changed');
  }
  final current = plan();
  if (!_sameJson(planSignature(current), data['signature'])) {
    throw const FormatException('Reconnect preview changed');
  }
  // Nothing found is enabled, started or run here.
  return config.apply(current, data['backup_root'] as String);
}

/// flutter_existing.check: the program's own --version in an empty home,
/// five seconds at most, its whole group ended after.
Future<Map<String, dynamic>> checkProgram(
  Map record, {
  void Function(Map)? validator,
}) async {
  (validator ?? validate)(record);
  if (record['kind'] != 'runtime') {
    throw const FormatException('Choose a program');
  }
  final folder = Directory.systemTemp.createTempSync('maprisma-check-');
  try {
    final env = {
      'PATH': '/usr/bin:/bin',
      'HOME': folder.path,
      'TMPDIR': folder.path,
      'LANG': 'C',
      for (final e in (record['environment'] as Map).entries)
        '${e.key}': '${e.value}',
    };
    final process = await Process.start(
      '/usr/bin/setsid',
      [(record['launch_path'] ?? record['path']) as String, '--version'],
      environment: env,
      includeParentEnvironment: false,
      workingDirectory: folder.path,
    );
    final group = ProcessGroup(process.pid)..watch(); // never by number
    process.stdin.close();
    process.stdout.drain<void>();
    process.stderr.drain<void>();
    try {
      final code = await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () => -1,
      );
      return {'ok': code == 0, 'checked': true};
    } finally {
      group.signal(9);
      group.close();
    }
  } finally {
    folder.deleteSync(recursive: true);
  }
}
