import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/action_rules_window.dart';

void main() {
  Future<List<List<Map<String, dynamic>>>> mount(
    WidgetTester tester,
    List<Map<String, dynamic>> rules, {
    bool Function(Map<String, String>)? allowed,
    bool rule = false,
  }) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final saved = <List<Map<String, dynamic>>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ActionRulesWindow(
            rules: rules,
            hints: true,
            items: const {
              'skills': {'/a': '/a'},
            },
            agents: const {'pi': 'Pi'},
            tr: (s) => s,
            onSave: (r, _) async => saved.add([
              for (final x in r) {...x},
            ]),
            onTest: (q) async => {
              'allowed': allowed?.call(q) ?? true,
              if (rule) 'rule': defaultRules()[4],
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return saved;
  }

  testWidgets('the + adds to its list, the x removes, defaults come back', (
    tester,
  ) async {
    final saved = await mount(tester, defaultRules());
    await tester.tap(find.byKey(const ValueKey('rule-add-deny')));
    await tester.pumpAndSettle();
    expect(saved.last.where((r) => r['effect'] == 'deny'), hasLength(1));
    await tester.ensureVisible(
      find.byKey(const ValueKey('rule-delete-deny-0')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rule-delete-deny-0')));
    await tester.pumpAndSettle();
    expect(saved.last.where((r) => r['effect'] == 'deny'), isEmpty);
    await tester.ensureVisible(
      find.byKey(const ValueKey('rule-delete-allow-0')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rule-delete-allow-0')));
    await tester.pumpAndSettle();
    expect(saved.last, hasLength(defaultRules().length - 1));
    await tester.tap(find.byKey(const ValueKey('rule-defaults')));
    await tester.pumpAndSettle();
    expect(saved.last, defaultRules());
    await tester.tap(find.byKey(const ValueKey('rule-undo')));
    await tester.pumpAndSettle();
    expect(saved.last, hasLength(defaultRules().length - 1));
    await tester.tap(find.byKey(const ValueKey('rule-defaults')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rule-add-deny')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rule-undo')), findsNothing);
  });

  testWidgets('a rule for what is gone stays; a dead deny says so', (
    tester,
  ) async {
    Map<String, dynamic> rule(String effect) => {
      'effect': effect,
      'action': 'disconnect',
      'category': 'skills',
      'item': '/gone',
      'agent': '*',
    };
    await mount(tester, [rule('allow'), rule('deny')]);
    expect(find.text('/gone'), findsNWidgets(2));
    expect(
      find.text('Never decides: an allow rule names the same things.'),
      findsOneWidget,
    );
  });

  testWidgets('the bar shows the answer for a request', (tester) async {
    await mount(tester, defaultRules(), allowed: (q) => q['action'] != 'x');
    await tester.tap(find.byKey(const ValueKey('rule-test')));
    await tester.pumpAndSettle();
    expect(find.text('Allowed'), findsOneWidget);
    await mount(tester, defaultRules(), rule: true);
    await tester.tap(find.byKey(const ValueKey('rule-test')));
    await tester.pumpAndSettle();
    expect(find.text('Allowed: Allow · Disconnect · All'), findsOneWidget);
  });
}
