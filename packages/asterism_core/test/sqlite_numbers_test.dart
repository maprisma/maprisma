import 'dart:io';
import 'package:test/test.dart';
import 'package:asterism_core/src/identity.dart';
import 'package:asterism_core/src/scan_files.dart';
import 'package:asterism_core/src/sqlite_numbers.dart';

void main() {
  late Directory home;
  late SqliteNumbers db;
  setUp(() {
    home = Directory.systemTemp.createTempSync('asterism-sqlite-test-');
    db = SqliteNumbers(
      ScanFiles(AppIdentity(environment: {'HOME': home.path})),
    );
  });
  tearDown(() => home.deleteSync(recursive: true));
  void fixture({bool wal = false}) {
    final result = Process.runSync(
      '/usr/bin/python3',
      [
        '-I',
        '-c',
        r'''
import sqlite3,sys,pathlib,shutil
root=pathlib.Path(sys.argv[1])
con=sqlite3.connect(root/'source.db')
if sys.argv[2]=='wal':
 con.execute('PRAGMA journal_mode=WAL')
 con.execute('PRAGMA wal_autocheckpoint=0')
con.execute('CREATE TABLE sessions(id TEXT, tokens INTEGER, model TEXT, transcript TEXT)')
con.execute('INSERT INTO sessions VALUES (?,?,?,?)',('one',123,'test-model','DO_NOT_SELECT_TRANSCRIPT'))
con.commit()
for suffix in ('','-wal'):
 path=root/('source.db'+suffix)
 if path.exists(): shutil.copyfile(path,root/('read.db'+suffix))
con.close()
''',
        home.path,
        wal ? 'wal' : 'delete',
      ],
      environment: {'HOME': home.path},
    );
    expect(result.exitCode, 0, reason: result.stderr.toString());
  }

  test('readonly numeric SELECT creates no files and refuses SQL writes', () {
    fixture();
    final path = '${home.path}/read.db';
    final before = File(path).readAsBytesSync();
    final entries = home.listSync().map((e) => e.path).toSet();
    expect(db.select(path, 'SELECT id, tokens, model FROM sessions'), [
      ['one', 123, 'test-model'],
    ]);
    expect(db.select(path, 'DELETE FROM sessions'), isEmpty);
    expect(
      db.select(
        path,
        'ATTACH DATABASE "/tmp/never-create-asterism.db" AS extra',
      ),
      isEmpty,
    );
    expect(File(path).readAsBytesSync(), before);
    expect(home.listSync().map((e) => e.path).toSet(), entries);
  });
  test('committed WAL data is visible without opening or creating shm', () {
    fixture(wal: true);
    final path = '${home.path}/read.db';
    final before = {
      for (final e in home.listSync().whereType<File>())
        e.path: e.readAsBytesSync(),
    };
    expect(db.select(path, 'SELECT id, tokens FROM sessions'), [
      ['one', 123],
    ]);
    expect(File('$path-shm').existsSync(), false);
    expect({
      for (final e in home.listSync().whereType<File>())
        e.path: e.readAsBytesSync(),
    }, before);
    File('$path-wal').writeAsBytesSync([1, 2, 3]);
    expect(db.select(path, 'SELECT tokens FROM sessions'), isEmpty);
  });
  test('malformed SQLite, links, FIFOs and credentials are unavailable', () {
    fixture();
    Link('${home.path}/linked.db').createSync('${home.path}/read.db');
    expect(
      db.select('${home.path}/linked.db', 'SELECT tokens FROM sessions'),
      isEmpty,
    );
    expect(
      Process.runSync('/usr/bin/mkfifo', ['${home.path}/fifo.db']).exitCode,
      0,
    );
    expect(
      db.select('${home.path}/fifo.db', 'SELECT tokens FROM sessions'),
      isEmpty,
    );
    File('${home.path}/bad.db').writeAsStringSync('not sqlite');
    expect(
      db.select('${home.path}/bad.db', 'SELECT tokens FROM sessions'),
      isEmpty,
    );
    expect(
      db.select('${home.path}/auth.json', 'SELECT tokens FROM sessions'),
      isEmpty,
    );
  });
}
