import 'dart:io';
import 'package:asterism_core/asterism_core.dart';
import 'package:asterism_core/src/connect_apply.dart';
import 'package:asterism_core/src/core_tasks.dart';
import 'package:asterism_core/src/dsh_profile.dart';
import 'package:asterism_core/src/plan_worker.dart';
import 'package:asterism_core/src/provider_ops.dart';
import 'package:asterism_core/src/provider_scans.dart';
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

  test(
    'a DeepSeek Harness insert holding other servers is refused, not rewritten',
    () {
      const profile =
          '- insert:\n'
          '  - id: mcp-a\n'
          "    name: '@deepseek-ai/dsh-mcp-client'\n"
          '    config:\n'
          '      serverName: a\n'
          '  - id: mcp-b\n'
          "    name: '@deepseek-ai/dsh-mcp-client'\n"
          '    config:\n'
          '      serverName: b\n'
          '      when: !!js "() => Date.now()"\n';
      expect(dshMcpServers(profile).keys, ['a', 'b']);
      expect(() => dshMcpText(profile, 'a', null), throwsUnsupportedError);
      // Untouched inserts stay byte for byte; a new server is its own insert.
      final added = dshMcpText(profile, 'c', {
        'transport': 'stdio',
        'command': 'x',
        'args': <String>[],
      });
      expect(added, startsWith('# Your patch layer'));
      expect(added, contains(profile));
      expect(
        added,
        endsWith(
          "      serverName: c\n      transport: stdio\n      command: x\n      args: []\n",
        ),
      );
    },
  );

  test('only a socket of this account on a loopback address is our server', () {
    final net = Directory.systemTemp.createTempSync('asterism-net-');
    addTearDown(() => net.deleteSync(recursive: true));
    const header =
        '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid\n';
    // 8080 on 127.0.0.1 by uid 1000; 9090 on 0.0.0.0 by uid 0; 7070 on 10.0.0.5 by 1000 (not loopback).
    File('${net.path}/tcp').writeAsStringSync(
      '$header'
      '   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000 0 1\n'
      '   1: 00000000:2382 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0 0 2\n'
      '   2: 0500000A:1B9E 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000 0 3\n'
      '   3: 0100007F:1F91 0100007F:9C40 01 00000000:00000000 00:00000000 00000000  1000 0 4\n',
    );
    File('${net.path}/tcp6').writeAsStringSync(
      '$header'
      '   0: 00000000000000000000000001000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1001 0 5\n',
    );
    expect(loopbackListeners(8080, proc: net.path), [1000, 1001]);
    expect(
      ownPort(8080, 1000, proc: net.path),
      isFalse,
    ); // another account listens too
    expect(ownPort(9090, 1000, proc: net.path), isFalse);
    expect(loopbackListeners(7070, proc: net.path), isEmpty);
    expect(
      loopbackListeners(8081, proc: net.path),
      isEmpty,
    ); // connected, not listening
  });

  test('contexts travel as flutter_plan_wire carries them', () {
    final rt = RuntimeRecord('ollama', 'Ollama')..address = '127.0.0.1:11434';
    final plan = Plan(
      'pi',
      'ollama',
      'ollama-local',
      contexts: [
        {'runtime': rt.toJson(), 'model': 'gemma:latest', 'tokens': 8192},
      ],
    );
    final (back, root) = decodePlan(encodePlan(plan, '/tmp/backups'));
    expect(root, '/tmp/backups');
    expect(back.contexts, plan.contexts);
    final odd = Map<String, dynamic>.from(rt.toJson())..['shell'] = 'x';
    plan.contexts[0] = {'runtime': odd, 'model': 'm', 'tokens': 1};
    expect(
      () => decodePlan(encodePlan(plan, '/tmp/backups')),
      throwsFormatException,
    );
  });
}
