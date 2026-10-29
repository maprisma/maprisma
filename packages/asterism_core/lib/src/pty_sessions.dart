import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'core_tasks.dart' show newHandle;

/// terminal_sessions: owned PTY sessions (Linux). Only the service supplies
/// argv from a registered adapter; no shell, no transcript, bounded reads.
///
/// Dart cannot fork, so an agent is started with posix_spawn: a new session
/// (SETSID), signals back to their defaults and none blocked (the Dart VM
/// ignores SIGPIPE), the PTY's slave opened as fd 0 (a session leader opening
/// a terminal takes it as its controlling terminal), fd 1 and 2 copies of
/// it, the project folder as its working folder and every other descriptor
/// closed. Each agent is held by a pidfd: Dart's own process thread may reap
/// a child that is not its own, so the group is never signalled by number
/// (killpg) — the leader and its remembered group members are signalled
/// through pidfds after their start time is checked.

final _libc = DynamicLibrary.open('libc.so.6');
final _openpt = _libc.lookupFunction<Int Function(Int), int Function(int)>(
  'posix_openpt',
);
final _grantpt = _libc.lookupFunction<Int Function(Int), int Function(int)>(
  'grantpt',
);
final _unlockpt = _libc.lookupFunction<Int Function(Int), int Function(int)>(
  'unlockpt',
);
final _ptsname = _libc
    .lookupFunction<
      Int Function(Int, Pointer<Utf8>, Size),
      int Function(int, Pointer<Utf8>, int)
    >('ptsname_r');
final _ioctl = _libc
    .lookupFunction<
      Int Function(Int, UnsignedLong, VarArgs<(Pointer<Void>,)>),
      int Function(int, int, Pointer<Void>)
    >('ioctl');
final _close = _libc.lookupFunction<Int Function(Int), int Function(int)>(
  'close',
);
final _read = _libc
    .lookupFunction<
      IntPtr Function(Int, Pointer<Uint8>, Size),
      int Function(int, Pointer<Uint8>, int)
    >('read');
final _write = _libc
    .lookupFunction<
      IntPtr Function(Int, Pointer<Uint8>, Size),
      int Function(int, Pointer<Uint8>, int)
    >('write');
final _poll = _libc
    .lookupFunction<
      Int Function(Pointer<Int32>, Uint64, Int),
      int Function(Pointer<Int32>, int, int)
    >('poll');
final _errno = _libc
    .lookupFunction<Pointer<Int> Function(), Pointer<Int> Function()>(
      '__errno_location',
    );
final _spawn = _libc
    .lookupFunction<
      Int Function(
        Pointer<Int32>,
        Pointer<Utf8>,
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Pointer<Utf8>>,
        Pointer<Pointer<Utf8>>,
      ),
      int Function(
        Pointer<Int32>,
        Pointer<Utf8>,
        Pointer<Void>,
        Pointer<Void>,
        Pointer<Pointer<Utf8>>,
        Pointer<Pointer<Utf8>>,
      )
    >('posix_spawn');
final _faInit = _libc
    .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'posix_spawn_file_actions_init',
    );
final _faDestroy = _libc
    .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'posix_spawn_file_actions_destroy',
    );
final _faOpen = _libc
    .lookupFunction<
      Int Function(Pointer<Void>, Int, Pointer<Utf8>, Int, Uint32),
      int Function(Pointer<Void>, int, Pointer<Utf8>, int, int)
    >('posix_spawn_file_actions_addopen');
final _faDup2 = _libc
    .lookupFunction<
      Int Function(Pointer<Void>, Int, Int),
      int Function(Pointer<Void>, int, int)
    >('posix_spawn_file_actions_adddup2');
final _faChdir = _libc
    .lookupFunction<
      Int Function(Pointer<Void>, Pointer<Utf8>),
      int Function(Pointer<Void>, Pointer<Utf8>)
    >('posix_spawn_file_actions_addchdir_np');
