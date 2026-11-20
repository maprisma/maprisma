import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:maprisma_core/src/core.dart';
import 'package:maprisma_core/src/connect_apply.dart';
import 'package:maprisma_core/src/agent_details.dart' show yamlMap;
import 'package:maprisma_core/src/llm_plans.dart';
import 'support/provider_config_fixture.dart';

void main() {
  late Directory home;
  late CoreService service;
  void write(String relative, String text) {
    final file = File('${home.path}/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  setUp(() {
    home = Directory.systemTemp.createTempSync('config-agent-contexts');
    for (final binary in ['llama-server', 'ollama', 'pi', 'hermes']) {
      write('bin/$binary', '#!/bin/sh\nexit 0\n');
      Process.runSync('chmod', ['+x', '${home.path}/bin/$binary']);
    }
    service = CoreService(
      environment: {
        'HOME': home.path,
        'PATH': '${home.path}/bin',
        'MAPRISMA_DESKTOP': 'generic',
        'MAPRISMA_SCAN_PROC': '${home.path}/proc',
        'MAPRISMA_SCAN_GPU': '${home.path}/gpu',
      },
      migrate: false,
    );
  });
  tearDown(() {
    service.dispose();
    home.deleteSync(recursive: true);
  });

  List<String> seed(String key, {List<String> betaOverrides = const []}) {
    final names = key == 'ollama'
        ? ['alpha:latest', 'beta:latest']
        : ['alpha', 'beta'];
    final provider = key == 'ollama' ? 'ollama-local' : 'llama-local';
    final facts = configFixture(key: key);
    final prototype = Map<String, dynamic>.from(
      (facts['models'] as List).single,
    );
    final context = key == 'ollama' ? 'OLLAMA_CONTEXT_LENGTH' : 'ctx-size';
    final parallel = key == 'ollama' ? 'OLLAMA_NUM_PARALLEL' : 'parallel';
    facts['models'] = [
      for (final name in names) {...prototype, 'name': name},
    ];
    facts['settings'] = {
      '*': {context: 8192, parallel: 1},
      for (final name in names)
        name: {
          context: name == names.last && betaOverrides.contains('ctx-size')
              ? 12288
              : 8192,
          parallel: 1,
        },
    };
    facts['configured'] = {
      for (final name in ['*', ...names]) name: [context, parallel],
    };
    facts['overrides'] = {names.last: betaOverrides};
    (facts['defaults'] as Map).addAll({context: 8192, parallel: 1});
    if (key == 'ollama') {
      write(
        '.config/ollama/server.env',
        'OLLAMA_CONTEXT_LENGTH=8192\nOLLAMA_NUM_PARALLEL=1\n',
      );
      write(
        '.config/systemd/user/ollama.service',
        '[Unit]\nDescription=Ollama (installed by Maprisma)\n[Service]\nExecStart=${home.path}/bin/ollama serve\n',
      );
      for (final name in ['alpha', 'beta']) {
        write(
          '.ollama/models/manifests/registry.ollama.ai/library/$name/latest',
          '{}',
        );
      }
    } else {
      write(
        '.config/llama.cpp/models.ini',
        'version = 1\n[*]\nctx-size = 8192\nparallel = 1\n[alpha]\n[beta]\n${betaOverrides.contains('ctx-size') ? 'ctx-size = 12288\n' : ''}${betaOverrides.contains('parallel') ? 'parallel = 1\n' : ''}',
      );
    }
    write(
      '.pi/agent/models.json',
      jsonEncode({
        'providers': {
          provider: {
            'baseUrl': 'http://127.0.0.1:8080/v1',
            'models': [
              for (final name in names) {'id': name, 'contextWindow': 8192},
            ],
          },
        },
      }),
    );
    write(
      '.pi/agent/settings.json',
      jsonEncode({'defaultProvider': provider, 'defaultModel': names.first}),
    );
    write(
      '.hermes/config.yaml',
      'model:\n  provider: $provider\n  default: ${names.first}\nproviders:\n  $provider:\n    name: Fixture\n    api: http://127.0.0.1:8080/v1\n    api_key: local\n    default_model: ${names.first}\n    models:\n${[for (final name in names) '      $name:\n        context_length: 8192\n'].join()}',
    );
    service.configCache.keep(key, facts);
    return names;
  }

  List<Change> preview(String key, Map<String, dynamic> values) {
    final result = service.configRoute('models.config_preview', {
      'key': key,
      'model': key == 'ollama' ? '' : '*',
      'values': values,
    });
    expect(result['ok'], true, reason: '$result');
    return service.connections.take(result['plan'] as String).changes;
  }

  void expectContexts(
    List<Change> changes,
    String provider,
    Map<String, int> contexts,
  ) {
    final pi = changes.singleWhere(
      (c) => c.path.endsWith('/.pi/agent/models.json'),
    );
    final models =
        (jsonDecode(pi.next)['providers'][provider]['models'] as List)
            .cast<Map>();
    expect({for (final m in models) m['id']: m['contextWindow']}, contexts);
    final hermes = changes.singleWhere(
      (c) => c.path.endsWith('/.hermes/config.yaml'),
    );
    final next = yamlMap(hermes.next);
    expect(next['providers'][provider]['default_model'], contexts.keys.first);
    expect(next['model']['default'], contexts.keys.first);
    final saved = next['providers'][provider]['models'] as Map;
    expect({
      for (final e in saved.entries) e.key: e.value['context_length'],
    }, contexts);
  }

  test(
    'total contexts are synchronized per slot for every model and keep Hermes selection',
    () {
      final names = seed('llamacpp');
      expectContexts(
        preview('llamacpp', {'ctx-size': 32768, 'parallel': 4}),
        'llama-local',
        {for (final name in names) name: 8192},
      );
    },
  );
  test('Ollama contexts remain per slot when parallel requests increase', () {
    final names = seed('ollama');
    expectContexts(
      preview('ollama', {
        'OLLAMA_CONTEXT_LENGTH': 16384,
        'OLLAMA_NUM_PARALLEL': 4,
      }),
      'ollama-local',
      {for (final name in names) name: 16384},
    );
  });
  for (final overrideParallel in [true, false]) {
    test(
      'default edits preserve model overrides (parallel override $overrideParallel)',
      () {
        seed(
          'llamacpp',
          betaOverrides: ['ctx-size', if (overrideParallel) 'parallel'],
        );
        expectContexts(
          preview('llamacpp', {'ctx-size': 32768, 'parallel': 2}),
          'llama-local',
          {'alpha': 16384, 'beta': overrideParallel ? 12288 : 6144},
        );
      },
    );
  }
  test('non-context edits leave agent files absent from the preview', () {
    seed('llamacpp');
    final changes = preview('llamacpp', {'threads': 4, 'batch-size': 1024});
    expect(changes.map((c) => c.path), [
      '${home.path}/.config/llama.cpp/models.ini',
    ]);
  });
  test('Ollama parallel alone has no effect on agent per-slot contexts', () {
    seed('ollama');
    final changes = preview('ollama', {'OLLAMA_NUM_PARALLEL': 2});
    expect(changes.map((c) => c.path), [
      '${home.path}/.config/ollama/server.env',
    ]);
  });
  for (final model in ['alpha', '']) {
    test(
      'Hermes preserves the existing default model "$model" for context-only updates',
      () {
        final old =
            'providers:\n  llama-local:\n    name: Fixture\n    api: http://127.0.0.1:8080/v1\n    default_model: $model\n    discover_models: false\n    models:\n      alpha: {}\n';
        final next = hermesLlmText(
          old,
          'llama-local',
          'Fixture',
          'http://127.0.0.1:8080/v1',
          ['alpha'],
          {'alpha': 16384},
          '',
          false,
          false,
        );
        final parsed = yamlMap(next);
        expect(
          parsed['providers']['llama-local']['default_model'],
          model.isEmpty ? isNull : model,
        );
        expect(
          parsed['providers']['llama-local']['models']['alpha']['context_length'],
          16384,
        );
      },
    );
  }
}
