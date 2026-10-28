import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'posix_ffi.dart';
import 'scan_files.dart';

const maxDatabaseBytes = 512 * 1024 * 1024;

/// Read committed WAL pages into a bounded memory image. No SQLite connection
/// opens the agent's path or its -shm, so queries cannot create sidecar files.
/// Format/checksum: https://sqlite.org/fileformat2.html#walformat
Uint8List committedImage(Uint8List base, Uint8List? wal) {
  if (base.length < 100 ||
      ascii.decode(base.sublist(0, 16), allowInvalid: true) !=
          'SQLite format 3\x00') {
    throw const FormatException('Invalid database');
  }
  final header = ByteData.sublistView(base);
  final page = header.getUint16(16) == 1 ? 65536 : header.getUint16(16);
  if (page < 512 ||
      page > 65536 ||
      page & (page - 1) != 0 ||
      base.length % page != 0) {
    throw const FormatException('Invalid page size');
  }
  Uint8List image = base;
  if (wal != null && wal.isNotEmpty) {
    if (wal.length < 32) throw const FormatException('Invalid WAL');
    final data = ByteData.sublistView(wal);
    final magic = data.getUint32(0);
    if (![0x377f0682, 0x377f0683].contains(magic) ||
        data.getUint32(4) != 3007000 ||
        data.getUint32(8) != page) {
      throw const FormatException('Invalid WAL header');
    }
    final endian = magic == 0x377f0682 ? Endian.little : Endian.big;
    var s0 = 0, s1 = 0;
    void checksum(int start, int count) {
      for (var i = start; i < start + count; i += 8) {
        s0 = (s0 + data.getUint32(i, endian) + s1) & 0xffffffff;
        s1 = (s1 + data.getUint32(i + 4, endian) + s0) & 0xffffffff;
      }
    }

    checksum(0, 24);
    if (s0 != data.getUint32(24) || s1 != data.getUint32(28)) {
      throw const FormatException('Invalid WAL checksum');
    }
    final frames = <int>[];
    var lastCommit = 0, committedPages = 0;
    for (var at = 32; at + 24 + page <= wal.length; at += 24 + page) {
      if (data.getUint32(at + 8) != data.getUint32(16) ||
          data.getUint32(at + 12) != data.getUint32(20)) {
        break;
      }
      if (data.getUint32(at) == 0) break;
      checksum(at, 8);
      checksum(at + 24, page);
      if (s0 != data.getUint32(at + 16) || s1 != data.getUint32(at + 20)) break;
      frames.add(at);
      final pages = data.getUint32(at + 4);
      if (pages != 0) {
        if (pages > maxDatabaseBytes ~/ page) {
          throw const FormatException('WAL exceeds bound');
        }
        lastCommit = frames.length;
        committedPages = pages;
      }
    }
    if (lastCommit > 0) {
      image = Uint8List(committedPages * page);
      image.setRange(0, base.length.clamp(0, image.length), base);
      for (final at in frames.take(lastCommit)) {
        final number = data.getUint32(at);
        if (number <= committedPages) {
          image.setRange((number - 1) * page, number * page, wal, at + 24);
        }
      }
    }
  }
  // sqlite3_deserialize expects rollback-format header bytes in its memory image.
  // https://sqlite.org/c3ref/deserialize.html
  image[18] = 1;
  image[19] = 1;
  return image;
}

