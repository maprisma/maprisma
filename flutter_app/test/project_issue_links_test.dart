import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/ai_project_center.dart';
import 'package:maprisma/project_board.dart';
import 'package:maprisma/project_page_parts.dart';

import 'project_board_test.dart' show card;

/// Issue links (task 092): Fix on map, Go to Team, Go to Goal.
const stopped = {
  'code': 'runtime_stopped',
  'target': 'runtime',
  'node': 'runtime:fixture',
  'fix': 'map',
};
const noLead = {'code': 'no_lead', 'target': 'team', 'fix': 'team'};
const folder = {'code': 'folder_missing', 'target': 'folder', 'fix': 'goal'};

Map<String, dynamic> withIssues(String id, List<Map> issues) => {
  ...card(id, bucket: 'needs_you', activity: 'approved_blocked'),
  'issues': issues,
};

Future<GlobalKey<AiProjectCenterPageState>> mount(
  WidgetTester tester,
  List<Map<String, dynamic>> list, {
  ValueChanged<String>? onFixOnMap,
  Size size = const Size(1400, 900),
  double text = 1,
}) async {
  final key = GlobalKey<AiProjectCenterPageState>();
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  tester.platformDispatcher.textScaleFactorTestValue = text;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AiProjectCenterPage(
          key: key,
          tr: (s) => s,
          onFixOnMap: onFixOnMap,
          onCall: (op, args) async {
            if (op == 'list') {
              return {
                'projects': list,
                'capabilities': ['board'],
              };
            }
            if (op == 'get') {
              final p = list.firstWhere((p) => p['id'] == args['id']);
              return {
                'project': {
                  ...p,
                  'brief': 'b',
                  'plan': '',
                  'team': [
                    {'agent': 'claude', 'role': 'lead'},
                  ],
                  'events': [],
                  'plan_version': 0,
                  'approved_version': null,
                },
              };
            }
            return {'profiles': [], 'runtimes': []};
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return key;
}

bool chosen(WidgetTester tester, String tab) =>
    tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, tab)).selected;

