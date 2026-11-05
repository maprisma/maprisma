// Task 063d: Ask AI reaches the manual menus (review 063, F12 to F16, F21).
import 'dart:convert';
import 'dart:io';
import 'package:maprisma_core/maprisma_core.dart';
import 'package:maprisma_core/src/action_rules.dart';
import 'package:maprisma_core/src/llm_plans.dart';
import 'package:maprisma_core/src/smart_card.dart';
import 'package:test/test.dart';

SmartAgent reply(String answer) =>
    (_) async => answer;

Map<String, dynamic> single(Map<String, dynamic> result) =>
    Map<String, dynamic>.from((result['candidates'] as List).single as Map);

/// Pi on Ollama with two models, its default the second; this PC's own
/// processes and system folders are left out of the scan.
({Directory home, CoreService core}) localSetup({List? rules}) {
  final home = Directory.systemTemp.createTempSync('ask-menus');
  addTearDown(() => home.deleteSync(recursive: true));
  final bin = Directory('${home.path}/bin')..createSync();
  for (final command in ['pi', 'ollama', 'claude']) {
    File('${bin.path}/$command').writeAsStringSync('#!/bin/sh\necho 1.0.0\n');
    Process.runSync('chmod', ['+x', '${bin.path}/$command']);
  }
  for (final (model, tag) in [('qwen3', '8b'), ('gemma3', '1b')]) {
    File(
        '${home.path}/.ollama/models/manifests/registry.ollama.ai/library/'
        '$model/$tag',
      )
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
  }
  final (models, settings) = piLlmTexts(
    '',
    '',
    'ollama-local',
    'http://127.0.0.1:11434/v1',
    ['gemma3:1b', 'qwen3:8b'],
    const {},
    'gemma3:1b',
    true,
    false,
  );
  File('${home.path}/.pi/agent/models.json')
    ..createSync(recursive: true)
    ..writeAsStringSync(models);
  File('${home.path}/.pi/agent/settings.json').writeAsStringSync(settings);
  if (rules != null) {
    File('${home.path}/.config/maprisma/settings.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'action_rules': rules}));
  }
  final core = CoreService(
    environment: {
      'HOME': home.path,
      'PATH': bin.path,
      'MAPRISMA_DESKTOP': 'generic',
      'MAPRISMA_SCAN_PROC': '${home.path}/proc',
      'MAPRISMA_SCAN_SYSTEM_ROOT': home.path,
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

List<Map<String, dynamic>> allowAll([
  List<Map<String, dynamic>> more = const [],
]) => [...defaultActionRules, ...more];

Map<String, dynamic> deny(
  String action,
  String category, [
  String item = '*',
]) => {
  'effect': 'deny',
  'action': action,
  'category': category,
  'item': item,
  'agent': '*',
};

void main() {
  group('F12/F13: connecting a model after its download', () {
    test('the download names the agents the manual Connect offers', () async {
      final facts = {
        'request': 'a model for ollama',
        'limits': {'vram': 16 << 30, 'ram': 32 << 30, 'free_disk': 100 << 30},
        'runtimes': [
          {
            'key': 'llamacpp',
            'name': 'llama.cpp',
            'download': 'file',
            'models': <String>[],
          },
        ],
        'connect_agents': [
          {'command': 'pi', 'name': 'Pi'},
        ],
      };
      var asked = 0;
      final result = await smartModels(
        facts,
        (_) async => asked++ == 0
            ? '{"action": "search", "query": "qwen", "runtime": "llamacpp"}'
            : '{"summary": "", "picks": [{"repo": "a/qwen-GGUF", "reason": "r"}]}',
        (_) async => [
          {'id': 'a/qwen-GGUF', 'pipeline': 'text-generation', 'downloads': 1},
        ],
        (_, _) async => [
          {'name': 'qwen-Q4_K_M', 'quant': 'Q4_K_M', 'size': 1 << 30},
        ],
      );
      expect(single(result)['connect'], [
        {'command': 'pi', 'name': 'Pi'},
      ]);
    });

    test(
      'only an agent that can use a local LLM, and it uses the model now',
      () async {
        final (:home, :core) = localSetup();
        final kept = core.smartProposals.keep({
          'status': 'proposal',
          'candidates': [
            {
              'id': 'c1',
              'fit': 'ok',
              'title': 'qwen3',
              'connect': [
                {'command': 'pi', 'name': 'Pi'},
              ],
              'action': {
                'operation': 'models.download',
                'runtime': 'ollama',
                'model': 'qwen3:8b',
                'repo': 'x/qwen3',
              },
            },
          ],
        });
        final handle = {'proposal': kept['proposal'], 'candidate': 'c1'};
        // Claude has no local LLM connector: the manual Connect does not offer it.
        expect(
          () => core.dispatch('map.smart_connect', {
            ...handle,
            'agent': 'claude',
          }),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'This agent cannot use a local LLM',
            ),
          ),
        );
        // Pi lists both models already; only "use it now" changes its default.
        final plan = core.dispatch('map.smart_connect', {
          ...handle,
          'agent': 'pi',
        });
        expect(plan['empty'], isFalse);
        expect([
          for (final f in plan['files'] as List) '${(f as Map)['path']}',
        ], contains(endsWith('.pi/agent/settings.json')));
        // Its default model moves (one line out, one in), as "Use now" does.
        expect(plan['files'], [
          {'path': '~/.pi/agent/settings.json', 'added': 1, 'removed': 1},
        ]);
      },
    );
  });

  group('F14: an online provider on the map', () {
    final facts = {
      'map_nodes': [
        {'id': 'agent:agy', 'kind': 'agent', 'label': 'Antigravity'},
        {'id': 'agent:pi', 'kind': 'agent', 'label': 'Pi'},
        {'id': 'cloud:google', 'kind': 'cloud', 'label': 'Google'},
        {'id': 'cloud:openai', 'kind': 'cloud', 'label': 'OpenAI'},
      ],
      'own_clouds': {
        'agy': {
          'cloud': 'cloud:google',
          'name': 'Antigravity CLI',
          'login': true,
          'logout': false,
        },
      },
    };
    Map<String, dynamic> connect(String command, String item, bool remove) =>
        smartMapEdit({
          'method': 'connections.preview',
          'params': {
            'kind': 'provider',
            'command': command,
            'item': item,
            'remove': remove,
          },
          'title': 'connect',
        }, facts);

    test('its own provider is its sign-in, the map\'s login route', () {
      for (final item in ['google', 'cloud:google']) {
        final candidate = single(connect('agy', item, false));
        expect(candidate['kind'], 'agent_action');
        expect(candidate['action'], {
          'kind': 'agent_action',
          'command': 'agy',
          'step': 'login',
        });
        expect(
          smartCandidateChecks(candidate).map((c) => (c.action, c.category)),
          [('connect', 'agents')],
        );
      }
    });

    test('another agent\'s provider or no sign-in is refused with why', () {
      expect(
        () => connect('agy', 'openai', false),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            smartCloudForeign,
          ),
        ),
      );
      expect(
        () => connect('pi', 'google', false),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            smartCloudForeign,
          ),
        ),
      );
      expect(
        () => connect('agy', 'google', true),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            smartCloudNoLogin,
          ),
        ),
      );
      // A provider that is not on the map at all stays unavailable.
      expect(() => connect('agy', 'xai', false), throwsFormatException);
    });
  });

  group('F15: the menu actions', () {
    test('agents: the test question through agents.action_preview', () async {
      final facts = {
        'agents': [
          {'command': 'pi', 'name': 'Pi', 'verify': true, 'key': false},
        ],
      };
      final verify = single(
        await smartAgents(
          facts,
          reply('{"action": "verify", "agents": ["pi"]}'),
        ),
      );
      expect(verify['kind'], 'agent_action');
      expect(verify['action'], {
        'kind': 'agent_action',
        'command': 'pi',
        'step': 'verify',
      });
      expect(
        smartCandidateChecks(verify).map((c) => (c.action, c.category, c.item)),
        [('start', 'agents', 'pi')],
      );
      // Only what is true for the agent.
      expect(
        () => smartAgents(facts, reply('{"action": "key", "agents": ["pi"]}')),
        throwsFormatException,
      );
    });

    test('agents: each menu step, checked as its own route', () async {
      const steps = {
        'key': ('connect', 'agents'),
        'security': ('update', 'agents'),
        'start': ('start', 'agents'),
        'halt': ('stop', 'agents'),
        'configure': null,
        'details': null,
      };
      final facts = {
        'agents': [
          {
            'command': 'pi',
            'name': 'Pi',
            for (final step in steps.keys) step: true,
          },
        ],
      };
      for (final MapEntry(key: step, value: check) in steps.entries) {
        final c = single(
          await smartAgents(
            facts,
            reply('{"action": "$step", "agents": ["pi"]}'),
          ),
        );
        expect(c['kind'], 'menu_action', reason: step);
        expect((c['area'], c['step'], c['key']), ('agents', step, 'pi'));
        expect(c['subtitle'], smartMenuNames['agents']![step]);
        expect(
          smartCandidateChecks(c).map((x) => (x.action, x.category)).toList(),
          check == null ? isEmpty : [check],
          reason: step,
        );
      }
      // The secret never passes through the helper: the step names no value.
      final key = single(
        await smartAgents(
          facts,
          reply('{"action": "key", "agents": ["pi"], "key": "sk-1"}'),
        ),
      );
      expect(jsonEncode(key), isNot(contains('sk-1')));
    });

    test('add-ons: only the steps their menus offer now', () async {
      final facts = {
        'agents': const [],
        'addons': [
          {
            'id': 'agent-goose',
            'name': 'Goose',
            'details': true,
            'on': false,
            'off': true,
            'remove': true,
            'install': false,
            'update': false,
          },
        ],
      };
      final off = single(
        await smartAgents(
          facts,
          reply(
            '{"action": "addon", "step": "off", "addons": ["agent-goose"]}',
          ),
        ),
      );
      expect(
        (off['area'], off['step'], off['key']),
        ('addons', 'off', 'agent-goose'),
      );
      expect(
        smartCandidateChecks(off).map((c) => (c.action, c.category, c.item)),
        [('remove', 'agents', 'goose')],
      );
      expect(
        () => smartAgents(
          facts,
          reply('{"action": "addon", "step": "on", "addons": ["agent-goose"]}'),
        ),
        throwsFormatException,
      );
      expect(smartAgentsPrompt(facts), contains('agent-goose'));
    });

    test('providers: find existing AI; no program uninstall', () async {
      final facts = {'providers': const []};
      final found = single(
        await smartProviders(
          facts,
          reply('{"action": "existing", "step": "reconnect"}'),
        ),
      );
      expect((found['area'], found['step']), ('existing', 'reconnect'));
      expect(smartCandidateChecks(found).map((c) => (c.action, c.category)), [
        ('connect', 'models'),
      ]);
      expect(
        () => smartProviders(
          facts,
          reply('{"action": "uninstall", "provider": "ollama"}'),
        ),
        throwsFormatException,
      );
    });

    test('models: load, unload, import, and a local LLM\'s own model', () async {
      final facts = {
        'limits': {'vram': 1, 'ram': 1},
        'runtimes': const [],
        'runtime_actions': [
          {
            'key': 'ollama',
            'name': 'Ollama',
            'import': false,
            'load': true,
            'models': ['qwen3:8b'],
          },
        ],
        'map_nodes': [
          {'id': 'runtime:ollama', 'kind': 'runtime', 'label': 'Ollama'},
          {
            'id': 'model:runtime:ollama:qwen3:8b',
            'kind': 'model',
            'label': 'qwen3:8b',
          },
          {
            'id': 'model:runtime:ollama:nomic-embed',
            'kind': 'model',
            'label': 'nomic-embed',
          },
        ],
        'provider_models': {'runtime:ollama': 'model:runtime:ollama:old'},
      };
      Future<Map<String, dynamic>> ask(String answer) => smartModels(
        facts,
        reply(answer),
        (_) async => [],
        (_, _) async => [],
      );
      final unload = single(
        await ask(
          '{"action": "unload", "runtime": "ollama", "model": "qwen3:8b"}',
        ),
      );
      expect(
        (unload['area'], unload['step'], unload['key'], unload['model']),
        ('models', 'unload', 'ollama', 'qwen3:8b'),
      );
      expect(
        smartCandidateChecks(unload).map((c) => (c.action, c.category, c.item)),
        [('stop', 'models', 'qwen3:8b')],
      );
      expect(
        () => ask('{"action": "import", "runtime": "ollama"}'),
        throwsFormatException,
      );
      expect(
        () => ask('{"action": "load", "runtime": "ollama", "model": "other"}'),
        throwsFormatException,
      );
      final choose = single(
        await ask(
          '{"action": "choose", "provider": "runtime:ollama", "model": "model:runtime:ollama:qwen3:8b"}',
        ),
      );
      expect(
        (choose['area'], choose['step'], choose['key'], choose['model']),
        ('models', 'choose', 'ollama', 'model:runtime:ollama:qwen3:8b'),
      );
      // As models.choose_preview: leaving the old model, reaching the new.
      expect(smartCandidateChecks(choose).map((c) => (c.action, c.item)), [
        ('disconnect', 'old'),
        ('connect', 'qwen3:8b'),
      ]);
      expect(
        () => ask(
          '{"action": "choose", "provider": "runtime:ollama", "model": "model:runtime:ollama:nomic-embed"}',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            smartMapChatModel,
          ),
        ),
      );
    });

    test('MCP: found on this PC opens its page', () async {
      final result = await smartMcp(
        {'agents': const [], 'mcp': const {}},
        reply('{"action": "found", "step": "unpack"}'),
        (_) async => const [],
      );
      final c = single(result);
      expect(
        (c['kind'], c['area'], c['step']),
        ('menu_action', 'mcp', 'unpack'),
      );
      expect(smartCandidateChecks(c), isEmpty);
    });

    test('a refused menu action never reaches the card', () {
      final menu = smartMenuCandidate(1, 'agents', 'start', 'pi', 'Pi');
      final rules = allowAll([deny('start', 'agents')]);
      expect(
        smartCandidateChecks(menu).every((c) => ruleAllows(rules, c)),
        isFalse,
      );
      // The app opens it itself: the core has no run or review of its own.
      final (:home, :core) = localSetup();
      final kept = core.smartProposals.keep({
        'status': 'proposal',
        'candidates': [menu],
      });
      expect(
        () => core.dispatch('map.smart_review', {
          'proposal': kept['proposal'],
          'candidate': 'c1',
        }),
        throwsFormatException,
      );
      expect(home.existsSync(), isTrue);
    });
  });

  test(
    'F16: Ask AI\'s disconnect only changes configuration, as the map\'s',
    () async {
      final (:home, :core) = localSetup();
      final before = File(
        '${home.path}/.pi/agent/settings.json',
      ).readAsStringSync();
      await mapOf(core);
      final kept = core.smartProposals.keep({
        'status': 'proposal',
        'candidates': [
          {
            'id': 'c1',
            'kind': 'model_disconnect',
            'agents': ['pi'],
            'title': 'gemma3:1b',
            'action': {
              'kind': 'model_disconnect',
              'key': 'ollama',
              'pairs': [
                {'model': 'gemma3:1b', 'agent': 'pi'},
              ],
            },
          },
        ],
      });
      final plan = core.dispatch('map.smart_plan', {
        'proposal': kept['proposal'],
        'candidate': 'c1',
        'agents': ['pi'],
        'values': <String, dynamic>{},
      });
      expect(plan['empty'], isFalse);
      expect(plan['model_actions'], isEmpty);
      expect(plan['notes'], isEmpty);
      // The same files as the map's own disconnect of the Pi → Ollama line.
      final manual = core.dispatch('connections.preview', {
        'kind': 'provider',
        'command': 'pi',
        'item': 'ollama',
        'remove': true,
        'model': '',
        'use_now': false,
      });
      expect(plan['files'], manual['files']);
      expect(manual['model_actions'] ?? const [], isEmpty);
      expect(
        File('${home.path}/.pi/agent/settings.json').readAsStringSync(),
        before,
        reason: 'nothing written before Apply',
      );
    },
  );

  group('F21: a local LLM\'s own model', () {
    const qwen = 'model:runtime:ollama:qwen3:8b';
    Map<String, dynamic> saved(Directory home) =>
        jsonDecode(
              File(
                '${home.path}/.config/maprisma/settings.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;

    test('a preview, its rules, and an Undo of only that choice', () async {
      final (:home, :core) = localSetup();
      await mapOf(core);
      final preview = core.dispatch('models.choose_preview', {
        'provider': 'runtime:ollama',
        'model': qwen,
      });
      expect(preview['empty'], isFalse);
      expect(preview['old'], isNull);
      expect(preview['line'], 'Ollama → qwen3:8b');
      final applied = core.dispatch('models.choose_apply', {
        'preview': preview['preview'],
      });
      expect(saved(home)['provider_models'], {'runtime:ollama': qwen});
      // A preview applies once.
      expect(
        () => core.dispatch('models.choose_apply', {
          'preview': preview['preview'],
        }),
        throwsFormatException,
      );
      core.dispatch('settings.update', {
        'values': {'flutter_theme_mode': 'dark'},
      });
      core.dispatch('models.choose_undo', {'undo': applied['undo']});
      expect(saved(home)['provider_models'], isEmpty);
      expect(
        saved(home)['flutter_theme_mode'],
        'dark',
        reason: 'only that choice',
      );
      // The same again is nothing to apply.
      final none = core.dispatch('models.choose_preview', {
        'provider': 'runtime:ollama',
        'model': null,
      });
      expect(none['empty'], isTrue);
    });

    test('refused by a rule, or for a model it does not serve', () async {
      final (:home, :core) = localSetup(
        rules: allowAll([deny('connect', 'models', 'qwen3:8b')]),
      );
      await mapOf(core);
      expect(
        () => core.dispatch('models.choose_preview', {
          'provider': 'runtime:ollama',
          'model': qwen,
        }),
        throwsA(isA<RuleRefused>()),
      );
      expect(
        () => core.dispatch('models.choose_preview', {
          'provider': 'runtime:ollama',
          'model': 'model:runtime:other:gemma3:1b',
        }),
        throwsFormatException,
      );
      expect(
        () => core.dispatch('models.choose_preview', {
          'provider': 'runtime:ollama',
        }),
        throwsFormatException,
      );
      expect(saved(home)['provider_models'], isNull);
    });
  });
}
