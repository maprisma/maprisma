import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'adapter_assets.g.dart';
import 'connect_apply.dart';
import 'existing_ai.dart' as existing_ai;
import 'posix_ffi.dart';
import 'provider_scans.dart';
import 'py_values.dart' show pyJsonDumps;
import 'system_actions.dart' show modelFolderChanges;
import 'system_map_cache.dart';

/// system_moves + model_folders + model_move: moving a model folder's own
/// GGUF files to another disk from the System Map. On one disk a file is
/// hard-linked to its new name, to another it is copied (owner-only .part
/// file first); a name is never replaced. Both folders are reached by
/// walking from / one name at a time, never through a link, and every file
/// must be the one the preview saw. What pointed at the files (links,
/// models.ini, settings) is changed with a backup; a private journal makes
/// the move undoable.

const moveMaxBytes = 700 * 1024;
const _journalMax = 4 * 1024 * 1024;
const _chunk = 4 * 1024 * 1024;

typedef Ident = List<int>; // st_dev, st_ino

String real(String path, String home) {
  final expanded = path == '~' || path.startsWith('~/')
      ? '$home${path.substring(1)}'
      : path;
  try {
    return File(expanded).resolveSymbolicLinksSync();
  } on FileSystemException {
    return _resolveLoose(p.normalize(p.absolute(expanded)));
  }
}

String _resolveLoose(String path) {
  var head = path;
  final tail = <String>[];
  while (FileSystemEntity.typeSync(head, followLinks: false) ==
          FileSystemEntityType.notFound &&
      head != '/') {
    tail.insert(0, p.basename(head));
    head = p.dirname(head);
  }
  try {
    final base = File(head).resolveSymbolicLinksSync();
    return tail.isEmpty ? base : p.joinAll([base, ...tail]);
  } on FileSystemException {
    return path;
  }
}

bool _within(String path, String root) =>
    path == root || p.isWithin(root, path);
bool _isLink(String path) => FileSystemEntity.isLinkSync(path);
bool _lexists(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) !=
    FileSystemEntityType.notFound;

/// A local LLM that reads a folder of GGUF files (its engine's gguf_folder).
bool readsGguf(String key) => const {'flat', 'publisher'}.contains(
  '${((providerFacts['engines'] as Map)[key] as Map?)?['layout'] ?? ''}',
);

final class ModelFolder {
  ModelFolder(this.path);
  final String path;
  List<String> files = [];
  List<String> readers = [];
  bool added = false;
}

/// model_folders._ggufs: (path as found, its real file) below folder.
Iterable<(String, String)> ggufs(
  String folder,
  String home, {
  int depth = 3,
}) sync* {
  var found = 0;
  final base = p.split(folder).length;
  final stack = [folder];
  while (stack.isNotEmpty) {
    final root = stack.removeAt(0);
    List<FileSystemEntity> entries;
    try {
      entries = Directory(root).listSync(followLinks: false);
    } on FileSystemException {
      continue;
    }
    final dirs = <String>[];
    for (final e in entries) {
      final isDir =
          e is Directory ||
          (e is Link && FileSystemEntity.isDirectorySync(e.path));
      if (isDir) {
        if (e is Directory) dirs.add(e.path);
        continue;
      }
      if (!p.basename(e.path).toLowerCase().endsWith('.gguf')) continue;
      final target = real(e.path, home);
      if (FileSystemEntity.isFileSync(target)) yield (e.path, target);
      if (++found >= 20000) return;
    }
    if (p.split(root).length - base < depth) stack.insertAll(0, dirs);
  }
}

