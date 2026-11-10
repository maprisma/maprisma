import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:maprisma_core/maprisma_core.dart' show Posix;

/// Characters of a note: a few sentences, not a document.
const screenshotNoteLimit = 4000;

/// Tests only: a write of a new picture or note fails after this many bytes
/// (a full disk, an I/O error).
int? debugFailWriteAfter;

/// F12: a picture of the app's own window and its note, in ~/Pictures/Maprisma
/// (the desktop's pictures folder from user-dirs.dirs), while the setting
/// screenshot_key is on (default). Only into a real folder of yours that
/// others cannot write to (made 0700 when missing, checked on its opened
/// handle and written relative to it), each file new (0600, never through a
/// link, never over an existing file), completely and synced or removed again.
final class WindowShots {
  WindowShots(this.folder);
  final String folder;

  static WindowShots fromEnvironment(Map<String, String> environment) =>
      WindowShots('${picturesFolder(environment)}/Maprisma');

  /// XDG_PICTURES_DIR from user-dirs.dirs (read bounded, never through a
  /// link), else ~/Pictures.
  static String picturesFolder(Map<String, String> environment) {
    final home = environment['HOME'] ?? '';
    final xdg = environment['XDG_CONFIG_HOME'] ?? '';
    final config = xdg.startsWith('/') ? xdg : '$home/.config';
    var pictures = '$home/Pictures';
    try {
      final text = utf8.decode(
        Posix().readRegular('$config/user-dirs.dirs', 64 * 1024),
        allowMalformed: true,
      );
      final entry = RegExp(r'^\s*XDG_PICTURES_DIR\s*=\s*"(.*)"\s*$');
      for (final line in const LineSplitter().convert(text)) {
        final match = entry.firstMatch(line);
        if (match == null) continue;
        final value = match[1]!.replaceFirst(RegExp(r'^\$HOME(?=/|$)'), home);
        final clean = value.replaceFirst(RegExp(r'/+$'), '');
        // "$HOME/" alone is no pictures folder of its own; relative is none.
        if (value.startsWith('/') && clean != home && clean.isNotEmpty) {
          pictures = clean;
        }
      }
    } on Object {
      // no (readable) user-dirs.dirs: ~/Pictures
    }
    return pictures;
  }

  static String _stem(DateTime time) {
    String two(int n) => '$n'.padLeft(2, '0');
    return 'maprisma-${time.year}-${two(time.month)}-${two(time.day)}'
        '-${two(time.hour)}-${two(time.minute)}-${two(time.second)}';
  }

  /// maprisma-2026-11-01-08-26-31.png, then -2 within the same second; a name
  /// is free when neither the picture nor its note exists (also no link that
  /// points nowhere).
  String pathFor(DateTime time) {
    final folder = _PrivateFolder.open(this.folder);
    try {
      return '${this.folder}/${folder.freeName(_stem(time))}';
    } finally {
      folder.close();
    }
  }

  Future<String> save(Uint8List png, DateTime time) async {
    final where = _PrivateFolder.open(folder);
    try {
      final name = where.freeName(_stem(time));
      where.writeNew(name, png);
      return '$folder/$name';
    } finally {
      where.close();
    }
  }

  /// Into the folder chosen in Settings; a folder that cannot be used loses
  /// no picture, it goes to the default one.
  Future<String> saveTo(String? chosen, Uint8List png, DateTime time) async {
    if (chosen == null || chosen.isEmpty) return save(png, time);
    try {
      return await WindowShots(chosen).save(png, time);
    } on Object {
      return save(png, time);
    }
  }

  /// The note goes next to its picture, with the same name (at most
  /// [screenshotNoteLimit] characters); no note, no file. The folder is
  /// checked again and an existing note is never overwritten.
  Future<void> note(String picture, String text) async {
    var note = text.trim();
    if (note.isEmpty) return;
    if (note.length > screenshotNoteLimit) {
      note = note.substring(0, screenshotNoteLimit);
    }
    final slash = picture.lastIndexOf('/');
    final name = picture.substring(slash + 1);
    final stem = name.endsWith('.png')
        ? name.substring(0, name.length - 4)
        : name;
    final where = _PrivateFolder.open(picture.substring(0, slash));
    try {
      where.writeNew('$stem.txt', utf8.encode('$note\n'));
    } finally {
      where.close();
    }
  }
}

