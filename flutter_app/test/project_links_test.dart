import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/ai_project_center.dart';
import 'package:maprisma/project_board.dart';
import 'package:maprisma/project_page_parts.dart';

import 'project_board_test.dart' show card;

/// The project side of the links between the tabs (task 091): the agent chip
/// and Show on map.
Map<String, dynamic> member(String phase, int position, String agent) => {
  'phase': phase,
  'position': position,
  'agent': agent,
  'name': agent == 'claude' ? 'Claude Code' : agent,
  'role': position == 0 ? 'lead' : 'reviewer',
  'issues': <Map>[],
};

final projects = [
  {
    ...card(
      'c1',
      bucket: 'running',
      activity: 'running',
      stage: 'run',
      status: 'running',
    ),
    'execution': [member('execution', 0, 'claude')],
  },
  {
    ...card('c2'),
    'planning': [member('planning', 0, 'codex')],
    'execution': [member('execution', 0, 'claude')],
  },
  {
    ...card('x1'),
    'execution': [member('execution', 0, 'codex')],
  },
  // A completed project whose runtime stopped later: still Agents finished.
  {
    ...card(
      'f1',
      bucket: 'finished',
      activity: 'agents_finished',
      stage: 'finished',
      status: 'completed',
      issues: [
        {'code': 'runtime_stopped'},
      ],
    ),
    'execution': [member('execution', 0, 'claude')],
  },
];

class Host {
  ({String command, String name})? agent = (
    command: 'claude',
    name: 'Claude Code',
  );
  final shown = <String>[];
}

