import 'dart:convert';
import 'dart:collection';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// Linux-only descriptor operations. No shell, credentials or UI-supplied argv.
/// statx's fixed Linux ABI avoids architecture-dependent struct stat offsets.
class Posix {
  Posix() {
    if (!Platform.isLinux) throw UnsupportedError('Linux core required');
  }
  static final _lib = DynamicLibrary.open('libc.so.6');
  static final _openat = _lib
      .lookupFunction<
        Int Function(Int, Pointer<Utf8>, Int, Uint32),
        int Function(int, Pointer<Utf8>, int, int)
      >('openat');
  static final _close = _lib
      .lookupFunction<Int Function(Int), int Function(int)>('close');
  static final _read = _lib
      .lookupFunction<
        IntPtr Function(Int, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int)
      >('read');
  static final _write = _lib
      .lookupFunction<
        IntPtr Function(Int, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int)
      >('write');
  static final _sync = _lib
      .lookupFunction<Int Function(Int), int Function(int)>('fsync');
  static final _chmod = _lib
      .lookupFunction<Int Function(Int, Uint32), int Function(int, int)>(
        'fchmod',
      );
  static final _statx = _lib
      .lookupFunction<
        Int Function(Int, Pointer<Utf8>, Int, Uint32, Pointer<Uint8>),
        int Function(int, Pointer<Utf8>, int, int, Pointer<Uint8>)
      >('statx');
  static final _statvfs = _lib
      .lookupFunction<
        Int Function(Pointer<Utf8>, Pointer<Uint8>),
        int Function(Pointer<Utf8>, Pointer<Uint8>)
      >('statvfs');
  static final _rename = _lib
      .lookupFunction<
        Int Function(Int, Pointer<Utf8>, Int, Pointer<Utf8>),
        int Function(int, Pointer<Utf8>, int, Pointer<Utf8>)
      >('renameat');
  static final _unlink = _lib
      .lookupFunction<
        Int Function(Int, Pointer<Utf8>, Int),
        int Function(int, Pointer<Utf8>, int)
      >('unlinkat');
  static final _mkdir = _lib
      .lookupFunction<
        Int Function(Int, Pointer<Utf8>, Uint32),
        int Function(int, Pointer<Utf8>, int)
      >('mkdirat');
  static final _utimensat = _lib
      .lookupFunction<
        Int Function(Int, Pointer<Utf8>, Pointer<Int64>, Int),
        int Function(int, Pointer<Utf8>, Pointer<Int64>, int)
      >('utimensat');
  static final _errno = _lib
      .lookupFunction<Pointer<Int> Function(), Pointer<Int> Function()>(
        '__errno_location',
      );
  static final _uid = _lib.lookupFunction<Uint32 Function(), int Function()>(
    'getuid',
  );
  static const noFollow = 0x20000,
      nonBlock = 0x800,
      cloexec = 0x80000,
      directory = 0x10000;
  int get uid => _uid();
  Never _fail() => throw FileSystemException(
    'POSIX operation failed',
    '',
    OSError('', _errno().value),
  );
  T _path<T>(String path, T Function(Pointer<Utf8>) action) {
    if (path.contains('\x00')) throw ArgumentError('NUL in path');
    final native = path.toNativeUtf8();
    try {
      return action(native);
    } finally {
      calloc.free(native);
    }
  }

  int openAt(int dir, String path, int flags, [int mode = 0]) =>
      _path(path, (name) {
        final fd = _openat(dir, name, flags | cloexec, mode);
        if (fd < 0) _fail();
        return fd;
      });
  void close(int fd) {
    if (_close(fd) != 0) _fail();
  }

  void sync(int fd) {
    if (_sync(fd) != 0) _fail();
  }

  void chmod(int fd, int mode) {
    if (_chmod(fd, mode) != 0) _fail();
  }

  static final _ftruncate = _lib
      .lookupFunction<Int Function(Int, Int64), int Function(int, int)>(
        'ftruncate',
      );

