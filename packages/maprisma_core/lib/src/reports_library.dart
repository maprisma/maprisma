import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'posix_ffi.dart';
import 'protocol.dart';
import 'reports_sqlite.dart';
import 'sqlite_numbers.dart' show committedImage, maxDatabaseBytes;

typedef ReportData = Map<String, dynamic>;

const _fields = [
  'title',
  'note',
  'saved_at',
  'from_day',
  'through_day',
  'filters',
  'helper',
  'generated_at',
  'entry_count',
  'total_entries',
  'capped',
  'topics',
  'text',
];
const _columns =
    'title,note,saved_at,from_day,through_day,filters_json,helper,'
    'generated_at,entry_count,total_entries,capped,topics_json,text';

String reportField(
  Object? value,
  int limit, {
  bool required = false,
  bool multiline = false,
}) {
  if (value is! String || value.runes.length > limit) {
    throw const FormatException('Invalid report text');
  }
  final clean = value
      .replaceAll('\r\n', '\n')
      .replaceAll(
        RegExp(
          multiline
              ? r'[\x00-\x09\x0b-\x1f\x7f-\x9f]'
              : r'[\x00-\x1f\x7f-\x9f]',
        ),
        ' ',
      )
      .trim();
  if (required && clean.isEmpty) throw const FormatException('Missing title');
  return clean;
}

final class ReportsLibrary {
  ReportsLibrary(String dataDirectory)
    : directory = p.join(dataDirectory, 'reports');

  final String directory;
  final _io = Posix();
  static const _files = [
    'reports.db',
    'reports.db-wal',
    'reports.db-shm',
    'reports.db-journal',
  ];

  T _locked<T>(T Function(int) action) {
    int? dir;
    try {
      if (FileSystemEntity.isLinkSync(directory)) {
        throw ServiceError('reports_db_unavailable');
      }
      dir = _io.privateDirectory(directory);
      final info = _io.stat(dir);
      if (info.uid != _io.uid) throw ServiceError('reports_db_unavailable');
      _io.chmod(dir, 0x1c0);
      final timer = Stopwatch()..start();
      while (!_io.tryFlock(dir, shared: false)) {
        if (timer.elapsedMilliseconds >= 5000) {
          throw ServiceError('reports_db_locked');
        }
        sleep(const Duration(milliseconds: 25));
      }
      return action(dir);
    } on FileSystemException {
      throw ServiceError('reports_db_unavailable');
    } on ArgumentError {
      throw ServiceError('reports_db_unavailable');
    } finally {
      if (dir != null) _io.close(dir);
    }
  }

  int? _privateFile(int dir, String name, {required bool create}) {
    int fd;
    try {
      fd = _io.openAt(
        dir,
        name,
        2 | Posix.noFollow | Posix.nonBlock | (create ? 0x40 : 0),
        0x180,
      );
    } on FileSystemException catch (e) {
      if (!create && e.osError?.errorCode == 2) return null;
      rethrow;
    }
    try {
      final info = _io.stat(fd);
      if (info.uid != _io.uid || info.mode & 0xf000 != 0x8000) {
        throw ServiceError('reports_db_unavailable');
      }
      _io.chmod(fd, 0x180);
      return fd;
    } catch (_) {
      _io.close(fd);
      rethrow;
    }
  }

  bool _exists(int dir, String name) {
    final info = _io.statAt(dir, name);
    if (info == null) return false;
    if (info.uid != _io.uid ||
        info.mode & 0xf000 != 0x8000 ||
        info.nlink != 1) {
      throw ServiceError('reports_db_unavailable');
    }
    return true;
  }

  ReportsSqlite _probeWithoutShm(int dir) {
    final main = _io.openAt(dir, _files.first, Posix.noFollow);
    int? wal;
    try {
      wal = _io.openAt(dir, _files[1], Posix.noFollow);
      return ReportsSqlite.snapshot(
        committedImage(
          _io.readDescriptor(main, maxDatabaseBytes),
          _io.readDescriptor(wal, maxDatabaseBytes),
        ),
      );
    } on FormatException {
      throw ServiceError('reports_db_corrupt');
    } finally {
      if (wal != null) _io.close(wal);
      _io.close(main);
    }
  }

  String _path(int dir) => p.join(
    Directory('/proc/self/fd/$dir').resolveSymbolicLinksSync(),
    _files.first,
  );

  (bool, bool, bool, bool) _existingFiles(int dir) => (
    _exists(dir, _files[0]),
    _exists(dir, _files[1]),
    _exists(dir, _files[2]),
    _exists(dir, _files[3]),
  );

  int _schema(ReportsSqlite db) =>
      db.query('PRAGMA user_version').single.single as int;

  ReportsSqlite _probe(int dir, bool wal) {
    final path = _path(dir);
    final main = ReportsSqlite(path, immutable: true);
    try {
      // Check the main database first, before SQLite touches an existing SHM.
      _schema(main);
      if (!wal) return main;
    } catch (_) {
      main.close();
      rethrow;
    }
    main.close();
    return _probeWithoutShm(dir);
  }

