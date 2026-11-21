import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/ai_project_center.dart';
import 'package:maprisma/project_board.dart';
import 'package:maprisma_core/maprisma_core.dart' show ServiceError;

/// The Projects board (task 088).
Map<String, dynamic> card(
  String id, {
  String bucket = 'drafts',
  String activity = 'draft',
  String stage = 'goal',
  String status = 'draft',
  String? second,
  Map<String, dynamic>? active,
  List<Map<String, dynamic>>? execution,
  List<Map<String, dynamic>> issues = const [],
  String? runId,
  String updated = '2026-11-21T10:00:00.000Z',
}) => {
  'id': id,
  'title': 'Project $id',
  'path': '/home/user/work/$id',
  'status': status,
  'revision': 1,
  'updated_at': updated,
  'phase': 'running',
  'run_id': runId,
  'stage': stage,
  'activity': activity,
  'second': second,
  'bucket': bucket,
  'approval_valid': false,
  'needs_reconciliation': false,
  'processes_stopping': false,
  'issues': issues,
  'planning': <Map<String, dynamic>>[],
  'execution':
      execution ??
      [
        {
          'phase': 'execution',
          'position': 0,
          'agent': 'claude',
          'name': 'Claude Code',
          'role': 'lead',
          'issues': <Map>[],
        },
      ],
  'active': active,
  'setup_agent': null,
  'setup_error': null,
  'last_event': {
    'at': '2026-11-21T10:00:00.000Z',
    'type': 'saved',
    'text': 'Saved.',
  },
};

