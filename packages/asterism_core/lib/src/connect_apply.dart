import 'dart:convert';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'posix_ffi.dart';
import 'py_values.dart';

/// Python connect.Change / Plan / apply / undo: back up every file, write the
/// new texts, make or remove skill links; Undo puts back only what was not
/// changed again since. The backup folder and manifest.json are the
/// reference's, so either side can undo the other's backup.
final class Change {
  Change(this.path, this.old, this.next);
  final String path, old, next;
}

final class Plan {
  Plan(
    this.agent,
    this.runtime,
    this.provider, {
    List<Change>? changes,
    List<(String, String)>? linksAdd,
    List<(String, String)>? linksRemove,
    List<Map<String, dynamic>>? contexts,
    List<Map<String, dynamic>>? modelActions,
    List<(String, List<int>, bool)>? filesAdd,
    List<String>? notes,
  }) : changes = changes ?? [],
       filesAdd = filesAdd ?? [],
       notes = notes ?? [],
       linksAdd = linksAdd ?? [],
       linksRemove = linksRemove ?? [],
       contexts = contexts ?? [],
       modelActions = modelActions ?? [];
  final String agent, runtime, provider;
  final List<Change> changes;
  final List<(String, String)> linksAdd, linksRemove;
  final List<Map<String, dynamic>> contexts, modelActions;
  final List<(String, List<int>, bool)> filesAdd; // path, bytes, executable
  final List<String> notes;
  bool get empty =>
      changes.isEmpty &&
      filesAdd.isEmpty &&
      linksAdd.isEmpty &&
      linksRemove.isEmpty &&
      modelActions.isEmpty;
}

final class ConfigFiles {
  ConfigFiles(this.posix, this.home);
  final Posix posix;
  final String home;

  /// connect.chain: texts planned so far, read instead of the files.
  Map<String, String>? staged;
  static const maxBytes = 2 * 1024 * 1024, claudeBytes = 8 * 1024 * 1024;

  String tilde(String path) => path == home || path.startsWith('$home/')
      ? '~${path.substring(home.length)}'
      : path;

  /// connect._read: "" when missing; this account's own regular file, not
  /// through a link, bounded, UTF-8 (anything else raises).
  String read(String path) {
    final planned = staged?[path];
    if (planned != null) return planned;
    if (const {
      'auth.json',
      '.credentials.json',
      'credentials.json',
    }.contains(p.basename(path))) {
      throw const FileSystemException('Credential file unavailable');
    }
    final limit = p.basename(path) == '.claude.json' ? claudeBytes : maxBytes;
    final int fd;
    try {
      fd = posix.openAt(-100, path, Posix.noFollow | Posix.nonBlock);
    } on FileSystemException catch (e) {
      if (e.osError?.errorCode == 2) return '';
      rethrow;
    }
    try {
      final info = posix.stat(fd);
      if (info.uid != posix.uid) {
        throw const FileSystemException('Foreign configuration unavailable');
      }
      if (info.size > limit) throw FileSystemException('$path is too large');
      return utf8.decode(posix.readDescriptor(fd, limit));
    } finally {
      posix.close(fd);
    }
  }

  /// connect._write: owner-only (the owner's own bits of an existing file are
  /// kept, group and other dropped), a fresh temporary file, then replaced.
  void write(String path, String text) {
    Directory(p.dirname(path)).createSync(recursive: true);
    var mode = 0x180;
    try {
      final own = File(path).statSync().mode & 0x1c0;
      if (own != 0) mode = own;
    } on FileSystemException {
      // a new file
    }
    posix.replaceFile(path, utf8.encode(text), mode);
  }