/// A handle on a folder of this account's that only it may write to (see
/// [WindowShots]).
final class _PrivateFolder {
  _PrivateFolder._(this.path, this._posix, this._fd);

  factory _PrivateFolder.open(String path) {
    if (!path.startsWith('/')) {
      throw FileSystemException('not an absolute folder', path);
    }
    final there = FileSystemEntity.typeSync(path, followLinks: false);
    if (there != FileSystemEntityType.directory &&
        there != FileSystemEntityType.notFound) {
      // A link or a file in its place is refused.
      throw FileSystemException(
        'mkdir',
        path,
        const OSError('File exists', 17),
      );
    }
    if (there == FileSystemEntityType.notFound) {
      Directory(path).parent.createSync(recursive: true);
    }
    final posix = Posix();
    // Every folder on the way trusted, the last one made 0700 when missing.
    final fd = posix.privateDirectory(path);
    final info = posix.statAt(fd, '');
    if (info == null ||
        info.mode & 0xf000 != 0x4000 ||
        info.uid != posix.uid ||
        info.mode & 0x12 != 0) {
      posix.close(fd);
      throw FileSystemException(
        'not a private folder of yours',
        path,
        const OSError('Permission denied', 13),
      );
    }
    return _PrivateFolder._(path, posix, fd);
  }

  final String path;
  final Posix _posix;
  int _fd;

  bool _taken(String name) => _posix.statAt(_fd, name) != null;

  String freeName(String stem) {
    var name = stem;
    for (var n = 2; _taken('$name.png') || _taken('$name.txt'); n++) {
      name = '$stem-$n';
    }
    return '$name.png';
  }

  /// O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW, 0600 from the first byte; short
  /// writes continued, a write of nothing fails; synced, or removed again.
  void writeNew(String name, List<int> bytes) {
    if (name.isEmpty || name == '.' || name == '..' || name.contains('/')) {
      throw ArgumentError.value(name, 'name', 'not a plain file name');
    }
    final out = _posix.openAt(
      _fd,
      name,
      1 | 0x40 | 0x80 | Posix.noFollow,
      0x180,
    );
    var ok = false;
    try {
      final limit = debugFailWriteAfter;
      if (limit != null && bytes.length > limit) {
        _posix.write(out, bytes.sublist(0, limit));
        throw FileSystemException(
          'write',
          '$path/$name',
          const OSError('No space left on device', 28),
        );
      }
      _posix.write(out, bytes);
      _posix.sync(out);
      ok = true;
    } finally {
      _posix.close(out);
      if (!ok) {
        try {
          _posix.unlinkAt(_fd, name); // nothing half-written is left behind
        } on Object {
          // already gone
        }
      }
    }
  }

  void close() {
    if (_fd >= 0) {
      _posix.close(_fd);
      _fd = -1;
    }
  }
}

/// F12 in a recorded manual test (tools/test-session.sh): the picture and a
/// note, next to the protocol, whatever the setting says. Only while
/// MAPRISMA_RECORD_PROTOCOL is set.
final class TestShots {
  TestShots(this.protocol);
  final String protocol;

  static TestShots? fromEnvironment(Map<String, String> environment) {
    final path = environment['MAPRISMA_RECORD_PROTOCOL'] ?? '';
    return path.isEmpty ? null : TestShots(path);
  }

  String get _run => File(protocol).parent.path;
  String get folder => '$_run/shots';

  /// shots/08-26-31.png, then 08-26-31-2.png within the same second.
  String pathFor(DateTime time) {
    String two(int n) => '$n'.padLeft(2, '0');
    final stem = '${two(time.hour)}-${two(time.minute)}-${two(time.second)}';
    var path = '$folder/$stem.png';
    for (var n = 2; File(path).existsSync(); n++) {
      path = '$folder/$stem-$n.png';
    }
    return path;
  }

  Future<String> save(Uint8List png, DateTime time) async {
    await Directory(folder).create(recursive: true);
    final path = pathFor(time);
    await File(path).writeAsBytes(png, flush: true);
    return path;
  }

  /// One line in the protocol, at the moment the picture was taken.
  Future<void> record(String path, String note, DateTime time) async {
    final line = {
      'time': time.toIso8601String(),
      'method': 'test.shot',
      'params': {'file': path.substring(_run.length + 1), 'note': note},
      'result': {},
    };
    await File(protocol).writeAsString(
      '${jsonEncode(line)}\n',
      mode: FileMode.append,
      flush: true,
    );
  }
}