final _faCloseFrom = _libc
    .lookupFunction<
      Int Function(Pointer<Void>, Int),
      int Function(Pointer<Void>, int)
    >('posix_spawn_file_actions_addclosefrom_np');
final _attrInit = _libc
    .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'posix_spawnattr_init',
    );
final _attrDestroy = _libc
    .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'posix_spawnattr_destroy',
    );
final _attrFlags = _libc
    .lookupFunction<
      Int Function(Pointer<Void>, Short),
      int Function(Pointer<Void>, int)
    >('posix_spawnattr_setflags');
final _attrSigDefault = _libc
    .lookupFunction<
      Int Function(Pointer<Void>, Pointer<Void>),
      int Function(Pointer<Void>, Pointer<Void>)
    >('posix_spawnattr_setsigdefault');
final _attrSigMask = _libc
    .lookupFunction<
      Int Function(Pointer<Void>, Pointer<Void>),
      int Function(Pointer<Void>, Pointer<Void>)
    >('posix_spawnattr_setsigmask');
final _sigFill = _libc
    .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'sigfillset',
    );
final _sigEmpty = _libc
    .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'sigemptyset',
    );
final _pidfdOpen = _libc
    .lookupFunction<Int Function(Int, Uint32), int Function(int, int)>(
      'pidfd_open',
    );
final _pidfdSend = _libc
    .lookupFunction<
      Int Function(Int, Int, Pointer<Void>, Uint32),
      int Function(int, int, Pointer<Void>, int)
    >('pidfd_send_signal');
final _waitid = _libc
    .lookupFunction<
      Int Function(Int, Int32, Pointer<Uint8>, Int),
      int Function(int, int, Pointer<Uint8>, int)
    >('waitid');

const _eagain = 11, _eio = 5;
const _oRdwr = 0x2, _oNoctty = 0x100, _oNonblock = 0x800, _oCloexec = 0x80000;
const _tiocswinsz = 0x5414;
const _spawnSetsigdef = 0x04, _spawnSetsigmask = 0x08, _spawnSetsid = 0x80;
const _pPidfd = 3, _wExited = 4, _wNohang = 1, _wNowait = 0x01000000;
const _sighup = 1, _sigterm = 15, _sigkill = 9;

void _setSize(int fd, int rows, int cols) {
  final size = calloc<Uint16>(4);
  try {
    size[0] = rows;
    size[1] = cols;
    if (_ioctl(fd, _tiocswinsz, size.cast()) != 0) {
      throw const FileSystemException('Terminal size could not be set');
    }
  } finally {
    calloc.free(size);
  }
}

/// A pidfd is readable once its process has exited.
bool _exited(int fd, {int waitMs = 0}) {
  final entry = calloc<Int32>(2);
  try {
    entry[0] = fd;
    entry[1] = 1;
    return _poll(entry, 1, waitMs) > 0 && (entry[1] >> 16) != 0;
  } finally {
    calloc.free(entry);
  }
}

/// (process group, session, start time) of a process, from /proc.
(int, int, String)? processIdentity(int pid) {
  try {
    final text = File('/proc/$pid/stat').readAsStringSync();
    final fields = text
        .substring(text.lastIndexOf(')') + 1)
        .trim()
        .split(RegExp(r'\s+'));
    return (int.parse(fields[2]), int.parse(fields[3]), fields[19]);
  } catch (_) {
    return null;
  }
}

/// _group_members: the processes of this leader's group and session.
Map<int, String> groupMembers(int leader) {
  final found = <int, String>{};
  List<FileSystemEntity> entries;
  try {
    entries = Directory('/proc').listSync();
  } on FileSystemException {
    return found;
  }
  for (final entry in entries) {
    final pid = int.tryParse(entry.path.substring(6));
    if (pid == null || pid == leader) continue;
    final identity = processIdentity(pid);
    if (identity != null && identity.$1 == leader && identity.$2 == leader) {
      found[pid] = identity.$3;
    }
  }
  return found;
}

