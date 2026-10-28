import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';
import 'identity.dart';
import 'posix_ffi.dart';

/// Bounded, own-UID, nonblocking metadata/config reads. Credentials are never
/// decoded, including when a caller accidentally names one as a normal config.
final class ScanFiles {
  ScanFiles(this.identity, {Posix? posix}) : posix = posix ?? Posix();
  final AppIdentity identity;
  final Posix posix;
  static const credentialNames = {
    'auth.json',
    '.credentials.json',
    'credentials.json',
  };
  static final _libc = DynamicLibrary.open('libc.so.6');
  static final _fdopendir = _libc
      .lookupFunction<Pointer<Void> Function(Int), Pointer<Void> Function(int)>(
        'fdopendir',
      );
  static final _readdir = _libc
      .lookupFunction<
        Pointer<Uint8> Function(Pointer<Void>),
        Pointer<Uint8> Function(Pointer<Void>)
      >('readdir');
  static final _closedir = _libc
      .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'closedir',
      );

  String expand(String path) => path == '~'
      ? identity.home
      : path.startsWith('~/')
      ? p.join(identity.home, path.substring(2))
      : path;
  bool credential(String path) => credentialNames.contains(p.basename(path));
  bool exists(String path) =>
      FileSystemEntity.typeSync(expand(path), followLinks: false) !=
      FileSystemEntityType.notFound;
  List<int>? bytes(
    String path, {
    int limit = 512 * 1024,
    bool follow = false,
    String portion = 'whole',
    bool allowRootOwned = false,
  }) {
    path = expand(path);
    if (credential(path) || !p.isAbsolute(path) || path.contains('\x00')) {
      return null;
    }
    int? fd;
    try {
      // Reads match the reference: the kernel resolves the folders, the final
      // name is not followed (unless asked), and the opened file is checked.
      // The pinned, trusted-parent walk stays for private writes.
      fd = posix.openAt(
        -100,
        path,
        Posix.nonBlock | (follow ? 0 : Posix.noFollow),
      );
      final owner = posix.stat(fd).uid;
      if (owner != posix.uid && !(allowRootOwned && owner == 0)) {
        return null;
      }
      return portion == 'head'
          ? posix.readPrefix(fd, limit)
          : portion == 'tail'
          ? posix.readSuffix(fd, limit)
          : posix.readDescriptor(fd, limit);
    } on FileSystemException {
      return null;
    } finally {
      if (fd != null) posix.close(fd);
    }
  }

  String? text(
    String path, {
    int limit = 512 * 1024,
    bool follow = false,
    String portion = 'whole',
    bool allowRootOwned = false,
  }) {
    final data = bytes(
      path,
      limit: limit,
      follow: follow,
      portion: portion,
      allowRootOwned: allowRootOwned,
    );
    return data == null ? null : utf8.decode(data, allowMalformed: true);
  }

  Map<String, dynamic> json(
    String path, {
    int limit = 512 * 1024,
    bool comments = true,
  }) {
    try {
      final source = text(path, limit: limit);
      final data = source == null
          ? null
          : jsonDecode(comments ? stripJsonComments(source) : source);
      return data is Map<String, dynamic> ? data : {};
    } on FormatException {
      return {};
    }
  }

  Map<String, dynamic> toml(String path) {
    try {
      return TomlDocument.parse(text(path) ?? '').toMap();
    } on TomlException {
      return {};
    } on FormatException {
      return {};
    }
  }

  /// readdir stops at the bound; Directory.listSync would first allocate the
  /// entire directory. Linux dirent64 names start at byte 19 on supported ABIs.
  List<String> list(
    String path, {
    int limit = 4000,
    bool allowRootOwned = false,
  }) {
    path = expand(path);
    if (!p.isAbsolute(path) || path.contains('\x00')) return [];
    int? fd;
    Pointer<Void> directory = nullptr;
    final result = <String>[];
    try {
      fd = posix.openAt(-100, path, Posix.directory);
      final owner = posix.stat(fd).uid;
      if (owner != posix.uid && !(allowRootOwned && owner == 0)) {
        return [];
      }
      directory = _fdopendir(fd);
      if (directory == nullptr) return [];
      fd = null; // owned by DIR after successful fdopendir
      while (result.length < limit) {
        final record = _readdir(directory);
        if (record == nullptr) break;
        final length = (record + 16).cast<Uint16>().value;
        if (length < 20 || length > 4096) break;
        final data = (record + 19).asTypedList(length - 19);
        final end = data.indexOf(0);
        if (end < 0) break;
        final name = utf8.decode(data.sublist(0, end), allowMalformed: true);
        if (name != '.' && name != '..') result.add(p.join(path, name));
      }
      return result;
    } on FileSystemException {
      return [];
    } finally {
      if (directory != nullptr) _closedir(directory);
      if (fd != null) posix.close(fd);
    }
  }
}

String stripJsonComments(String text) {
  final out = StringBuffer();
  var inside = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (inside) {
      out.write(c);
      if (c == r'\' && i + 1 < text.length) {
        out.write(text[++i]);
      } else if (c == '"') {
        inside = false;
      }
    } else if (c == '"') {
      inside = true;
      out.write(c);
    } else if (text.startsWith('//', i)) {
      while (i < text.length && text[i] != '\n') {
        i++;
      }
      out.write('\n');
    } else if (text.startsWith('/*', i)) {
      final end = text.indexOf('*/', i + 2);
      i = end < 0 ? text.length : end + 1;
    } else {
      out.write(c);
    }
  }
  return out.toString().replaceAllMapped(RegExp(r',\s*([}\]])'), (m) => m[1]!);
}
