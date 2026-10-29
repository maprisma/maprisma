import 'dart:io';
import 'package:asterism_core/src/adapters.dart';
import 'package:asterism_core/src/agent_keys.dart';
import 'package:asterism_core/src/posix_ffi.dart';
import 'package:test/test.dart';

Adapter adapter(Map<String, dynamic> key) => Adapter({
  'command': 'fixture',
  'name': 'Fixture',
  'access': {'how': 'An API key', 'key': key},
});

void main() {
  const key = 'sk-test_0123456789abcdef';

  test('a key goes into the .env file the agent reads, owner-only', () async {
    final home = Directory.systemTemp.createTempSync('asterism-key-');
    addTearDown(() => home.deleteSync(recursive: true));
    final file = File('${home.path}/.fixture/.env');
    file.parent.createSync();
    file.writeAsStringSync('KEEP=1\nexport FIXTURE_API_KEY=old\n# a comment\n');
    final result = await storeKey(
      {'key': ' $key '},
      adapter({'var': 'FIXTURE_API_KEY', 'env_file': '~/.fixture/.env'}),
      home.path,
      const {},
    );
    expect(result, {'ok': true, 'message': ''});
    expect(
      file.readAsStringSync(),
      'KEEP=1\n# a comment\nFIXTURE_API_KEY=$key\n',
    );
    expect(file.statSync().mode & 0x1ff, 0x180);
  });

  test('a link at the .env path is replaced, its target left alone', () {
    final home = Directory.systemTemp.createTempSync('asterism-key-');
    addTearDown(() => home.deleteSync(recursive: true));
    final target = File('${home.path}/elsewhere')
      ..writeAsStringSync('SECRET=keep\n');
    Link('${home.path}/link.env').createSync(target.path);
    writeEnv('${home.path}/link.env', 'FIXTURE_API_KEY', key, Posix());
    expect(target.readAsStringSync(), 'SECRET=keep\n');
    expect(FileSystemEntity.isLinkSync('${home.path}/link.env'), isFalse);
    expect(
      File('${home.path}/link.env').readAsStringSync(),
      'FIXTURE_API_KEY=$key\n',
    );
  });

  test('a new folder for the .env file is private', () async {
    final home = Directory.systemTemp.createTempSync('asterism-key-');
    addTearDown(() => home.deleteSync(recursive: true));
    await storeKey(
      {'key': key},
      adapter({'var': 'FIXTURE_API_KEY', 'env_file': '~/.new/deeper/.env'}),
      home.path,
      const {},
    );
    expect(Directory('${home.path}/.new').statSync().mode & 0x1ff, 0x1c0);
    expect(
      Directory('${home.path}/.new/deeper').statSync().mode & 0x1ff,
      0x1c0,
    );
  });

  test(
    "the agent's own command gets the key on stdin; its answer hides it",
    () async {
      final home = Directory.systemTemp.createTempSync('asterism-key-');
      addTearDown(() => home.deleteSync(recursive: true));
      final script = File('${home.path}/fixture-login')
        ..writeAsStringSync(
          '#!/bin/sh\nread k\necho "\${CLAUDECODE:-none} \$*" > "\$0.seen"\necho "stored \$k for you"\n',
        );
      Process.runSync('chmod', ['700', script.path]);
      final result = await storeKey(
        {'key': key},
        adapter({
          'var': 'FIXTURE_API_KEY',
          'stdin': [script.path, 'login', '--with-api-key'],
        }),
        home.path,
        {'PATH': '/usr/bin:/bin', 'CLAUDECODE': '1'},
      );
      expect(result['ok'], isTrue);
      expect(result['message'], 'stored … for you');
      // Without the agent-session variables, with its own words only.
      expect(
        File('${script.path}.seen').readAsStringSync(),
        'none login --with-api-key\n',
      );
      expect(result.toString(), isNot(contains(key)));
    },
  );

  test(
    'keys of the wrong shape and agents without a key step are refused',
    () async {
      final step = adapter({'var': 'FIXTURE_API_KEY', 'env_file': '~/.env'});
      expect(
        () => storeKey({'key': 'short'}, step, '/tmp', const {}),
        throwsFormatException,
      );
      expect(
        () => storeKey({'key': 'has space in it'}, step, '/tmp', const {}),
        throwsFormatException,
      );
      expect(
        () => storeKey({'key': key}, adapter({'var': 'X'}), '/tmp', const {}),
        throwsFormatException,
      );
      expect(
        () => storeKey(
          {'key': key},
          adapter({'var': 'FIXTURE_API_KEY', 'env_file': '/etc/env'}),
          '/tmp',
          const {},
        ),
        throwsFormatException,
      );
    },
  );

  test('a preview is used once and must still describe the same step', () {
    var n = 0;
    final keys = AgentKeys(() => 'token${n++}');
    final step = adapter({
      'var': 'FIXTURE_API_KEY',
      'url': 'https://example.org/keys',
      'env_file': '~/.env',
    });
    final preview = keys.preview({'command': 'fixture'}, step, true, 'Fixture');
    expect(preview, {
      'preview': 'token0',
      'name': 'Fixture',
      'variable': 'FIXTURE_API_KEY',
      'url': 'https://example.org/keys',
      'stores': 'file',
      'command': '',
      'file': '~/.env',
    });
    expect(
      () => keys.preview({'command': 'fixture'}, step, false, 'Fixture'),
      throwsFormatException,
    );
    final changed = adapter({'var': 'OTHER_KEY', 'env_file': '~/.env'});
    expect(
      () => keys.apply({'preview': 'token0', 'key': key}, (_) => changed),
      throwsFormatException,
    );
    final again = keys.preview(
      {'command': 'fixture'},
      step,
      true,
      'Fixture',
    )['preview'];
    expect(keys.apply({'preview': again, 'key': key}, (_) => step), isNotEmpty);
    expect(
      () => keys.apply({'preview': again, 'key': key}, (_) => step),
      throwsFormatException,
    );
  });
}
