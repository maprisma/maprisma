import 'dart:convert';
import 'dart:io';
import 'package:maprisma_core/maprisma_core.dart';
import 'package:maprisma_core/src/action_rules.dart';
import 'package:maprisma_core/src/smart_card.dart';
import 'package:test/test.dart';

Map<String, dynamic> rule(
  String effect,
  String action, [
  String category = '*',
  String item = '*',
  String agent = '*',
]) => {
  'effect': effect,
  'action': action,
  'category': category,
  'item': item,
  'agent': agent,
};

void main() {
  const pi = ActionCheck('disconnect', 'skills', '/a', 'pi');
  const claude = ActionCheck('disconnect', 'skills', '/a', 'claude');

  test('the defaults allow everything', () {
    for (final action in ruleActions) {
      expect(
        ruleAllows(defaultActionRules, ActionCheck(action, 'mcp', 'x', 'pi')),
        isTrue,
      );
    }
  });

  test(
    'the most specific rule wins, the deny over the default, Pi over it',
    () {
      final rules = [
        ...defaultActionRules,
        rule('deny', 'disconnect', 'skills'),
        rule('allow', 'disconnect', 'skills', '*', 'pi'),
      ];
      expect(ruleAllows(rules, claude), isFalse);
      expect(ruleAllows(rules, pi), isTrue);
      final folder = [...rules, rule('deny', 'disconnect', 'skills', '/a')];
      expect(ruleAllows(folder, pi), isFalse, reason: 'an item beats an agent');
      expect(
        ruleAllows(
          folder,
          const ActionCheck('disconnect', 'skills', '/b', 'pi'),
        ),
        isTrue,
      );
    },
  );

  test('a deny of a whole category or agent beats the defaults', () {
    final rules = [...defaultActionRules, rule('deny', '*', 'skills')];
    expect(ruleAllows(rules, pi), isFalse);
    final agent = [...defaultActionRules, rule('deny', '*', '*', '*', 'pi')];
    expect(ruleAllows(agent, pi), isFalse);
    expect(
      ruleAllows(agent, const ActionCheck('remove', 'agents', 'pi')),
      isFalse,
      reason: 'everything for Pi covers Pi itself',
    );
  });

  test('a tie goes to allow, and the order of the rules does not count', () {
    final deny = rule('deny', 'disconnect', 'skills');
    final allow = rule('allow', 'disconnect', 'skills');
    expect(ruleAllows([deny, allow], pi), isTrue);
    expect(ruleAllows([allow, deny], pi), isTrue);
  });

  test('a deleted default refuses', () {
    expect(ruleAllows(const [], pi), isFalse);
  });

  test('moving a line is leaving one end and reaching the other', () {
    final moved = actionChecks('connections.move_preview', {
      'agent': 'agent:pi',
      'old': 'skills:/a',
      'new': 'skills:/b',
    });
    expect(moved.map((c) => (c.action, c.item)), [
      ('disconnect', '/a'),
      ('connect', '/b'),
    ]);
    final gone = actionChecks('connections.move_preview', {
      'agent': 'agent:pi',
      'old': 'skills:/a',
      'new': null,
    });
    expect(gone.single.action, 'disconnect');
  });

  test('bad rules are refused', () {
    expect(validActionRules(defaultActionRules), isTrue);
    expect(validActionRules([rule('maybe', 'install')]), isFalse);
    expect(validActionRules([rule('deny', 'fly')]), isFalse);
    expect(
      validActionRules([rule('deny', 'install', '*', 'x')]),
      isFalse,
      reason: 'an item needs a category',
    );
  });

  // Parameters as the handlers really take them.
  final expected = <String, (Map<String, dynamic>, String, String, String)>{
    'connections.preview': (
      {'kind': 'skills', 'command': 'pi', 'item': '/a', 'remove': true},
      'disconnect',
      'skills',
      '/a',
    ),
    'connections.forget_preview': ({'name': 's'}, 'remove', 'mcp', 's'),
    'connections.author_preview': (
      {
        'kind': 'skills',
        'folder': '/a',
        'agents': ['pi'],
      },
      'connect',
      'skills',
      '/a',
    ),
    'connections.repair_preview': (
      {'agent': 'agent:pi', 'target': 'mcp:s'},
      'connect',
      'mcp',
      's',
    ),
    'connections.move_preview': (
      {'agent': 'agent:pi', 'old': 'mcp:s', 'new': null},
      'disconnect',
      'mcp',
      's',
    ),
    'mcp.option_preview': ({'name': 's'}, 'install', 'mcp', 's'),
    'skills.web_preview': ({'folder': '/a'}, 'install', 'skills', '/a'),
    'models.switch_preview': (
      {'provider': 'runtime:o', 'old': 'model:runtime:o:m', 'new': null},
      'disconnect',
      'models',
      'm',
    ),
    'models.attach_preview': (
      {
        'provider': 'runtime:o',
        'model': 'model:runtime:o:m',
        'agents': ['pi'],
      },
      'connect',
      'models',
      'm',
    ),
    'models.remove_preview': (
      {'key': 'o', 'model': 'm'},
      'remove',
      'models',
      'm',
    ),
    'models.tuning_preview': ({'key': 'o'}, 'update', 'providers', 'o'),
    'models.slots_preview': (const {}, 'update', 'providers', ''),
    'agents.security_preview': ({'command': 'pi'}, 'update', 'agents', 'pi'),
    'agents.action_preview': (
      {'action': 'uninstall', 'command': 'pi'},
      'remove',
      'agents',
      'pi',
    ),
    'agents.key_preview': ({'command': 'pi'}, 'connect', 'agents', 'pi'),
    'agents.halt_preview': ({'command': 'pi'}, 'stop', 'agents', 'pi'),
    'sessions.stop': ({'command': 'pi'}, 'stop', 'agents', 'pi'),
    'sessions.start': ({'command': 'pi'}, 'start', 'agents', 'pi'),
    'system.help_preview': ({'command': 'pi'}, 'start', 'agents', 'pi'),
    'system.fix_preview': ({'command': 'pi'}, 'start', 'agents', 'pi'),
    'system.move_preview': (const {}, 'move', 'models', ''),
    'system.stack_preview': ({'part': 'x'}, 'install', 'providers', 'x'),
    'existing.preview': (const {}, 'connect', 'models', ''),
    'system.folder_preview': (const {}, 'connect', 'models', ''),
    'providers.run': (
      {
        'operation': 'models.download',
        'params': {'key': 'o', 'repo': 'r/m', 'file': 'f', 'size': 1},
      },
      'install',
      'models',
      'r/m',
    ),
    'jobs.continue': ({'id': 'j'}, 'install', 'models', ''),
    'updates.run': ({'key': 'pi'}, 'update', 'agents', 'pi'),
    'installers.preview': (
      {'kind': 'runtime', 'key': 'o'},
      'install',
      'providers',
      'o',
    ),
    'addons.remove_preview': ({'id': 'agent-pi'}, 'remove', 'agents', 'pi'),
    'addons.set_enabled': (
      {'id': 'llm-ollama', 'enabled': false},
      'remove',
      'providers',
      'ollama',
    ),
    'addons.file_preview': (const {}, 'install', 'agents', ''),
    'setup.apply': (const {}, 'update', 'agents', ''),
  };

  test('every route gives what its handler does, or is exempt', () {
    final routes =
        (jsonDecode(File('protocol/routes.json').readAsStringSync())
                as Map)['routes']
            as Map;
    final open = [
      for (final e in routes.entries)
        if (const {'preview', 'change', 'handle'}.contains(e.value['kind']) &&
            !rulesExempt.contains(e.key) &&
            !expected.containsKey(e.key))
          e.key,
    ];
    expect(open, isEmpty);
    expect(rulesExempt.intersection(expected.keys.toSet()), isEmpty);
    expected.forEach((method, want) {
      final check = actionChecks(method, want.$1).first;
      expect(
        (check.action, check.category, check.item),
        (want.$2, want.$3, want.$4),
        reason: method,
      );
    });
  });

  test('a model answers to any spelling of its name', () {
    String normal(String category, String item) =>
        category == 'models' ? item.toLowerCase() : item;
    final rules = [
      ...defaultActionRules,
      rule('deny', 'remove', 'models', 'qwen'),
    ];
    expect(
      ruleAllows(
        rules,
        const ActionCheck('remove', 'models', 'Qwen'),
        normal: normal,
      ),
      isFalse,
    );
  });

  test('the update of what is here is an update; a line names its agents', () {
    final check = actionChecks('installers.preview', {
      'kind': 'runtime',
      'key': 'o',
    }, RuleFacts(installed: (_, _) => true)).single;
    expect(check.action, 'update');
    final users = actionChecks('models.switch_preview', {
      'old': 'model:runtime:o:m',
      'new': 'model:runtime:o:n',
    }, RuleFacts(modelUsers: (_) => ['pi']));
    expect(users.map((c) => (c.action, c.agent)), [
      ('disconnect', 'pi'),
      ('connect', 'pi'),
    ]);
  });

  test('a proposal knows what it would do', () {
    expect(
      smartCandidateChecks({
        'kind': 'provider_action',
        'key': 'ollama',
        'step': 'stop',
        'action': {'kind': 'provider_action'},
      }).single.action,
      'stop',
    );
    expect(
      smartCandidateChecks({
        'action': {
          'kind': 'mcp_add',
          'server': {'name': 'io.github.a/files'},
        },
      }).single.item,
      'files',
    );
    expect(
      smartCandidateChecks({
        'action': {
          'operation': 'models.download',
          'params': {'key': 'o', 'repo': 'r/m', 'file': 'f', 'size': 1},
        },
      }).single.item,
      'r/m',
    );
    final checks = smartCandidateChecks({
      'action': {
        'kind': 'mcp_disconnect',
        'pairs': [
          {'skill': '/a', 'agent': 'pi'},
        ],
      },
    });
    expect(checks.single.category, 'skills');
  });

  test('the core refuses, and again when rules tighten before apply', () {
    final home = Directory.systemTemp.createTempSync('rules');
    addTearDown(() => home.deleteSync(recursive: true));
    final core = CoreService(
      environment: {
        'HOME': home.path,
        'PATH': '${home.path}/bin',
        'MAPRISMA_DESKTOP': 'generic',
      },
    );
    core.settings.update({
      'values': {
        'action_rules': [
          ...defaultActionRules,
          rule('deny', 'stop', 'providers'),
        ],
      },
    });
    final reply = jsonDecode(
      core.handle(
        jsonEncode({
          'id': 1,
          'protocol': 2,
          'method': 'providers.run',
          'params': {
            'operation': 'runtime.stop',
            'params': {'runtime': 'ollama'},
          },
        }),
      ),
    );
    expect(reply['error']['code'], 'action_refused');
    expect(reply['error']['message'], contains('Stop, Providers'));
    core.settings.update({
      'values': {'action_rule_hints': false},
    });
    final quiet = jsonDecode(
      core.handle(
        jsonEncode({
          'id': 2,
          'protocol': 2,
          'method': 'providers.run',
          'params': {
            'operation': 'runtime.stop',
            'params': {'runtime': 'ollama'},
          },
        }),
      ),
    );
    expect(quiet['error']['message'], isNot(contains('Stop')));
    expect(
      core.dispatch('rules.test', {
        'action': 'stop',
        'category': 'providers',
        'item': 'ollama',
        'agent': '',
      })['allowed'],
      isFalse,
    );
  });
}