/// model_folders.discover.
List<ModelFolder> discoverFolders(
  List<RuntimeRecord> runtimes,
  List<String> added,
  String home,
) {
  final folders = <String, ModelFolder>{};
  ModelFolder folderOf(String path) =>
      folders.putIfAbsent(path, () => ModelFolder(path));
  for (final rt in runtimes) {
    if (!readsGguf(rt.key) || !rt.installed || rt.modelsDir.isEmpty) continue;
    final root = real(rt.modelsDir, home);
    if (!FileSystemEntity.isDirectorySync(root)) continue;
    for (final (path, target) in ggufs(root, home)) {
      if (_isLink(path) && p.dirname(path) != root) {
        continue; // another LLM's router folder
      }
      final entry = folderOf(p.dirname(target));
      if (!entry.readers.contains(rt.key)) entry.readers.add(rt.key);
    }
  }
  for (final x in added) {
    final path = real(x, home);
    if (!FileSystemEntity.isDirectorySync(path)) continue;
    folderOf(path).added = true;
    for (final (_, target) in ggufs(path, home, depth: 1)) {
      folderOf(p.dirname(target));
    }
  }
  for (final entry in folders.values) {
    try {
      entry.files = [
        for (final e in Directory(entry.path).listSync(followLinks: false))
          if (p.basename(e.path).toLowerCase().endsWith('.gguf') && e is File)
            e.path,
      ]..sort();
    } on FileSystemException {
      entry.files = [];
    }
  }
  return folders.values.where((f) => f.files.isNotEmpty || f.added).toList()
    ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
}

/// model_move.anchor: the deepest existing folder of `folder` and its identity.
(String, Ident) anchor(String folder, Posix posix) {
  var probe = folder;
  while (true) {
    final st = posix.statAt(-100, probe);
    if (st == null) {
      if (p.dirname(probe) == probe) {
        throw FormatException('$folder cannot be reached');
      }
      probe = p.dirname(probe);
      continue;
    }
    if (st.mode & 0xf000 != 0x4000) {
      throw FormatException('$probe is not a folder');
    }
    return (probe, [st.dev, st.ino]);
  }
}

/// One planned move: the files, the folders' anchors and what changes.
final class MoveFacts {
  MoveFacts(
    this.source,
    this.target,
    this.steps,
    this.size,
    this.copy,
    this.idents,
    this.anchors,
  );
  final String source, target; // back, root
  final List<(String, String)> steps;
  final int size;
  final bool copy;
  final Map<String, Ident> idents;
  final Map<String, (String, Ident)> anchors;

  Map<String, dynamic> toJson() => {
    'name': p.basename(source),
    'steps': [
      for (final (a, b) in steps) [a, b],
    ],
    'size': size,
    'copy': copy,
    'root': target,
    'back': source,
    'idents': {for (final e in idents.entries) e.key: e.value},
    'anchors': {
      for (final e in anchors.entries) e.key: [e.value.$1, e.value.$2],
    },
  };

  static MoveFacts fromJson(Map m) => MoveFacts(
    m['back'] as String,
    m['root'] as String,
    [
      for (final s in m['steps'] as List)
        ((s as List)[0] as String, s[1] as String),
    ],
    m['size'] as int,
    m['copy'] as bool,
    {
      for (final e in (m['idents'] as Map).entries)
        e.key as String: [for (final x in e.value as List) x as int],
    },
    {
      for (final e in (m['anchors'] as Map).entries)
        e.key as String: (
          (e.value as List)[0] as String,
          [for (final x in (e.value as List)[1] as List) x as int],
        ),
    },
  );

  (String, Ident) anchorOf(String folder) {
    final found = anchors[folder];
    if (found == null) {
      throw const FormatException('the move has no preview of its folders');
    }
    return found;
  }
}

// --- moving one file ---------------------------------------------------------------------------

final class MovedFile {
  MovedFile(this.copied, this.ident);
  final int copied;
  final Ident ident;
}

final class FileMover {
  FileMover(this.posix);
  final Posix posix;