/// codecs' incremental UTF-8 decoder with 'replace': a sequence cut at the
/// end of a read waits for the next one.
final class _Utf8Stream {
  final _pending = <int>[];
  String decode(List<int> data, {bool last = false}) {
    _pending.addAll(data);
    var end = _pending.length;
    if (!last) {
      // Hold back an incomplete sequence at the end (at most 3 bytes).
      for (var back = 1; back <= math.min(3, _pending.length); back++) {
        final byte = _pending[_pending.length - back];
        if (byte & 0xc0 == 0x80) continue; // a continuation byte
        final need = byte >= 0xf0
            ? 4
            : byte >= 0xe0
            ? 3
            : byte >= 0xc0
            ? 2
            : 1;
        if (need > back) end = _pending.length - back;
        break;
      }
    }
    final text = const Utf8Decoder(
      allowMalformed: true,
    ).convert(_pending.sublist(0, end));
    _pending.removeRange(0, end);
    return text;
  }
}

final class PtySession {
  PtySession(this.pid, this.pidfd, this.master, this.command, this.cwd);
  final int pid, pidfd, master;
  final String command, cwd;
  var decoder = _Utf8Stream();
  bool eof = false, reaped = false;
  int? code;
  DateTime? exitedAt, groupSeen;
  final children = <int, String>{};
}

final class PtySessions {
  final items = <String, PtySession>{};

  /// Start argv in a new PTY (24 rows, 80 columns); its handle.
  String start(
    String command,
    List<String> argv,
    String cwd,
    Map<String, String> env,
  ) {
    if (items.length >= 32) {
      throw const FormatException('Too many terminal sessions');
    }
    final master = _openpt(_oRdwr | _oNoctty | _oNonblock | _oCloexec);
    if (master < 0) throw const FileSystemException('No terminal available');
    final arena = Arena();
    try {
      final name = arena<Uint8>(256).cast<Utf8>();
      if (_grantpt(master) != 0 ||
          _unlockpt(master) != 0 ||
          _ptsname(master, name, 256) != 0) {
        throw const FileSystemException('No terminal available');
      }
      _setSize(master, 24, 80);
      final actions = arena<Uint8>(512).cast<Void>();
      final attr = arena<Uint8>(1024).cast<Void>();
      final all = arena<Uint8>(256).cast<Void>(),
          none = arena<Uint8>(256).cast<Void>();
      _faInit(actions);
      _attrInit(attr);
      try {
        _sigFill(all);
        _sigEmpty(none);
        if (_faOpen(actions, 0, name, _oRdwr, 0) != 0 ||
            _faDup2(actions, 0, 1) != 0 ||
            _faDup2(actions, 0, 2) != 0 ||
            _faChdir(actions, cwd.toNativeUtf8(allocator: arena)) != 0 ||
            _faCloseFrom(actions, 3) != 0 ||
            _attrFlags(
                  attr,
                  _spawnSetsid | _spawnSetsigdef | _spawnSetsigmask,
                ) !=
                0 ||
            _attrSigDefault(attr, all) != 0 ||
            _attrSigMask(attr, none) != 0) {
          throw const FileSystemException('The agent could not be started');
        }
        Pointer<Pointer<Utf8>> strings(List<String> values) {
          final list = arena<Pointer<Utf8>>(values.length + 1);
          for (var i = 0; i < values.length; i++) {
            list[i] = values[i].toNativeUtf8(allocator: arena);
          }
          list[values.length] = nullptr;
          return list;
        }

        final pid = arena<Int32>();
        final error = _spawn(
          pid,
          argv.first.toNativeUtf8(allocator: arena),
          actions,
          attr,
          strings(argv),
          strings([for (final e in env.entries) '${e.key}=${e.value}']),
        );
        if (error != 0) {
          throw FileSystemException(
            'The agent could not be started',
            argv.first,
            OSError('', error),
          );
        }
        final pidfd = _pidfdOpen(pid.value, 0);
        final session = PtySession(pid.value, pidfd, master, command, cwd);
        final ident = newHandle();
        items[ident] = session;
        _rememberGroup(session);
        return ident;
      } finally {
        _faDestroy(actions);
        _attrDestroy(attr);
      }
    } catch (_) {
      _close(master);
      rethrow;
    } finally {
      arena.releaseAll();
    }
  }