  T _open<T>(int dir, bool write, T Function(ReportsSqlite, int) action) {
    final (exists, wal, shm, journal) = _existingFiles(dir);
    if (!exists) {
      if (wal || shm || journal) throw ServiceError('reports_db_unavailable');
      final fd = _privateFile(dir, _files.first, create: true);
      if (fd != null) _io.close(fd);
    } else {
      // Inspect the schema without creating a missing WAL or SHM.
      final probe = _probe(dir, wal);
      try {
        final version = _schema(probe);
        if (version > 1) {
          if (write) throw ServiceError('reports_db_read_only');
          probe.exec('PRAGMA query_only=ON');
          probe.exec('PRAGMA trusted_schema=OFF');
          return action(probe, version);
        }
      } finally {
        probe.close();
      }
    }
    final path = _path(dir);
    final db = ReportsSqlite(path);
    try {
      final version = _schema(db);
      db.exec('PRAGMA trusted_schema=OFF');
      if (version > 1) {
        if (write) throw ServiceError('reports_db_read_only');
        db.exec('PRAGMA query_only=ON');
      } else {
        db.query('PRAGMA journal_mode=WAL');
        db.exec('PRAGMA synchronous=NORMAL');
        if (version == 0) {
          db.transaction(() {
            db.exec('''
CREATE TABLE IF NOT EXISTS reports (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL, note TEXT, saved_at TEXT NOT NULL,
  from_day TEXT NOT NULL, through_day TEXT NOT NULL, filters_json TEXT NOT NULL,
  helper TEXT NOT NULL, generated_at TEXT NOT NULL, entry_count INTEGER NOT NULL,
  total_entries INTEGER NOT NULL, capped INTEGER NOT NULL, topic_names TEXT NOT NULL,
  topics_json TEXT NOT NULL, text TEXT NOT NULL
);
PRAGMA user_version=1;
''');
          });
        }
        for (final name in _files) {
          final fd = _privateFile(dir, name, create: false);
          if (fd != null) _io.close(fd);
        }
      }
      return action(db, version == 0 ? 1 : version);
    } finally {
      db.close();
    }
  }

  T _use<T>(bool write, T Function(ReportsSqlite, int) action) =>
      _locked((dir) => _open(dir, write, action));

  ReportData list(String query, int? cursor) => _use(false, (db, version) {
    final needle =
        "%${query.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%";
    final rows = db.query(
      r"""
SELECT id,title,saved_at,from_day,through_day,json_array_length(topics_json)
FROM reports WHERE (? IS NULL OR id < ?)
AND (title LIKE ? ESCAPE '\' OR note LIKE ? ESCAPE '\'
OR topic_names LIKE ? ESCAPE '\' OR text LIKE ? ESCAPE '\')
ORDER BY id DESC LIMIT 51
""",
      [cursor, cursor, needle, needle, needle, needle],
    );
    return {
      'reports': [
        for (final row in rows.take(50))
          {
            'id': row[0],
            'title': row[1],
            'saved_at': row[2],
            'from_day': row[3],
            'through_day': row[4],
            'topic_count': row[5],
          },
      ],
      'next_cursor': rows.length > 50 ? rows[49][0] : null,
      'read_only': version > 1,
      'schema_version': version,
    };
  });

  ReportData _get(ReportsSqlite db, int id) {
    final rows = db.query('SELECT $_columns FROM reports WHERE id=?', [id]);
    if (rows.isEmpty) throw ServiceError('report_not_found');
    final row = rows.single;
    return {
      'id': id,
      for (final (i, field) in _fields.indexed)
        field: switch (field) {
          'filters' || 'topics' => jsonDecode(row[i] as String),
          'capped' => row[i] == 1,
          _ => row[i],
        },
    };
  }

  ReportData get(int id) => _use(false, (db, _) => _get(db, id));

  ReportData save(ReportData draft, String title, String? note) => _use(
    true,
    (db, _) => db.transaction(() {
      final fields = {
        ...draft,
        'title': title,
        'note': note,
        'saved_at': DateTime.now().toUtc().toIso8601String(),
      };
      db.query(
        'INSERT INTO reports ($_columns,topic_names) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        [
          for (final field in _fields)
            switch (field) {
              'filters' || 'topics' => jsonEncode(fields[field]),
              'capped' => fields[field] == true ? 1 : 0,
              _ => fields[field],
            },
          (draft['topics'] as List).map((t) => t['name']).join('\n'),
        ],
      );
      return _get(db, db.insertedId);
    }),
  );

  ReportData update(int id, {String? title, String? note}) => _use(
    true,
    (db, _) => db.transaction(() {
      db.query(
        'UPDATE reports SET title=coalesce(?,title), '
        'note=CASE WHEN ? IS NULL THEN note ELSE nullif(?,\'\') END WHERE id=?',
        [title, note, note, id],
      );
      return _get(db, id);
    }),
  );

  bool delete(int id) => _use(
    true,
    (db, _) => db.transaction(() {
      db.query('DELETE FROM reports WHERE id=?', [id]);
      if (db.changes == 0) throw ServiceError('report_not_found');
      return true;
    }),
  );

  String moveAside() => _locked((dir) {
    final (exists, wal, shm, _) = _existingFiles(dir);
    if (!exists) throw ServiceError('reports_db_unavailable');
    try {
      final probe = _probe(dir, wal);
      try {
        _schema(probe);
        if (probe.query('PRAGMA integrity_check(1)').single.single != 'ok') {
          throw ServiceError('reports_db_corrupt');
        }
      } finally {
        probe.close();
      }
      throw ServiceError('reports_db_unavailable');
    } on ServiceError catch (e) {
      if (e.code != 'reports_db_corrupt') rethrow;
    }
    final suffix = '.broken-${DateTime.now().toUtc().toIso8601String()}';
    final moved = <(String, String)>[];
    try {
      for (final name in _files.reversed) {
        final path = '/proc/self/fd/$dir/$name';
        if (FileSystemEntity.typeSync(path, followLinks: false) ==
            FileSystemEntityType.notFound) {
          continue;
        }
        final target = '$path$suffix';
        File(path).renameSync(target);
        moved.add((path, target));
      }
      _io.sync(dir);
    } catch (_) {
      for (final (path, target) in moved.reversed) {
        File(target).renameSync(path);
      }
      rethrow;
    }
    return p.join(directory, '${_files.first}$suffix');
  });
}
