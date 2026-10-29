import 'dart:io';
import 'package:asterism_core/asterism_core.dart';
import 'package:asterism_core/src/agent_updates.dart';
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
    final temp = Directory.systemTemp.createTempSync('asterism-upd-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final core = CoreService(
      environment: {
        'HOME': temp.path,
        'ASTERISM_DESKTOP': 'generic',
        'PATH': '${temp.path}/bin',
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
}
