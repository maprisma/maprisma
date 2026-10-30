import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'connect_apply.dart';

/// The connection changes kept on disk (each one's backup folder with its
/// manifest.json), for Undo after the app was closed or crashed: the
/// in-session Undo only knows the last change. What a backup can still undo
/// is what was not changed again since, as ConfigFiles.undo decides; an
/// apply that stopped half way left its manifest first, so its written files
/// can be undone and the others are seen as never changed.

final _stamp = RegExp(r'^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})-(\d{6})$');
const historyLimit = 20;
const _manifestBytes = 1024 * 1024;

/// A backup folder's name as a time, null for anything else.
DateTime? backupTime(String name) {
  final m = _stamp.firstMatch(name);
  if (m == null) return null;
  return DateTime(
    int.parse(m[1]!),
    int.parse(m[2]!),
    int.parse(m[3]!),
    int.parse(m[4]!),
    int.parse(m[5]!),
    int.parse(m[6]!),
    0,
    int.parse(m[7]!),
  );
}

/// The manifest of `folder` (own regular file, no link, small), null when
/// it cannot be read.
Map? _manifest(String folder) {
  final path = p.join(folder, 'manifest.json');
  try {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    final file = File(path);
    if (file.lengthSync() > _manifestBytes) return null;
    final data = jsonDecode(file.readAsStringSync());
    return data is Map ? data : null;
  } on Object {
    return null;
  }
}

bool _isLink(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) ==
    FileSystemEntityType.link;

bool _exists(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) !=
    FileSystemEntityType.notFound;

/// What Undo of this manifest would put back now (the same checks as
/// ConfigFiles.undo, nothing changed).
List<String> undoable(ConfigFiles files, String folder, Map manifest) {
  final found = <String>[];
  if ((manifest['undo_commands'] as List? ?? const []).isNotEmpty) {
    return found; // not run by the core
  }
  final links = manifest['links'] is Map ? manifest['links'] as Map : const {};
  for (final entry in links['added'] as List? ?? const []) {
    final link = '${entry[0]}', target = '${entry[1]}';
    try {
      if (_isLink(link) && Link(link).targetSync() == target) found.add(link);
    } on FileSystemException {
      continue;
    }
  }
  for (final entry in links['removed'] as List? ?? const []) {
    final link = '${entry[0]}';
    if (!_exists(link)) found.add(link);
  }
  final made = manifest['created'] is Map
      ? manifest['created'] as Map
      : const {};
  for (final entry in made['added'] as List? ?? const []) {
    final path = '${entry[0]}';
    try {
      if (!_isLink(path) &&
          sha256.convert(File(path).readAsBytesSync()).toString() == entry[1]) {
        found.add(path);
      }
    } on FileSystemException {
      continue;
    }
  }
  for (final entry in manifest['retired'] as List? ?? const []) {
    final path = '${entry[0]}', name = '${entry[1]}';
    if (!_exists(path) && Directory(p.join(folder, name)).existsSync()) {
      found.add(path);
    }
  }
  for (final item in manifest['files'] as List? ?? const []) {
    if (item is! Map || item['path'] is! String) continue;
    try {
      if (files.read(item['path'] as String) == item['written']) {
        found.add(item['path'] as String);
      }
    } on FileSystemException {
      continue;
    }
  }
  return found;
}

/// The newest changes first: when, which files and links, and what Undo
/// would still put back.
List<Map<String, dynamic>> changeHistory(
  ConfigFiles files,
  String backupRoot, {
  int limit = historyLimit,
}) {
  List<FileSystemEntity> entries;
  try {
    entries = Directory(backupRoot).listSync(followLinks: false);
  } on FileSystemException {
    return [];
  }
  final folders = [
    for (final e in entries)
      if (e is Directory && backupTime(p.basename(e.path)) != null) e.path,
  ]..sort((a, b) => p.basename(b).compareTo(p.basename(a)));
  final history = <Map<String, dynamic>>[];
  for (final folder in folders) {
    if (history.length >= limit) break;
    final manifest = _manifest(folder);
    if (manifest == null) continue;
    final links = manifest['links'] is Map
        ? manifest['links'] as Map
        : const {};
    final made = manifest['created'] is Map
        ? manifest['created'] as Map
        : const {};
    final changed = <String>[
      for (final item in manifest['files'] as List? ?? const [])
        if (item is Map && item['path'] is String) item['path'] as String,
      for (final entry in made['added'] as List? ?? const []) '${entry[0]}',
      for (final key in const ['added', 'removed'])
        for (final entry in links[key] as List? ?? const []) '${entry[0]}',
      for (final entry in manifest['retired'] as List? ?? const [])
        '${entry[0]}',
    ];
    if (changed.isEmpty) continue;
    final still = undoable(files, folder, manifest);
    history.add({
      'id': p.basename(folder),
      'when': backupTime(p.basename(folder))!.toIso8601String(),
      'changed': [for (final path in changed.take(50)) files.tilde(path)],
      'count': changed.length,
      'undoable': [for (final path in still.take(50)) files.tilde(path)],
    });
  }
  return history;
}

/// Undo of one listed change: its folder directly in [backupRoot], by its
/// name only.
List<String> undoChange(ConfigFiles files, String backupRoot, String id) {
  if (backupTime(id) == null) throw const FormatException('Unknown change');
  final folder = p.join(backupRoot, id);
  if (FileSystemEntity.typeSync(folder, followLinks: false) !=
          FileSystemEntityType.directory ||
      _manifest(folder) == null) {
    throw const FormatException('Unknown change');
  }
  return [for (final path in files.undo(folder)) files.tilde(path)];
}
