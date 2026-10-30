import 'dart:io';

import 'package:path/path.dart' as p;

import 'identity.dart';
import 'posix_ffi.dart';

/// The app was called Asterism until 2026-10-30 (docs/plan-naming.md, step
/// 7). At the first start of Maprisma, while its config folder does not
/// exist yet, the Asterism folders are copied over once: the config folder
/// (settings, the MCP server list, connection backups), the installed
/// add-ons and the state folder (jobs, notices). The cache is not copied (it
/// is rebuilt), and nothing of Asterism is changed or deleted. Links are
/// copied as links, never followed; modes are kept.

/// (from, to) pairs of folders, the config folder first.
List<(String, String)> legacyFolders(AppIdentity identity) {
  final old = AppIdentity.legacyShortName;
  return [
    (
      p.join(identity.root('XDG_CONFIG_HOME', '.config'), old),
      identity.configDir,
    ),
    (
      p.join(identity.root('XDG_DATA_HOME', '.local/share'), old, 'addons'),
      p.join(identity.dataDir, 'addons'),
    ),
    (
      p.join(identity.root('XDG_STATE_HOME', '.local/state'), old),
      identity.stateDir,
    ),
  ];
}

bool _isDir(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) ==
    FileSystemEntityType.directory;

/// Copies `from` to `to` (which must not exist): through a temporary folder
/// beside it, renamed at the end, so a stopped copy never looks finished.
void _copyTree(String from, String to, Posix posix) {
  final temp = '$to.moving-$pid';
  if (FileSystemEntity.typeSync(temp, followLinks: false) !=
      FileSystemEntityType.notFound) {
    Directory(temp).deleteSync(recursive: true);
  }
  void copy(String source, String target) {
    Directory(target).createSync();
    posix.chmodPath(target, Directory(source).statSync().mode & 0xfff);
    for (final entry in Directory(source).listSync(followLinks: false)) {
      final name = p.basename(entry.path);
      final into = p.join(target, name);
      switch (entry) {
        case Link():
          Link(into).createSync(entry.targetSync());
        case Directory():
          copy(entry.path, into);
        case File():
          entry.copySync(into);
          posix.chmodPath(into, entry.statSync().mode & 0xfff);
      }
    }
  }

  Directory(p.dirname(to)).createSync(recursive: true);
  copy(from, temp);
  Directory(temp).renameSync(to);
}

/// The copy, when it is due; null when it worked or was not needed, else
/// why it failed (the app then starts with defaults: `migration_error`).
String? moveFromAsterism(AppIdentity identity, {Posix? posix}) {
  final folders = legacyFolders(identity);
  final (oldConfig, newConfig) = folders.first;
  if (FileSystemEntity.typeSync(newConfig, followLinks: false) !=
          FileSystemEntityType.notFound ||
      !_isDir(oldConfig)) {
    return null;
  }
  final px = posix ?? Posix();
  try {
    // The config folder last: while it is missing, the copy is due again.
    for (final (from, to) in folders.skip(1)) {
      if (_isDir(from) &&
          FileSystemEntity.typeSync(to, followLinks: false) ==
              FileSystemEntityType.notFound) {
        _copyTree(from, to, px);
      }
    }
    _copyTree(oldConfig, newConfig, px);
    return null;
  } on FileSystemException catch (error) {
    return 'The Asterism settings could not be copied: ${error.message}';
  }
}