  /// model_move._walk: the folder's descriptor, walked from / one name at a
  /// time and never through a link; the anchor must be the preview's.
  int walk(
    String path,
    String root,
    (String, Ident) base, {
    bool make = false,
  }) {
    final (top, ident) = base;
    if (!p.isAbsolute(path) ||
        !_within(path, root) ||
        !_within(root, top) ||
        p.split(path).contains('..')) {
      throw FormatException('$path is not inside $root');
    }
    final topParts = p.split(top).length;
    var fd = posix.openAt(-100, '/', Posix.directory);
    try {
      if (top == '/') {
        final st = posix.statAt(fd, '')!;
        if (st.dev != ident[0] || st.ino != ident[1]) {
          throw FormatException('$top changed after the preview');
        }
      }
      final parts = p.split(path);
      for (var depth = 2; depth <= parts.length; depth++) {
        final name = parts[depth - 1];
        final below = depth > topParts, mine = depth >= topParts;
        if (make && below) posix.mkdirAt(fd, name, 0x1ed);
        final next = posix.openAt(fd, name, Posix.directory | Posix.noFollow);
        posix.close(fd);
        fd = next;
        final st = posix.statAt(fd, '')!;
        if (depth == topParts && (st.dev != ident[0] || st.ino != ident[1])) {
          throw FormatException('$top changed after the preview');
        }
        if (mine && (st.uid != posix.uid || st.mode & 0x12 != 0)) {
          throw FormatException(
            '$path is not a folder of this account alone inside the model folder',
          );
        }
      }
      final st = posix.statAt(fd, '')!;
      if (st.uid != posix.uid) {
        throw FormatException('$path is not a folder of this account');
      }
      if (st.mode & 0x12 != 0) {
        throw FormatException(
          'other accounts can write into $path: make it this account\'s alone (chmod go-w)',
        );
      }
      return fd;
    } on FileSystemException {
      posix.close(fd);
      throw FormatException(
        '${p.basename(path)}: a folder on its way is a link or changed after the preview',
      );
    } catch (_) {
      posix.close(fd);
      rethrow;
    }
  }

  bool _is(int dir, String name, Ident ident) {
    final st = posix.statAt(dir, name);
    return st != null &&
        st.mode & 0xf000 == 0x8000 &&
        st.dev == ident[0] &&
        st.ino == ident[1];
  }

  bool _remove(int dir, String name, Ident ident) {
    if (!_is(dir, name, ident)) return false;
    posix.unlinkAt(dir, name);
    return true;
  }

  MovedFile _copyTo(
    int srcFd,
    ({
      int dev,
      int ino,
      int mode,
      int uid,
      int size,
      int nlink,
      int atimeNs,
      int mtimeNs,
    })
    st,
    String name,
    int folder,
    void Function(double, String) progress,
    int done,
    int total,
  ) {
    final partial = '.$name.part';
    final fd = posix.openAt(
      folder,
      partial,
      1 | 0x40 | 0x80 | Posix.noFollow,
      0x180,
    );
    final made = posix.statAt(fd, '')!;
    final ident = [made.dev, made.ino];
    var copied = 0;
    try {
      try {
        while (true) {
          final block = posix.readAt(srcFd, copied, _chunk);
          if (block.isEmpty) break;
          posix.write(fd, block);
          copied += block.length;
          progress((done + copied) / (total < 1 ? 1 : total), name);
        }
        posix.sync(fd);
        if (posix.statAt(fd, '')!.size != st.size) {
          throw FormatException('$name: the copy is incomplete');
        }
        posix.setTimes(fd, st.atimeNs, st.mtimeNs);
        posix.chmod(fd, st.mode & 0x1ff);
      } finally {
        posix.close(fd);
      }
      if (!_is(folder, partial, ident)) {
        throw FormatException('$name: the partial copy changed');
      }
      posix.linkAt(
        folder,
        partial,
        folder,
        name,
      ); // fails if the name exists now
    } finally {
      _remove(folder, partial, ident);
    }
    return MovedFile(copied, ident);
  }

