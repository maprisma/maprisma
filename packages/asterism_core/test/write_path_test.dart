import 'dart:io';
import 'package:asterism_core/asterism_core.dart';
import 'package:asterism_core/src/connect_apply.dart';
import 'package:asterism_core/src/core_tasks.dart';
import 'package:test/test.dart';

void main() {
  test('preview, apply through the worker, status, Undo', () async {
    final home = Directory.systemTemp.createTempSync('asterism-write-');
    addTearDown(() => home.deleteSync(recursive: true));
    final config = File('${home.path}/.codex/config.toml')
      ..createSync(recursive: true)
      ..writeAsStringSync('model = "a"\nkeep = 1\n');
    final tasks = CoreTasks([
      Platform.resolvedExecutable,
      '--disable-dart-dev',
      '--packages=.dart_tool/package_config.json',
      'bin/asterism-core.dart',
      'worker',
    ]);
    final connections = CoreConnections(
      ConfigFiles(Posix(), home.path),
      tasks,
      '${home.path}/.config/asterism/connection-backups',
    );
    final preview = connections.keep(
      Plan(
        'codex',
        '',
        '',
        changes: [
          Change(
            config.path,
            'model = "a"\nkeep = 1\n',
            'model = "b"\nkeep = 1\nnew = 2\n',
          ),
        ],
      ),
    );
    expect(preview['plan'], startsWith(coreHandle));
    expect(preview['files'], [
      {'path': '~/.codex/config.toml', 'added': 2, 'removed': 1},
    ]);
    final started = connections.apply(preview['plan'] as String);
    expect(
      () => connections.apply(preview['plan'] as String),
      throwsFormatException,
    );
    final ident = started['task'] as String;
    var status = tasks.status(ident);
    expect(() => tasks.cancel(ident), throwsFormatException);
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (status['state'] == 'running' && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      status = tasks.status(ident);
    }
    expect(status['state'], 'done', reason: '$status');
    final result = status['result'] as Map;
    expect(result['ok'], isTrue);
    expect(result['context_failures'], 0);
    expect(config.readAsStringSync(), 'model = "b"\nkeep = 1\nnew = 2\n');
    final undone = connections.undo(result['undo'] as String);
    expect(undone['restored'], ['~/.codex/config.toml']);
    expect(config.readAsStringSync(), 'model = "a"\nkeep = 1\n');
    expect(
      () => connections.undo(result['undo'] as String),
      throwsFormatException,
    );
  });

  test('a changed file fails the task and writes nothing', () async {
    final home = Directory.systemTemp.createTempSync('asterism-write-');
    addTearDown(() => home.deleteSync(recursive: true));
    final config = File('${home.path}/settings.json')..writeAsStringSync('{}');
    final tasks = CoreTasks([
      Platform.resolvedExecutable,
      '--disable-dart-dev',
      '--packages=.dart_tool/package_config.json',
      'bin/asterism-core.dart',
      'worker',
    ]);
    final connections = CoreConnections(
      ConfigFiles(Posix(), home.path),
      tasks,
      '${home.path}/backups',
    );
    final preview = connections.keep(
      Plan('x', '', '', changes: [Change(config.path, '{}', '{"a": 1}')]),
    );
    config.writeAsStringSync('{"edited": true}');
    final ident =
        connections.apply(preview['plan'] as String)['task'] as String;
    var status = tasks.status(ident);
    while (status['state'] == 'running') {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      status = tasks.status(ident);
    }
    expect(status['state'], 'failed');
    expect(config.readAsStringSync(), '{"edited": true}');
    expect(Directory('${home.path}/backups').existsSync(), isFalse);
  });

  test('empty plans need no worker; unknown handles are refused', () {
    final connections = CoreConnections(
      ConfigFiles(Posix(), '/nonexistent'),
      CoreTasks(['/bin/false']),
      '/nonexistent/backups',
    );
    final preview = connections.keep(Plan('x', '', ''));
    expect(preview['empty'], isTrue);
    expect(connections.apply(preview['plan'] as String), {
      'ok': true,
      'undo': null,
    });
    expect(() => connections.undo('core-unknown'), throwsFormatException);
  });
}
