import 'dart:convert';
import 'dart:io';
import 'package:maprisma_core/maprisma_core.dart';
import 'package:maprisma_core/src/agent_catalog.dart';
import 'package:maprisma_core/src/agent_details.dart';
import 'package:maprisma_core/src/inventory.dart';
import 'package:maprisma_core/src/provider_scans.dart';
import 'package:test/test.dart';

/// Review 063 (Codex): the map's agent → provider → model chain.
void main() {
  late Directory home;
  late CoreService core;
  setUp(() {
    home = Directory.systemTemp.createTempSync('chain');
    Directory('${home.path}/proc').createSync();
    core = CoreService(
      environment: {
        'HOME': home.path,
        'PATH': '${home.path}/bin',
        'MAPRISMA_DESKTOP': 'generic',
        'MAPRISMA_SCAN_PROC': '${home.path}/proc',
      },
    );
  });
  tearDown(() => home.deleteSync(recursive: true));

  void write(String path, String text) => File('${home.path}/$path')
    ..createSync(recursive: true)
    ..writeAsStringSync(text);
  AgentRecord agent(String command) => AgentRecord(
    core.reads.catalog.adapter(command)!,
    name: command,
    icon: '',
    installed: true,
  );
  RuntimeRecord llama(String address, List<String> models) =>
      RuntimeRecord('llamacpp', 'llama.cpp')
        ..installed = true
        ..running = true
        ..address = address
        ..models = models;
  Set<(String, String, String)> edges(Map graph) => {
    for (final e in (graph['edges'] as List).cast<Map>())
      ('${e['source']}', '${e['target']}', '${e['kind']}'),
  };
  Map<String, Map> nodes(Map graph) => {
    for (final n in (graph['nodes'] as List).cast<Map>()) '${n['id']}': n,
  };

  test('F4: a configured port finds the runtime detected there', () {
    final provider = core.reads.details.provider(
      'llama',
      'http://127.0.0.1:9090/v1',
    );
    expect(provider['runtime'], '');
    final info = AgentInfo()
      ..model = 'qwen (llama)'
      ..providers.add(provider);
    final inv = InventorySnapshot()
      ..runtimes.add(llama('127.0.0.1:9090', ['qwen']));
    final graph = core.reads.graph.build([agent('pi')], {'pi': info}, inv);
    expect(edges(graph), contains(('agent:pi', 'runtime:llamacpp', 'uses')));
    expect(
      edges(graph),
      contains(('agent:pi', 'model:runtime:llamacpp:qwen', 'default')),
    );
    // Its usual port still finds it when nothing is detected on another.
    inv.runtimes.single.address = '';
    expect(
      localRuntime(
        core.reads.details.provider('llama', 'http://127.0.0.1:8080/v1'),
        inv.runtimes,
      ),
      same(inv.runtimes.single),
    );
  });

  test('F5, F7: an unqualified model on a local endpoint is that LLM\'s', () {
    final info = AgentInfo()
      ..model = 'qwen'
      ..providers.add(
        core.reads.details.provider('Anthropic API', 'http://localhost:8080'),
      );
    final inv = InventorySnapshot()
      ..runtimes.add(llama('127.0.0.1:8080', ['qwen', 'gemma']));
    final graph = core.reads.graph.build(
      [agent('claude')],
      {'claude': info},
      inv,
      running: {
        'claude': ['gemma'],
      },
    );
    expect(
      edges(graph),
      contains(('agent:claude', 'model:runtime:llamacpp:qwen', 'default')),
    );
    expect(nodes(graph).values.where((n) => n['kind'] == 'cloud'), isEmpty);
    expect(nodes(graph)['model:runtime:llamacpp:gemma']!['status'], 'running');
  });

  test('F6: the models in use are drawn past the first ten; a gone one '
      'stays, missing', () {
    final provider = core.reads.details.provider(
      'llama',
      'http://127.0.0.1:8080/v1',
    );
    final inv = InventorySnapshot()
      ..runtimes.add(
        llama('127.0.0.1:8080', [
          for (var i = 0; i < 12; i++) 'm${'$i'.padLeft(2, '0')}',
        ]),
      );
    AgentInfo set(String model) => AgentInfo()
      ..model = '$model (llama)'
      ..providers.add(provider);
    var graph = core.reads.graph.build(
      [agent('pi')],
      {'pi': set('m10')},
      inv,
      providerModels: {'runtime:llamacpp': 'model:runtime:llamacpp:m11'},
    );
    expect(
      edges(graph),
      contains(('agent:pi', 'model:runtime:llamacpp:m10', 'default')),
    );
    expect(nodes(graph), contains('model:runtime:llamacpp:m11'));
    expect(nodes(graph), isNot(contains('more:runtime:llamacpp')));
    graph = core.reads.graph.build([agent('pi')], {'pi': set('gone')}, inv);
    final gone = nodes(graph)['model:runtime:llamacpp:gone']!;
    expect([gone['status'], gone['label']], ['missing', 'gone']);
    expect(
      edges(graph),
      containsAll([
        ('agent:pi', 'model:runtime:llamacpp:gone', 'default'),
        ('runtime:llamacpp', 'model:runtime:llamacpp:gone', 'serves'),
      ]),
    );
    expect(nodes(graph)['more:runtime:llamacpp']!['label'], '+2 more');
  });

  test('F17: an own provider without its sign-in is one it can use', () {
    Map build() => core.reads.graph.build(
      [agent('codex')],
      {'codex': AgentInfo()..model = 'gpt-6.1-sol'},
      InventorySnapshot(),
    );
    expect(
      edges(build()),
      contains(('agent:codex', 'cloud:openai', 'available')),
    );
    expect(nodes(build())['agent:codex']!['own_provider'], 'cloud:openai');
    write('.codex/auth.json', '{}');
    expect(edges(build()), contains(('agent:codex', 'cloud:openai', 'uses')));
  });

  test('#16: a key it names but is not set is no sign-in; nor a drop', () {
    // Grok names no sign-in file, only XAI_API_KEY.
    Map build(Map<String, String> extra) {
      final service = CoreService(
        environment: {
          'HOME': home.path,
          'PATH': '${home.path}/bin',
          'MAPRISMA_DESKTOP': 'generic',
          'MAPRISMA_SCAN_PROC': '${home.path}/proc',
          ...extra,
        },
      );
      return service.reads.graph.build(
        [
          AgentRecord(
            service.reads.catalog.adapter('grok')!,
            name: 'grok',
            icon: '',
            installed: true,
          ),
        ],
        {'grok': AgentInfo()..model = 'grok-5'},
        InventorySnapshot(),
      );
    }

    expect(
      edges(build({})),
      contains(('agent:grok', 'cloud:xai', 'available')),
    );
    expect(
      edges(build({'XAI_API_KEY': 'set'})),
      contains(('agent:grok', 'cloud:xai', 'uses')),
    );
    // Its own provider, but no sign-in the app can start (Ask AI refuses it
    // too); Codex has one.
    final grok = nodes(build({}))['agent:grok']!;
    expect([grok['own_provider'], grok['own_login']], ['cloud:xai', false]);
    final codex = core.reads.graph.build(
      [agent('codex')],
      {},
      InventorySnapshot(),
    );
    expect(nodes(codex)['agent:codex']!['own_login'], isTrue);
  });

  test('F2: servers of one name but other commands stay two boxes', () {
    write(
      '.claude.json',
      jsonEncode({
        'mcpServers': {
          'filesystem': {'command': 'fs-a'},
        },
      }),
    );
    write('.codex/config.toml', '[mcp_servers.filesystem]\ncommand = "fs-b"\n');
    final agents = [agent('claude'), agent('codex')];
    final inv = core.reads.inventory.collect(agents, remember: false);
    final servers = {for (final s in inv.mcp) s['id']: s};
    expect(servers['filesystem']!['target'], 'fs-a');
    expect(servers['filesystem~2']!['target'], 'fs-b');
    expect(servers['filesystem~2']!['agents'], ['codex']);
    final graph = core.reads.graph.build(agents, {}, inv);
    expect(
      edges(graph),
      containsAll([
        ('agent:claude', 'mcp:filesystem', 'mcp'),
        ('agent:codex', 'mcp:filesystem~2', 'mcp'),
      ]),
    );
    expect(nodes(graph)['mcp:filesystem~2']!['label'], 'filesystem');
  });

  test('F8: LM Studio and Jan on other ports', () {
    RuntimeRecord scan(String key) =>
        core.reads.inventory.providers.scan().singleWhere((r) => r.key == key);
    write(
      '.lmstudio/.internal/http-server-config.json',
      jsonEncode({'port': 4321}),
    );
    expect(scan('lmstudio').address, '127.0.0.1:4321');
    write('.lmstudio/.internal/http-server-config.json', '{}');
    expect(scan('lmstudio').address, '127.0.0.1:1234');
    expect(scan('jan').address, '127.0.0.1:6767');
    write(
      '.config/systemd/user/jan.service',
      "[Service]\nExecStart=/bin/sh -c 'exec w --port 7001'\n",
    );
    expect(
      [scan('jan').address, scan('jan').running],
      ['127.0.0.1:7001', false],
    );
    write('proc/9/comm', 'jan-llama-worke\n');
    write(
      'proc/9/cmdline',
      [
        'jan-llama-worker',
        '--preset',
        'p.ini',
        '--port',
        '7002',
        '',
      ].join('\x00'),
    );
    expect(
      [scan('jan').address, scan('jan').running],
      ['127.0.0.1:7002', true],
    );
  });

  test('F11: a reused model folder is on the map', () {
    write('Old/models/qwen-7b-Q4_K_M.gguf', '');
    final inv = core.reads.inventory.collect(
      [],
      remember: false,
      modelFolders: ['${home.path}/Old/models'],
    );
    expect(inv.modelFolders, [
      {
        'path': '~/Old/models',
        'models': ['qwen-7b-Q4_K_M'],
      },
    ]);
    final node = nodes(
      core.reads.graph.build([], {}, inv),
    )['model:folder:~/Old/models:qwen-7b-q4_k_m']!;
    expect([node['kind'], node['group']], ['model', '~/Old/models']);
    // Saved in Settings, the map's own scan finds it.
    File('${home.path}/.config/maprisma/settings.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'model_folders': ['${home.path}/Old/models'],
        }),
      );
    expect(
      nodes(core.reads.buildMap()),
      contains('model:folder:~/Old/models:qwen-7b-q4_k_m'),
    );
  });
}
