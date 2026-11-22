import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/ai_project_center.dart';
import 'package:maprisma/project_page_parts.dart';

import 'project_board_test.dart' show card;

/// The project page's large rail and Team graph (task 089).
Map<String, dynamic> member(
  String phase,
  int position,
  String name,
  String role, {
  String? runtime,
  String? provider,
  String? model,
  List<Map<String, String>> issues = const [],
}) => {
  'phase': phase,
  'position': position,
  'agent': name.toLowerCase(),
  'name': name,
  'role': role,
  'runtime': ?runtime,
  'provider': ?provider,
  'model': ?model,
  'issues': issues,
};

Future<void> show(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(1200, 900),
  double text = 1,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  tester.platformDispatcher.textScaleFactorTestValue = text;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

FontWeight? weight(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style?.fontWeight;

void main() {
  const stages = [
    ('goal', 'Goal'),
    ('plan', 'Plan'),
    ('approval', 'Approval'),
    ('ready', 'Ready'),
    ('run', 'Run'),
    ('finished', 'Agents finished'),
  ];
  for (final (i, (stage, label)) in stages.indexed) {
    testWidgets('the large rail at $stage: that stop is the current one', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await show(
        tester,
        LargeStageRail(
          project: {
            ...card('x'),
            'stage': stage,
            'activity': 'paused',
            'second': 'check_changes_first',
          },
          tr: (s) => s,
        ),
      );
      expect(find.byKey(const ValueKey('large-rail')), findsOneWidget);
      // Only the current stop's name is bold.
      for (final (j, (_, other)) in stages.indexed) {
        expect(
          weight(tester, other),
          j == i ? FontWeight.w600 : FontWeight.w400,
          reason: other,
        );
      }
      expect(find.text('Paused · Check the changes first'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Stage: $label, Paused, Check the changes first'),
        findsOneWidget,
      );
      handle.dispose();
    });
  }

  testWidgets('the compact rail names only the current stage', (tester) async {
    await show(
      tester,
      LargeStageRail(
        project: {...card('x'), 'stage': 'ready', 'activity': 'ready_to_run'},
        tr: (s) => s,
        compact: true,
      ),
    );
    expect(find.byKey(const ValueKey('large-rail-compact')), findsOneWidget);
    expect(find.text('Ready · Approved, ready to run'), findsOneWidget);
    expect(find.text('Goal'), findsNothing);
  });

  testWidgets('compact, narrow, large text: the next step stays readable', (
    tester,
  ) async {
    await show(
      tester,
      LargeStageRail(
        project: {
          ...card('x'),
          'stage': 'run',
          'activity': 'interrupted',
          'second': 'check_changes_first',
        },
        tr: (s) => s == 'Check the changes first'
            ? 'Prüfe zuerst die Änderungen, bevor du weitermachst'
            : s,
        compact: true,
      ),
      size: const Size(480, 400),
      text: 1.5,
    );
    final second = find.byKey(const ValueKey('large-rail-second'));
    expect(second, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: second, matching: find.byType(RichText)),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide at 600 px, large text: the next step stays readable', (
    tester,
  ) async {
    await show(
      tester,
      LargeStageRail(
        project: {
          ...card('x'),
          'stage': 'ready',
          'activity': 'ready_to_run',
          'second': 'check_changes_first',
        },
        tr: (s) => switch (s) {
          'Approved, ready to run' => 'Goedgekeurd, klaar om te starten',
          'Check the changes first' => 'Controleer eerst de wijzigingen',
          _ => s,
        },
      ),
      size: const Size(600, 700),
      text: 2,
    );
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.byKey(const ValueKey('large-rail-activity')),
        matching: find.byType(RichText),
      ),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unknown stage or second line adds no stray text', (
    tester,
  ) async {
    await show(
      tester,
      LargeStageRail(
        project: {
          ...card('x'),
          'stage': null,
          'activity': 'draft',
          'second': 'something',
        },
        tr: (s) => s,
        compact: true,
      ),
    );
    expect(find.text('Draft'), findsOneWidget);
  });

  testWidgets('the graph: Planning above Execution, members in launch order', (
    tester,
  ) async {
    await show(
      tester,
      TeamGraph(
        tr: (s) => s,
        project: {
          ...card('x'),
          'planning': [
            member('planning', 0, 'Claude Code', 'lead'),
            member('planning', 1, 'Pi', 'contributor'),
          ],
          'execution': [
            member('execution', 0, 'Claude Code', 'lead'),
            member('execution', 1, 'Pi', 'implementer'),
            member('execution', 2, 'Codex', 'reviewer'),
          ],
        },
      ),
    );
    Offset at(String key) => tester.getTopLeft(find.byKey(ValueKey(key)));
    expect(
      at('graph-member-planning-0').dy,
      lessThan(at('graph-member-execution-0').dy),
    );
    // In launch order: each next member to the right or below.
    for (var i = 1; i < 3; i++) {
      final before = at('graph-member-execution-${i - 1}');
      final after = at('graph-member-execution-$i');
      expect(
        after.dy > before.dy || (after.dy == before.dy && after.dx > before.dx),
        isTrue,
      );
    }
    expect(find.text('Contributor'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('graph-member-initials')),
      findsNWidgets(5),
    );
  });

  testWidgets('targets: explicit runtime and provider, a model alone, none', (
    tester,
  ) async {
    await show(
      tester,
      TeamGraph(
        tr: (s) => s,
        project: {
          ...card('x'),
          'planning': [],
          'execution': [
            member('execution', 0, 'Claude Code', 'lead'),
            member(
              'execution',
              1,
              'Pi',
              'implementer',
              runtime: 'llamacpp',
              provider: 'local',
              model: 'qwen',
            ),
            member('execution', 2, 'Codex', 'reviewer', model: 'gpt-5'),
          ],
        },
      ),
    );
    Finder target(int i, String text) => find.descendant(
      of: find.byKey(ValueKey('graph-target-execution-$i')),
      matching: find.text(text),
    );
    expect(target(0, 'Agent default'), findsOneWidget);
    expect(target(1, 'llamacpp · local · qwen'), findsOneWidget);
    // A model alone: still the agent's default connection, with the model.
    expect(target(2, 'Agent default · gpt-5'), findsOneWidget);
  });

  for (final (state, text) in [
    ('active', 'Working'),
    ('stopping', 'Stopping'),
    ('stopped', 'Stopped'),
    ('next', 'Next'),
  ]) {
    testWidgets('the marked member: $state, readable with long words', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await show(
        tester,
        TeamGraph(
          tr: (s) => '$s $s',
          project: {
            ...card('x'),
            'planning': [],
            'execution': [
              member('execution', 0, 'Claude Code', 'lead'),
              member(
                'execution',
                1,
                'Pi',
                'implementer',
                issues: [
                  {'code': 'runtime_stopped'},
                  {'code': 'model_unavailable'},
                ],
              ),
            ],
            'active': {'phase': 'execution', 'position': 1, 'state': state},
          },
        ),
        size: const Size(480, 800),
        text: 1.5,
      );
      expect(tester.takeException(), isNull);
      final line = find.byKey(const ValueKey('graph-member-state'));
      expect(line, findsOneWidget);
      expect(
        find.descendant(of: line, matching: find.text('$text $text')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('graph-member-issue')), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          'Execution Execution, Implementer Implementer, Pi, '
          'Agent default Agent default, $text $text, '
          'A local runtime is stopped A local runtime is stopped · '
          'A model is not available A model is not available',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  }

  testWidgets('a phase without agents says so', (tester) async {
    await show(
      tester,
      TeamGraph(
        tr: (s) => s,
        project: {...card('x'), 'planning': [], 'execution': []},
      ),
    );
    expect(find.text('No agents in this phase yet.'), findsNWidgets(2));
  });

  group('in the project page', () {
    Future<GlobalKey<AiProjectCenterPageState>> mount(
      WidgetTester tester,
      Size size, {
      double text = 1,
      bool board = true,
      bool openNew = false,
    }) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      tester.platformDispatcher.textScaleFactorTestValue = text;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final projected = {
        ...card(
          't',
          bucket: 'ready',
          activity: 'ready_to_run',
          stage: 'ready',
          status: 'ready',
        ),
        'planning': [member('planning', 0, 'Claude Code', 'lead')],
        'execution': [
          member('execution', 0, 'Claude Code', 'lead'),
          member('execution', 1, 'Codex', 'reviewer'),
        ],
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(title: const Text('Maprisma')),
            body: AiProjectCenterPage(
              key: key,
              tr: (s) => s,
              onCall: (op, args) async {
                if (op == 'list') {
                  return {
                    'projects': [projected],
                    if (board) 'capabilities': ['board'],
                  };
                }
                if (op == 'get') {
                  // The full record only: rail and graph must come from
                  // the list's projection.
                  return {
                    'project': {
                      'id': 't',
                      'title': 'Project t',
                      'path': '/home/user/work/t',
                      'status': 'ready',
                      'phase': 'running',
                      'revision': 1,
                      'brief': 'b',
                      'plan': '1. Plan.',
                      'team': [
                        {'agent': 'claude', 'role': 'lead'},
                        {'agent': 'codex', 'role': 'reviewer'},
                      ],
                      'events': [],
                      'plan_version': 1,
                      'approved_version': 1,
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
      if (!board) return key;
      final button = find.byKey(ValueKey(openNew ? 'board-new' : 'card-open'));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      return key;
    }

    testWidgets('the rail between breadcrumb and tabs; the graph beside', (
      tester,
    ) async {
      await mount(tester, const Size(1400, 1000));
      final rail = find.byKey(const ValueKey('large-rail'));
      expect(rail, findsOneWidget);
      final crumb = tester.getTopLeft(
        find.byKey(const ValueKey('breadcrumb-projects')),
      );
      final tabs = tester.getTopLeft(find.widgetWithText(ChoiceChip, 'Goal'));
      expect(tester.getTopLeft(rail).dy, greaterThan(crumb.dy));
      expect(tester.getTopLeft(rail).dy, lessThan(tabs.dy));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Team'));
      await tester.pumpAndSettle();
      final graph = find.byKey(const ValueKey('team-graph'));
      // Beside the form: to the right of it, starting at the tab's top.
      expect(tester.getTopLeft(graph).dx, greaterThan(700));
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrow with large text: compact rail, graph below the form', (
      tester,
    ) async {
      await mount(tester, const Size(480, 360), text: 1.5);
      expect(find.byKey(const ValueKey('large-rail-compact')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('project-tab-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Team').last);
      await tester.pumpAndSettle();
      final graph = find.byKey(const ValueKey('team-graph'));
      await tester.scrollUntilVisible(
        graph,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      final form = find.byType(DropdownButtonFormField<String>).first;
      expect(
        tester.getTopLeft(graph).dy,
        greaterThan(tester.getTopLeft(form).dy),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a new project has no rail and no graph yet', (tester) async {
      await mount(tester, const Size(1400, 1000), openNew: true);
      expect(find.byKey(const ValueKey('large-rail')), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Team'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('team-graph')), findsNothing);
    });

    testWidgets('an older backend (no board): no rail, no graph', (
      tester,
    ) async {
      await mount(tester, const Size(1400, 1000), board: false);
      await tester.tap(find.text('Project t').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('large-rail')), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Team'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('team-graph')), findsNothing);
    });
  });
}
