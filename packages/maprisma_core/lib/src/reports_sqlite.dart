import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'protocol.dart';

final class ReportsSqlite {
  ReportsSqlite(String path, {bool readOnly = false, bool immutable = false}) {
    final Pointer<Pointer<Void>> result = calloc();
    final name = (immutable ? '${Uri.file(path)}?immutable=1' : path)
        .toNativeUtf8();
    try {
      // READWRITE | CREATE | NOFOLLOW
      final code = _open(
        name,
        result,
        immutable
            ? 0x01000041
            : readOnly
            ? 0x01000001
            : 0x01000006,
        nullptr,
      );
      _db = result.value;
      check(code);
      check(_timeout(_db, 5000));
    } catch (_) {
      close();
      rethrow;
    } finally {
      calloc.free(result);
      calloc.free(name);
    }
  }

  factory ReportsSqlite.snapshot(Uint8List image) {
    final db = ReportsSqlite(':memory:');
    final data = calloc<Uint8>(image.length);
    try {
      data.asTypedList(image.length).setAll(0, image);
      db.check(
        _deserialize(db._db, nullptr, data, image.length, image.length, 4),
      );
      db._image = data;
      return db;
    } catch (_) {
      db.close();
      calloc.free(data);
      rethrow;
    }
  }

  Pointer<Void> _db = nullptr;
  Pointer<Uint8> _image = nullptr;
  static final _lib = DynamicLibrary.open('libsqlite3.so.0');
  static final _transient = Pointer<Void>.fromAddress(-1);

  void close() {
    if (_db != nullptr) _close(_db);
    _db = nullptr;
    if (_image != nullptr) calloc.free(_image);
    _image = nullptr;
  }

  void check(int result) {
    if (result == 0) return;
    final extended = _db == nullptr ? 0 : _error(_db);
    final code = (extended == 0 ? result : extended) & 255;
    throw ServiceError(switch (code) {
      5 || 6 => 'reports_db_locked',
      8 => 'reports_db_read_only',
      11 || 26 => 'reports_db_corrupt',
      _ => 'reports_db_unavailable',
    }, _db == nullptr ? null : _errmsg(_db).toDartString());
  }

  int get insertedId => _lastId(_db);
  int get changes => _changes(_db);

  void exec(String sql) {
    final query = sql.toNativeUtf8();
    try {
      check(_exec(_db, query, nullptr, nullptr, nullptr));
    } finally {
      calloc.free(query);
    }
  }

  T transaction<T>(T Function() action) {
    exec('BEGIN IMMEDIATE');
    try {
      final value = action();
      exec('COMMIT');
      return value;
    } catch (_) {
      try {
        exec('ROLLBACK');
      } catch (_) {
        // Preserve the failure that ended the transaction.
      }
      rethrow;
    }
  }

  List<List<Object?>> query(String sql, [List<Object?> arguments = const []]) {
    final Pointer<Pointer<Void>> result = calloc();
    final source = sql.toNativeUtf8();
    try {
      check(_prepare(_db, source, -1, result, nullptr));
      final statement = result.value;
      for (final (offset, value) in arguments.indexed) {
        final index = offset + 1;
        if (value == null) {
          check(_bindNull(statement, index));
        } else if (value is int) {
          check(_bindInt(statement, index, value));
        } else {
          final text = (value as String).toNativeUtf8();
          try {
            check(_bindText(statement, index, text, text.length, _transient));
          } finally {
            calloc.free(text);
          }
        }
      }
      final rows = <List<Object?>>[];
      while (true) {
        final code = _step(statement);
        if (code == 101) return rows;
        if (code != 100) check(code);
        rows.add([
          for (var i = 0; i < _count(statement); i++)
            switch (_type(statement, i)) {
              1 => _int(statement, i),
              3 => utf8.decode(
                _text(statement, i).asTypedList(_bytes(statement, i)),
                allowMalformed: true,
              ),
              _ => null,
            },
        ]);
      }
    } finally {
      if (result.value != nullptr) _finalize(result.value);
      calloc.free(result);
      calloc.free(source);
    }
  }

  static final _errmsg = _lib
      .lookupFunction<
        Pointer<Utf8> Function(Pointer<Void>),
        Pointer<Utf8> Function(Pointer<Void>)
      >('sqlite3_errmsg');
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
  static final _open = _lib
      .lookupFunction<
        Int Function(Pointer<Utf8>, Pointer<Pointer<Void>>, Int, Pointer<Utf8>),
        int Function(Pointer<Utf8>, Pointer<Pointer<Void>>, int, Pointer<Utf8>)
      >('sqlite3_open_v2');
  static final _close = _lib
      .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'sqlite3_close_v2',
      );
  static final _timeout = _lib
      .lookupFunction<
        Int Function(Pointer<Void>, Int),
        int Function(Pointer<Void>, int)
      >('sqlite3_busy_timeout');
  static final _error = _lib
      .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'sqlite3_extended_errcode',
      );
  static final _lastId = _lib
      .lookupFunction<
        Int64 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('sqlite3_last_insert_rowid');
  static final _changes = _lib
      .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'sqlite3_changes',
      );
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
  static final _bindNull = _lib
      .lookupFunction<
        Int Function(Pointer<Void>, Int),
        int Function(Pointer<Void>, int)
      >('sqlite3_bind_null');
  static final _bindInt = _lib
      .lookupFunction<
        Int Function(Pointer<Void>, Int, Int64),
        int Function(Pointer<Void>, int, int)
      >('sqlite3_bind_int64');
  static final _bindText = _lib
      .lookupFunction<
        Int Function(Pointer<Void>, Int, Pointer<Utf8>, Int, Pointer<Void>),
        int Function(Pointer<Void>, int, Pointer<Utf8>, int, Pointer<Void>)
      >('sqlite3_bind_text');
  static final _step = _lib
      .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'sqlite3_step',
      );
  static final _count = _lib
      .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'sqlite3_column_count',
      );
  static final _type = _lib
      .lookupFunction<
        Int Function(Pointer<Void>, Int),
        int Function(Pointer<Void>, int)
      >('sqlite3_column_type');
  static final _int = _lib
      .lookupFunction<
        Int64 Function(Pointer<Void>, Int),
        int Function(Pointer<Void>, int)
      >('sqlite3_column_int64');
  static final _text = _lib
      .lookupFunction<
        Pointer<Uint8> Function(Pointer<Void>, Int),
        Pointer<Uint8> Function(Pointer<Void>, int)
      >('sqlite3_column_text');
  static final _bytes = _lib
      .lookupFunction<
        Int Function(Pointer<Void>, Int),
        int Function(Pointer<Void>, int)
      >('sqlite3_column_bytes');
  static final _finalize = _lib
      .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'sqlite3_finalize',
      );
}