final class SqliteNumbers {
  SqliteNumbers(this.files);
  final ScanFiles files;
  static final _lib = DynamicLibrary.open('libsqlite3.so.0');
  static final _open = _lib
      .lookupFunction<
        Int Function(Pointer<Utf8>, Pointer<Pointer<Void>>, Int, Pointer<Utf8>),
        int Function(Pointer<Utf8>, Pointer<Pointer<Void>>, int, Pointer<Utf8>)
      >('sqlite3_open_v2');
  static final _close = _lib
      .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'sqlite3_close',
      );
  static final _deserialize = _lib
      .lookupFunction<
        Int Function(
          Pointer<Void>,
          Pointer<Utf8>,
          Pointer<Uint8>,
          Int64,
          Int64,
          Uint32,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Utf8>,
          Pointer<Uint8>,
          int,
          int,
          int,
        )
      >('sqlite3_deserialize');
  static final _exec = _lib
      .lookupFunction<
        Int Function(
          Pointer<Void>,
          Pointer<Utf8>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Pointer<Utf8>>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Utf8>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Pointer<Utf8>>,
        )
      >('sqlite3_exec');
  static final _prepare = _lib
      .lookupFunction<
        Int Function(
          Pointer<Void>,
          Pointer<Utf8>,
          Int,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Utf8>>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Utf8>,
          int,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Utf8>>,
        )
      >('sqlite3_prepare_v2');
  static final _step = _lib
      .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'sqlite3_step',
      );
  static final _finalize = _lib
      .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'sqlite3_finalize',
      );
  static final _columns = _lib
      .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'sqlite3_column_count',
      );
  static final _type = _lib
      .lookupFunction<
        Int Function(Pointer<Void>, Int),
        int Function(Pointer<Void>, int)
      >('sqlite3_column_type');
  static final _integer = _lib
      .lookupFunction<
        Int64 Function(Pointer<Void>, Int),
        int Function(Pointer<Void>, int)
      >('sqlite3_column_int64');
  static final _double = _lib
      .lookupFunction<
        Double Function(Pointer<Void>, Int),
        double Function(Pointer<Void>, int)
      >('sqlite3_column_double');
  static final _text = _lib
      .lookupFunction<
        Pointer<Uint8> Function(Pointer<Void>, Int),
        Pointer<Uint8> Function(Pointer<Void>, int)
      >('sqlite3_column_text');
  static final _blob = _lib
      .lookupFunction<
        Pointer<Uint8> Function(Pointer<Void>, Int),
        Pointer<Uint8> Function(Pointer<Void>, int)
      >('sqlite3_column_blob');
  static final _length = _lib
      .lookupFunction<
        Int Function(Pointer<Void>, Int),
        int Function(Pointer<Void>, int)
      >('sqlite3_column_bytes');
  static final _limit = _lib
      .lookupFunction<
        Int Function(Pointer<Void>, Int, Int),
        int Function(Pointer<Void>, int, int)
      >('sqlite3_limit');
  static final _readonly = _lib
      .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'sqlite3_stmt_readonly',
      );
  static final _progress = _lib
      .lookupFunction<
        Void Function(
          Pointer<Void>,
          Int,
          Pointer<NativeFunction<Int Function(Pointer<Void>)>>,
          Pointer<Void>,
        ),
        void Function(
          Pointer<Void>,
          int,
          Pointer<NativeFunction<Int Function(Pointer<Void>)>>,
          Pointer<Void>,
        )
      >('sqlite3_progress_handler');

  Uint8List? snapshot(String path) {
    path = files.expand(path);
    if (files.credential(path)) return null;
    final io = files.posix;
    int? parent, fd, walFd;
    try {
      parent = io.existingDirectory(p.dirname(path));
      fd = io.openAt(parent, p.basename(path), Posix.noFollow | Posix.nonBlock);
      if (io.stat(fd).uid != io.uid) return null;
      try {
        walFd = io.openAt(
          parent,
          '${p.basename(path)}-wal',
          Posix.noFollow | Posix.nonBlock,
        );
      } on FileSystemException catch (e) {
        if (e.osError?.errorCode != 2) rethrow;
      }
      if (walFd != null && io.stat(walFd).uid != io.uid) return null;
      int? journal;
      try {
        journal = io.openAt(
          parent,
          '${p.basename(path)}-journal',
          Posix.noFollow | Posix.nonBlock,
        );
        if (io.stat(journal).uid != io.uid) return null;
        final header = io.readPrefix(journal, 8);
        if (header.length == 8 &&
            header.join(',') == '217,213,5,249,32,161,99,215') {
          return null;
        }
      } on FileSystemException catch (e) {
        if (e.osError?.errorCode != 2) rethrow;
      } finally {
        if (journal != null) io.close(journal);
      }
      final baseStamp = io.stamp(fd),
          walStamp = walFd == null ? null : io.stamp(walFd);
      final base = io.readDescriptor(fd, maxDatabaseBytes);
      final wal = walFd == null
          ? null
          : io.readDescriptor(walFd, maxDatabaseBytes);
      if (io.stamp(fd) != baseStamp ||
          walFd != null && io.stamp(walFd) != walStamp) {
        return null;
      }
      return committedImage(base, wal);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } finally {
      if (walFd != null) io.close(walFd);
      if (fd != null) io.close(fd);
      if (parent != null) io.close(parent);
    }
  }

  /// Called only with built-in SELECTs naming numeric/identity columns. No SQL
  /// comes from UI input. The resulting database is readonly and memory-only.
  List<List<dynamic>> select(
    String path,
    String sql, {
    int maxRows = 20000,
    int maxText = 2048,
    bool blobs = false,
  }) {
    final image = snapshot(path);
    if (image == null) return [];
    final connection = calloc<Pointer<Void>>(),
        statement = calloc<Pointer<Void>>();
    final memory = calloc<Uint8>(image.length + 20);
    final filename = ':memory:'.toNativeUtf8(), query = sql.toNativeUtf8();
    NativeCallable<Int Function(Pointer<Void>)>? progress;
    try {
      memory.asTypedList(image.length).setAll(0, image);
      if (_open(filename, connection, 6, nullptr) != 0) return [];
      if (_deserialize(
            connection.value,
            nullptr,
            memory,
            image.length,
            image.length,
            4,
          ) !=
          0) {
        return [];
      }
      final pragmas =
          'PRAGMA temp_store=MEMORY; PRAGMA query_only=ON; PRAGMA trusted_schema=OFF;'
              .toNativeUtf8();
      try {
        if (_exec(connection.value, pragmas, nullptr, nullptr, nullptr) != 0) {
          return [];
        }
      } finally {
        calloc.free(pragmas);
      }
      _limit(connection.value, 0, 1024 * 1024); // maximum cell/string length
      _limit(connection.value, 1, 32768); // SQL bytes
      _limit(connection.value, 2, 128); // columns
      final deadline = Stopwatch()..start();
      progress = NativeCallable<Int Function(Pointer<Void>)>.isolateLocal(
        (Pointer<Void> _) => deadline.elapsedMilliseconds > 2000 ? 1 : 0,
        exceptionalReturn: 1,
      );
      _progress(connection.value, 1000, progress.nativeFunction, nullptr);
      if (_prepare(connection.value, query, -1, statement, nullptr) != 0 ||
          statement.value == nullptr ||
          _readonly(statement.value) == 0) {
        return [];
      }
      final rows = <List<dynamic>>[];
      var result = 101;
      while (rows.length < maxRows &&
          (result = _step(statement.value)) == 100) {
        rows.add([
          for (var c = 0; c < _columns(statement.value); c++)
            switch (_type(statement.value, c)) {
              1 => _integer(statement.value, c),
              2 => _double(statement.value, c),
              3 =>
                _length(statement.value, c) > maxText
                    ? ''
                    : utf8.decode(
                        _text(
                          statement.value,
                          c,
                        ).asTypedList(_length(statement.value, c)),
                        allowMalformed: true,
                      ),
              4 =>
                blobs && _length(statement.value, c) <= 1024 * 1024
                    ? Uint8List.fromList(
                        _blob(
                          statement.value,
                          c,
                        ).asTypedList(_length(statement.value, c)),
                      )
                    : null,
              _ => null,
            },
        ]);
      }
      return result == 101 || rows.length == maxRows ? rows : [];
    } finally {
      if (statement.value != nullptr) _finalize(statement.value);
      if (connection.value != nullptr) _close(connection.value);
      progress?.close();
      calloc.free(memory);
      calloc.free(filename);
      calloc.free(query);
      calloc.free(statement);
      calloc.free(connection);
    }
  }
}
