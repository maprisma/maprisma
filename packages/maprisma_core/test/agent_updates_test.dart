import 'dart:io';
import 'package:maprisma_core/maprisma_core.dart';
import 'package:maprisma_core/src/agent_updates.dart';
import 'package:test/test.dart';

void main() {
  test('versions compare as the reference does', () {
    expect(newer('2.1.10', '2.1.9'), isTrue);
    expect(newer('v1.2', '1.2'), isFalse);
    expect(newer('1.2.0', '1.2'), isTrue);
    expect(newer('b9100', 'b9000'), isFalse); // not a version: never "newer"
    expect(newer('1.3-rc1', '1.2'), isTrue);
    expect(parseVersion('x'), isNull);
    expect(miseCommandOf('npm:@openai/codex'), 'codex');
    expect(miseCommandOf('http:muse'), 'muse');
  });

  test('updates.run runs only an allowed command of the last check', () {
    final temp = Directory.systemTemp.createTempSync('maprisma-upd-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final core = CoreService(
      environment: {
        'HOME': temp.path,
        'MAPRISMA_DESKTOP': 'generic',
        'PATH': '${temp.path}/bin',
        // No real agent instances: a codex running on this PC must not count.
        'MAPRISMA_SCAN_PROC': '${temp.path}/proc',
      },
    );
    Map<String, dynamic> u(String key, List<String> command) => update(
      'agent',
      key,
      key,
      '1',
      '2',
      command: command,
      page: command.isEmpty,
    );
    core.lastUpdates = [
      u('codex', ['mise', 'upgrade', 'codex']),
      u('evil', ['rm', '-rf', '/']),
      u('page', []),
      u('odd', ['mise', 'upgrade', 'a b']),
    ];
    for (final key in ['unknown', 'evil', 'page', 'odd']) {
      expect(
        () => core.dispatch('updates.run', {'key': key}),
        throwsFormatException,
        reason: key,
      );
    }
    // Allowed, but no terminal here: nothing is started.
    expect(
      () => core.dispatch('updates.run', {'key': 'codex'}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'No terminal available',
        ),
      ),
    );
  });

  test('updates.task: the Ask AI helper, never the agent it updates', () {
    expect(
      updateHelper('codex', ['claude', 'codex'], 'claude', 'codex'),
      'claude',
    );
    expect(
      updateHelper('goose', ['claude', 'codex'], 'claude', 'codex'),
      'codex',
    );
    expect(
      updateHelper('goose', ['claude', 'codex'], 'codex', 'local-helper'),
      'codex',
    );
    expect(updateHelper('goose', ['claude'], 'gone', ''), 'claude');
    expect(updateHelper('codex', ['codex'], 'codex', 'codex'), 'codex');
    expect(updateHelper('codex', [], null, 'codex'), isNull);
  });

  test('updates.task: the prompt says how, the route checks what', () {
    final withCommand = taskPrompt(
      update(
        'agent',
        'codex',
        'Codex',
        '1.0',
        '1.1',
        command: ['mise', 'upgrade', 'codex'],
      ),
    );
    expect(
      withCommand,
      contains('env MISE_USE_VERSIONS_HOST=0 mise upgrade codex'),
    );
    expect(withCommand, contains('from 1.0 to 1.1'));
    expect(withCommand, contains('after I agree'));
    final page = taskPrompt(
      update('runtime', 'll', 'llama.cpp', 'b1', 'b2', page: true),
    );
    expect(page, contains('Do not download, install or change anything'));
    final temp = Directory.systemTemp.createTempSync('maprisma-upd-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final core = CoreService(
      environment: {
        'HOME': temp.path,
        'MAPRISMA_DESKTOP': 'generic',
        'PATH': '${temp.path}/bin',
        'MAPRISMA_SCAN_PROC': '${temp.path}/proc',
      },
    );
    core.lastUpdates = [update('agent', 'codex', 'Codex', '1', '2')];
    for (final params in [
      {'key': 'unknown'},
      {'key': 'codex', 'x': 1},
      <String, dynamic>{},
    ]) {
      expect(
        () => core.dispatch('updates.task', params),
        throwsFormatException,
        reason: '$params',
      );
    }
    // Known, but no agent here can take the task.
    expect(
      () => core.dispatch('updates.task', {'key': 'codex'}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Helper unavailable',
        ),
      ),
    );
  });

  test('an agent\'s Update (its page, Ask AI) runs what the check found', () {
    final temp = Directory.systemTemp.createTempSync('maprisma-upd-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final bin = Directory('${temp.path}/bin')..createSync();
    for (final command in ['claude', 'mise']) {
      File('${bin.path}/$command').writeAsStringSync('#!/bin/sh\necho 1.0.0\n');
      Process.runSync('chmod', ['+x', '${bin.path}/$command']);
    }
    final core = CoreService(
      environment: {
        'HOME': temp.path,
        'MAPRISMA_DESKTOP': 'generic',
        'PATH': bin.path,
        'MAPRISMA_SCAN_PROC': '${temp.path}/proc',
        'MAPRISMA_SCAN_SYSTEM_ROOT': temp.path,
      },
    );
    List commandsOf() => core.dispatch('agents.action_preview', {
      'command': 'claude',
      'action': 'update',
    })['commands'];
    core.lastUpdates = [
      update(
        'agent',
        'claude',
        'Claude Code',
        '1.0.0',
        '2.0.0',
        command: ['claude', 'update'],
      ),
    ];
    expect(commandsOf(), ['claude update']);
    core.lastUpdates = [
      update(
        'agent',
        'claude',
        'Claude Code',
        '1.0.0',
        '2.0.0',
        command: ['mise', 'upgrade', 'claude'],
      ),
    ];
    expect(commandsOf(), ['env MISE_USE_VERSIONS_HOST=0 mise upgrade claude']);
    // A command the check may not run is not taken over.
    core.lastUpdates = [
      update(
        'agent',
        'claude',
        'Claude Code',
        '1.0.0',
        '2.0.0',
        command: ['rm', '-rf', '/'],
      ),
    ];
    final fallback = () {
      try {
        return commandsOf();
      } on FormatException {
        return const [];
      }
    }();
    expect(fallback, isNot(contains('rm -rf /')));
  });
}
