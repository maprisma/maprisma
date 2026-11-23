import 'dart:io';

import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/services.dart';

import 'window_popup.dart' show windowChannel;

/// Where data disks are mounted (fstab under /mnt, udisks under /run/media).
const _mountRoots = ['/mnt/', '/media/', '/run/media/', '/srv/'];

/// The folder dialog's extra sidebar entries: every mounted data disk
/// (/mnt/Data, /mnt/Games, a USB stick) and the folders pinned in the
/// desktop's file manager (COSMIC Files favorites, KDE Places), in this
/// order, without duplicates, the home folder or what is gone. GTK's own
/// bookmarks (~/.config/gtk-3.0/bookmarks) the dialog shows by itself.
///
/// [isDir] says whether a path is an existing folder; [isSystemRoot] whether
/// a mount is another system's root (the Omarchy disk opened at
/// /mnt/omarchy-root), which is no place to start a project.
List<String> folderShortcuts({
  required String mounts,
  required String home,
  String? cosmicFavorites,
  String? kdePlaces,
  bool Function(String path)? isDir,
  bool Function(String path)? isSystemRoot,
}) {
  final exists = isDir ?? (path) => Directory(path).existsSync();
  final system = isSystemRoot ?? (_) => false;
  final found = <String>[];
  void add(String path) {
    var clean = path;
    while (clean.length > 1 && clean.endsWith('/')) {
      clean = clean.substring(0, clean.length - 1);
    }
    if (!clean.startsWith('/') || clean == home || clean == '/') return;
    if (found.contains(clean) || !exists(clean)) return;
    found.add(clean);
  }

  for (final line in mounts.split('\n')) {
    final fields = line.split(' ');
    if (fields.length < 3 || !fields[0].startsWith('/dev/')) continue;
    // /proc/self/mounts writes a space as \040 (and tab, newline, \ alike).
    final target = fields[1].replaceAllMapped(
      RegExp(r'\\([0-7]{3})'),
      (m) => String.fromCharCode(int.parse(m[1]!, radix: 8)),
    );
    if (!_mountRoots.any(target.startsWith) || system(target)) continue;
    add(target);
  }
  if (cosmicFavorites != null) {
    for (final m in RegExp(
      r'Path\("((?:[^"\\]|\\.)*)"\)',
    ).allMatches(cosmicFavorites)) {
      add(m[1]!.replaceAll(r'\"', '"').replaceAll(r'\\', r'\'));
    }
  }
  if (kdePlaces != null) {
    for (final m in RegExp(r'href="(file://[^"]+)"').allMatches(kdePlaces)) {
      try {
        add(Uri.parse(m[1]!.replaceAll('&amp;', '&')).toFilePath());
      } on FormatException {
        // Not a local path.
      } on UnsupportedError {
        // Not a local path.
      }
    }
  }
  return found;
}

String? _read(String path) {
  try {
    return File(path).readAsStringSync();
  } on FileSystemException {
    return null;
  }
}

/// [folderShortcuts] of this PC.
List<String> currentFolderShortcuts() {
  final home = Platform.environment['HOME'] ?? '';
  final config = Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
  final data = Platform.environment['XDG_DATA_HOME'] ?? '$home/.local/share';
  return folderShortcuts(
    mounts: _read('/proc/self/mounts') ?? '',
    home: home,
    cosmicFavorites: _read(
      '$config/cosmic/com.system76.CosmicFiles/v1/favorites',
    ),
    kdePlaces: _read('$data/user-places.xbel'),
    isSystemRoot: (path) =>
        Directory('$path/etc').existsSync() &&
        Directory('$path/usr').existsSync(),
  );
}

/// Choose a folder: GTK's dialog with the mounted disks and pinned folders
/// in its sidebar (Uwe 2026-11-23); file_selector's where the runner has no
/// such method (an older runner, other platforms). A drop-in for
/// file_selector's getDirectoryPath.
Future<String?> chooseFolder({
  String? initialDirectory,
  String? confirmButtonText,
}) async {
  if (Platform.isLinux) {
    try {
      return await windowChannel.invokeMethod<String>('chooseFolder', {
        'shortcuts': currentFolderShortcuts(),
        'initial': ?initialDirectory,
        'accept': ?confirmButtonText,
      });
    } on MissingPluginException {
      // file_selector's dialog below.
    }
  }
  return file_selector.getDirectoryPath(
    initialDirectory: initialDirectory,
    confirmButtonText: confirmButtonText,
  );
}