  /// model_move.move_file: one file to its new name, never over another.
  MovedFile moveFile(
    String source,
    String target,
    String srcRoot,
    String dstRoot,
    bool copy,
    Ident? expect,
    (String, Ident) srcBase,
    (String, Ident) dstBase,
    void Function(double, String) progress,
    int done,
    int total,
  ) {
    final srcDir = walk(p.dirname(source), srcRoot, srcBase);
    try {
      final name = p.basename(source);
      int srcFd;
      try {
        srcFd = posix.openAt(srcDir, name, Posix.noFollow | Posix.nonBlock);
      } on FileSystemException {
        throw FormatException("$name is not this account's own file");
      }
      try {
        final st = posix.statAt(srcFd, '')!;
        if (st.mode & 0xf000 != 0x8000 || st.uid != posix.uid) {
          throw FormatException("$name is not this account's own file");
        }
        if (expect == null || st.dev != expect[0] || st.ino != expect[1]) {
          throw FormatException('$name changed after the preview');
        }
        final dstDir = walk(p.dirname(target), dstRoot, dstBase, make: true);
        try {
          final to = p.basename(target);
          MovedFile moved;
          if (copy || !Directory('/proc/self/fd').existsSync()) {
            moved = _copyTo(srcFd, st, to, dstDir, progress, done, total);
          } else {
            // The open file itself, not whatever its name is now.
            try {
              posix.linkAt(
                -100,
                '/proc/self/fd/$srcFd',
                dstDir,
                to,
                follow: true,
              );
            } on FileSystemException {
              if (posix.statAt(srcFd, '')!.nlink == 0) {
                throw FormatException('$name changed while it was moved');
              }
              rethrow;
            }
            moved = MovedFile(0, [st.dev, st.ino]);
          }
          if (!_is(srcDir, name, [st.dev, st.ino]) ||
              !_is(dstDir, to, moved.ident)) {
            _remove(dstDir, to, moved.ident);
            throw FormatException('$name changed while it was moved');
          }
          try {
            posix.unlinkAt(srcDir, name);
          } on FileSystemException catch (error) {
            _remove(dstDir, to, moved.ident);
            throw FormatException(
              '$name cannot be removed from its folder: ${error.osError?.message ?? error}',
            );
          }
          return moved;
        } finally {
          posix.close(dstDir);
        }
      } finally {
        posix.close(srcFd);
      }
    } finally {
      posix.close(srcDir);
    }
  }

  /// model_move.apply for the given steps; the steps done, also when one fails.
  List<(String, String, Ident)> apply(
    MoveFacts move,
    List<(String, String)> steps,
    void Function(double, String) progress,
    List<(String, String, Ident)> done,
  ) {
    var copied = 0;
    for (final (source, target) in steps) {
      final moved = moveFile(
        source,
        target,
        move.source,
        move.target,
        move.copy,
        move.idents[source],
        move.anchorOf(move.source),
        move.anchorOf(move.target),
        progress,
        copied,
        move.size < 1 ? 1 : move.size,
      );
      copied += moved.copied;
      done.add((source, target, moved.ident));
    }
    return done;
  }

  /// model_move.undo: the files back, last first; the problems (empty: all back).
  List<String> undo(
    MoveFacts move,
    List<(String, String, Ident)> done,
    void Function(double, String) progress,
  ) {
    final problems = <String>[];
    var total = 0;
    for (final (_, t, _) in done) {
      if (_lexists(t)) total += posix.statAt(-100, t)?.size ?? 0;
    }
    for (final (source, target, ident) in done.reversed) {
      try {
        moveFile(
          target,
          source,
          move.target,
          move.source,
          move.copy,
          ident,
          move.anchorOf(move.target),
          move.anchorOf(move.source),
          progress,
          0,
          total < 1 ? 1 : total,
        );
      } on FormatException catch (error) {
        problems.add('${p.basename(target)}: ${error.message}');
      } on FileSystemException catch (error) {
        problems.add('${p.basename(target)}: $error');
      }
    }
    return problems;
  }
}

// --- the System Map's moves (system_moves) ------------------------------------------------------

String _canonical(dynamic value) => pyJsonDumps(_sorted(value));
dynamic _sorted(dynamic value) {
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return {for (final k in keys) k: _sorted(value[k])};
  }
  if (value is List) return [for (final x in value) _sorted(x)];
  return value;
}

final class SystemMoves {
  SystemMoves(this.files, this.home, this.settingsPath, this.cachePath)
    : posix = Posix(),
      config = ConfigFiles(Posix(), home);
  final ScanFilesLike files;
  final String home, settingsPath, cachePath;
  final Posix posix;
  final ConfigFiles config;
  String get modelsIni => '$home/.config/llama.cpp/models.ini';
  String get journalRoot => p.join(p.dirname(settingsPath), 'model-moves');

