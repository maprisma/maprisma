import 'dart:convert';
import 'dart:io';

import 'package:asterism_core/src/change_history.dart';
import 'package:asterism_core/src/connect_apply.dart';
import 'package:asterism_core/src/posix_ffi.dart';
import 'package:test/test.dart';

/// The changes kept on disk: listed newest first with what Undo would still
/// put back; Undo by id after a restart; a change edited again since is left
/// alone; an apply that stopped after its manifest undoes only what it wrote;
/// ids that are not a backup's name are refused.
void main() {
  late Directory home;
  late ConfigFiles files;
  late String backups;
  setUp(() {
    home = Directory.systemTemp.createTempSync('history');
    files = ConfigFiles(Posix(), home.path);
    backups = '${home.path}/backups';
  });
  tearDown(() => home.deleteSync(recursive: true));

  String apply(String path, String old, String next, DateTime now) =>
      files.apply(
        Plan('claude', '', '', changes: [Change(path, old, next)]),
        backups,
        now: now,
      );

  test('listed newest first, undone by id, edited ones left alone', () {
    final a = File('${home.path}/a.json')..writeAsStringSync('{}');
    final b = File('${home.path}/b.json')..writeAsStringSync('{}');
    apply(a.path, '{}', '{"x": 1}', DateTime(2026, 10, 30, 9));
    apply(b.path, '{}', '{"y": 1}', DateTime(2026, 10, 30, 10));
    var history = changeHistory(files, backups);
    expect(history.map((h) => h['changed']), [
      ['~/b.json'],
      ['~/a.json'],
    ]);
    expect(history.first['when'], startsWith('2026-10-30T10:00:00'));
    expect(history.every((h) => (h['undoable'] as List).isNotEmpty), isTrue);

    b.writeAsStringSync('{"y": 2}'); // edited again since
    history = changeHistory(files, backups);
    expect(history.first['undoable'], isEmpty);
    expect(undoChange(files, backups, history.first['id'] as String), isEmpty);
    expect(b.readAsStringSync(), '{"y": 2}');

    expect(undoChange(files, backups, history.last['id'] as String), [
      '~/a.json',
    ]);
    expect(a.readAsStringSync(), '{}');
    expect(changeHistory(files, backups).last['undoable'], isEmpty);
  });

  test('an apply that stopped after its manifest', () {
    final a = File('${home.path}/a.json')..writeAsStringSync('{}');
    final b = File('${home.path}/b.json')..writeAsStringSync('{}');
    final folder = files.apply(
      Plan(
        'claude',
        '',
        '',
        changes: [
          Change(a.path, '{}', '{"x": 1}'),
          Change(b.path, '{}', '{"y": 1}'),
        ],
      ),
      backups,
      now: DateTime(2026, 10, 30, 11),
    );
    b.writeAsStringSync('{}'); // as if the crash came before writing b
    final entry = changeHistory(files, backups).single;
    expect(entry['undoable'], ['~/a.json']);
    expect(undoChange(files, backups, entry['id'] as String), ['~/a.json']);
    expect(a.readAsStringSync(), '{}');
    expect(b.readAsStringSync(), '{}');
    expect(Directory(folder).existsSync(), isTrue); // the backup stays
  });

  test('other folders and ids are not changes', () {
    Directory(
      '$backups/manual-20261021-130125-fix',
    ).createSync(recursive: true);
    Directory('$backups/20261030-120000-000000').createSync(); // no manifest
    File(
      '$backups/20261030-120000-000000/manifest.json',
    ).writeAsStringSync(jsonEncode({'files': []}));
    expect(changeHistory(files, backups), isEmpty);
    for (final id in ['../x', 'manual-20261021-130125-fix', '20261030-1']) {
      expect(() => undoChange(files, backups, id), throwsFormatException);
    }
    expect(changeHistory(files, '${home.path}/none'), isEmpty);
  });
}
