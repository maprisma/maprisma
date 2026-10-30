import 'dart:convert';
import 'dart:io';
import 'package:maprisma_core/maprisma_core.dart';
import 'package:maprisma_core/src/protocol_recording.dart';
import 'package:test/test.dart';

/// The protocol recording blanks secrets before a line is written (task 001).
void main() {
  test('secrets are blanked, the rest stays', () {
    final line = redactForRecord('connections.preview', {
      'params': {'command': 'claude', 'item': 'files'},
      'result': {
        'servers': [
          {
            'name': 'github',
            'command': 'npx',
            'args': [
              '-y',
              'server',
              '--token',
              'ghp_abcdefghijklmnopqrstuvwxyz0123',
            ],
            'env': {'GITHUB_TOKEN': 'plain-value', 'DEBUG': '1'},
            'headers': {'X-Api': 'abc'},
          },
        ],
        'api_key': 'secret-text',
        'credentials': true,
        'password': null,
        'note': 'Use Bearer abc.def.ghi to sign in',
        'tokens': 1234,
      },
    });
    final text = jsonEncode(line);
    for (final secret in [
      'ghp_abcdefghijklmnopqrstuvwxyz0123',
      'plain-value',
      'abc"',
      'secret-text',
      'abc.def.ghi',
    ]) {
      expect(text, isNot(contains(secret)), reason: secret);
    }
    final server = ((line as Map)['result']['servers'] as List).first as Map;
    expect(server['env'], {'GITHUB_TOKEN': recordBlank, 'DEBUG': recordBlank});
    expect(server['headers'], {'X-Api': recordBlank});
    expect(server['name'], 'github');
    expect(server['args'], ['-y', 'server', '--token', recordBlank]);
    final result = line['result'] as Map;
    expect(result['credentials'], true);
    expect(result['password'], isNull);
    expect(result['tokens'], 1234);
    expect(line['params'], {'command': 'claude', 'item': 'files'});
  });

  test('the key of an API-key route is blanked, a provider key is not', () {
    expect(
      redactForRecord('agents.key_apply', {
        'params': {'key': 'AIzaSyD-example-example-example', 'preview': 'x'},
      }),
      {
        'params': {'key': recordBlank, 'preview': 'x'},
      },
    );
    expect(
      redactForRecord('providers.details', {
        'params': {'key': 'ollama'},
      }),
      {
        'params': {'key': 'ollama'},
      },
    );
  });

  test('a recorded route writes blanked lines; off, nothing is written', () {
    final home = Directory.systemTemp.createTempSync('recording');
    addTearDown(() => home.deleteSync(recursive: true));
    final record = File('${home.path}/protocol.jsonl');
    CoreService core(Map<String, String> extra) => CoreService(
      environment: {
        'HOME': home.path,
        'PATH': '${home.path}/bin',
        'MAPRISMA_DESKTOP': 'generic',
        ...extra,
      },
    );
    final off = core({'MAPRISMA_RECORD_PROTOCOL': ''});
    off.dispatch('settings.get', {});
    expect(record.existsSync(), isFalse);

    final on = core({'MAPRISMA_RECORD_PROTOCOL': record.path});
    on.dispatch('settings.get', {});
    expect(
      () => on.dispatch('agents.key_preview', {
        'command': 'nope',
        'key': 'sk-ant-abcdefghijklmnopqrstuv',
      }),
      throwsFormatException,
    );
    final lines = record
        .readAsLinesSync()
        .map((l) => jsonDecode(l) as Map)
        .toList();
    expect(
      [for (final l in lines) l['method']],
      ['settings.get', 'agents.key_preview'],
    );
    expect(lines.first.containsKey('result'), isTrue);
    expect(lines.first['time'], isA<String>());
    expect(lines.last['error'], 'invalid');
    expect(record.readAsStringSync(), isNot(contains('sk-ant-')));
  });
}