  /// system_moves.prepare: the move's record with its signature.
  Map<String, dynamic> prepare(Map selection) {
    final String source;
    try {
      source = File(selection['source'] as String).resolveSymbolicLinksSync();
    } on FileSystemException {
      throw const FormatException('Folder/disk unavailable');
    }
    final disk = selection['disk'] as String;
    final mount = existing_ai.rootFor(disk, existing_ai.mounts());
    if (jsonEncode(mount) != jsonEncode(selection['mount'])) {
      throw const FormatException('Destination mount changed');
    }
    final target = p.join(disk, p.basename(source));
    final diskSt = posix.statAt(-100, disk);
    final targetSt =
        FileSystemEntity.typeSync(target) == FileSystemEntityType.notFound
        ? null
        : FileStat.statSync(target);
    if (_resolveLoose(target) != target ||
        (targetSt != null &&
            posix.statBlocks(target, follow: true)?.dev != diskSt?.dev)) {
      throw const FormatException('Use a real destination on this mount');
    }
    if (_isLink(modelsIni)) {
      throw const FormatException('Model preset is a symbolic link');
    }
    final runtimes = files.runtimes();
    final folders = discoverFolders(runtimes, [source], home);
    final folder = folders.where((f) => f.path == source).firstOrNull;
    if (folder == null) throw const FormatException('No movable model files');
    if (runtimes.any((rt) => rt.running && folder.readers.contains(rt.key))) {
      throw const FormatException(
        'Stop runtimes reading this folder before moving it',
      );
    }
    final change = _plan(folder, target, runtimes);
    // The app's model folders: the old one out, the new one in.
    if (_isLink(settingsPath)) {
      throw const FormatException('Settings path is a symbolic link');
    }
    final before = config.read(settingsPath);
    final saved = before.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(before);
    if (saved is! Map) {
      throw const FormatException('Invalid application settings');
    }
    final added = saved['model_folders'] ?? [];
    if (added is! List || added.any((x) => x is! String)) {
      throw const FormatException('Invalid model folders');
    }
    final updated = [
      for (final x in added)
        if (real(x as String, home) != source) x,
    ];
    if (!updated.contains(target)) updated.add(target);
    final plan = Plan('system-map', '', '');
    if (jsonEncode(updated) != jsonEncode(added)) {
      saved['model_folders'] = updated;
      plan.changes.add(
        Change(
          settingsPath,
          before,
          '${pyJsonDumps(saved, indent: 2, ensureAscii: false)}\n',
        ),
      );
    }
    // llama.cpp's presets name the new place (also through a same-disk alias).
    final old = config.read(modelsIni);
    var next = old;
    final replacements = {for (final (a, b) in change.move.steps) a: b};
    for (final e in replacements.entries) {
      next = next.replaceAll(e.key, e.value);
    }
    for (final line in const LineSplitter().convert(old)) {
      final at = line.indexOf('=');
      if (at < 0) continue;
      final value = line.substring(at + 1).trim();
      if (value.startsWith('/') &&
          replacements.containsKey(real(value, home))) {
        next = next.replaceAll(value, replacements[real(value, home)]!);
      }
    }
    if (next != old) plan.changes.add(Change(modelsIni, old, next));
    final lost = <String>[];
    for (final key in change.lost) {
      final rt = runtimes.firstWhere((r) => r.key == key);
      if (!const {'ollama', 'llamacpp'}.contains(key) ||
          real(rt.modelsDir, home) != source) {
        lost.add(key);
        continue;
      }
      try {
        plan.changes.addAll(
          modelFolderChanges(rt, target, home, posix, config),
        );
      } on FormatException {
        lost.add(key);
      } on FileSystemException {
        lost.add(key);
      }
    }
    for (final (link, _, now) in change.links) {
      if (posix.statAt(-100, link)?.uid != posix.uid) {
        throw const FormatException('A model link belongs to another user');
      }
      plan.linksRemove.add((link, Link(link).targetSync()));
      plan.linksAdd.add((link, now));
    }
    final facts = {
      'move': change.move.toJson(),
      'config': {
        'changes': [
          for (final c in plan.changes)
            {'path': c.path, 'old': c.old, 'new': c.next},
        ],
        'links_add': [
          for (final (a, b) in plan.linksAdd) [a, b],
        ],
        'links_remove': [
          for (final (a, b) in plan.linksRemove) [a, b],
        ],
      },
      'lost': lost,
    };
    final signature = sha256.convert(utf8.encode(_canonical(facts))).toString();
    final record = {...selection, 'signature': signature, 'facts': facts};
    if (utf8.encode(_canonical(record)).length > moveMaxBytes) {
      throw const FormatException('Move preview too large');
    }
    return jsonDecode(jsonEncode(record)) as Map<String, dynamic>;
  }

