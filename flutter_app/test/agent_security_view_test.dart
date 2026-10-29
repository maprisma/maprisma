import 'package:asterism/agent_security_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _report({
  dynamic current = 'never',
  bool editable = true,
}) => {
  'agent': 'codex',
  'name': 'Codex',
  'known': true,
  'level': 'high',
  'settings': [
    {
      'key': 'approval_policy',
      'title': 'Asks before acting',
      'explain': 'When it stops to ask you.',
      'choices': [
        {'value': 'untrusted', 'label': 'Always', 'explain': '', 'risk': 1},
        {'value': 'never', 'label': 'Never', 'explain': '', 'risk': 3},
      ],
      'current': current,
      'default': 'untrusted',
      'editable': editable,
      'recommended': 'untrusted',
    },
  ],
  'rules': [
    [
      'Allow and deny rules',
      'permissions',
      ['Bash(ls:*)'],
    ],
  ],
  'risks': [
    {
      'level': 'high',
      'title': 'It never asks',
      'why': 'Commands run without a question.',
      'lower': 'Let it ask first.',
      'fix_key': 'approval_policy',
      'fix_value': 'untrusted',
    },
  ],
  'files': ['~/.codex/config.toml'],
  'note': '',
};

Future<List<(String, dynamic)>> _pump(
  WidgetTester tester,
  Map<String, dynamic> report,
) async {
  final changes = <(String, dynamic)>[];
  await tester.binding.setSurfaceSize(const Size(900, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AgentSecurityView(
          report: report,
          tr: (key) => key,
          onChange: (key, value) => changes.add((key, value)),
          onClose: () {},
        ),
      ),
    ),
  );
  return changes;
}

void main() {
  testWidgets('shows the level, the settings, the rules and the risks', (
    tester,
  ) async {
    await _pump(tester, _report());
    expect(find.text('High risk'), findsOneWidget);
    expect(find.text('Asks before acting'), findsOneWidget);
    expect(find.text('Never'), findsOneWidget);
    expect(find.text('Allow and deny rules'), findsOneWidget);
    expect(find.text('It never asks'), findsOneWidget);
    expect(
      find.text(
        'Open a setting to see every choice. A change is shown first, backed up and can be undone; it applies the next time Codex starts.',
      ),
      findsOneWidget,
    );
    expect(find.text('Settings file: ~/.codex/config.toml'), findsOneWidget);
  });

  testWidgets('a choice and "Lower it…" ask for the change', (tester) async {
    final changes = await _pump(tester, _report());
    await tester.tap(find.text('Lower it…'));
    expect(changes, [('approval_policy', 'untrusted')]);
    await tester.tap(find.text('Never'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Always · recommended').last);
    await tester.pumpAndSettle();
    expect(changes.last, ('approval_policy', 'untrusted'));
  });

  testWidgets('nothing to lower when it is already set or not editable', (
    tester,
  ) async {
    await _pump(tester, _report(current: 'untrusted'));
    expect(find.text('Lower it…'), findsNothing);
    await _pump(tester, _report(editable: false));
    expect(find.text('Lower it…'), findsNothing);
    expect(find.byType(DropdownButton<int>), findsNothing);
    expect(find.text('In use: Never'), findsOneWidget);
  });

  testWidgets('a setting not set shows the agent default', (tester) async {
    await _pump(tester, _report(current: null));
    expect(
      find.text("Not set: the agent's own default applies."),
      findsOneWidget,
    );
  });
}