  static final _linkat = _lib
      .lookupFunction<
        Int Function(Int, Pointer<Utf8>, Int, Pointer<Utf8>, Int),
        int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int)
      >('linkat');

  /// os.link: a hard link (a link given as the existing name is followed,
  /// AT_SYMLINK_FOLLOW, as os.link does); false on failure.
  bool hardLink(String existing, String link) {
    final from = existing.toNativeUtf8(), to = link.toNativeUtf8();
    try {
      return _linkat(-100, from, -100, to, 0x400) == 0;
    } finally {
      calloc.free(from);
      calloc.free(to);
    }
  }

  /// flock(2) without waiting: false when another holds a conflicting lock.
  /// [shared]: LOCK_SH, else LOCK_EX (task 073: the install's instance lock).
  bool tryFlock(int fd, {required bool shared}) =>
      _flock(fd, (shared ? 1 : 2) | 4) == 0;

  void truncate(int fd, int length) {
    if (_ftruncate(fd, length) != 0) _fail();
  }

  /// fstat's type, owner, size, link count and identity (device, inode).
  ({int mode, int uid, int size, int nlink, List<int> identity}) statFull(
    int fd,
  ) {
    final buffer = calloc<Uint8>(256);
    try {
      _path('', (name) {
        if (_statx(fd, name, 0x1000, 0x7ff, buffer) != 0) _fail();
      });
      final b = ByteData.sublistView(buffer.asTypedList(256));
      return (
        mode: b.getUint16(28, Endian.host),
        uid: b.getUint32(20, Endian.host),
        size: b.getUint64(40, Endian.host),
        nlink: b.getUint32(16, Endian.host),
        identity: [
          b.getUint32(136, Endian.host),
          b.getUint32(140, Endian.host),
          b.getUint64(32, Endian.host),
        ],
      );
    } finally {
      calloc.free(buffer);
    }
  }

  ({int mode, int uid, int size}) stat(int fd) {
    final buffer = calloc<Uint8>(256);
    try {
      _path('', (name) {
        if (_statx(fd, name, 0x1000, 0x7ff, buffer) != 0) _fail();
      });
      final bytes = ByteData.sublistView(buffer.asTypedList(256));
      return (
        mode: bytes.getUint16(28, Endian.host),
        uid: bytes.getUint32(20, Endian.host),
        size: bytes.getUint64(40, Endian.host),
      );
    } finally {
      calloc.free(buffer);
    }
  }

  /// lstat's modification time and type bits, without following a final link
  /// (statx AT_SYMLINK_NOFOLLOW); null when the path cannot be examined.
  ({int sec, int nsec, int mode})? lstatTime(String path) {
    final buffer = calloc<Uint8>(256);
    try {
      var ok = false;
      _path(path, (name) => ok = _statx(-100, name, 0x100, 0x7ff, buffer) == 0);
      if (!ok) return null;
      final bytes = ByteData.sublistView(buffer.asTypedList(256));
      return (
        sec: bytes.getInt64(112, Endian.host),
        nsec: bytes.getUint32(120, Endian.host),
        mode: bytes.getUint16(28, Endian.host),
      );
    } finally {
      calloc.free(buffer);
    }
  }

  static final _lseek = _lib
      .lookupFunction<
        Int64 Function(Int, Int64, Int),
        int Function(int, int, int)
      >('lseek');

  /// lstat (or stat with [follow]): times, type, owner and the identity Python
  /// compares as (st_dev, st_ino, st_size, st_mtime_ns, st_ctime_ns).
  ({int sec, int nsec, int mode, int uid, List<int> signature})? lstatFull(
    String path, {
    bool follow = false,
  }) {
    final buffer = calloc<Uint8>(256);
    try {
      var ok = false;
      _path(
        path,
        (name) =>
            ok = _statx(-100, name, follow ? 0 : 0x100, 0x7ff, buffer) == 0,
      );
      if (!ok) return null;
      final b = ByteData.sublistView(buffer.asTypedList(256));
      return (
        sec: b.getInt64(112, Endian.host),
        nsec: b.getUint32(120, Endian.host),
        mode: b.getUint16(28, Endian.host),
        uid: b.getUint32(20, Endian.host),
        signature: [
          b.getUint32(136, Endian.host),
          b.getUint32(140, Endian.host),
          b.getUint64(32, Endian.host),
          b.getUint64(40, Endian.host),
          b.getInt64(112, Endian.host),
          b.getUint32(120, Endian.host),
          b.getInt64(96, Endian.host),
          b.getUint32(104, Endian.host),
        ],
      );
    } finally {
      calloc.free(buffer);
    }
  }

  /// lstat's type, owner, size, link count and identity; null when the path
  /// cannot be examined.
  ({int mode, int uid, int size, int nlink, List<int> identity})? lstatOwn(
    String path,
  ) {
    final buffer = calloc<Uint8>(256);
    try {
      var ok = false;
      _path(path, (name) => ok = _statx(-100, name, 0x100, 0x7ff, buffer) == 0);
      if (!ok) return null;
      final b = ByteData.sublistView(buffer.asTypedList(256));
      return (
        mode: b.getUint16(28, Endian.host),
        uid: b.getUint32(20, Endian.host),
        size: b.getUint64(40, Endian.host),
        nlink: b.getUint32(16, Endian.host),
        identity: [
          b.getUint32(136, Endian.host),
          b.getUint32(140, Endian.host),
          b.getUint64(32, Endian.host),
        ],
      );
    } finally {
      calloc.free(buffer);
    }
  }

  List<int>? signature(String path) => lstatFull(path)?.signature;

  /// os.stat / os.lstat as Python's DirEntry.stat gives them: st_dev (made
  /// the glibc way), st_ino, st_mode, st_uid, st_size, st_blocks; null when
  /// the path cannot be looked at.
  ({int dev, int ino, int mode, int uid, int size, int blocks})? statBlocks(
    String path, {
    bool follow = false,
  }) {
    final buffer = calloc<Uint8>(256);
    try {
      var ok = false;
      _path(
        path,
        (name) =>
            ok = _statx(-100, name, follow ? 0 : 0x100, 0x7ff, buffer) == 0,
      );
      if (!ok) return null;
      final b = ByteData.sublistView(buffer.asTypedList(256));
      final major = b.getUint32(136, Endian.host),
          minor = b.getUint32(140, Endian.host);
      return (
        dev:
            ((major & 0xfffff000) << 32) |
            ((major & 0xfff) << 8) |
            ((minor & 0xffffff00) << 12) |
            (minor & 0xff),
        ino: b.getUint64(32, Endian.host),
        mode: b.getUint16(28, Endian.host),
        uid: b.getUint32(20, Endian.host),
        size: b.getUint64(40, Endian.host),
        blocks: b.getUint64(48, Endian.host),
      );
    } finally {
      calloc.free(buffer);
    }
  }

  /// mkdirat; false when the name exists already (EEXIST), else it throws.
  bool mkdirAt(int dir, String name, int mode) => _path(name, (native) {
    if (_mkdir(dir, native, mode) == 0) return true;
    if (_errno().value == 17) return false;
    _fail();
  });

  /// os.stat(name, dir_fd=dir, follow_symlinks=False) as Python gives it:
  /// st_dev (made the glibc way), st_ino, st_mode, st_uid, st_size,
  /// st_nlink; null when it cannot be looked at. An empty name: dir itself.
  ({
    int dev,
    int ino,
    int mode,
    int uid,
    int size,
    int nlink,
    int atimeNs,
    int mtimeNs,
  })?
  statAt(int dir, String name) {
    final buffer = calloc<Uint8>(256);
    try {
      var ok = false;
      _path(
        name,
        (native) => ok =
            _statx(dir, native, name.isEmpty ? 0x1100 : 0x100, 0x7ff, buffer) ==
            0,
      );
      if (!ok) return null;
      final b = ByteData.sublistView(buffer.asTypedList(256));
      final major = b.getUint32(136, Endian.host),
          minor = b.getUint32(140, Endian.host);
      return (
        dev:
            ((major & 0xfffff000) << 32) |
            ((major & 0xfff) << 8) |
            ((minor & 0xffffff00) << 12) |
            (minor & 0xff),
        ino: b.getUint64(32, Endian.host),
        mode: b.getUint16(28, Endian.host),
        uid: b.getUint32(20, Endian.host),
        size: b.getUint64(40, Endian.host),
        nlink: b.getUint32(16, Endian.host),
        atimeNs:
            b.getInt64(64, Endian.host) * 1000000000 +
            b.getUint32(72, Endian.host),
        mtimeNs:
            b.getInt64(112, Endian.host) * 1000000000 +
            b.getUint32(120, Endian.host),
      );
    } finally {
      calloc.free(buffer);
    }
  }

  /// linkat(fromDir, from, toDir, to, flags); throws on failure.
  void linkAt(
    int fromDir,
    String from,
    int toDir,
    String to, {
    bool follow = false,
  }) => _path(
    from,
    (a) => _path(to, (b) {
      if (_linkat(fromDir, a, toDir, b, follow ? 0x400 : 0) != 0) _fail();
    }),
  );

  /// unlinkat(dir, name, 0); throws on failure.
  void unlinkAt(int dir, String name) => _path(name, (native) {
    if (_unlink(dir, native, 0) != 0) _fail();
  });

  /// futimens: the file's access and modification times, in nanoseconds.
  void setTimes(int fd, int atimeNs, int mtimeNs) {
    final times = calloc<Int64>(4);
    try {
      times[0] = atimeNs ~/ 1000000000;
      times[1] = atimeNs % 1000000000;
      times[2] = mtimeNs ~/ 1000000000;
      times[3] = mtimeNs % 1000000000;
      if (_utimensat(fd, nullptr, times, 0) != 0) _fail();
    } finally {
      calloc.free(times);
    }
  }

  /// os.statvfs: (f_blocks, f_frsize, f_bavail); null when it fails.
  ({int blocks, int frsize, int bavail})? statvfs(String path) {
    final buffer = calloc<Uint8>(128);
    try {
      var ok = false;
      _path(path, (name) => ok = _statvfs(name, buffer) == 0);
      if (!ok) return null;
      final b = ByteData.sublistView(buffer.asTypedList(128));
      return (
        blocks: b.getUint64(16, Endian.host),
        frsize: b.getUint64(8, Endian.host),
        bavail: b.getUint64(32, Endian.host),
      );
    } finally {
      calloc.free(buffer);
    }
  }

  /// Open [path] without following it, check it is this account's own regular
  /// file with the same device and inode as [expected] (when given), then read.
  T? readChecked<T>(
    String path,
    T Function(int fd, int size) read, {
    List<int>? expected,
  }) {
    int? fd;
    try {
      fd = openAt(-100, path, noFollow | nonBlock);
      final opened = lstatFull('/proc/self/fd/$fd', follow: true);
      if (opened == null ||
          opened.mode & 0xf000 != 0x8000 ||
          opened.uid != uid ||
          expected != null &&
              (expected.length < 3 ||
                  opened.signature[0] != expected[0] ||
                  opened.signature[1] != expected[1] ||
                  opened.signature[2] != expected[2])) {
        return null;
      }
      return read(fd, opened.signature[3]);
    } on FileSystemException {
      return null;
    } finally {
      if (fd != null) close(fd);
    }
  }

  /// Up to [length] bytes from [offset] (pread-like, short reads continued).
  Uint8List readAt(int fd, int offset, int length) {
    if (_lseek(fd, offset, 0) < 0) _fail();
    final buffer = calloc<Uint8>(max(1, min(length, 1 << 20)));
    final out = BytesBuilder(copy: false);
    try {
      while (out.length < length) {
        final count = _read(fd, buffer, min(length - out.length, 1 << 20));
        if (count < 0) _fail();
        if (count == 0) break;
        out.add(Uint8List.fromList(buffer.asTypedList(count)));
      }
      return out.takeBytes();
    } finally {
      calloc.free(buffer);
    }
  }

  String stamp(int fd) {
    final buffer = calloc<Uint8>(256);
    try {
      _path('', (name) {
        if (_statx(fd, name, 0x1000, 0x7ff, buffer) != 0) _fail();
      });
      final data = ByteData.sublistView(buffer.asTypedList(256));
      return '${data.getUint64(32, Endian.host)}:${data.getUint64(40, Endian.host)}:${data.getInt64(96, Endian.host)}:${data.getUint32(104, Endian.host)}:${data.getInt64(112, Endian.host)}:${data.getUint32(120, Endian.host)}';
    } finally {
      calloc.free(buffer);
    }
  }

  Uint8List readRegular(String path, int limit, {bool follow = false}) {
    final fd = openAt(-100, path, nonBlock | (follow ? 0 : noFollow));
    try {
      return readDescriptor(fd, limit);
    } finally {
      close(fd);
    }
  }

  Uint8List readSuffix(int fd, int limit) {
    final seek = _lib
        .lookupFunction<
          Int64 Function(Int, Int64, Int),
          int Function(int, int, int)
        >('lseek');
    final info = stat(fd);
    if ((info.mode & 0xf000) != 0x8000 ||
        limit < 0 ||
        limit > 8 * 1024 * 1024) {
      throw const FileSystemException('Invalid suffix read');
    }
    if (seek(fd, max(0, info.size - limit), 0) < 0) _fail();
    return readPrefix(fd, limit);
  }

  Uint8List readPrefix(int fd, int limit) {
    if ((stat(fd).mode & 0xf000) != 0x8000 ||
        limit < 0 ||
        limit > 8 * 1024 * 1024) {
      throw const FileSystemException('Invalid prefix read');
    }
    final buffer = calloc<Uint8>(max(1, limit));
    try {
      final size = _read(fd, buffer, limit);
      if (size < 0) _fail();
      return Uint8List.fromList(buffer.asTypedList(size));
    } finally {
      calloc.free(buffer);
    }
  }

  Uint8List readDescriptor(int fd, int limit) {
    if ((stat(fd).mode & 0xf000) != 0x8000) {
      throw const FileSystemException('Not a regular file');
    }
    if (stat(fd).size > limit) {
      throw const FileSystemException('File exceeds bound');
    }
    final buffer = calloc<Uint8>(min(limit + 1, 65536));
    final bytes = BytesBuilder(copy: false);
    try {
      while (bytes.length <= limit) {
        final count = _read(fd, buffer, min(limit + 1 - bytes.length, 65536));
        if (count < 0) _fail();
        if (count == 0) break;
        bytes.add(Uint8List.fromList(buffer.asTypedList(count)));
      }
      if (bytes.length > limit) {
        throw const FileSystemException('File exceeds bound');
      }
      return bytes.takeBytes();
    } finally {
      calloc.free(buffer);
    }
  }

  void write(int fd, List<int> bytes) {
    final buffer = calloc<Uint8>(max(1, bytes.length));
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      var offset = 0;
      while (offset < bytes.length) {
        final count = _write(fd, buffer + offset, bytes.length - offset);
        if (count <= 0) _fail();
        offset += count;
      }
    } finally {
      calloc.free(buffer);
    }
  }

  void _trustedDirectory(int fd) {
    final info = stat(fd);
    if (![0, uid].contains(info.uid) ||
        (info.mode & 0x12 != 0 && info.mode & 0x200 == 0)) {
      throw const FileSystemException('Unsafe private-write ancestor');
    }
  }

  String _readLink(int fd, String part) {
    final readlink = _lib
        .lookupFunction<
          IntPtr Function(Int, Pointer<Utf8>, Pointer<Uint8>, IntPtr),
          int Function(int, Pointer<Utf8>, Pointer<Uint8>, int)
        >('readlinkat');
    final buffer = calloc<Uint8>(4096);
    try {
      final length = _path(part, (name) => readlink(fd, name, buffer, 4096));
      if (length < 0) _fail();
      if (length == 4096) {
        throw const FileSystemException('Parent symlink too long');
      }
      return utf8.decode(buffer.asTypedList(length));
    } finally {
      calloc.free(buffer);
    }
  }

  /// Descriptor-based realpath: validate every traversed directory, including
  /// directories hidden by intermediate symlinks, and allow a missing suffix.
  /// The returned path is subsequently walked again without following links.
  String resolveParent(String absolute) {
    if (!p.isAbsolute(absolute)) throw ArgumentError('Absolute path required');
    final pending = ListQueue<String>.from(p.split(absolute).skip(1));
    final resolved = <String>[];
    var fd = openAt(-100, '/', directory | noFollow);
    var links = 0;
    try {
      _trustedDirectory(fd);
      while (pending.isNotEmpty) {
        final part = pending.removeFirst();
        if (part.isEmpty || part == '.') continue;
        if (part == '..') {
          final child = openAt(fd, '..', directory | noFollow);
          close(fd);
          fd = child;
          if (resolved.isNotEmpty) resolved.removeLast();
          _trustedDirectory(fd);
          continue;
        }
        int child;
        try {
          child = openAt(fd, part, directory | noFollow);
        } on FileSystemException catch (e) {
          if (e.osError?.errorCode == 2) {
            return p.normalize(p.joinAll(['/', ...resolved, part, ...pending]));
          }
          if (![20, 40].contains(e.osError?.errorCode)) rethrow;
          final target = _readLink(fd, part);
          if (++links > 40) {
            throw const FileSystemException('Too many parent symlinks');
          }
          final absoluteTarget = p.isAbsolute(target);
          if (absoluteTarget) {
            close(fd);
            fd = openAt(-100, '/', directory | noFollow);
            resolved.clear();
            _trustedDirectory(fd);
          }
          final parts = p.split(target);
          for (final component
              in (absoluteTarget ? parts.skip(1) : parts).toList().reversed) {
            pending.addFirst(component);
          }
          continue;
        }
        close(fd);
        fd = child;
        resolved.add(part);
        _trustedDirectory(fd);
      }
      return p.joinAll(['/', ...resolved]);
    } finally {
      close(fd);
    }
  }

  /// Resolve the existing layout once, then pin the trusted, resolved chain.
  /// A symlink inserted into that chain after resolution fails closed.
  int privateDirectory(String absolute) {
    if (!p.isAbsolute(absolute)) throw ArgumentError('Absolute path required');
    final resolved = resolveParent(p.normalize(absolute));
    var fd = openAt(-100, '/', directory | noFollow);
    try {
      _trustedDirectory(fd);
      for (final part in p.split(resolved).skip(1)) {
        try {
          final child = openAt(fd, part, directory | noFollow);
          close(fd);
          fd = child;
        } on FileSystemException catch (e) {
          if (e.osError?.errorCode != 2) rethrow;
          _path(part, (name) {
            if (_mkdir(fd, name, 0x1c0) != 0 && _errno().value != 17) _fail();
          });
          final child = openAt(fd, part, directory | noFollow);
          close(fd);
          fd = child;
        }
        _trustedDirectory(fd);
      }
      return fd;
    } catch (_) {
      close(fd);
      rethrow;
    }
  }

  /// Resolve trusted aliases and pin an existing directory without creating it.
  int existingDirectory(String absolute) {
    final resolved = resolveParent(p.normalize(absolute));
    var fd = openAt(-100, '/', directory | noFollow);
    try {
      _trustedDirectory(fd);
      for (final part in p.split(resolved).skip(1)) {
        final child = openAt(fd, part, directory | noFollow);
        close(fd);
        fd = child;
        _trustedDirectory(fd);
      }
      return fd;
    } catch (_) {
      close(fd);
      rethrow;
    }
  }

  static final _chmodPath = _lib
      .lookupFunction<
        Int Function(Pointer<Utf8>, Uint32),
        int Function(Pointer<Utf8>, int)
      >('chmod');

  /// chmod for a path this process just created (folders and copies in its
  /// own backup folder).
  void chmodPath(String path, int mode) => _path(path, (name) {
    if (_chmodPath(name, mode) != 0) _fail();
  });

  /// Python connect._write for an agent's settings: a fresh exclusive
  /// temporary file in the same folder (opened like the reference, through the
  /// kernel's lookup), its mode set before writing, fsync, then renamed over.
  void replaceFile(String path, List<int> bytes, int mode) {
    final dir = openAt(-100, p.dirname(path), directory);
    final temporary =
        '.${p.basename(path)}-${Random.secure().nextInt(1 << 32)}-${Random.secure().nextInt(1 << 32)}';
    int? fd;
    var created = false, renamed = false;
    try {
      fd = openAt(dir, temporary, 1 | 0x40 | 0x80 | noFollow, mode);
      created = true;
      chmod(fd, mode);
      write(fd, bytes);
      sync(fd);
      close(fd);
      fd = null;
      _path(
        temporary,
        (from) => _path(p.basename(path), (to) {
          if (_rename(dir, from, dir, to) != 0) _fail();
        }),
      );
      renamed = true;
    } finally {
      if (fd != null) close(fd);
      if (created && !renamed) {
        _path(temporary, (name) => _unlink(dir, name, 0));
      }
      close(dir);
    }
  }

  void atomicWrite(String path, List<int> bytes) {
    final dir = privateDirectory(p.dirname(path));
    final temporary =
        '.${p.basename(path)}-${Random.secure().nextInt(1 << 32)}-${Random.secure().nextInt(1 << 32)}';
    int? fd;
    var created = false;
    try {
      fd = openAt(dir, temporary, 1 | 0x40 | 0x80 | noFollow, 0x180);
      created = true;
      chmod(fd, 0x180);
      write(fd, bytes);
      sync(fd);
      close(fd);
      fd = null;
      _path(
        temporary,
        (from) => _path(p.basename(path), (to) {
          if (_rename(dir, from, dir, to) != 0) _fail();
        }),
      );
      sync(dir);
    } finally {
      if (fd != null) close(fd);
      if (created) _path(temporary, (name) => _unlink(dir, name, 0));
      close(dir);
    }
  }

  /// pidfd pins the process identity. Start time and UID are checked after open;
  /// an exited/reused PID cannot make this descriptor target its replacement.
  bool signalOwned(int pid, String expectedStart, int signal) {
    if (pid <= 0 || ![0, 15].contains(signal)) return false;
    late final int Function(int, int) open;
    late final int Function(int, int, Pointer<Void>, int) send;
    try {
      open = _lib
          .lookupFunction<Int Function(Int, Uint32), int Function(int, int)>(
            'pidfd_open',
          );
      send = _lib
          .lookupFunction<
            Int Function(Int, Int, Pointer<Void>, Uint32),
            int Function(int, int, Pointer<Void>, int)
          >('pidfd_send_signal');
    } on ArgumentError {
      throw UnsupportedError(
        'Linux pidfd libc symbols are unavailable; no signal was sent',
      );
    }
    final fd = open(pid, 0);
    if (fd < 0) return false;
    try {
      final proc = openAt(-100, '/proc/$pid', directory | noFollow);
      try {
        if (stat(proc).uid != uid) return false;
      } finally {
        close(proc);
      }
      final status = utf8.decode(readRegular('/proc/$pid/stat', 65536));
      final tail = status.substring(status.lastIndexOf(')') + 2).split(' ');
      if (tail.length < 20 || tail[19] != expectedStart) return false;
      return send(fd, signal, nullptr, 0) == 0;
    } on FileSystemException {
      return false;
    } finally {
      close(fd);
    }
  }

  // --- pidfds held across a stop (provider_watch.stop_lmstudio_service) ----------------

  static final _pidfdOpen = _lib
      .lookupFunction<Int Function(Int, Uint32), int Function(int, int)>(
        'pidfd_open',
      );
  static final _pidfdSend = _lib
      .lookupFunction<
        Int Function(Int, Int, Pointer<Void>, Uint32),
        int Function(int, int, Pointer<Void>, int)
      >('pidfd_send_signal');
  static final _poll = _lib
      .lookupFunction<
        Int Function(Pointer<Int32>, Uint64, Int),
        int Function(Pointer<Int32>, int, int)
      >('poll');

  /// os.pidfd_open: the pidfd pins this process; -1 when it is gone.
  int pidfdOpen(int pid) => pid > 0 ? _pidfdOpen(pid, 0) : -1;

  /// signal.pidfd_send_signal (errors ignored, as the reference does).
  void pidfdSignal(int fd, int signal) => _pidfdSend(fd, signal, nullptr, 0);

  /// A pidfd is readable once its process has exited (select with no wait).
  bool pidfdExited(int fd) {
    final entry = calloc<Int32>(2);
    try {
      entry[0] = fd;
      entry[1] = 1; // POLLIN in events (the low 16 bits); revents above
      final ready = _poll(entry, 1, 0);
      return ready > 0 && (entry[1] >> 16) & 0x39 != 0;
    } finally {
      calloc.free(entry);
    }
  }

  static final _flock = _lib
      .lookupFunction<Int Function(Int, Int), int Function(int, int)>('flock');

  /// fcntl.flock(fd, LOCK_EX): the same lock the reference takes.
  void lockExclusive(int fd) {
    if (_flock(fd, 2) != 0) _fail();
  }

  /// flock(fd, LOCK_EX | LOCK_NB): false when another holds it.
  bool tryLockExclusive(int fd) => _flock(fd, 6) == 0;
}