  /// model_folders.plan with no folder setting the app may repoint.
  ({MoveFacts move, List<(String, String, String)> links, List<String> lost})
  _plan(ModelFolder folder, String newFolder, List<RuntimeRecord> runtimes) {
    final source = folder.path;
    var target = p.normalize(p.absolute(newFolder));
    if (real(target, home) == source) {
      throw const FormatException('that is this folder already');
    }
    if (_within(real(target, home), source)) {
      throw const FormatException('the new folder is inside this one');
    }
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound &&
        !FileSystemEntity.isDirectorySync(target)) {
      throw FormatException('$target is not a folder');
    }
    final steps = <(String, String)>[];
    final idents = <String, Ident>{};
    var size = 0;
    target = real(target, home);
    for (final file in folder.files) {
      final path = p.join(real(p.dirname(file), home), p.basename(file));
      if (!_within(path, source)) {
        throw FormatException('${p.basename(path)} lies outside this folder');
      }
      final st = posix.statAt(-100, path);
      if (st == null || st.mode & 0xf000 != 0x8000 || st.uid != posix.uid) {
        throw FormatException('${p.basename(path)} belongs to another account');
      }
      final dest = p.join(target, p.basename(path));
      if (_lexists(dest)) throw FormatException('$dest exists already');
      steps.add((path, dest));
      idents[path] = [st.dev, st.ino];
      size += st.size;
    }
    if (steps.isEmpty) {
      throw const FormatException(
        'this folder holds no model files of its own',
      );
    }
    var probe = target;
    while (FileSystemEntity.typeSync(probe) == FileSystemEntityType.notFound) {
      probe = p.dirname(probe);
    }
    final copy =
        posix.statBlocks(source, follow: true)?.dev !=
        posix.statBlocks(probe, follow: true)?.dev;
    final move = MoveFacts(source, target, steps, size, copy, idents, {
      target: anchor(target, posix),
      source: anchor(source, posix),
    });
    final links = <(String, String, String)>[];
    final lost = <String>[];
    final moved = {for (final (s, d) in steps) s: d};
    for (final rt in runtimes) {
      if (!readsGguf(rt.key) || rt.modelsDir.isEmpty) continue;
      final root = real(rt.modelsDir, home);
      var relinked = false;
      if (FileSystemEntity.isDirectorySync(root)) {
        for (final (path, now) in ggufs(root, home)) {
          if (_isLink(path) && moved.containsKey(now)) {
            if (!links.any((l) => l.$1 == path)) {
              links.add((path, now, moved[now]!));
            }
            relinked = relinked || p.dirname(path) == root;
          }
        }
      }
      if (!folder.readers.contains(rt.key) || relinked) continue;
      if (root == source) {
        lost.add(rt.key);
      } else if (!_within(real(target, home), root)) {
        lost.add(rt.key);
      }
    }
    return (move: move, links: links, lost: lost);
  }

  Plan _config(Map record) {
    final c = (record['facts'] as Map)['config'] as Map;
    return Plan(
      'system-map',
      '',
      '',
      changes: [
        for (final x in (c['changes'] as List).cast<Map>())
          Change(x['path'] as String, x['old'] as String, x['new'] as String),
      ],
      linksAdd: [
        for (final x in c['links_add'] as List)
          ((x as List)[0] as String, x[1] as String),
      ],
      linksRemove: [
        for (final x in c['links_remove'] as List)
          ((x as List)[0] as String, x[1] as String),
      ],
    );
  }

  void _journal(String path, Map journal) {
    Directory(p.dirname(path)).createSync(recursive: true);
    posix.chmodPath(p.dirname(path), 0x1c0);
    posix.atomicWrite(path, utf8.encode(_canonical(journal)));
  }

  /// system_moves.update_records: the saved map's discoveries follow the files.
  void updateRecords(Map record, String source, String destination) {
    final saved = loadMapCache(cachePath, posix);
    if (saved.isEmpty) return;
    saved['records'] = [
      for (final r in saved['records'] as List)
        if (r['path'] != source && r['path'] != destination) r,
    ];
    try {
      final mounted = existing_ai.rootFor(destination, existing_ai.mounts());
      final moved = [
        for (final s
            in ((record['facts'] as Map)['move'] as Map)['steps'] as List)
          if (FileSystemEntity.isFileSync(
            p.join(destination, p.basename((s as List)[0] as String)),
          ))
            p.join(destination, p.basename(s[0] as String)),
      ];
      if (moved.isNotEmpty) {
        final tracked = [destination, ...moved];
        (saved['records'] as List).add({
          'kind': 'models',
          'provider': '',
          'name': 'GGUF',
          'path': destination,
          'count': moved.length,
          'models': '',
          'environment': <String, String>{},
          'dependencies': moved,
          'mount': mounted,
          'stamps': {for (final x in tracked) x: existing_ai.stamp(x)},
        });
      }
    } on FormatException {
      /* the destination is no longer a data disk */
    } on FileSystemException {
      /* the files changed meanwhile */
    }
    saveMapCache(cachePath, posix, saved);
  }

  /// system_moves.execute: prepared again and the same, the files moved one
  /// by one into the journal, then the settings with a backup.
  Map<String, dynamic> execute(
    List<int> body,
    String token,
    void Function(double, String) progress,
  ) {
    if (body.length > moveMaxBytes) {
      throw const FormatException('Move plan too large');
    }
    final record = jsonDecode(utf8.decode(body)) as Map;
    final current = prepare({
      for (final k in ['source', 'disk', 'mount', 'settings_path'])
        k: record[k],
    });
    if (current['signature'] != record['signature']) {
      throw const FormatException('Move preview changed');
    }
    final move = MoveFacts.fromJson((current['facts'] as Map)['move'] as Map);
    final root = p.join(journalRoot, token);
    final path = p.join(root, 'journal.json');
    final journal = <String, dynamic>{
      'record': record,
      'done': <dynamic>[],
      'backup': null,
      'complete': false,
    };
    _journal(path, journal);
    final mover = FileMover(posix);
    final done = <(String, String, Ident)>[];
    try {
      for (final step in move.steps) {
        final before = done.length;
        mover.apply(move, [step], progress, done);
        for (final (a, b, i) in done.skip(before)) {
          (journal['done'] as List).add([a, b, i]);
        }
        _journal(path, journal);
      }
      final backup = config.apply(_config(current), p.join(root, 'config'));
      journal
        ..['backup'] = backup
        ..['complete'] = true;
      _journal(path, journal);
      updateRecords(record, move.source, move.target);
    } catch (_) {
      journal['complete'] = false;
      // A partial configuration transaction wrote its manifest before changes.
      final configs = Directory(p.join(root, 'config'));
      if (configs.existsSync()) {
        for (final backup in configs.listSync()) {
          if (File(p.join(backup.path, 'manifest.json')).existsSync()) {
            config.undo(backup.path);
          }
        }
      }
      final remaining = <dynamic>[];
      for (final entry in (journal['done'] as List).reversed) {
        final e = entry as List;
        final step = (
          e[0] as String,
          e[1] as String,
          [for (final x in e[2] as List) x as int],
        );
        if (mover.undo(move, [step], progress).isNotEmpty) remaining.add(e);
      }
      journal['done'] = remaining;
      _journal(path, journal);
      return {'ok': false, 'move_undo': remaining.isNotEmpty ? token : null};
    }
    return {'ok': true, 'move_undo': token};
  }

  /// system_moves.undo: the journal's files back, then the settings' backup.
  Map<String, dynamic> undo(
    String token,
    void Function(double, String) progress,
  ) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(token)) {
      throw const FormatException('Invalid move Undo');
    }
    final root = p.join(journalRoot, token);
    final path = p.join(root, 'journal.json');
    final st = posix.lstatOwn(path);
    if (st == null ||
        st.mode & 0xf000 != 0x8000 ||
        st.uid != posix.uid ||
        st.mode & 0x3f != 0) {
      throw const FormatException('Invalid move journal');
    }
    final raw = posix.readRegular(path, _journalMax + 1);
    if (raw.length > _journalMax) {
      throw const FormatException('Move journal too large');
    }
    final journal = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    final record = journal['record'] as Map;
    final move = MoveFacts.fromJson((record['facts'] as Map)['move'] as Map);
    final mover = FileMover(posix);
    final problems = <String>[];
    for (final entry in [...(journal['done'] as List).reversed]) {
      final e = entry as List;
      final errors = mover.undo(move, [
        (
          e[0] as String,
          e[1] as String,
          [for (final x in e[2] as List) x as int],
        ),
      ], progress);
      if (errors.isNotEmpty) {
        problems.addAll(errors);
      } else {
        (journal['done'] as List).remove(entry);
        _journal(path, journal);
      }
    }
    if (problems.isEmpty && journal['backup'] != null) {
      final backup = journal['backup'] as String;
      if (p.dirname(backup) != p.join(root, 'config')) {
        throw const FormatException('Invalid configuration backup');
      }
      config.undo(backup);
      journal['backup'] = null;
      _journal(path, journal);
    }
    if (problems.isEmpty) updateRecords(record, move.target, move.source);
    return {
      'ok': problems.isEmpty,
      'remaining': (journal['done'] as List).length,
    };
  }
}

