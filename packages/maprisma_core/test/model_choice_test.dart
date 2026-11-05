// Task 063f: a provider's models, review 063 round 2 (#6, #7, #8).
import 'dart:convert';
import 'dart:io';
import 'package:maprisma_core/maprisma_core.dart';
import 'package:maprisma_core/src/llm_plans.dart';
import 'package:maprisma_core/src/smart_card.dart';
import 'package:test/test.dart';

const gone = 'model:runtime:llamacpp:gone',
    qwen = 'model:runtime:llamacpp:qwen',
    gemma = 'model:runtime:llamacpp:gemma';

/// Pi on llama.cpp with qwen and gemma in its
/// cache, set to [model]; [chosen] is llama.cpp's own model.
({Directory home, CoreService core}) llamaSetup(
  String model, {
  String? chosen,
}) {
  final home = Directory.systemTemp.createTempSync('model-choice');
  addTearDown(() => home.deleteSync(recursive: true));
  final bin = Directory('${home.path}/bin')..createSync();
  for (final command in ['pi', 'llama-server', 'claude']) {
    File('${bin.path}/$command').writeAsStringSync('#!/bin/sh\necho 1.0.0\n');
    Process.runSync('chmod', ['+x', '${bin.path}/$command']);
  }
  for (final name in ['qwen', 'gemma']) {
    File('${home.path}/.cache/llama.cpp/$name.gguf')
      ..createSync(recursive: true)
      ..writeAsStringSync('');
  }
  final (models, settings) = piLlmTexts(
    '',
    '',
    'llama-local',
    'http://127.0.0.1:8080/v1',
    [model],
    const {},
    model,
    true,
    false,
  );
  File('${home.path}/.pi/agent/models.json')
    ..createSync(recursive: true)
    ..writeAsStringSync(models);
  File('${home.path}/.pi/agent/settings.json').writeAsStringSync(settings);
  if (chosen != null) {
    File('${home.path}/.config/maprisma/settings.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'provider_models': {'runtime:llamacpp': chosen},
        }),
      );
  }
  // The worker that applies a plan: this package's own core, on this home
  // only (no process of this PC, so no model is loaded anywhere).
  final worker = File('${home.path}/worker')
    ..writeAsStringSync(
      '#!/bin/sh\nexport HOME="${home.path}" PATH="${bin.path}" '
      'MAPRISMA_SCAN_PROC="${home.path}/proc" '
      'MAPRISMA_SCAN_SYSTEM_ROOT="${home.path}"\n'
      'exec "${Platform.resolvedExecutable}" '
      '--disable-dart-dev '
      '--packages="${Directory.current.path}/.dart_tool/package_config.json" '
      '"${Directory.current.path}/bin/maprisma-core.dart" "\$@"\n',
    );
  Process.runSync('chmod', ['+x', worker.path]);
  final core = CoreService(
    environment: {
      'HOME': home.path,
      'PATH': bin.path,
      'MAPRISMA_DESKTOP': 'generic',
      'MAPRISMA_SCAN_PROC': '${home.path}/proc',
      'MAPRISMA_SCAN_SYSTEM_ROOT': home.path,
      'MAPRISMA_CORE_WORKER': worker.path,
    },
  );
  return (home: home, core: core);
}

Future<Map<String, dynamic>> mapOf(CoreService core) async {
  var graph = core.dispatch('map.snapshot', {'force': true});
  for (var i = 0; i < 100 && graph['pending'] == true; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    graph = core.dispatch('map.snapshot', {'poll': true});
  }
  return graph;
}

