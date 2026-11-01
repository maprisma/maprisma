import 'dart:convert';
import 'dart:io';
import 'package:maprisma_core/maprisma_core.dart';
import 'package:maprisma_core/src/action_rules.dart';
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

  test('every route that changes the setup has checks or is exempt', () {
    final routes =
        (jsonDecode(File('protocol/routes.json').readAsStringSync())
                as Map)['routes']
            as Map;
    const samples = <String, dynamic>{
      'agent': 'agent:pi',
      'agents': ['pi'],
      'old': 'mcp:a',
      'target': 'mcp:a',
      'model': 'm',
    };
    final missing = [
      for (final e in routes.entries)
        if (const {'preview', 'change', 'handle'}.contains(e.value['kind']) &&
            !rulesExempt.contains(e.key) &&
            actionChecks(e.key, {
              'kind': 'mcp',
              'operation': 'runtime.start',
              ...samples,
            }).isEmpty)
          e.key,
    ];
    print(missing);
    expect(missing, isEmpty);
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
    expect(reply['error']['message'], contains('stop, providers'));
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
    expect(quiet['error']['message'], isNot(contains('stop')));
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