  void _rememberGroup(PtySession session) {
    // While the leader has not exited, its group cannot have been reused.
    if (session.pidfd >= 0 && !_exited(session.pidfd)) {
      session.children.addAll(groupMembers(session.pid));
    }
  }

  void _refreshGroup(PtySession session) {
    // A surviving known member anchors the original group through this scan.
    bool known(int pid, String birth) =>
        processIdentity(pid) == (session.pid, session.pid, birth);
    final anchors = {
      for (final e in session.children.entries)
        if (known(e.key, e.value)) e.key: e.value,
    };
    if (anchors.isEmpty) return;
    final found = groupMembers(session.pid);
    if (anchors.entries.any((e) => known(e.key, e.value))) {
      session.children.addAll(found);
    }
  }

  /// The exit code once the leader has ended (a signal as its negative), else
  /// null. While the ended leader is still our unreaped child it anchors its
  /// group, which is remembered first (WNOWAIT), then it is reaped. Reaped by
  /// another waiter already (Dart's own process thread): -1, its code unknown.
  int? poll(PtySession session) {
    if (session.code != null) return session.code;
    if (session.pidfd < 0) return session.code = -1;
    if (!_exited(session.pidfd)) return null;
    final info = calloc<Uint8>(128);
    try {
      int? wait(int flags) {
        info.asTypedList(128).fillRange(0, 128, 0);
        if (_waitid(_pPidfd, session.pidfd, info, flags) != 0) return null;
        final data = ByteData.sublistView(info.asTypedList(128));
        if (data.getInt32(16, Endian.host) == 0) return 0;
        final how = data.getInt32(8, Endian.host);
        final status = data.getInt32(24, Endian.host);
        return how == 1 ? status : -status;
      }

      if (wait(_wExited | _wNohang | _wNowait) == null) {
        return session.code = -1;
      }
      session.children.addAll(groupMembers(session.pid));
      final code = wait(_wExited | _wNohang);
      session.reaped = code != null;
      return session.code = code ?? -1;
    } finally {
      calloc.free(info);
    }
  }

  Map<String, dynamic> read(String ident) {
    final session = items[ident]!;
    var data = <int>[];
    if (!session.eof) {
      final buffer = calloc<Uint8>(64 * 1024);
      try {
        final count = _read(session.master, buffer, 64 * 1024);
        if (count > 0) {
          data = Uint8List.fromList(buffer.asTypedList(count));
        } else if (count == 0) {
          session.eof = true;
        } else {
          final errno = _errno().value;
          if (errno == _eio) {
            session.eof = true;
          } else if (errno != _eagain) {
            throw FileSystemException(
              'Terminal read failed',
              '',
              OSError('', errno),
            );
          }
        }
      } finally {
        calloc.free(buffer);
      }
    }
    // Dart's own process thread may reap the leader before we do, and then
    // its group cannot be scanned safely any more: while the leader runs,
    // its group is remembered (at most once a second).
    final now = DateTime.now();
    if (session.code == null &&
        (session.groupSeen == null ||
            now.difference(session.groupSeen!).inMilliseconds >= 1000)) {
      session.groupSeen = now;
      _rememberGroup(session);
    }
    final text = session.decoder.decode(data, last: session.eof);
    if (session.eof) session.decoder = _Utf8Stream();
    final code = poll(session);
    if (code != null) session.exitedAt ??= DateTime.now();
    final drained =
        session.eof ||
        session.exitedAt != null &&
            DateTime.now().difference(session.exitedAt!).inMilliseconds >= 1000;
    return {'text': text, 'exit_code': code, 'ended': drained && code != null};
  }

