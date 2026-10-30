import 'dart:convert';
import 'dart:io';

import 'package:asterism_core/src/adapters.dart';
import 'package:asterism_core/src/mcp_updates.dart';
import 'package:test/test.dart';

/// mcp_updates.check's asking part with a fake agent: the prompt on stdin,
/// its answer checked and cached, the run in the token log; a failing agent
/// keeps the old answer and is asked again after six hours.
void main() {
  late Directory home;
  late Map<String, String> env;
  const servers = <McpServer>[
    (
      name: 'fetch',
      app: '@acme/fetch-mcp',
      version: '1.4.2',
      source: 'npm',
      program: '',
    ),
  ];
  final adapter = Adapter({
    'command': 'fake',
    'name': 'Fake',
    'research': {
      'argv': ['fake', '-p'],
      'output': 'text',
    },
    'closed': {'background': <String>[]},
  });

  setUp(() {
    home = Directory.systemTemp.createTempSync('mcp-updates-');
    Directory('${home.path}/bin').createSync();
    env = {
      'HOME': home.path,
      'PATH': '${home.path}/bin:/usr/bin:/bin',
      'XDG_STATE_HOME': '${home.path}/.local/state',
    };
  });
  tearDown(() => home.deleteSync(recursive: true));

  void agent(String script) {
    final file = File('${home.path}/bin/fake')
      ..writeAsStringSync('#!/bin/sh\n$script\n');
    Process.runSync('chmod', ['755', file.path]);
  }

  test('asks, checks and caches the answer', () async {
    agent(
      'cat > "\$HOME/asked.txt"\n'
      'echo \'Sure: {"servers": [{"name": "fetch", "latest": "1.5.0", '
      '"release_url": "https://www.npmjs.com/package/@acme/fetch-mcp", '
      '"notes": "Faster."}, {"name": "evil", "latest": "9.0", '
      '"release_url": "https://x.org", "notes": ""}]}\'',
    );
    final cache = '${home.path}/.cache/maprisma/mcp-updates.json';
    final found = await checkNow(
      adapter,
      'fake',
      servers,
      cache,
      1000,
      env,
      home.path,
      'asterism',
    );
    expect(found.map((f) => (f.name, f.latest)), [('fetch', '1.5.0')]);
    expect(
      File('${home.path}/asked.txt').readAsStringSync(),
      contains('- fetch: @acme/fetch-mcp 1.4.2 (npm package)'),
    );
    final saved = jsonDecode(File(cache).readAsStringSync()) as Map;
    expect(saved['ok'], true);
    expect(saved['agent'], 'fake');
    expect(cached(cache).single.url, contains('npmjs.com'));
    expect(due(1000.0 + checkEvery - 1, cache), isFalse);
    expect(due(1000.0 + checkEvery, cache), isTrue);
    final log = Directory('${home.path}/.local/state')
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.readAsStringSync())
        .join();
    expect(log, contains('mcp-updates'));
    expect(log, contains('1 update found'));
  });

  test('a failing agent keeps the old answer', () async {
    final cache = '${home.path}/.cache/maprisma/mcp-updates.json';
    File(cache)
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'checked': 10,
          'ok': true,
          'found': [
            {
              'name': 'fetch',
              'app': '@acme/fetch-mcp',
              'current': '1.4.2',
              'latest': '1.5.0',
              'url': 'https://x.org',
              'notes': '',
              'source': 'npm',
              'program': '',
            },
          ],
        }),
      );
    agent('echo "not signed in" >&2; exit 1');
    final found = await checkNow(
      adapter,
      'fake',
      servers,
      cache,
      1000,
      env,
      home.path,
      'asterism',
    );
    expect(found.single.latest, '1.5.0');
    final saved = jsonDecode(File(cache).readAsStringSync()) as Map;
    expect(saved['ok'], false);
    expect(saved['found'], isNotEmpty);
    expect(due(1000.0 + retryFailed - 1, cache), isFalse);
    expect(due(1000.0 + retryFailed, cache), isTrue);
  });
}