/// What SystemMoves needs to know of this PC: the local LLMs as the map
/// sees them (built-in ones an add-on hides included).
final class ScanFilesLike {
  ScanFilesLike(this.scans);
  final ProviderScans scans;
  List<RuntimeRecord> runtimes() =>
      scans.scan(facts: providerFacts['local'] as List);
}

/// system_moves.Moves: reviewed move previews, used once within ten minutes.
final class MovePreviews {
  MovePreviews(this.newToken);
  final String Function() newToken;
  final plans = <String, (DateTime, Map<String, dynamic>)>{};

  Map<String, dynamic> register(Map<String, dynamic> record) {
    final now = DateTime.now();
    plans.removeWhere((_, v) => now.difference(v.$1).inSeconds >= 600);
    while (plans.length >= 8) {
      plans.remove(plans.keys.first);
    }
    final token = newToken();
    plans[token] = (now, record);
    final facts = record['facts'] as Map,
        move = facts['move'] as Map,
        config = facts['config'] as Map;
    return {
      'preview': token,
      'source': record['source'],
      'destination': move['root'],
      'size': move['size'],
      'count': (move['steps'] as List).length,
      'model_files': [
        for (final s in move['steps'] as List)
          p.basename((s as List)[0] as String),
      ],
      'files': [
        for (final c in (config['changes'] as List).cast<Map>())
          {'path': c['path']},
      ],
      'notes': [
        if (move['copy'] == true)
          'The new folder is on another disk: copied first, then removed here.',
        if ((config['links_add'] as List).isNotEmpty)
          'Links and model references will be updated.',
        if ((facts['lost'] as List).isNotEmpty)
          'Some runtimes will need their model folder updated after this move.',
      ],
      'empty': false,
    };
  }

  Map<String, dynamic> apply(
    dynamic token,
    Map<String, dynamic> Function(Map<String, dynamic>) queue,
  ) {
    final kept = token is String ? plans[token] : null;
    if (kept == null) throw const FormatException('Unknown move preview');
    if (DateTime.now().difference(kept.$1).inSeconds >= 600) {
      throw const FormatException('Move preview expired');
    }
    final result = queue(kept.$2);
    plans.remove(token);
    return result;
  }
}