  Map<String, dynamic> write(String ident, List<int> data) {
    final session = items[ident]!;
    if (poll(session) != null) return {'accepted': 0, 'ended': true};
    if (data.length > 16 * 1024) {
      throw const FormatException('Terminal input unavailable');
    }
    final entry = calloc<Int32>(2);
    try {
      entry[0] = session.master;
      entry[1] = 4; // POLLOUT
      if (_poll(entry, 1, 100) <= 0 || (entry[1] >> 16) & 4 == 0) {
        return {'accepted': 0};
      }
    } finally {
      calloc.free(entry);
    }
    final buffer = calloc<Uint8>(math.max(1, data.length));
    try {
      buffer.asTypedList(data.length).setAll(0, data);
      final count = _write(session.master, buffer, data.length);
      return {'accepted': count < 0 ? 0 : count};
    } finally {
      calloc.free(buffer);
    }
  }

  Map<String, dynamic> resize(String ident, dynamic cols, dynamic rows) {
    if (cols is! int ||
        rows is! int ||
        cols < 2 ||
        cols > 1000 ||
        rows < 2 ||
        rows > 1000) {
      throw const FormatException('Invalid terminal dimensions');
    }
    _setSize(items[ident]!.master, rows, cols);
    return {};
  }

  /// Signal the leader (by its pidfd) and the group members still known by
  /// their start time (each by a pidfd opened and checked first).
  void _signalGroup(PtySession session, int signal) {
    if (session.pidfd >= 0) _pidfdSend(session.pidfd, signal, nullptr, 0);
    for (final e in groupMembers(session.pid).entries) {
      final fd = _pidfdOpen(e.key, 0);
      if (fd < 0) continue;
      if (processIdentity(e.key) == (session.pid, session.pid, e.value)) {
        _pidfdSend(fd, signal, nullptr, 0);
      }
      _close(fd);
    }
  }

  void _stopChildren(PtySession session) {
    final handles = <int>[];
    try {
      for (final e in session.children.entries) {
        final fd = _pidfdOpen(e.key, 0);
        if (fd < 0) continue;
        if (processIdentity(e.key) == (session.pid, session.pid, e.value)) {
          handles.add(fd);
        } else {
          _close(fd);
        }
      }
      for (final signal in [_sighup, _sigterm, _sigkill]) {
        for (final fd in handles) {
          _pidfdSend(fd, signal, nullptr, 0);
        }
        final until = DateTime.now().add(const Duration(milliseconds: 200));
        final ready = <int>{};
        for (final fd in handles) {
          final left = until.difference(DateTime.now()).inMilliseconds;
          if (_exited(fd, waitMs: math.max(0, left))) ready.add(fd);
        }
        for (final fd in ready) {
          _close(fd);
        }
        handles.removeWhere(ready.contains);
        if (handles.isEmpty) break;
      }
    } finally {
      for (final fd in handles) {
        _close(fd);
      }
    }
  }

  Map<String, dynamic> stop(String ident) {
    final session = items.remove(ident)!;
    try {
      // A completed tab may stay open for hours: its group is only reached
      // through members still known by their start time.
      if (poll(session) != null) {
        _refreshGroup(session);
        return {};
      }
      _rememberGroup(session);
      for (final signal in [_sighup, _sigterm, _sigkill]) {
        _signalGroup(session, signal);
        if (_exited(session.pidfd, waitMs: 300)) break;
      }
      _exited(session.pidfd, waitMs: 1000);
      poll(session);
    } finally {
      try {
        _stopChildren(session);
      } finally {
        _close(session.master);
        if (session.pidfd >= 0) _close(session.pidfd);
      }
    }
    return {};
  }

  /// Whether the session's agent still runs.
  bool running(PtySession session) => poll(session) == null;

  void close() {
    for (final ident in items.keys.toList()) {
      try {
        stop(ident);
      } catch (_) {
        // the next one
      }
    }
  }
}