void main() {
  test('where an issue is fixed', () {
    expect(issueFix(stopped), 'map');
    expect(issueFix(stopped, map: false), 'team');
    expect(issueFix({...stopped}..remove('node')), 'team');
    expect(issueFix({...stopped, 'node': ''}), 'team');
    expect(issueFix(folder), 'goal');
    expect(issueFix(noLead), 'team');
    // An older backend without fix: the Team tab.
    expect(issueFix({'code': 'runtime_stopped'}), 'team');
    expect(issueFixLabel('map'), 'Fix on map');
    expect(issueFixLabel('goal'), 'Go to Goal');
    expect(issueFixLabel('team'), 'Go to Team');
  });

  testWidgets('a card: Fix on map goes to the box the issue names', (
    tester,
  ) async {
    final fixed = <String>[];
    await mount(tester, [
      withIssues('a', [stopped, noLead]),
    ], onFixOnMap: fixed.add);
    final fix = find.byKey(const ValueKey('card-fix'));
    expect(
      find.descendant(of: fix, matching: find.text('Fix on map')),
      findsOneWidget,
    );
    await tester.tap(fix);
    await tester.pumpAndSettle();
    expect(fixed, ['runtime:fixture']);
  });

  testWidgets('a card: Go to Goal opens the project on its Goal tab', (
    tester,
  ) async {
    final key = await mount(tester, [
      withIssues('a', [folder]),
    ], onFixOnMap: (_) {});
    await tester.tap(find.byKey(const ValueKey('card-fix')));
    await tester.pumpAndSettle();
    expect(key.currentState!.projectOpen, isTrue);
    expect(chosen(tester, 'Goal'), isTrue);
  });

  testWidgets('a card: Go to Team opens the project on its Team tab', (
    tester,
  ) async {
    final key = await mount(tester, [
      withIssues('a', [noLead]),
    ], onFixOnMap: (_) {});
    await tester.tap(find.byKey(const ValueKey('card-fix')));
    await tester.pumpAndSettle();
    expect(key.currentState!.projectOpen, isTrue);
    expect(chosen(tester, 'Team'), isTrue);
  });

  testWidgets('without the shell a map issue goes to the Team tab', (
    tester,
  ) async {
    await mount(tester, [
      withIssues('a', [stopped]),
    ]);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('card-fix')),
        matching: find.text('Go to Team'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the project page lists every issue once, members\' too, '
      'each with its link', (tester) async {
    final handle = tester.ensureSemantics();
    final fixed = <String>[];
    final key = await mount(tester, [
      {
        ...withIssues('a', [stopped, folder]),
        'execution': [
          {
            'phase': 'execution',
            'position': 0,
            'agent': 'claude',
            'name': 'Claude Code',
            'role': 'lead',
            // The same as the card's, and one of its own.
            'issues': [
              stopped,
              {
                'code': 'access_unsupported',
                'target': 'permission',
                'fix': 'team',
              },
            ],
          },
        ],
      },
    ], onFixOnMap: fixed.add);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('project-card-a')),
        matching: find.byKey(const ValueKey('card-open')),
      ),
    );
    await tester.pumpAndSettle();
    expect(key.currentState!.projectOpen, isTrue);
    expect(find.byKey(const ValueKey('page-issues')), findsOneWidget);
    expect(find.byKey(const ValueKey('page-issue-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('page-issue-3')), findsNothing);
    // Screen readers: the reason and its link in one.
    expect(
      tester.getSemantics(find.byKey(const ValueKey('page-issue-0'))),
      isSemantics(
        label: 'A local runtime is stopped\nFix on map',
        hasTapAction: true,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('page-fix-2')));
    await tester.pumpAndSettle();
    expect(chosen(tester, 'Team'), isTrue);
    await tester.tap(find.byKey(const ValueKey('page-fix-1')));
    await tester.pumpAndSettle();
    expect(chosen(tester, 'Goal'), isTrue);
    await tester.tap(find.byKey(const ValueKey('page-fix-0')));
    await tester.pumpAndSettle();
    expect(fixed, ['runtime:fixture']);
    handle.dispose();
  });

  Future<GlobalKey<AiProjectCenterPageState>> openPage(
    WidgetTester tester,
    List<Map> issues, {
    Size size = const Size(1400, 900),
    double text = 1,
    ValueChanged<String>? onFixOnMap,
  }) async {
    final key = await mount(
      tester,
      [withIssues('a', issues)],
      onFixOnMap: onFixOnMap ?? (_) {},
      size: size,
      text: text,
    );
    final open = find.byKey(const ValueKey('card-open'));
    await tester.ensureVisible(open);
    await tester.pumpAndSettle();
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(key.currentState!.projectOpen, isTrue);
    return key;
  }

  testWidgets('a small window with large text: every issue is reachable '
      'and its link works', (tester) async {
    await openPage(
      tester,
      [stopped, folder, noLead],
      size: const Size(480, 360),
      text: 1.5,
    );
    final last = find.byKey(const ValueKey('page-fix-2'));
    await tester.scrollUntilVisible(
      last,
      100,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // The Team tab is chosen (the selector shows it in a small window).
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('project-tab-select')),
        matching: find.text('Team'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('many issues scroll with the body: no overflow, the tabs stay', (
    tester,
  ) async {
    await openPage(tester, [
      for (var i = 0; i < 20; i++) {...stopped, 'node': 'runtime:r$i'},
    ], size: const Size(900, 700));
    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(ChoiceChip, 'Goal'), findsOneWidget);
    expect(find.byKey(const ValueKey('page-issue-0')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('page-issue-19')),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.byKey(const ValueKey('page-issue-19')), findsOneWidget);
  });

  testWidgets('a link by keyboard: Enter goes to the Goal tab', (tester) async {
    await openPage(tester, [stopped, folder]);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Team'));
    await tester.pumpAndSettle();
    Focus.of(
      tester.element(
        find.descendant(
          of: find.byKey(const ValueKey('page-fix-1')),
          matching: find.text('Go to Goal'),
        ),
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(chosen(tester, 'Goal'), isTrue);
  });

  testWidgets('a card with every line still fits (second line, issue with '
      'its link, event, actions)', (tester) async {
    for (final width in [700.0, 1100.0, 1400.0]) {
      await mount(
        tester,
        [
          {
            ...withIssues('a', [stopped]),
            'second': 'check_changes_first',
            'active': {'phase': 'execution', 'position': 0, 'state': 'active'},
            'activity': 'running',
            'bucket': 'running',
          },
        ],
        onFixOnMap: (_) {},
        size: Size(width, 900),
      );
      expect(find.byKey(const ValueKey('card-fix')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '$width');
    }
  });

  test('collect: each code and box once', () {
    final issues = ProjectIssues.collect({
      'issues': [stopped],
      'planning': [
        {
          'issues': [
            stopped,
            {...stopped, 'node': 'runtime:other'},
          ],
        },
      ],
      'execution': [],
    });
    expect(
      [for (final i in issues) i['node']],
      ['runtime:fixture', 'runtime:other'],
    );
  });
}