Future<void> showBoard(
  WidgetTester tester,
  List<Map<String, dynamic>> projects, {
  BoardFilter? filter,
  ValueChanged<BoardFilter?>? onFilter,
  void Function(Map<String, dynamic>)? onOpen,
  void Function(Map<String, dynamic>)? onReview,
  void Function(Map<String, dynamic>)? onPause,
  Set<String> busy = const {},
  Size size = const Size(1200, 900),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ProjectBoard(
          projects: projects,
          tr: (s) => s,
          filter: filter,
          onFilter: onFilter,
          onOpen: onOpen ?? (_) {},
          onNew: () {},
          onReview: onReview ?? (_) {},
          onPause: onPause ?? (_) {},
          busyIds: busy,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('the summary row counts each filter; chosen again clears', (
    tester,
  ) async {
    BoardFilter? chosen = BoardFilter.ready;
    final projects = [
      card('a', bucket: 'running', activity: 'running', stage: 'run'),
      card('b', bucket: 'needs_you', activity: 'needs_review'),
      card('c', bucket: 'needs_you', activity: 'paused'),
      card('d'),
    ];
    await showBoard(
      tester,
      projects,
      filter: BoardFilter.needsYou,
      onFilter: (f) => chosen = f,
    );
    expect(find.text('All 4'), findsOneWidget);
    expect(find.text('Running 1'), findsOneWidget);
    expect(find.text('Needs you 2'), findsOneWidget);
    expect(find.text('Drafts 1'), findsOneWidget);
    // Only the filtered cards.
    expect(find.byKey(const ValueKey('project-card-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('project-card-a')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('board-filter-needs_you')));
    expect(chosen, isNull);
    await tester.tap(find.byKey(const ValueKey('board-filter-running')));
    expect(chosen, BoardFilter.running);
  });

  testWidgets('a card: activity, second line, stage, team and actions', (
    tester,
  ) async {
    Map<String, dynamic>? reviewed, paused;
    final team = [
      for (final (i, name) in [
        'Claude Code',
        'Codex',
        'Antigravity',
        'Pi',
        'Gemini',
        'Copilot',
      ].indexed)
        {
          'phase': 'execution',
          'position': i,
          'agent': name.toLowerCase(),
          'name': name,
          'role': i == 0 ? 'lead' : 'implementer',
          'issues': <Map>[],
        },
    ];
    final projects = [
      card(
        'r',
        bucket: 'needs_you',
        activity: 'needs_review',
        stage: 'approval',
        status: 'awaiting_review',
        second: 'check_changes_first',
      ),
      card(
        'x',
        bucket: 'running',
        activity: 'running',
        stage: 'run',
        status: 'running',
        runId: 'run-1',
        execution: team,
        active: {'phase': 'execution', 'position': 5, 'state': 'active'},
      ),
    ];
    await showBoard(
      tester,
      projects,
      onReview: (p) => reviewed = p,
      onPause: (p) => paused = p,
    );
    final review = find.byKey(const ValueKey('project-card-r'));
    expect(
      find.descendant(of: review, matching: find.text('Needs your review')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: review,
        matching: find.text('Check the changes first'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: review, matching: find.text('Approval')),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(
        of: review,
        matching: find.byKey(const ValueKey('card-review')),
      ),
    );
    expect(reviewed?['id'], 'r');
    // The running card: four nodes, the active sixth member among them.
    final running = find.byKey(const ValueKey('project-card-x'));
    expect(
      find.descendant(of: running, matching: find.text('Copilot')),
      findsOneWidget,
    );
    // Its state as a symbol and read out; its configuration stays shown.
    expect(
      find.descendant(
        of: running,
        matching: find.byTooltip(
          'Execution · Implementer · Agent default · Working',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: running, matching: find.text('+2')),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(
        of: running,
        matching: find.byKey(const ValueKey('card-pause')),
      ),
    );
    expect(paused?['run_id'], 'run-1');
    // Review is only for a project waiting for review.
    expect(
      find.descendant(
        of: running,
        matching: find.byKey(const ValueKey('card-review')),
      ),
      findsNothing,
    );
  });

  testWidgets('Retry pause while pausing; busy disables it', (tester) async {
    await showBoard(
      tester,
      [
        card(
          'p',
          bucket: 'running',
          activity: 'stopping',
          stage: 'run',
          status: 'pausing',
        ),
      ],
      busy: {'p'},
    );
    final button = tester.widget<TextButton>(
      find.byKey(const ValueKey('card-pause')),
    );
    expect(find.text('Retry pause'), findsOneWidget);
    expect(button.onPressed, isNull);
  });

  testWidgets('an empty board offers a new project', (tester) async {
    await showBoard(tester, []);
    expect(find.byKey(const ValueKey('board-empty-new')), findsOneWidget);
  });

  testWidgets('64 projects scroll; 480 × 360 with large text fits', (
    tester,
  ) async {
    final many = [for (var i = 0; i < 64; i++) card('$i')];
    await showBoard(tester, many);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('project-card-63')),
      400,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.byKey(const ValueKey('project-card-63')), findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(480, 360));
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(480, 360),
            textScaler: TextScaler.linear(1.5),
          ),
          child: Scaffold(
            body: ProjectBoard(
              projects: many,
              tr: (s) => s,
              onOpen: (_) {},
              onNew: () {},
              onReview: (_) {},
              onPause: (_) {},
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  group('in the Project Center page', () {
    Future<List<(String, Map<String, dynamic>)>> mountPage(
      WidgetTester tester,
      GlobalKey<AiProjectCenterPageState> key, {
      bool board = true,
    }) async {
      final calls = <(String, Map<String, dynamic>)>[];
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final projects = [
        card(
          'a1',
          bucket: 'running',
          activity: 'running',
          stage: 'run',
          status: 'running',
          runId: 'run-7',
          active: {'phase': 'execution', 'position': 0, 'state': 'active'},
        ),
        card('b2'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiProjectCenterPage(
              key: key,
              tr: (s) => s,
              onCall: (op, args) async {
                calls.add((op, args));
                if (op == 'list') {
                  return {
                    'projects': projects,
                    if (board) 'capabilities': ['summary2', 'board'],
                  };
                }
                if (op == 'get') {
                  final p = projects.firstWhere((p) => p['id'] == args['id']);
                  return {
                    'project': {
                      ...p,
                      'brief': 'Do it.',
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
      return calls;
    }

    testWidgets('a card opens the project; the breadcrumb returns, focus on '
        'the card', (tester) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      await mountPage(tester, key);
      expect(find.byType(ProjectBoard), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('project-card-b2')),
          matching: find.byKey(const ValueKey('card-open')),
        ),
      );
      await tester.pumpAndSettle();
      expect(key.currentState!.projectOpen, isTrue);
      expect(find.byType(ProjectBoard), findsNothing);
      expect(find.byKey(const ValueKey('breadcrumb-projects')), findsOneWidget);
      // Unsaved changes ask before the board; Cancel stays.
      await tester.enterText(
        find.widgetWithText(TextField, 'Project title'),
        'Changed',
      );
      await tester.tap(find.byKey(const ValueKey('breadcrumb-projects')));
      await tester.pumpAndSettle();
      expect(find.text('Save project changes?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(key.currentState!.projectOpen, isTrue);
      await tester.tap(find.byKey(const ValueKey('breadcrumb-projects')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Discard'));
      await tester.pumpAndSettle();
      expect(find.byType(ProjectBoard), findsOneWidget);
      // The keyboard is on the card that was opened.
      final focus = FocusManager.instance.primaryFocus;
      expect(
        focus?.context == null
            ? false
            : find
                  .ancestor(
                    of: find.byWidget(focus!.context!.widget),
                    matching: find.byKey(const ValueKey('project-card-b2')),
                  )
                  .evaluate()
                  .isNotEmpty,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Pause on a card sends the run it shows', (tester) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      final calls = await mountPage(tester, key);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('project-card-a1')),
          matching: find.byKey(const ValueKey('card-pause')),
        ),
      );
      await tester.pumpAndSettle();
      final pause = calls.singleWhere((c) => c.$1 == 'pause');
      expect(pause.$2, {'id': 'a1', 'run_id': 'run-7'});
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an older backend keeps the list page and says so', (
      tester,
    ) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      await mountPage(tester, key, board: false);
      expect(find.byType(ProjectBoard), findsNothing);
      expect(find.byKey(const ValueKey('board-needs-update')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the board reads every 2 s while a project runs', (
      tester,
    ) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      final calls = await mountPage(tester, key);
      final before = calls.where((c) => c.$1 == 'list').length;
      // A running project: every 2 s.
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(calls.where((c) => c.$1 == 'list').length, greaterThan(before));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a project page at 480 × 360 with large text: one action and '
        'More', (tester) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      await mountPage(tester, key);
      await tester.binding.setSurfaceSize(const Size(480, 360));
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      final open = find.descendant(
        of: find.byKey(const ValueKey('project-card-a1')),
        matching: find.byKey(const ValueKey('card-open')),
      );
      await tester.ensureVisible(open);
      await tester.pumpAndSettle();
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('project-more')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('review: Review plan opens the Plan tab', (tester) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      final calls = <String>[];
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final projects = [
        card(
          'r1',
          bucket: 'needs_you',
          activity: 'needs_review',
          stage: 'approval',
          status: 'awaiting_review',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiProjectCenterPage(
              key: key,
              tr: (s) => s,
              onCall: (op, args) async {
                calls.add(op);
                if (op == 'list') {
                  return {
                    'projects': projects,
                    'capabilities': ['board'],
                  };
                }
                if (op == 'get') {
                  return {
                    'project': {
                      ...projects.single,
                      'brief': 'Do it.',
                      'plan': '1. The plan.',
                      'team': [
                        {'agent': 'claude', 'role': 'lead'},
                      ],
                      'events': [],
                      'plan_version': 1,
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
      await tester.tap(find.byKey(const ValueKey('card-review')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Project plan'), findsOneWidget);
      // On the board no project's details are read.
      calls.clear();
      await key.currentState!.backToBoard();
      await tester.pumpAndSettle();
      await key.currentState!.refresh();
      await tester.pumpAndSettle();
      expect(calls, isNot(contains('get')));
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('board states and rhythm', () {
    Future<void> mountWith(
      WidgetTester tester,
      GlobalKey<AiProjectCenterPageState> key,
      Future<Map<String, dynamic>> Function(String op, Map args) call, {
      Size size = const Size(1200, 900),
      String Function(String)? tr,
    }) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiProjectCenterPage(
              key: key,
              tr: tr ?? (s) => s,
              onCall: (op, args) => call(op, args),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Map<String, dynamic> withBoard(
      List<Map<String, dynamic>> projects, {
      Map<String, dynamic>? summary,
    }) => {
      'projects': projects,
      'capabilities': ['board'],
      'summary': ?summary,
    };

    testWidgets('a failed Open stays on the board with the reason', (
      tester,
    ) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      await mountWith(tester, key, (op, args) async {
        if (op == 'list') return withBoard([card('gone')]);
        if (op == 'get') throw ServiceError('project_unknown');
        return {'profiles': [], 'runtimes': []};
      });
      await tester.tap(find.byKey(const ValueKey('card-open')));
      await tester.pumpAndSettle();
      expect(key.currentState!.projectOpen, isFalse);
      expect(find.byType(ProjectBoard), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a store fault is a banner; unreachable says so with Retry', (
      tester,
    ) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      var fail = true;
      await mountWith(tester, key, (op, args) async {
        if (op == 'list') {
          if (fail) throw StateError('no backend');
          return withBoard([], summary: {'error': 'project_store_corrupt'});
        }
        return {'profiles': [], 'runtimes': []};
      });
      // Never the old page, never zero: unavailable, with Retry.
      expect(find.byKey(const ValueKey('board-unavailable')), findsOneWidget);
      expect(find.byType(ProjectBoard), findsNothing);
      fail = false;
      await tester.tap(find.byKey(const ValueKey('board-retry')));
      await tester.pumpAndSettle();
      expect(find.byType(ProjectBoard), findsOneWidget);
      expect(find.byKey(const ValueKey('board-store-fault')), findsOneWidget);
      expect(find.byKey(const ValueKey('board-unavailable')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('team setup: its helper is shown and can be paused', (
      tester,
    ) async {
      await showBoard(tester, [
        {
          ...card('s', bucket: 'running', activity: 'setting_up_team'),
          'phase': 'setup',
          'status': 'planning',
          'setup_agent': {'agent': 'claude', 'name': 'Claude Code'},
        },
      ]);
      expect(find.byKey(const ValueKey('card-pause')), findsOneWidget);
      expect(
        find.byTooltip('Setup helper · Agent default · Working'),
        findsOneWidget,
      );
    });

    testWidgets('a member with a problem is marked', (tester) async {
      await showBoard(tester, [
        card(
          'm',
          execution: [
            {
              'phase': 'execution',
              'position': 0,
              'agent': 'pi',
              'name': 'Pi',
              'role': 'lead',
              'issues': [
                {'code': 'runtime_stopped'},
              ],
            },
          ],
        ),
      ]);
      expect(find.byKey(const ValueKey('node-issue')), findsOneWidget);
    });

    testWidgets('the last event in the user\'s words, with its time', (
      tester,
    ) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      final today = DateTime.now().toUtc().toIso8601String();
      await mountWith(tester, key, (op, args) async {
        if (op == 'list') {
          return withBoard([
            {
              ...card('e'),
              'last_event': {
                'at': today,
                'type': 'failed',
                'text': 'project_agent_unavailable',
              },
            },
          ]);
        }
        return {'profiles': [], 'runtimes': []};
      });
      final line = tester
          .widget<Text>(find.byKey(const ValueKey('card-event')))
          .data!;
      expect(line, contains(' · '));
      expect(line, isNot(contains('project_agent_unavailable')));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('back from a running project: the board slows down when it '
        'ended', (tester) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      var status = 'running';
      var lists = 0;
      await mountWith(tester, key, (op, args) async {
        if (op == 'list') {
          lists++;
          return withBoard([
            card(
              'x',
              bucket: status == 'running' ? 'running' : 'finished',
              status: status,
              activity: status == 'running' ? 'running' : 'agents_finished',
            ),
          ]);
        }
        if (op == 'get') {
          return {
            'project': {
              ...card('x', status: 'running'),
              'brief': 'b',
              'plan': 'p',
              'team': [
                {'agent': 'claude', 'role': 'lead'},
              ],
              'events': [],
              'plan_version': 1,
              'approved_version': 1,
            },
          };
        }
        return {'profiles': [], 'runtimes': []};
      });
      await tester.tap(find.byKey(const ValueKey('card-open')));
      await tester.pumpAndSettle();
      await key.currentState!.backToBoard();
      await tester.pumpAndSettle();
      status = 'completed';
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(key.currentState!.hasActive, isFalse);
      // Nothing runs: no read for the next 14 s, then one.
      final before = lists;
      for (var i = 0; i < 7; i++) {
        await tester.pump(const Duration(seconds: 2));
      }
      expect(lists, before);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(lists, before + 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a focused card stays in place when a refresh reorders', (
      tester,
    ) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      var urgent = false;
      await mountWith(tester, key, (op, args) async {
        if (op == 'list') {
          final a = card('a');
          final b = card(
            'b',
            bucket: urgent ? 'attention' : 'drafts',
            activity: urgent ? 'failed' : 'draft',
          );
          return withBoard(urgent ? [b, a] : [a, b]);
        }
        return {'profiles': [], 'runtimes': []};
      });
      // The card's own focus node (the one the board gives it).
      final node = tester
          .widget<InkWell>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('project-card-a')),
                  matching: find.byType(InkWell),
                )
                .first,
          )
          .focusNode!;
      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isTrue);
      final before = tester.getTopLeft(
        find.byKey(const ValueKey('project-card-a')),
      );
      urgent = true;
      await key.currentState!.refresh();
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('project-card-a'))),
        before,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('back from the last of 64 cards: it has the keyboard', (
      tester,
    ) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      final many = [for (var i = 0; i < 64; i++) card('$i')];
      await mountWith(tester, key, (op, args) async {
        if (op == 'list') return withBoard(many);
        if (op == 'get') {
          return {
            'project': {
              ...many.last,
              'brief': 'b',
              'plan': '',
              'team': [],
              'events': [],
              'plan_version': 0,
              'approved_version': null,
            },
          };
        }
        return {'profiles': [], 'runtimes': []};
      });
      final last = find.byKey(const ValueKey('project-card-63'));
      await tester.scrollUntilVisible(
        last,
        400,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(
        find.descendant(
          of: last,
          matching: find.byKey(const ValueKey('card-open')),
        ),
      );
      await tester.pumpAndSettle();
      expect(key.currentState!.projectOpen, isTrue);
      await key.currentState!.backToBoard();
      await tester.pumpAndSettle();
      final focus = FocusManager.instance.primaryFocus;
      expect(
        focus?.context != null &&
            find
                .ancestor(
                  of: find.byWidget(focus!.context!.widget),
                  matching: last,
                )
                .evaluate()
                .isNotEmpty,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('long words in a narrow window do not overflow', (
      tester,
    ) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await mountWith(
        tester,
        key,
        (op, args) async {
          if (op == 'list') {
            return withBoard([
              card(
                'w',
                bucket: 'needs_you',
                activity: 'needs_review',
                status: 'awaiting_review',
                stage: 'approval',
              ),
            ]);
          }
          if (op == 'get') {
            return {
              'project': {
                ...card('w', status: 'awaiting_review'),
                'brief': 'b',
                'plan': 'p',
                'team': [
                  {'agent': 'claude', 'role': 'lead'},
                ],
                'events': [],
                'plan_version': 1,
                'approved_version': null,
              },
            };
          }
          return {'profiles': [], 'runtimes': []};
        },
        size: const Size(480, 360),
        // Long translations everywhere.
        tr: (s) => '$s $s',
      );
      final open = find.byKey(const ValueKey('card-open'));
      await tester.ensureVisible(open);
      await tester.pumpAndSettle();
      await tester.tap(open);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Edited');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a pressed card stays in place when a refresh reorders', (
      tester,
    ) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      var urgent = false;
      await mountWith(tester, key, (op, args) async {
        if (op == 'list') {
          final a = card('a');
          final b = card(
            'b',
            bucket: urgent ? 'attention' : 'drafts',
            activity: urgent ? 'failed' : 'draft',
          );
          return withBoard(urgent ? [b, a] : [a, b]);
        }
        return {'profiles': [], 'runtimes': []};
      });
      final a = find.byKey(const ValueKey('project-card-a'));
      final before = tester.getTopLeft(a);
      final gesture = await tester.startGesture(tester.getCenter(a));
      urgent = true;
      await key.currentState!.refresh();
      await tester.pump();
      expect(tester.getTopLeft(a), before);
      await gesture.cancel();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a card that would move while its project is open gets the '
        'keyboard back', (tester) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      var moved = false;
      List<Map<String, dynamic>> many() {
        final all = [for (var i = 0; i < 64; i++) card('$i')];
        if (!moved) return all;
        // The opened card became the most urgent one.
        final last = {
          ...all.removeLast(),
          'bucket': 'attention',
          'activity': 'failed',
        };
        return [last, ...all];
      }

      await mountWith(tester, key, (op, args) async {
        if (op == 'list') return withBoard(many());
        if (op == 'get') {
          return {
            'project': {
              ...card('63'),
              'brief': 'b',
              'plan': '',
              'team': [],
              'events': [],
              'plan_version': 0,
              'approved_version': null,
            },
          };
        }
        return {'profiles': [], 'runtimes': []};
      });
      final last = find.byKey(const ValueKey('project-card-63'));
      await tester.scrollUntilVisible(
        last,
        400,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(
        find.descendant(
          of: last,
          matching: find.byKey(const ValueKey('card-open')),
        ),
      );
      await tester.pumpAndSettle();
      moved = true;
      await key.currentState!.refresh();
      await tester.pumpAndSettle();
      await key.currentState!.backToBoard();
      await tester.pumpAndSettle();
      final focus = FocusManager.instance.primaryFocus;
      expect(
        focus?.context != null &&
            find
                .ancestor(
                  of: find.byWidget(focus!.context!.widget),
                  matching: last,
                )
                .evaluate()
                .isNotEmpty,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failed Pause keeps its reason; a second click waits', (
      tester,
    ) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      var pauses = 0;
      var lists = 0;
      final answer = Completer<Map<String, dynamic>>();
      await mountWith(tester, key, (op, args) async {
        if (op == 'list') {
          lists++;
          return withBoard([
            card(
              'p',
              bucket: 'running',
              activity: 'running',
              status: 'running',
              runId: 'old-run',
              active: {'phase': 'execution', 'position': 0, 'state': 'active'},
            ),
          ]);
        }
        if (op == 'pause') {
          pauses++;
          return answer.future;
        }
        return {'profiles': [], 'runtimes': []};
      });
      final pause = find.byKey(const ValueKey('card-pause'));
      await tester.tap(pause);
      await tester.pump();
      await tester.tap(pause);
      await tester.pump();
      expect(pauses, 1);
      final before = lists;
      // A newer run than the card showed.
      answer.completeError(ServiceError('project_changed'));
      await tester.pumpAndSettle();
      expect(lists, before + 1);
      expect(find.text('The project operation failed.'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Text &&
              (w.style?.color ==
                  Theme.of(tester.element(pause)).colorScheme.error),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failed read of the open project leaves the board usable', (
      tester,
    ) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      var gone = false;
      await mountWith(tester, key, (op, args) async {
        if (op == 'list') return withBoard([card('d')]);
        if (op == 'get') {
          if (gone) throw ServiceError('project_unknown');
          return {
            'project': {
              ...card('d'),
              'brief': 'b',
              'plan': '',
              'team': [],
              'events': [],
              'plan_version': 0,
              'approved_version': null,
            },
          };
        }
        return {'profiles': [], 'runtimes': []};
      });
      await tester.tap(find.byKey(const ValueKey('card-open')));
      await tester.pumpAndSettle();
      gone = true;
      await key.currentState!.refresh();
      await tester.pumpAndSettle();
      await key.currentState!.backToBoard();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('board-unavailable')), findsNothing);
      expect(find.text('All 1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a stopped team setup marks its helper stopped', (
      tester,
    ) async {
      await showBoard(tester, [
        {
          ...card('s', bucket: 'attention', activity: 'interrupted'),
          'phase': 'setup',
          'status': 'interrupted',
          'setup_agent': {'agent': 'claude', 'name': 'Claude Code'},
        },
      ]);
      expect(
        find.byTooltip('Setup helper · Agent default · Stopped'),
        findsOneWidget,
      );
    });

    testWidgets('the app header, a warning and an edit at 480 × 360', (
      tester,
    ) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.binding.setSurfaceSize(const Size(480, 360));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(title: const Text('Maprisma')),
            body: AiProjectCenterPage(
              key: key,
              tr: (s) => '$s $s',
              onCall: (op, args) async {
                if (op == 'list') {
                  return withBoard([
                    {
                      ...card('w', status: 'paused', activity: 'stopping'),
                      'processes_stopping': true,
                    },
                  ]);
                }
                if (op == 'get') {
                  return {
                    'project': {
                      ...card('w', status: 'paused'),
                      'processes_stopping': true,
                      'brief': 'b',
                      'plan': 'p',
                      'team': [
                        {'agent': 'claude', 'role': 'lead'},
                      ],
                      'events': [],
                      'plan_version': 1,
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
      final open = find.byKey(const ValueKey('card-open'));
      await tester.ensureVisible(open);
      await tester.pumpAndSettle();
      await tester.tap(open);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Edited');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // The footer's action stays reachable.
      expect(find.byKey(const ValueKey('project-more')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('profiles that cannot be read leave the board usable', (
      tester,
    ) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      await mountWith(tester, key, (op, args) async {
        if (op == 'list') return withBoard([card('k')]);
        if (op == 'profiles') throw StateError('scan failed');
        return {};
      });
      expect(find.byType(ProjectBoard), findsOneWidget);
      expect(find.byKey(const ValueKey('board-unavailable')), findsNothing);
      expect(find.text('All 1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failed Pause keeps its reason past a poll on its way', (
      tester,
    ) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      Completer<Map<String, dynamic>>? held;
      final pausing = Completer<Map<String, dynamic>>();
      await mountWith(tester, key, (op, args) async {
        if (op == 'list') {
          final wait = held;
          final answer = withBoard([
            card(
              'p',
              bucket: 'running',
              activity: 'running',
              status: 'running',
              runId: 'r',
              active: {'phase': 'execution', 'position': 0, 'state': 'active'},
            ),
          ]);
          if (wait != null) {
            held = null;
            await wait.future;
          }
          return answer;
        }
        if (op == 'pause') return pausing.future;
        return {'profiles': [], 'runtimes': []};
      });
      await tester.tap(find.byKey(const ValueKey('card-pause')));
      await tester.pump();
      // A poll starts and waits; meanwhile the pause fails.
      final poll = held = Completer();
      unawaited(key.currentState!.refresh());
      await tester.pump();
      pausing.completeError(ServiceError('project_still_pausing'));
      await tester.pump();
      poll.complete({});
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Some agent processes are still stopping. Try again shortly.',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('back to a card that left the filter: shown and focused', (
      tester,
    ) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      var running = false;
      await mountWith(tester, key, (op, args) async {
        if (op == 'list') {
          return withBoard([
            running
                ? card('f', bucket: 'running', activity: 'running')
                : card('f'),
            card('g'),
          ]);
        }
        if (op == 'get') {
          return {
            'project': {
              ...card('f'),
              'brief': 'b',
              'plan': '',
              'team': [],
              'events': [],
              'plan_version': 0,
              'approved_version': null,
            },
          };
        }
        return {'profiles': [], 'runtimes': []};
      });
      final drafts = find.byKey(const ValueKey('board-filter-drafts'));
      await tester.ensureVisible(drafts);
      await tester.pumpAndSettle();
      await tester.tap(drafts);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('project-card-g')), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('project-card-f')),
          matching: find.byKey(const ValueKey('card-open')),
        ),
      );
      await tester.pumpAndSettle();
      running = true;
      await key.currentState!.refresh();
      await tester.pumpAndSettle();
      await key.currentState!.backToBoard();
      await tester.pumpAndSettle();
      final opened = find.byKey(const ValueKey('project-card-f'));
      expect(opened, findsOneWidget);
      final focus = FocusManager.instance.primaryFocus;
      expect(
        focus?.context != null &&
            find
                .ancestor(
                  of: find.byWidget(focus!.context!.widget),
                  matching: opened,
                )
                .evaluate()
                .isNotEmpty,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the empty board at 480 × 360 with large text; New project', (
      tester,
    ) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.binding.setSurfaceSize(const Size(480, 360));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(title: const Text('Maprisma')),
            body: AiProjectCenterPage(
              key: key,
              tr: (s) => '$s $s',
              onCall: (op, args) async => op == 'list'
                  ? withBoard([])
                  : {'profiles': [], 'runtimes': []},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('board-empty-new')));
      await tester.pumpAndSettle();
      expect(key.currentState!.projectOpen, isTrue);
      expect(find.byKey(const ValueKey('breadcrumb-projects')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('back to a card behind 63 others after its filter went', (
      tester,
    ) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      var started = false;
      List<Map<String, dynamic>> all() => [
        for (var i = 0; i < 63; i++)
          card('r$i', bucket: 'running', activity: 'running'),
        started ? card('d', bucket: 'running', activity: 'running') : card('d'),
      ];
      await mountWith(tester, key, (op, args) async {
        if (op == 'list') return withBoard(all());
        if (op == 'get') {
          return {
            'project': {
              ...card('d'),
              'brief': 'b',
              'plan': '',
              'team': [],
              'events': [],
              'plan_version': 0,
              'approved_version': null,
            },
          };
        }
        return {'profiles': [], 'runtimes': []};
      });
      final drafts = find.byKey(const ValueKey('board-filter-drafts'));
      await tester.ensureVisible(drafts);
      await tester.pumpAndSettle();
      await tester.tap(drafts);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('card-open')));
      await tester.pumpAndSettle();
      started = true;
      await key.currentState!.refresh();
      await tester.pumpAndSettle();
      await key.currentState!.backToBoard();
      await tester.pumpAndSettle();
      final opened = find.byKey(const ValueKey('project-card-d'));
      expect(opened, findsOneWidget);
      final focus = FocusManager.instance.primaryFocus;
      expect(
        focus?.context != null &&
            find
                .ancestor(
                  of: find.byWidget(focus!.context!.widget),
                  matching: opened,
                )
                .evaluate()
                .isNotEmpty,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('back after the project was deleted: the first card', (
      tester,
    ) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      var deleted = false;
      await mountWith(tester, key, (op, args) async {
        if (op == 'list') {
          return withBoard([card('one'), if (!deleted) card('two')]);
        }
        if (op == 'get') {
          return {
            'project': {
              ...card('two'),
              'brief': 'b',
              'plan': '',
              'team': [],
              'events': [],
              'plan_version': 0,
              'approved_version': null,
            },
          };
        }
        return {'profiles': [], 'runtimes': []};
      });
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('project-card-two')),
          matching: find.byKey(const ValueKey('card-open')),
        ),
      );
      await tester.pumpAndSettle();
      deleted = true;
      await key.currentState!.refresh();
      await tester.pumpAndSettle();
      await key.currentState!.backToBoard();
      await tester.pumpAndSettle();
      final focus = FocusManager.instance.primaryFocus;
      expect(
        focus?.context != null &&
            find
                .ancestor(
                  of: find.byWidget(focus!.context!.widget),
                  matching: find.byKey(const ValueKey('project-card-one')),
                )
                .evaluate()
                .isNotEmpty,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the last of 64 deleted while open: the first card, in view', (
      tester,
    ) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      var deleted = false;
      await mountWith(tester, key, (op, args) async {
        if (op == 'list') {
          return withBoard([
            for (var i = 0; i < (deleted ? 63 : 64); i++) card('$i'),
          ]);
        }
        if (op == 'get') {
          return {
            'project': {
              ...card('63'),
              'brief': 'b',
              'plan': '',
              'team': [],
              'events': [],
              'plan_version': 0,
              'approved_version': null,
            },
          };
        }
        return {'profiles': [], 'runtimes': []};
      });
      final last = find.byKey(const ValueKey('project-card-63'));
      await tester.scrollUntilVisible(
        last,
        400,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(
        find.descendant(
          of: last,
          matching: find.byKey(const ValueKey('card-open')),
        ),
      );
      await tester.pumpAndSettle();
      deleted = true;
      await key.currentState!.refresh();
      await tester.pumpAndSettle();
      await key.currentState!.backToBoard();
      await tester.pumpAndSettle();
      final first = find.byKey(const ValueKey('project-card-0'));
      expect(first, findsOneWidget);
      final focus = FocusManager.instance.primaryFocus;
      expect(
        focus?.context != null &&
            find
                .ancestor(
                  of: find.byWidget(focus!.context!.widget),
                  matching: first,
                )
                .evaluate()
                .isNotEmpty,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the only filtered card deleted: New project', (tester) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      var deleted = false;
      await mountWith(tester, key, (op, args) async {
        if (op == 'list') {
          return withBoard([
            card('r', bucket: 'running', activity: 'running'),
            if (!deleted) card('d'),
          ]);
        }
        if (op == 'get') {
          return {
            'project': {
              ...card('d'),
              'brief': 'b',
              'plan': '',
              'team': [],
              'events': [],
              'plan_version': 0,
              'approved_version': null,
            },
          };
        }
        return {'profiles': [], 'runtimes': []};
      });
      final drafts = find.byKey(const ValueKey('board-filter-drafts'));
      await tester.ensureVisible(drafts);
      await tester.pumpAndSettle();
      await tester.tap(drafts);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('card-open')));
      await tester.pumpAndSettle();
      deleted = true;
      await key.currentState!.refresh();
      await tester.pumpAndSettle();
      await key.currentState!.backToBoard();
      await tester.pumpAndSettle();
      final focus = FocusManager.instance.primaryFocus;
      expect(
        focus?.context != null &&
            find
                .ancestor(
                  of: find.byWidget(focus!.context!.widget),
                  matching: find.byKey(const ValueKey('board-new')),
                )
                .evaluate()
                .isNotEmpty,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a card in the last row is scrolled to (10 cards)', (
      tester,
    ) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      var started = false;
      await mountWith(tester, key, (op, args) async {
        if (op == 'list') {
          return withBoard([
            for (var i = 0; i < 9; i++)
              card('r$i', bucket: 'running', activity: 'running'),
            started
                ? card('d', bucket: 'running', activity: 'running')
                : card('d'),
          ]);
        }
        if (op == 'get') {
          return {
            'project': {
              ...card('d'),
              'brief': 'b',
              'plan': '',
              'team': [],
              'events': [],
              'plan_version': 0,
              'approved_version': null,
            },
          };
        }
        return {'profiles': [], 'runtimes': []};
      });
      final drafts = find.byKey(const ValueKey('board-filter-drafts'));
      await tester.ensureVisible(drafts);
      await tester.pumpAndSettle();
      await tester.tap(drafts);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('card-open')));
      await tester.pumpAndSettle();
      started = true;
      await key.currentState!.refresh();
      await tester.pumpAndSettle();
      await key.currentState!.backToBoard();
      await tester.pumpAndSettle();
      final opened = find.byKey(const ValueKey('project-card-d'));
      // Fully in the visible area, with the keyboard.
      final box = tester.getRect(opened);
      final view = tester.getRect(find.byType(GridView));
      expect(box.top >= view.top && box.bottom <= view.bottom, isTrue);
      final focus = FocusManager.instance.primaryFocus;
      expect(
        focus?.context != null &&
            find
                .ancestor(
                  of: find.byWidget(focus!.context!.widget),
                  matching: opened,
                )
                .evaluate()
                .isNotEmpty,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    });

    for (final width in [640.0, 700.0, 800.0]) {
      testWidgets(
        'a wide but low window (${width.toInt()} × 360) stays compact',
        (tester) async {
          final key = GlobalKey<AiProjectCenterPageState>();
          tester.platformDispatcher.textScaleFactorTestValue = 1.5;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.binding.setSurfaceSize(Size(width, 360));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                appBar: AppBar(title: const Text('Maprisma')),
                body: AiProjectCenterPage(
                  key: key,
                  tr: (s) => '$s $s',
                  onCall: (op, args) async {
                    if (op == 'list') return withBoard([card('w')]);
                    if (op == 'get') {
                      return {
                        'project': {
                          ...card('w'),
                          'brief': 'b',
                          'plan': '1. The plan.',
                          'team': [
                            {'agent': 'claude', 'role': 'lead'},
                          ],
                          'events': [],
                          'plan_version': 1,
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
          final open = find.byKey(const ValueKey('card-open'));
          await tester.ensureVisible(open);
          await tester.pumpAndSettle();
          await tester.tap(open);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            find.byKey(const ValueKey('project-tab-select')),
            findsOneWidget,
          );
          expect(find.byKey(const ValueKey('project-more')), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  });
}
