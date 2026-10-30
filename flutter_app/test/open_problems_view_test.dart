import 'package:maprisma/open_problems_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _report({bool problems = true}) => {
  'warn': problems ? 1 : 0,
  'hint': 1,
  'summary': problems ? '1 thing to fix · 1 tip' : 'Works well · 1 tip',
  'open_text': '1 open problem',
  'areas': [
    {
      'key': 'agents',
      'title': 'Agents',
      'icon': '',
      'findings': [
        {'level': 'ok', 'title': '2 agents ready', 'text': '', 'action': []},
        if (problems)
          {
            'level': 'warn',
            'title': 'Pi: Not signed in',
            'text': 'Sign in: pi login',
            'action': ['details', 'pi'],
          },
        {'level': 'hint', 'title': 'A tip', 'text': '', 'action': []},
      ],
    },
  ],
  'uses': [
    {
      'key': 'coding',
      'title': 'Vibe coding',
      'icon': '',
      'blurb': 'Describe what you want.',
      'have': ['Claude Code', 'Qwen3-Coder'],
      'steps': [
        {
          'level': 'hint',
          'title': 'Add skills',
          'text': 'Ready-made workflows.',
          'action': ['addskills'],
        },
      ],
      'level': 'almost',
    },
  ],
};

void main() {
  Future<List<List<String>>> pump(
    WidgetTester tester,
    Map<String, dynamic> r,
  ) async {
    final actions = <List<String>>[];
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OpenProblemsView(
            report: r,
            tr: (k) => k,
            onAction: actions.add,
            onCheckAgain: () {},
            onClose: () {},
          ),
        ),
      ),
    );
    return actions;
  }

  testWidgets('only the problems, each opening where it is fixed; the uses', (
    tester,
  ) async {
    final actions = await pump(tester, _report());
    expect(find.text('1 open problem'), findsOneWidget);
    expect(find.text('Pi: Not signed in'), findsOneWidget);
    expect(find.text('2 agents ready'), findsNothing);
    expect(find.text('A tip'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Details'));
    expect(actions.single, ['details', 'pi']);
    expect(find.text('Vibe coding'), findsOneWidget);
    expect(find.text('Almost'), findsOneWidget);
    expect(find.text('✓ Claude Code, Qwen3-Coder'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Add skills'));
    expect(actions.last, ['addskills']);
  });

  testWidgets('nothing to fix says so', (tester) async {
    await pump(tester, _report(problems: false));
    expect(find.text('Nothing to fix.'), findsOneWidget);
    expect(find.text('Works well · 1 tip'), findsOneWidget);
  });

  testWidgets('updates: each with what is new and Update', (tester) async {
    final updated = <String>[];
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OpenProblemsView(
            report: _report(problems: false),
            tr: (k) => k,
            onAction: (_) {},
            updates: const [
              {
                'kind': 'agent',
                'key': 'opencode',
                'name': 'OpenCode',
                'current': '2.2.1',
                'available': '2.2.2',
                'command': ['mise', 'upgrade', 'opencode'],
                'page': false,
              },
            ],
            onUpdate: (u) => updated.add('${u['key']}'),
            onCheckAgain: () {},
            onClose: () {},
          ),
        ),
      ),
    );
    expect(find.text('Updates and suggestions'), findsOneWidget);
    expect(
      find.text('OpenCode 2.2.2 is available (you have 2.2.1)'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Update'));
    expect(updated, ['opencode']);
  });
}
