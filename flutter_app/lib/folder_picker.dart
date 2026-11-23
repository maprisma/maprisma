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
  String trim(String path) {
    var clean = path;
    while (clean.length > 1 && clean.endsWith('/')) {
      clean = clean.substring(0, clean.length - 1);
    }
    return clean;
  }

  final homeDir = trim(home);
  void add(String path) {
    final clean = trim(path);
    if (!clean.startsWith('/') || clean == homeDir || clean == '/') return;
    if (found.contains(clean) || !exists(clean)) return;
    found.add(clean);
  }

  // Another system's root and every mount inside it (its /boot, /home).
  final systemRoots = <String>[];
  for (final line in mounts.split('\n')) {
    final fields = line.split(' ');
    if (fields.length < 3 || !_dataFilesystem(fields[0], fields[2])) continue;
    // /proc/self/mounts writes a space as \040 (and tab, newline, \ alike).
    final target = trim(
      fields[1].replaceAllMapped(
        RegExp(r'\\([0-7]{3})'),
        (m) => String.fromCharCode(int.parse(m[1]!, radix: 8)),
      ),
    );
    if (!_mountRoots.any(target.startsWith)) continue;
    if (systemRoots.any((root) => target.startsWith('$root/'))) continue;
    if (system(target)) {
      systemRoots.add(target);
      continue;
    }
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
    // Each <bookmark>; one the user hid in KDE stays hidden.
    for (final b in RegExp(
      r'<bookmark\b([^>]*)>(.*?)</bookmark>',
      dotAll: true,
    ).allMatches(kdePlaces)) {
      if (RegExp(r'<isHidden>\s*true\s*</isHidden>').hasMatch(b[2]!)) continue;
      final href = RegExp(r'href="(file://[^"]+)"').firstMatch(b[1]!);
      if (href == null) continue;
      try {
        add(Uri.parse(_xmlText(href[1]!)).toFilePath());
      } on FormatException {
        // Not a local path.
      } on UnsupportedError {
        // Not a local path.
      }
    }
  }
  return found;
}

/// A mount that holds data: a disk (/dev/...), a network share (NFS, SMB,
/// SSHFS) or a ZFS/btrfs pool; not tmpfs, proc, overlay and the like.
bool _dataFilesystem(String source, String type) {
  if (source.startsWith('/dev/')) return true;
  const network = {'nfs', 'nfs4', 'cifs', 'smb3', 'fuse.sshfs', 'zfs', '9p'};
  return network.contains(type);
}

/// An XML attribute's text (&amp;, &apos;, &#39;, ...).
String _xmlText(String text) => text.replaceAllMapped(
  RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);'),
  (m) {
    final name = m[1]!;
    if (name.startsWith('#x')) {
      return String.fromCharCode(int.parse(name.substring(2), radix: 16));
    }
    if (name.startsWith('#')) {
      return String.fromCharCode(int.parse(name.substring(1)));
    }
    return const {
      'amp': '&',
      'lt': '<',
      'gt': '>',
      'quot': '"',
      'apos': "'",
    }[name]!;
  },
);

String? _read(String path) {
  try {
    return File(path).readAsStringSync();
  } on FileSystemException {
    return null;
  }
}

/// [folderShortcuts] of this PC.
List<String> currentFolderShortcuts() {
  final env = Platform.environment;
  final home = env['HOME'] ?? '';
  // An empty XDG variable counts as unset (XDG Base Directory spec).
  String xdg(String name, String fallback) {
    final value = env[name] ?? '';
    return value.startsWith('/') ? value : fallback;
  }

  final config = xdg('XDG_CONFIG_HOME', '$home/.config');
  final data = xdg('XDG_DATA_HOME', '$home/.local/share');
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
/// file_selector's getDirectoryPath; [title] is the dialog's (translated)
/// title, GTK's own "Select a folder" without it.
Future<String?> chooseFolder({
  String? title,
  String? initialDirectory,
  String? confirmButtonText,
}) async {
  if (Platform.isLinux) {
    try {
      return await windowChannel.invokeMethod<String>('chooseFolder', {
        'title': ?title,
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
