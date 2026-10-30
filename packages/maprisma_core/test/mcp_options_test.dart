import 'package:maprisma_core/src/mcp_catalog.dart';
import 'package:test/test.dart';

Map<String, dynamic> _server(Map<String, dynamic> package) => parseServers({
  'servers': [
    {
      'server': {
        'name': 'io.github.someone/files',
        'packages': [package],
      },
    },
  ],
}, '').single;

void main() {
  var n = 0;
  McpOptions options() => McpOptions(() => 'h${n++}');

  test('the app gets handles and field names, the entry stays here', () {
    final store = options();
    final shown = store.server(
      _server({
        'registryType': 'npm',
        'identifier': '@someone/files',
        'version': '1.0.0',
        'environmentVariables': [
          {
            'name': 'API_KEY',
            'isRequired': true,
            'isSecret': true,
            'default': 'not-shown',
          },
          {'name': 'REGION', 'description': 'Region'},
        ],
        'packageArguments': [
          {'type': 'positional', 'isRequired': true, 'description': 'Folder'},
        ],
      }),
      translate: (t) => t == 'Folder' ? 'Ordner' : t,
    );
    final option = (shown['options'] as List).single as Map;
    expect(option['env'], ['API_KEY', 'REGION']);
    expect(option.containsKey('entry'), isFalse);
    final needs = (option['needs'] as List).cast<Map>();
    expect(needs.map((n) => n['name']), ['API_KEY', 'REGION', 'arg:0']);
    expect(needs.first['value'], '');
    expect(needs.last['description'], 'Ordner');
    expect(option['on_command_line'], isEmpty);

    final entry = store.entryFor(option['option'], {
      'API_KEY': 'sk-1',
      'arg:0': '~/Documents',
    }, '/home/u');
    expect(entry['args'], ['-y', '@someone/files@1.0.0', '/home/u/Documents']);
    expect(entry['env'], {'API_KEY': 'sk-1'});

    expect(
      () => store.entryFor(option['option'], {'API_KEY': 'sk-1'}, '/home/u'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Fill in: Folder',
        ),
      ),
    );
    for (final values in [
      {'API_KEY': 'sk', 'arg:0': '/x', 'OTHER': 'y'},
      {'API_KEY': 'a\nb', 'arg:0': '/x'},
      {'API_KEY': 5, 'arg:0': '/x'},
      'not a map',
    ]) {
      expect(
        () => store.entryFor(option['option'], values, '/home/u'),
        throwsFormatException,
      );
    }
    expect(
      () => store.entryFor('unknown', {}, '/home/u'),
      throwsFormatException,
    );
  });

  test('a secret that would be on the command line is refused', () {
    final store = options();
    final shown = store.server(
      _server({
        'registryType': 'npm',
        'identifier': 'tokens',
        'packageArguments': [
          {
            'type': 'named',
            'name': '--token',
            'value': '{token}',
            'isSecret': true,
          },
        ],
      }),
    );
    final option = (shown['options'] as List).single as Map;
    expect(option['on_command_line'], ['token']);
    expect(
      () => store.entryFor(option['option'], {'token': 'secret'}, '/home/u'),
      throwsFormatException,
    );
    // Left empty (optional), the flag goes with it.
    expect(store.entryFor(option['option'], {}, '/home/u')['args'], [
      '-y',
      'tokens',
    ]);
  });

  test('old handles go', () {
    final store = options();
    final shown = store.server(
      _server({'registryType': 'npm', 'identifier': 'plain'}),
    );
    final handle = ((shown['options'] as List).single as Map)['option'];
    final (_, option) = store.items[handle]!;
    store.items[handle] = (DateTime.now().subtract(McpOptions.keep), option);
    expect(() => store.entryFor(handle, {}, '/home/u'), throwsFormatException);
  });
}
