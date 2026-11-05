// Task 063e: MCP servers of one name (review 063, round 2, #1 and #3 to #5).
import 'dart:convert';
import 'dart:io';
import 'package:maprisma_core/maprisma_core.dart';
import 'package:maprisma_core/src/action_rules.dart';
import 'package:maprisma_core/src/mcp_plans.dart';
import 'package:maprisma_core/src/mcp_tools.dart';
import 'package:test/test.dart';

const _a = {
  'transport': 'stdio',
  'command': 'fs-a',
  'args': <String>[],
  'env': <String, String>{},
  'url': '',
  'headers': <String, String>{},
};
const _b = {
  'transport': 'stdio',
  'command': 'fs-b',
  'args': <String>[],
  'env': <String, String>{},
  'url': '',
  'headers': <String, String>{},
};

void main() {
  late Directory home;
  late CoreService core;

  void write(String path, String text) => File('${home.path}/$path')
    ..createSync(recursive: true)
    ..writeAsStringSync(text);
  String read(String path) => File('${home.path}/$path').readAsStringSync();

  /// Claude's "filesystem" runs fs-a, Codex's runs fs-b; Pi has none.
  void claudeAndCodex() {
    write(
      '.claude.json',
      jsonEncode({
        'mcpServers': {
          'filesystem': {'command': 'fs-a'},
        },
      }),
    );
    write('.codex/config.toml', '[mcp_servers.filesystem]\ncommand = "fs-b"\n');
  }

  void rules(List<Map<String, dynamic>> more) => write(
    '.config/maprisma/settings.json',
    jsonEncode({
      'action_rules': [...defaultActionRules, ...more],
    }),
  );
  Map<String, dynamic> deny(String action) => {
    'effect': 'deny',
    'action': action,
    'category': 'mcp',
    'item': 'filesystem',
    'agent': '*',
  };
  Map<String, Map> servers() => {
    for (final s
        in core.reads.inventory
            .collect(core.reads.catalog.scan(), remember: false)
            .mcp)
      '${s['id']}': s,
  };
  Map<String, dynamic> library() =>
      (jsonDecode(read('.config/maprisma/mcp-servers.json')) as Map)['servers']
          as Map<String, dynamic>;
  String planned(Map<String, dynamic> preview) => [
    for (final c in core.connections.take(preview['plan'] as String).changes)
      c.next,
  ].join('\n');

  setUp(() {
    home = Directory.systemTemp.createTempSync('mcp-variants');
    Directory('${home.path}/proc').createSync();
    final bin = Directory('${home.path}/bin')..createSync();
    for (final command in ['claude', 'codex', 'pi']) {
      File('${bin.path}/$command').writeAsStringSync('#!/bin/sh\necho 1.0\n');
      Process.runSync('chmod', ['+x', '${bin.path}/$command']);
    }
    core = CoreService(
      environment: {
        'HOME': home.path,
        'PATH': bin.path,
        'MAPRISMA_DESKTOP': 'generic',
        'MAPRISMA_SCAN_PROC': '${home.path}/proc',
        'MAPRISMA_SCAN_SYSTEM_ROOT': home.path,
      },
    );
  });
  tearDown(() => home.deleteSync(recursive: true));

  group('#1: rules see the configuration name', () {
    test('a deny for filesystem refuses connecting filesystem~2', () {
      claudeAndCodex();
      rules([deny('connect')]);
      expect(servers().keys, containsAll(['filesystem', 'filesystem~2']));
      expect(
        () => core.dispatch('connections.preview', {
          'kind': 'mcp',
          'command': 'pi',
          'item': 'filesystem~2',
          'remove': false,
        }),
        throwsA(isA<RuleRefused>()),
      );
      // Moving a line onto it, and Ask AI's candidate for it, too.
      expect(
        core.dispatch('rules.test', {
          'action': 'connect',
          'category': 'mcp',
          'item': 'filesystem~2',
          'agent': 'pi',
        })['allowed'],
        isFalse,
      );
      final kept = core.smartProposals.keep({
        'status': 'proposal',
        'candidates': [
          {
            'id': 'c1',
            'kind': 'mcp_connect',
            'agents': ['pi'],
            'title': 'filesystem~2',
            'action': {
              'kind': 'mcp_connect',
              'server': 'filesystem~2',
              'agent': 'pi',
            },
          },
        ],
      });
      expect(
        () => core.dispatch('map.smart_plan', {
          'proposal': kept['proposal'],
          'candidate': 'c1',
          'agents': ['pi'],
          'values': <String, dynamic>{},
        }),
        throwsA(isA<RuleRefused>()),
      );
    });

    test('and a deny of disconnecting it refuses leaving filesystem~2', () {
      claudeAndCodex();
      rules([deny('disconnect')]);
      expect(
        () => core.dispatch('connections.preview', {
          'kind': 'mcp',
          'command': 'codex',
          'item': 'filesystem~2',
          'remove': true,
        }),
        throwsA(isA<RuleRefused>()),
      );
    });
  });

  test('#3: tools of filesystem~2 are its own, never the first server\'s', () {
    claudeAndCodex();
    final inventory = core.reads.inventory.collect(
      core.reads.catalog.scan(),
      remember: false,
    );
    Map server(String id) => inventory.mcp.singleWhere((s) => s['id'] == id);
    // mcp.tools starts what this gives: Codex's fs-b.
    expect(core.mcpServerEntry(server('filesystem~2'), inventory), _b);
    expect(core.mcpServerEntry(server('filesystem'), inventory), _a);
    // The first server's answer is not the second's.
    void keep(String id, Map entry, String tool) => write(
      '.cache/maprisma/mcp-tools/$id.json',
      jsonEncode({
        'status': 'ok',
        'tools': [
          {'name': tool, 'description': ''},
        ],
        'identity': mcpIdentityHash(entry),
      }),
    );
    keep('filesystem', _a, 'read-a');
    expect(
      core.dispatch('mcp.tools_cached', {'name': 'filesystem~2'})['cached'],
      isNull,
    );
    keep('filesystem~2', _a, 'read-a'); // kept for another server of that id
    expect(
      core.dispatch('mcp.tools_cached', {'name': 'filesystem~2'})['cached'],
      isNull,
    );
    // R3 #5: an answer kept before digests tells not whose it is: none.
    write(
      '.cache/maprisma/mcp-tools/filesystem~2.json',
      jsonEncode({
        'status': 'ok',
        'tools': [
          {'name': 'read-old', 'description': ''},
        ],
      }),
    );
    expect(
      core.dispatch('mcp.tools_cached', {'name': 'filesystem~2'})['cached'],
      isNull,
    );
    expect(
      core.dispatch('details.mcp', {'name': 'filesystem~2'})['tools'],
      isEmpty,
    );
    expect(
      read('.cache/maprisma/mcp-tools/filesystem~2.json'),
      contains('read-old'),
    );
    // Without a digest to compare (no definition known) it is still shown.
    expect(
      (cachedTools(home.path, 'filesystem~2')!['tools'] as List).single['name'],
      'read-old',
    );
    keep('filesystem~2', _b, 'read-b');
    final cached =
        core.dispatch('mcp.tools_cached', {'name': 'filesystem~2'})['cached']
            as Map;
    expect((cached['tools'] as List).single['name'], 'read-b');
    expect(cached.containsKey('identity'), isFalse);
    final details = core.dispatch('details.mcp', {'name': 'filesystem~2'});
    expect(details['server'], 'filesystem~2');
    expect(details['tools'], [
      ['read-b', ''],
    ]);
    expect(jsonEncode(details['sections']), contains('fs-b'));
    expect(jsonEncode(details['sections']), isNot(contains('fs-a')));
    expect(
      () => core.dispatch('mcp.tools', {'name': 'filesystem~9'}),
      throwsFormatException,
    );
  });

  test('#3: an answer is kept with the digest of the server asked', () async {
    final written = <String, List<int>>{};
    final result = await askAndKeep(
      'filesystem~2',
      {..._b}..['command'] = '${home.path}/missing',
      identity: 'abc',
      home: home.path,
      environment: Platform.environment,
      write: (path, bytes) => written[path] = bytes,
    );
    expect(result.containsKey('identity'), isFalse);
    final file = '${home.path}/.cache/maprisma/mcp-tools/filesystem~2.json';
    expect(jsonDecode(utf8.decode(written[file]!))['identity'], 'abc');
  });

  test('#4: servers are told apart by what they are, not their label', () {
    write(
      '.claude.json',
      jsonEncode({
        'mcpServers': {
          'web': {'type': 'http', 'url': 'https://example.test/a'},
          'port': {'type': 'http', 'url': 'https://example.test:8443/mcp'},
          'tool': {
            'command': 'node',
            'args': ['/x/server.js'],
          },
          'same': {
            'command': 'same-cli',
            'env': {'ROOT': '/data/one'},
          },
          'desk': {
            'type': 'http',
            'url': 'https://example.test/desk',
            'headers': {'X-Workspace': 'alpha'},
          },
          'twin': {
            'command': 'twin-cli',
            'env': {'A': '1', 'B': '2'},
          },
        },
      }),
    );
    write(
      '.codex/config.toml',
      [
        '[mcp_servers.web]',
        'url = "https://example.test/b"',
        '[mcp_servers.port]',
        'url = "https://example.test:9443/mcp"',
        '[mcp_servers.tool]',
        'command = "node"',
        'args = ["/y/server.js"]',
        '[mcp_servers.same]',
        'command = "same-cli"',
        'env = { ROOT = "/data/two" }',
        '[mcp_servers.desk]',
        'url = "https://example.test/desk"',
        'http_headers = { X-Workspace = "beta" }',
        '[mcp_servers.twin]',
        'command = "twin-cli"',
        'env = { B = "2", A = "1" }',
        '',
      ].join('\n'),
    );
    final found = servers();
    for (final name in ['web', 'port', 'tool']) {
      expect(found['$name~2']?['agents'], ['codex'], reason: name);
      expect(found['$name~2']!['target'], found[name]!['target']);
    }
    expect(found['web']!['target'], 'example.test');
    expect(found['tool']!['target'], 'node server.js');
    // Another ROOT or workspace is another server (R3 #1), shown as before.
    for (final name in ['same', 'desk']) {
      expect(found['$name~2']?['agents'], ['codex'], reason: name);
      expect(found['$name~2']!['target'], found[name]!['target']);
    }
    // The same env in another order is the same server.
    expect(found['twin']!['agents'], ['claude', 'codex']);
    expect(found.containsKey('twin~2'), isFalse);
    // Their values are in no id, label or identity, only digested.
    final entry = {
      'command': 'same-cli',
      'env': {'ROOT': '/data/one'},
    };
    for (final text in [
      jsonEncode(found),
      mcpIdentity(entry),
      mcpIdentityHash(entry),
    ]) {
      expect(text, isNot(contains('/data/')));
      expect(text, isNot(contains('alpha')));
      expect(text, isNot(contains('beta')));
    }
    expect(mcpIdentity(entry), isNot(mcpIdentity({'command': 'same-cli'})));
  });

  test('#4: a saved server with its env still is the server it was', () {
    // A list saved before env took part in the identity.
    final rooted = {
      ..._a,
      'env': {'ROOT': '/data/a'},
    };
    write(
      '.config/maprisma/mcp-servers.json',
      jsonEncode({
        'servers': {'filesystem': rooted},
      }),
    );
    write(
      '.claude.json',
      jsonEncode({
        'mcpServers': {
          'filesystem': {
            'command': 'fs-a',
            'env': {'ROOT': '/data/a'},
          },
        },
      }),
    );
    write(
      '.codex/config.toml',
      '[mcp_servers.filesystem]\ncommand = "fs-a"\n'
          'env = { ROOT = "/data/b" }\n',
    );
    final inventory = core.reads.inventory.collect(core.reads.catalog.scan());
    expect(library().keys, ['filesystem', 'filesystem~2']);
    expect(library()['filesystem'], rooted);
    expect(library()['filesystem~2']['env'], {'ROOT': '/data/b'});
    expect(inventory.mcpLibrary, {
      'filesystem': 'filesystem',
      'filesystem~2': 'filesystem~2',
    });
    // Without env the digest is the one kept before (old tool answers match).
    expect(mcpIdentityHash(_a), mcpIdentityHash({'command': 'fs-a'}));
  });

  group('#5: Ask AI and the list of known servers keep each server', () {
    test('Ask AI names filesystem~2 and its own agent', () {
      claudeAndCodex();
      final facts = core.smartMcpFacts(core.reads.catalog.scan());
      expect(facts['mcp'], {
        'filesystem': ['claude'],
        'filesystem~2': ['codex'],
      });
      final kept = core.smartProposals.keep({
        'status': 'proposal',
        'candidates': [
          {
            'id': 'c1',
            'kind': 'mcp_connect',
            'agents': ['pi'],
            'title': 'filesystem~2',
            'action': {
              'kind': 'mcp_connect',
              'server': 'filesystem~2',
              'agent': 'pi',
            },
          },
        ],
      });
      final preview = core.dispatch('map.smart_plan', {
        'proposal': kept['proposal'],
        'candidate': 'c1',
        'agents': ['pi'],
        'values': <String, dynamic>{},
      });
      final text = planned(preview);
      expect(text, contains('fs-b'));
      expect(text, isNot(contains('fs-a')));
    });

    test('the second server stays known after its last agent left', () {
      claudeAndCodex();
      // A list saved before: its entry keeps its plain name.
      write(
        '.config/maprisma/mcp-servers.json',
        jsonEncode({
          'servers': {'filesystem': _a},
        }),
      );
      core.reads.inventory.collect(core.reads.catalog.scan());
      expect(library()['filesystem']['command'], 'fs-a');
      expect(library()['filesystem~2']['command'], 'fs-b');
      // Codex leaves its server.
      write('.codex/config.toml', '');
      core.reads.inventory.collect(core.reads.catalog.scan());
      expect(library().keys, ['filesystem', 'filesystem~2']);
      final unused = servers()['filesystem~2']!;
      expect([unused['target'], unused['agents']], ['fs-b', isEmpty]);
      // Drawing the line again sets that very server up.
      final again = core.dispatch('connections.preview', {
        'kind': 'mcp',
        'command': 'codex',
        'item': 'filesystem~2',
        'remove': false,
      });
      expect(planned(again), contains('fs-b'));
      expect(
        jsonEncode(core.dispatch('details.mcp', {'name': 'filesystem~2'})),
        contains('fs-b'),
      );
      // Forgetting it takes only that one from the list.
      final forget = core.dispatch('connections.forget_preview', {
        'name': 'filesystem~2',
      });
      final rest = jsonDecode(planned(forget))['servers'] as Map;
      expect(rest.keys, ['filesystem']);
      expect(
        () =>
            core.dispatch('connections.forget_preview', {'name': 'filesystem'}),
        throwsFormatException,
        reason: 'Claude still uses it',
      );
    });

    test('a saved server keeps its key when another takes its name', () {
      // R3 #4: saved filesystem -> fs-a, used by no agent.
      write(
        '.config/maprisma/mcp-servers.json',
        jsonEncode({
          'servers': {'filesystem': _a},
        }),
      );
      write(
        '.claude.json',
        jsonEncode({
          'mcpServers': {
            'filesystem': {'command': 'fs-b'},
          },
        }),
      );
      final inventory = core.reads.inventory.collect(core.reads.catalog.scan());
      expect(library().keys, ['filesystem', 'filesystem~2']);
      expect(library()['filesystem'], _a);
      expect(library()['filesystem~2'], _b);
      expect(inventory.mcpLibrary['filesystem'], 'filesystem~2');
      final unused = inventory.mcp.singleWhere(
        (s) => (s['agents'] as List).isEmpty,
      );
      expect(unused['target'], 'fs-a');
      expect(inventory.mcpLibrary[unused['id']], 'filesystem');
    });

    test('a changed server is a new one; the saved one keeps its key', () {
      claudeAndCodex();
      core.reads.inventory.collect(core.reads.catalog.scan());
      write(
        '.claude.json',
        jsonEncode({
          'mcpServers': {
            'filesystem': {
              'command': 'fs-a',
              'args': ['--new'],
            },
          },
        }),
      );
      core.reads.inventory.collect(core.reads.catalog.scan());
      expect(library().keys, ['filesystem', 'filesystem~2', 'filesystem~3']);
      expect(library()['filesystem'], _a);
      expect(library()['filesystem~2']['command'], 'fs-b');
      expect(library()['filesystem~3']['args'], ['--new']);
    });
  });

  test('a library key is a name or name~N, and only that', () {
    expect(libraryKeyPattern.hasMatch('filesystem~2'), isTrue);
    expect(libraryKeyPattern.hasMatch('filesystem~'), isFalse);
    expect(libraryKeyPattern.hasMatch('a~2~3'), isFalse);
    expect(mcpBaseName('filesystem~12'), 'filesystem');
    expect(mcpBaseName('file~system'), 'file~system');
    expect(() => toolsCacheFile(home.path, '../x'), throwsFormatException);
    // The same digest as the reference's mcp_ctl.identity_hash.
    expect(mcpIdentityHash({'command': 'fs-b'}), 'a26b0c25c36845b4');
    expect(
      mcpIdentityHash({'url': 'https://example.test:9443/mcp?k=ü'}),
      'eab49f62c0943d7e',
    );
    expect(
      mcpIdentityHash({
        'command': 'fs',
        'env': {'ROOT': '/data/a', 'Ä': 'ü'},
      }),
      'dee19b55720f91e8',
    );
    expect(
      mcpIdentityHash({
        'url': 'https://x.test/mcp',
        'headers': {'X-Workspace': 'b'},
      }),
      '9cde67ee6fefe0a6',
    );
  });
}