Future<GlobalKey<AiProjectCenterPageState>> mount(
  WidgetTester tester,
  Host host, {
  Size size = const Size(1400, 900),
}) async {
  final key = GlobalKey<AiProjectCenterPageState>();
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => AiProjectCenterPage(
            key: key,
            tr: (s) => s,
            agent: host.agent,
            onClearAgent: () => setState(() => host.agent = null),
            onShowOnMap: host.shown.add,
            onCall: (op, args) async {
              if (op == 'list') {
                return {
                  'projects': projects,
                  'capabilities': ['board'],
                };
              }
              if (op == 'get') {
                final p = projects.firstWhere((p) => p['id'] == args['id']);
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
    ),
  );
  await tester.pumpAndSettle();
  return key;
}

Finder cardOf(String id) => find.byKey(ValueKey('project-card-$id'));

String chipText(WidgetTester tester, String code) {
  final chip = tester.widget<FilterChip>(
    find.byKey(ValueKey('board-filter-$code')),
  );
  return (chip.label as Text).data!;
}

void main() {
  testWidgets('the agent chip: only its projects, counts follow it', (
    tester,
  ) async {
    final host = Host();
    await mount(tester, host);
    expect(find.byKey(const ValueKey('board-agent')), findsOneWidget);
    expect(find.text('Claude Code'), findsWidgets);
    expect(cardOf('c1'), findsOneWidget);
    expect(cardOf('c2'), findsOneWidget);
    expect(cardOf('f1'), findsOneWidget);
    expect(cardOf('x1'), findsNothing);
    expect(chipText(tester, 'all'), 'All 3');
    expect(chipText(tester, 'drafts'), 'Drafts 1');
    // The completed project stays Agents finished under the chip.
    expect(chipText(tester, 'finished'), 'Agents finished 1');
  });

  testWidgets('with a status filter both combine; × clears only the chip', (
    tester,
  ) async {
    final host = Host();
    await mount(tester, host);
    await tester.ensureVisible(
      find.byKey(const ValueKey('board-filter-drafts')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('board-filter-drafts')));
    await tester.pumpAndSettle();
    expect(cardOf('c2'), findsOneWidget);
    expect(cardOf('x1'), findsNothing);
    expect(cardOf('c1'), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('board-agent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show all agents'));
    await tester.pumpAndSettle();
    expect(host.agent, isNull);
    expect(find.byKey(const ValueKey('board-agent')), findsNothing);
    // The status filter stays.
    expect(cardOf('x1'), findsOneWidget);
    expect(cardOf('c1'), findsNothing);
  });

  testWidgets('All clears both', (tester) async {
    final host = Host();
    await mount(tester, host);
    await tester.ensureVisible(
      find.byKey(const ValueKey('board-filter-drafts')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('board-filter-drafts')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('board-filter-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('board-filter-all')));
    await tester.pumpAndSettle();
    expect(host.agent, isNull);
    for (final id in ['c1', 'c2', 'x1', 'f1']) {
      expect(cardOf(id), findsOneWidget);
    }
  });

  testWidgets('a chip that leaves nothing says so (no New project card)', (
    tester,
  ) async {
    final host = Host()..agent = (command: 'pi', name: 'Pi');
    await mount(tester, host);
    expect(find.byKey(const ValueKey('board-none')), findsOneWidget);
    expect(find.byKey(const ValueKey('board-empty-new')), findsNothing);
  });

  testWidgets('back from a project the chip would hide: the chip goes', (
    tester,
  ) async {
    final host = Host();
    final key = await mount(tester, host);
    await tester.tap(
      find.descendant(
        of: cardOf('c2'),
        matching: find.byKey(const ValueKey('card-open')),
      ),
    );
    await tester.pumpAndSettle();
    expect(key.currentState!.projectOpen, isTrue);
    // Meanwhile Claude left its team: the chip would hide it.
    projects[1]['execution'] = [member('execution', 0, 'codex')];
    addTearDown(
      () => projects[1]['execution'] = [member('execution', 0, 'claude')],
    );
    await key.currentState!.refresh();
    await tester.pumpAndSettle();
    await key.currentState!.backToBoard();
    await tester.pumpAndSettle();
    expect(host.agent, isNull);
    expect(cardOf('c2'), findsOneWidget);
  });

  testWidgets('a new project saved on the way back that the chip would hide: '
      'the chip goes, the project is shown', (tester) async {
    final host = Host();
    final list = [...projects];
    final key = GlobalKey<AiProjectCenterPageState>();
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => AiProjectCenterPage(
              key: key,
              tr: (s) => s,
              agent: host.agent,
              onClearAgent: () => setState(() => host.agent = null),
              onCall: (op, args) async {
                if (op == 'list') {
                  return {
                    'projects': list,
                    'capabilities': ['board'],
                  };
                }
                if (op == 'save') {
                  final saved = {
                    ...card('n1'),
                    'execution': [member('execution', 0, 'codex')],
                  };
                  list.add(saved);
                  return {
                    'project': {
                      ...saved,
                      'title': args['title'],
                      'brief': args['brief'],
                      'plan': '',
                      'team': [
                        {'agent': 'codex', 'role': 'lead'},
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
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('board-new')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Project title'),
      'New one',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Project goal'),
      'Do it.',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Working folder'),
      '/home/user/work/n1',
    );
    await tester.pump();
    final back = key.currentState!.backToBoard();
    await tester.pumpAndSettle();
    expect(find.text('Save project changes?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(await back, isTrue);
    await tester.pumpAndSettle();
    expect(host.agent, isNull);
    expect(cardOf('n1'), findsOneWidget);
  });

  testWidgets('Show on map from a Team graph member, by its agent', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final shown = <String>[];
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TeamGraph(
              tr: (s) => s,
              onShowOnMap: shown.add,
              project: projects[1],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('graph-show-planning-0')));
    await tester.pump();
    expect(shown, ['codex']);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Show Claude Code on map')),
      isSemantics(isButton: true, isFocusable: true, hasTapAction: true),
    );
    expect(find.byTooltip('Show Claude Code on map'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('no Show on map without the shell', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TeamGraph(tr: (s) => s, project: projects[1]),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('graph-show-planning-0')), findsNothing);
  });

  test('namesAgent: planning or execution', () {
    expect(namesAgent(projects[1], 'codex'), isTrue);
    expect(namesAgent(projects[1], 'claude'), isTrue);
    expect(namesAgent(projects[0], 'codex'), isFalse);
    expect(namesAgent(projects[0], null), isTrue);
  });

  test('the board keeps its own filter type', () {
    expect(BoardFilter.values.first.code, 'running');
  });
}