Map<String, dynamic> saved(Directory home) =>
    jsonDecode(
          File(
            '${home.path}/.config/maprisma/settings.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

String piModel(Directory home) =>
    '${(jsonDecode(File('${home.path}/.pi/agent/settings.json').readAsStringSync()) as Map)['defaultModel']}';

/// connections.apply through the worker, to its result.
Future<Map> apply(CoreService core, String plan) =>
    finish(core, core.dispatch('connections.apply', {'plan': plan}));

/// A started connections.apply, to its result.
Future<Map> finish(CoreService core, Map started) async {
  var status = core.dispatch('tasks.status', {'task': started['task']});
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (status['state'] == 'running' && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    status = core.dispatch('tasks.status', {'task': started['task']});
  }
  expect(status['state'], 'done', reason: '$status');
  return status['result'] as Map;
}

void main() {
  test('#6: a missing model\'s line moves to one the LLM has', () async {
    final (:home, :core) = llamaSetup('gone');
    final graph = await mapOf(core);
    final node = (graph['nodes'] as List).cast<Map>().singleWhere(
      (n) => n['id'] == gone,
    );
    expect(node['status'], 'missing');
    final preview = core.dispatch('models.switch_preview', {
      'provider': 'runtime:llamacpp',
      'old': gone,
      'new': qwen,
    });
    expect(preview['empty'], isFalse);
    expect(preview['agents'], ['Pi']);
    // Nothing to unload: only the new one is loaded.
    expect(preview['model_actions'], [
      {'operation': 'model.load', 'model': 'qwen'},
    ]);
    final result = await apply(core, preview['plan'] as String);
    expect(piModel(home), 'qwen');
    core.dispatch('connections.undo', {'undo': result['undo']});
    expect(piModel(home), 'gone');
    // Only the new one must be there.
    expect(
      () => core.dispatch('models.switch_preview', {
        'provider': 'runtime:llamacpp',
        'old': gone,
        'new': gone,
      }),
      throwsFormatException,
    );
  });

  group('#7: a provider\'s own model is one it has', () {
    test('a missing model is refused, with the reason', () async {
      final (:home, :core) = llamaSetup('gone');
      await mapOf(core);
      expect(
        () => core.dispatch('models.choose_preview', {
          'provider': 'runtime:llamacpp',
          'model': gone,
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'This model is no longer on this PC.',
          ),
        ),
      );
      expect(
        File('${home.path}/.config/maprisma/settings.json').existsSync(),
        isFalse,
      );
    });

    test('one deleted since the map, or before Apply, is refused', () async {
      final (:home, :core) = llamaSetup('qwen');
      await mapOf(core);
      File('${home.path}/.cache/llama.cpp/gemma.gguf').deleteSync();
      expect(
        () => core.dispatch('models.choose_preview', {
          'provider': 'runtime:llamacpp',
          'model': gemma,
        }),
        throwsFormatException,
      );
      final preview = core.dispatch('models.choose_preview', {
        'provider': 'runtime:llamacpp',
        'model': qwen,
      });
      File('${home.path}/.cache/llama.cpp/qwen.gguf').deleteSync();
      expect(
        () => core.dispatch('models.choose_apply', {
          'preview': preview['preview'],
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'This model is no longer on this PC.',
          ),
        ),
      );
      expect(
        File('${home.path}/.config/maprisma/settings.json').existsSync(),
        isFalse,
      );
    });

    test('Ask AI does not offer a missing model', () {
      final facts = {
        'map_nodes': [
          {'id': 'runtime:llamacpp', 'kind': 'runtime', 'label': 'llama.cpp'},
          {'id': gone, 'kind': 'model', 'label': 'gone', 'status': 'missing'},
        ],
        'provider_models': const {},
      };
      expect(
        () => smartModelAction({
          'action': 'choose',
          'provider': 'runtime:llamacpp',
          'model': gone,
        }, facts),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            smartMapChatModel,
          ),
        ),
      );
    });

    test('Ask AI\'s facts say which model is missing', () async {
      final (:home, :core) = llamaSetup('gone');
      final nodes = smartMapNodes(await mapOf(core));
      expect(nodes.singleWhere((n) => n['id'] == gone)['status'], 'missing');
      expect(
        nodes.singleWhere((n) => n['id'] == qwen),
        isNot(contains('status')),
      );
      expect(home.existsSync(), isTrue);
    });
  });

  test('#8: the provider\'s choice moves with its agents, one Undo', () async {
    final (:home, :core) = llamaSetup('gemma', chosen: gemma);
    await mapOf(core);
    final preview = core.dispatch('models.switch_preview', {
      'provider': 'runtime:llamacpp',
      'old': gemma,
      'new': qwen,
    });
    // Nothing is written before Apply.
    expect(saved(home)['provider_models'], {'runtime:llamacpp': gemma});
    final result = await apply(core, preview['plan'] as String);
    expect(piModel(home), 'qwen');
    expect(saved(home)['provider_models'], {'runtime:llamacpp': qwen});
    // Another setting meanwhile stays.
    core.dispatch('settings.update', {
      'values': {'flutter_theme_mode': 'dark'},
    });
    core.dispatch('connections.undo', {'undo': result['undo']});
    expect(piModel(home), 'gemma');
    expect(saved(home)['provider_models'], {'runtime:llamacpp': gemma});
    expect(saved(home)['flutter_theme_mode'], 'dark');
  });

  test('#8: a choice changed since the preview refuses its Apply', () async {
    final (:home, :core) = llamaSetup('gemma', chosen: gemma);
    await mapOf(core);
    final preview = core.dispatch('models.switch_preview', {
      'provider': 'runtime:llamacpp',
      'old': gemma,
      'new': qwen,
    });
    // Chosen otherwise meanwhile.
    core.dispatch('models.choose_apply', {
      'preview': core.dispatch('models.choose_preview', {
        'provider': 'runtime:llamacpp',
        'model': qwen,
      })['preview'],
    });
    expect(
      () => core.dispatch('connections.apply', {'plan': preview['plan']}),
      throwsFormatException,
    );
    expect(piModel(home), 'gemma');
  });

  group('review 063 round 3', () {
    Future<(Directory, CoreService, Map)> switched() async {
      final (:home, :core) = llamaSetup('gemma', chosen: gemma);
      await mapOf(core);
      final preview = core.dispatch('models.switch_preview', {
        'provider': 'runtime:llamacpp',
        'old': gemma,
        'new': qwen,
      });
      return (home, core, preview);
    }

    test(
      '#2: a choice changed while the worker ran is said, with Undo',
      () async {
        final (home, core, preview) = await switched();
        final started = core.dispatch('connections.apply', {
          'plan': preview['plan'],
        });
        // Before the worker answers: llama.cpp is set to no model of its own.
        core.dispatch('models.choose_apply', {
          'preview': core.dispatch('models.choose_preview', {
            'provider': 'runtime:llamacpp',
            'model': null,
          })['preview'],
        });
        final result = await finish(core, started);
        expect(piModel(home), 'qwen');
        expect(result['choice_failures'], 1);
        expect(result['undo'], isA<String>());
        expect(saved(home)['provider_models'], isEmpty);
        // Its Undo puts the files back and leaves that later choice alone.
        final undone = core.dispatch('connections.undo', {
          'undo': result['undo'],
        });
        expect(piModel(home), 'gemma');
        expect(undone['choice_failures'], 0);
        expect(saved(home)['provider_models'], isEmpty);
      },
    );

    test('#2: settings that cannot be saved still return the Undo', () async {
      final (home, core, preview) = await switched();
      core.connections.chooseModel = (_, _, _) =>
          throw const FileSystemException('read-only');
      final result = await apply(core, preview['plan'] as String);
      expect(piModel(home), 'qwen');
      expect(result['ok'], isTrue);
      expect(result['choice_failures'], 1);
      expect(saved(home)['provider_models'], {'runtime:llamacpp': gemma});
      core.dispatch('connections.undo', {'undo': result['undo']});
      expect(piModel(home), 'gemma');
    });

    test(
      '#3: an agent file changed since keeps its provider\'s choice',
      () async {
        final (home, core, preview) = await switched();
        final result = await apply(core, preview['plan'] as String);
        expect(result['choice_failures'], 0);
        expect(saved(home)['provider_models'], {'runtime:llamacpp': qwen});
        // Pi's settings changed by hand since: its Undo skips that file.
        final settings = File('${home.path}/.pi/agent/settings.json');
        settings.writeAsStringSync('${settings.readAsStringSync()}\n');
        final undone = core.dispatch('connections.undo', {
          'undo': result['undo'],
        });
        expect(
          undone['restored'],
          isNot(contains('~/.pi/agent/settings.json')),
        );
        expect(piModel(home), 'qwen');
        expect(undone['choice_failures'], 1);
        expect(saved(home)['provider_models'], {'runtime:llamacpp': qwen});
      },
    );

    /// llama.cpp now runs on 9090; Pi is still set to 8080.
    void moved(Directory home) {
      File('${home.path}/proc/77/comm')
        ..createSync(recursive: true)
        ..writeAsStringSync('llama-server\n');
      File(
        '${home.path}/proc/77/cmdline',
      ).writeAsStringSync('llama-server\x00--port\x009090\x00');
    }

    Map failedLine(Map graph, String agent) => (graph['edges'] as List)
        .cast<Map>()
        .singleWhere((e) => e['source'] == agent && e['kind'] == 'failed');

    test(
      '#7: Repair rewrites an inactive moved provider, not its use',
      () async {
        final (:home, :core) = llamaSetup('qwen');
        moved(home);
        final settings = File('${home.path}/.pi/agent/settings.json')
          ..writeAsStringSync(
            jsonEncode({'defaultProvider': 'openai', 'defaultModel': 'gpt-5'}),
          );
        final line = failedLine(await mapOf(core), 'agent:pi');
        expect([line['target'], line['dangling']], ['runtime:llamacpp', '']);
        final preview = core.dispatch('connections.repair_preview', {
          'agent': 'agent:pi',
          'target': 'runtime:llamacpp',
        });
        await apply(core, preview['plan'] as String);
        expect(
          File('${home.path}/.pi/agent/models.json').readAsStringSync(),
          contains('127.0.0.1:9090'),
        );
        expect(jsonDecode(settings.readAsStringSync()), {
          'defaultProvider': 'openai',
          'defaultModel': 'gpt-5',
        });
      },
    );

    test(
      'R4 #2: Repair rewrites the agent\'s own name for the moved LLM',
      () async {
        final (:home, :core) = llamaSetup('qwen');
        moved(home);
        final (models, _) = piLlmTexts(
          '',
          '',
          'workstation',
          'http://127.0.0.1:8080/v1',
          ['qwen'],
          const {},
          'qwen',
          false,
          false,
        );
        final file = File('${home.path}/.pi/agent/models.json')
          ..writeAsStringSync(models);
        File('${home.path}/.pi/agent/settings.json').writeAsStringSync(
          jsonEncode({'defaultProvider': 'openai', 'defaultModel': 'gpt-5'}),
        );
        final line = failedLine(await mapOf(core), 'agent:pi');
        expect(line['provider'], 'workstation');
        final preview = core.dispatch('connections.repair_preview', {
          'agent': 'agent:pi',
          'target': 'runtime:llamacpp',
        });
        await apply(core, preview['plan'] as String);
        final providers =
            (jsonDecode(file.readAsStringSync()) as Map)['providers'] as Map;
        expect(providers.keys, ['workstation']);
        expect('${providers['workstation']}', contains('127.0.0.1:9090'));
        // A name the agent does not have is refused.
        expect(
          () => core.dispatch('connections.preview', {
            'kind': 'provider',
            'command': 'pi',
            'item': 'llamacpp',
            'remove': false,
            'model': 'qwen',
            'use_now': false,
            'name': 'elsewhere',
          }),
          throwsA(anything),
        );
      },
    );

    test('#8: Claude Code\'s moved endpoint is not offered a Repair', () async {
      final (:home, :core) = llamaSetup('qwen');
      moved(home);
      File('${home.path}/.claude/settings.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'model': 'qwen',
            'env': {'ANTHROPIC_BASE_URL': 'http://localhost:8080'},
          }),
        );
      final line = failedLine(await mapOf(core), 'agent:claude');
      expect(line['target'], 'runtime:llamacpp');
      expect(line['fixed'], contains('127.0.0.1:9090'));
      expect(line['hints'], isNull);
      expect(
        () => core.dispatch('connections.repair_preview', {
          'agent': 'agent:claude',
          'target': 'runtime:llamacpp',
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('own settings'),
          ),
        ),
      );
    });
  });
}