  bool _exists(String path) =>
      FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
  bool _isLink(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.link;

  static String _stamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}-'
        '${(t.millisecond * 1000 + t.microsecond).toString().padLeft(6, '0')}';
  }

  /// connect.apply (no commands or retired folders: the app's plans have
  /// none). Returns the backup folder.
  String apply(Plan plan, String backupRoot, {DateTime? now}) {
    void unchanged() {
      for (final change in plan.changes) {
        if (read(change.path) != change.old) {
          throw StateError('${change.path} changed in the meantime');
        }
      }
    }

    unchanged();
    final replaced = {for (final (link, _) in plan.linksRemove) link};
    for (final (link, _) in plan.linksAdd) {
      if ((_exists(link) || _isLink(link)) && !replaced.contains(link)) {
        throw StateError('$link exists already');
      }
    }
    for (final (link, target) in plan.linksRemove) {
      if (!_isLink(link) ||
          p.normalize(Link(link).targetSync()) != p.normalize(target)) {
        throw StateError('$link changed in the meantime');
      }
    }
    for (final (path, _, _) in plan.filesAdd) {
      if (_exists(path) || _isLink(path)) {
        throw StateError('$path exists already');
      }
    }
    unchanged(); // again, just before writing
    final folder = p.join(backupRoot, _stamp(now ?? DateTime.now()));
    Directory(backupRoot).createSync(recursive: true);
    Directory(folder).createSync();
    posix.chmodPath(folder, 0x1c0);
    final manifest = <Map<String, dynamic>>[];
    for (var i = 0; i < plan.changes.length; i++) {
      final change = plan.changes[i];
      final copy = p.join(folder, '$i-${p.basename(change.path)}');
      final existed = _exists(change.path);
      if (existed) {
        File(copy).writeAsStringSync(change.old);
        posix.chmodPath(copy, 0x180);
      }
      manifest.add({
        'path': change.path,
        'copy': existed ? p.basename(copy) : null,
        'written': change.next,
      });
    }
    final created = <String>[];
    for (final path in [
      for (final (path, _, _) in plan.filesAdd) path,
      for (final change in plan.changes)
        if (!_exists(change.path)) change.path,
    ]) {
      final parents = <String>[];
      for (var d = p.dirname(path); ; d = p.dirname(d)) {
        parents.add(d);
        if (d == p.dirname(d)) break;
      }
      for (final parent in parents.reversed) {
        if (!_exists(parent) && !created.contains(parent)) created.add(parent);
      }
    }
    final body = pyJsonDumps({
      'files': manifest,
      'undo_commands': <dynamic>[],
      'links': {
        'added': [
          for (final (l, t) in plan.linksAdd) [l, t],
        ],
        'removed': [
          for (final (l, t) in plan.linksRemove) [l, t],
        ],
      },
      'created': {
        'added': [
          for (final (path, data, _) in plan.filesAdd)
            [path, sha256.convert(data).toString()],
        ],
        'dirs': created,
      },
      'retired': <dynamic>[],
    });
    File(p.join(folder, 'manifest.json')).writeAsStringSync(body);
    posix.chmodPath(p.join(folder, 'manifest.json'), 0x180);
    for (final change in plan.changes) {
      write(change.path, change.next);
    }
    for (final (link, _) in plan.linksRemove) {
      Link(link).deleteSync();
    }
    for (final (link, target) in plan.linksAdd) {
      Directory(p.dirname(link)).createSync(recursive: true);
      Link(link).createSync(target);
    }
    for (final (path, data, executable) in plan.filesAdd) {
      Directory(p.dirname(path)).createSync(recursive: true);
      // O_WRONLY | O_CREAT | O_EXCL, never through a link; the umask applies.
      final fd = posix.openAt(
        -100,
        path,
        1 | 0x40 | 0x80 | Posix.noFollow | Posix.cloexec,
        executable ? 0x1ed : 0x1a4,
      );
      try {
        posix.write(fd, data);
      } finally {
        posix.close(fd);
      }
    }
    return folder;
  }

  /// connect.undo: what was not changed again since; returns restored paths.
  List<String> undo(String folder) {
    final restored = <String>[];
    final manifest = jsonDecode(
      File(p.join(folder, 'manifest.json')).readAsStringSync(),
    );
    List items;
    var dirs = <dynamic>[];
    if (manifest is Map) {
      if ((manifest['undo_commands'] as List? ?? []).isNotEmpty) {
        throw StateError('Undo commands are not run by the core');
      }
      final links = manifest['links'] as Map? ?? {};
      for (final entry in links['added'] as List? ?? []) {
        final link = entry[0] as String, target = entry[1] as String;
        if (_isLink(link) && Link(link).targetSync() == target) {
          Link(link).deleteSync();
          restored.add(link);
        }
      }
      for (final entry in links['removed'] as List? ?? []) {
        final link = entry[0] as String, target = entry[1] as String;
        if (!_exists(link) && !_isLink(link)) {
          Link(link).createSync(target);
          restored.add(link);
        }
      }
      final made = manifest['created'] as Map? ?? {};
      for (final entry in made['added'] as List? ?? []) {
        final path = entry[0] as String;
        try {
          if (!_isLink(path) &&
              sha256.convert(File(path).readAsBytesSync()).toString() ==
                  entry[1]) {
            File(path).deleteSync();
            restored.add(path);
          }
        } on FileSystemException {
          continue;
        }
      }
      dirs = made['dirs'] as List? ?? [];
      for (final entry in manifest['retired'] as List? ?? []) {
        final path = entry[0] as String, name = entry[1] as String;
        if (!_exists(path) &&
            !_isLink(path) &&
            Directory(p.join(folder, name)).existsSync()) {
          Directory(p.join(folder, name)).renameSync(path);
          restored.add(path);
        }
      }
      items = manifest['files'] as List? ?? [];
    } else {
      items = manifest as List;
    }
    for (final item in items) {
      final path = item['path'] as String;
      if (read(path) != item['written']) continue;
      if (item['copy'] != null) {
        write(
          path,
          File(p.join(folder, item['copy'] as String)).readAsStringSync(),
        );
      } else if (_exists(path) || _isLink(path)) {
        File(path).deleteSync();
      }
      restored.add(path);
    }
    final ordered = [for (final d in dirs) d as String];
    mergeSort(ordered, compare: (a, b) => b.length.compareTo(a.length));
    for (final dir in ordered) {
      try {
        Directory(dir).deleteSync();
      } on FileSystemException {
        // not empty: it stays
      }
    }
    return restored;
  }
}
