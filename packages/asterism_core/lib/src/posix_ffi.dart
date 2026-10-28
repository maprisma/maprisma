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

  Uint8List readRegular(String path, int limit, {bool follow = false}) {
    final fd = openAt(-100, path, nonBlock | (follow ? 0 : noFollow));
    try {
      return readDescriptor(fd, limit);
    } finally {
      close(fd);
    }
  }

  Uint8List readDescriptor(int fd, int limit) {
    if ((stat(fd).mode & 0xf000) != 0x8000) {
      throw const FileSystemException('Not a regular file');
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
}
