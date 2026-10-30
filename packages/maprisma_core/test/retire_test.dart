import 'dart:convert';
import 'dart:io';
import 'package:maprisma_core/src/connect_apply.dart';
import 'package:maprisma_core/src/core_tasks.dart' show encodePlan;
import 'package:maprisma_core/src/plan_worker.dart' show decodePlan;
import 'package:maprisma_core/src/posix_ffi.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  setUp(() => home = Directory.systemTemp.createTempSync('retire'));
  tearDown(() => home.deleteSync(recursive: true));

  test('an old version moves into the backup; Undo brings it back', () {
    final old = Directory('${home.path}/Applications/app-1.0/usr/bin')
      ..createSync(recursive: true);
    File('${old.path}/app').writeAsStringSync('x');
    final config = File('${home.path}/.claude.json')..writeAsStringSync('{}');
    final files = ConfigFiles(Posix(), home.path);
    final plan = Plan(
      'claude',
      '',
      'app',
      changes: [Change(config.path, '{}', '{"a": 1}')],
      retire: ['${home.path}/Applications/app-1.0'],
    );
    expect(plan.empty, isFalse);
    final backup = files.apply(plan, '${home.path}/backups');
    expect(
      Directory('${home.path}/Applications/app-1.0').existsSync(),
      isFalse,
    );
    expect(File('$backup/retired-0-app-1.0/usr/bin/app').existsSync(), isTrue);
    final manifest = jsonDecode(
      File('$backup/manifest.json').readAsStringSync(),
    );
    expect(manifest['retired'], [
      ['${home.path}/Applications/app-1.0', 'retired-0-app-1.0'],
    ]);
    files.undo(backup);
    expect(File('${old.path}/app').readAsStringSync(), 'x');
    expect(config.readAsStringSync(), '{}');
  });

  test('retired folders go after seven days, the backup stays', () {
    for (final name in ['20261001-120000-000000', '20261028-120000-000000']) {
      Directory('${home.path}/$name/retired-0-app').createSync(recursive: true);
      File('${home.path}/$name/manifest.json').writeAsStringSync('{}');
    }
    Directory(
      '${home.path}/not-a-backup/retired-0-x',
    ).createSync(recursive: true);
    pruneRetired(home.path, now: DateTime(2026, 10, 29));
    expect(
      Directory(
        '${home.path}/20261001-120000-000000/retired-0-app',
      ).existsSync(),
      isFalse,
    );
    expect(
      File('${home.path}/20261001-120000-000000/manifest.json').existsSync(),
      isTrue,
    );
    expect(
      Directory(
        '${home.path}/20261028-120000-000000/retired-0-app',
      ).existsSync(),
      isTrue,
    );
    expect(
      Directory('${home.path}/not-a-backup/retired-0-x').existsSync(),
      isTrue,
    );
  });

  test('the worker retires only real folders right in ~/Applications', () {
    for (final path in [
      home.path,
      '/etc',
      '${Platform.environment['HOME']}/Applications/../.ssh',
      '${Platform.environment['HOME']}/Applications/.hidden',
    ]) {
      final body = encodePlan(
        Plan('a', '', 'b', retire: [path]),
        '${home.path}/backups',
      );
      expect(() => decodePlan(body), throwsFormatException, reason: path);
    }
  });
}
