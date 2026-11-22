import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/ai_project_center.dart';
import 'package:maprisma/project_board.dart';
import 'package:maprisma/project_phases.dart';

import 'project_board_test.dart' show card;

/// The board's Phases view (task 090).
final projects = [
  card(
    'r1',
    bucket: 'running',
    activity: 'running',
    stage: 'run',
    status: 'running',
  ),
  card(
    'n1',
    bucket: 'needs_you',
    activity: 'needs_review',
    stage: 'approval',
    status: 'awaiting_approval',
    second: 'approve_again',
  ),
  card('d1'),
  card('d2', stage: 'plan', activity: 'draft'),
  card('x1', stage: 'unknown'),
  card(
    'f1',
    bucket: 'finished',
    activity: 'agents_finished',
    stage: 'finished',
    status: 'completed',
  ),
];

Future<void> showPhases(
  WidgetTester tester,
  List<Map<String, dynamic>> shown, {
  Size size = const Size(1400, 900),
  double text = 1,
  BoardFilter? filter,
  void Function(Map<String, dynamic>)? onOpen,
  List<BoardView>? views,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  tester.platformDispatcher.textScaleFactorTestValue = text;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  var view = BoardView.phases;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => ProjectBoard(
            projects: shown,
            tr: (s) => s,
            filter: filter,
            view: view,
            onView: (v) {
              views?.add(v);
              setState(() => view = v);
            },
            onOpen: onOpen ?? (_) {},
            onNew: () {},
            onReview: (_) => fail('no quick actions in Phases'),
            onPause: (_) => fail('no quick actions in Phases'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder inColumn(String stage, String id) => find.descendant(
  of: find.byKey(ValueKey('phase-column-$stage')),
  matching: find.byKey(ValueKey('phase-card-$id')),
);

void main() {
  testWidgets('six columns, cards in their stage and board order, counts', (
    tester,
  ) async {
    await showPhases(tester, projects);
    expect(find.byKey(const ValueKey('phases-columns')), findsOneWidget);
    for (final (code, _) in boardStages) {
      expect(find.byKey(ValueKey('phase-column-$code')), findsOneWidget);
    }
    expect(inColumn('run', 'r1'), findsOneWidget);
    expect(inColumn('approval', 'n1'), findsOneWidget);
    expect(inColumn('plan', 'd2'), findsOneWidget);
    expect(inColumn('finished', 'f1'), findsOneWidget);
    // An unknown stage is never lost: it counts as Goal.
    expect(inColumn('goal', 'x1'), findsOneWidget);
    expect(
      tester.getTopLeft(inColumn('goal', 'd1')).dy,
      lessThan(tester.getTopLeft(inColumn('goal', 'x1')).dy),
    );
    Text count(String code) =>
        tester.widget<Text>(find.byKey(ValueKey('phase-count-$code')));
    expect(count('goal').data, '2');
    expect(count('ready').data, '0');
    expect(count('run').data, '1');
    // Navigation only: no quick actions here.
    expect(find.byKey(const ValueKey('card-open')), findsNothing);
    expect(find.byKey(const ValueKey('card-pause')), findsNothing);
    expect(find.byKey(const ValueKey('card-review')), findsNothing);
    expect(find.text('Approve again'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the filter applies; the columns count what is shown', (
    tester,
  ) async {
    await showPhases(tester, projects, filter: BoardFilter.drafts);
    expect(find.byKey(const ValueKey('phase-card-r1')), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('phase-count-goal'))).data,
      '2',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('phase-count-run'))).data,
      '0',
    );
  });

  testWidgets('a filter that leaves nothing says so', (tester) async {
    await showPhases(tester, projects, filter: BoardFilter.ready);
    expect(find.byKey(const ValueKey('phases-empty')), findsOneWidget);
    expect(find.text('No projects here.'), findsOneWidget);
  });

  testWidgets('a compact card opens its project by click and by Enter', (
    tester,
  ) async {
    final opened = <String>[];
    await showPhases(tester, projects, onOpen: (p) => opened.add('${p['id']}'));
    await tester.tap(find.byKey(const ValueKey('phase-card-n1')));
    await tester.pump();
    expect(opened, ['n1']);
    final ink = find.descendant(
      of: find.byKey(const ValueKey('phase-card-f1')),
      matching: find.byType(InkWell),
    );
    // Focus the card (its InkWell's focus), then Enter.
    Focus.of(
      tester.element(
        find.descendant(of: ink, matching: find.byType(Padding)).first,
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opened, ['n1', 'f1']);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(opened, ['n1', 'f1', 'f1']);
  });

  testWidgets('screen readers: one line per card, which they can open', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final opened = <String>[];
    await showPhases(tester, projects, onOpen: (p) => opened.add('${p['id']}'));
    final label = find.bySemanticsLabel(
      'Project n1, Approval, Needs your review, Approve again',
    );
    expect(label, findsOneWidget);
    final node = tester.getSemantics(label);
    expect(
      node,
      isSemantics(isButton: true, isFocusable: true, hasTapAction: true),
    );
    tester.semantics.tap(
      find.semantics.byLabel(
        'Project n1, Approval, Needs your review, Approve again',
      ),
    );
    await tester.pump();
    expect(opened, ['n1']);
    expect(find.bySemanticsLabel('Goal, 2 projects'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the switch: Cards ↔ Phases', (tester) async {
    final views = <BoardView>[];
    await showPhases(tester, projects, views: views);
    await tester.tap(find.byKey(const ValueKey('board-view-cards')));
    await tester.pumpAndSettle();
    expect(find.byType(PhasesBoard), findsNothing);
    expect(find.byKey(const ValueKey('project-card-r1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('board-view-phases')));
    await tester.pumpAndSettle();
    expect(find.byType(PhasesBoard), findsOneWidget);
    expect(views, [BoardView.cards, BoardView.phases]);
    // By keyboard: the segment focused, then Space.
    Focus.of(
      tester.element(find.byKey(const ValueKey('board-view-cards'))),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byType(PhasesBoard), findsNothing);
    expect(views.last, BoardView.cards);
  });

  testWidgets('the same width: columns at normal text, a list at large text', (
    tester,
  ) async {
    await showPhases(tester, projects, size: const Size(1200, 800));
    expect(find.byKey(const ValueKey('phases-columns')), findsOneWidget);
    await showPhases(tester, projects, size: const Size(1200, 800), text: 1.5);
    expect(find.byKey(const ValueKey('phases-stacked')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('480 × 360 with large text: a stacked list, symbols only', (
    tester,
  ) async {
    await showPhases(tester, projects, size: const Size(480, 360), text: 1.5);
    expect(find.byKey(const ValueKey('phases-stacked')), findsOneWidget);
    expect(find.byKey(const ValueKey('phases-columns')), findsNothing);
    // Empty stages are left out.
    expect(find.byKey(const ValueKey('phase-header-ready')), findsNothing);
    expect(find.byKey(const ValueKey('board-view-phases')), findsNothing);
    expect(find.byTooltip('Phases'), findsOneWidget);
    // Stages in order, each above its cards.
    final last = find.byKey(const ValueKey('phase-card-f1'));
    await tester.scrollUntilVisible(
      last,
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('phase-header-finished'))).dy,
      lessThan(tester.getTopLeft(last).dy),
    );
    expect(tester.takeException(), isNull);
  });

  group('in the page', () {
    Future<GlobalKey<AiProjectCenterPageState>> mount(
      WidgetTester tester,
      List<Map<String, dynamic>> list, {
      Size size = const Size(1400, 900),
    }) async {
      final key = GlobalKey<AiProjectCenterPageState>();
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiProjectCenterPage(
              key: key,
              tr: (s) => s,
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

    bool focusedIn(Finder card) {
      final focus = FocusManager.instance.primaryFocus;
      return focus?.context != null &&
          find
              .ancestor(
                of: find.byWidget(focus!.context!.widget),
                matching: card,
              )
              .evaluate()
              .isNotEmpty;
    }

    testWidgets('open from Phases; back: still Phases, the card focused', (
      tester,
    ) async {
      final key = await mount(tester, projects);
      await tester.tap(find.byKey(const ValueKey('board-view-phases')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('phase-card-n1')));
      await tester.pumpAndSettle();
      expect(key.currentState!.projectOpen, isTrue);
      await key.currentState!.backToBoard();
      await tester.pumpAndSettle();
      expect(find.byType(PhasesBoard), findsOneWidget);
      expect(focusedIn(find.byKey(const ValueKey('phase-card-n1'))), isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('back to a card far down its column after the column '
        'scrolled away: scrolled to, focused', (tester) async {
      final many = [for (var i = 0; i < 40; i++) card('$i')];
      final key = await mount(tester, many, size: const Size(1400, 700));
      await tester.tap(find.byKey(const ValueKey('board-view-phases')));
      await tester.pumpAndSettle();
      final last = find.byKey(const ValueKey('phase-card-39'));
      Finder column({bool skip = true}) => find
          .descendant(
            of: find.byKey(
              const ValueKey('phase-column-goal'),
              skipOffstage: skip,
            ),
            matching: find.byType(Scrollable, skipOffstage: skip),
          )
          .first;
      await tester.scrollUntilVisible(last, 300, scrollable: column());
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(key.currentState!.projectOpen, isTrue);
      // The kept board's column back at the top while the project is open.
      tester.state<ScrollableState>(column(skip: false)).position.jumpTo(0);
      await tester.pump();
      await key.currentState!.backToBoard();
      await tester.pumpAndSettle();
      expect(focusedIn(last), isTrue);
      final rect = tester.getRect(last);
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(700));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('stacked: back to a card far down the list, scrolled to', (
      tester,
    ) async {
      final many = [for (var i = 0; i < 40; i++) card('$i')];
      final key = await mount(tester, many, size: const Size(600, 700));
      await tester.tap(find.byTooltip('Phases'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('phases-stacked')), findsOneWidget);
      final last = find.byKey(const ValueKey('phase-card-39'));
      Finder list({bool skip = true}) => find
          .descendant(
            of: find.byKey(
              const ValueKey('phases-stacked'),
              skipOffstage: skip,
            ),
            matching: find.byType(Scrollable, skipOffstage: skip),
          )
          .first;
      await tester.scrollUntilVisible(last, 300, scrollable: list());
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(key.currentState!.projectOpen, isTrue);
      tester.state<ScrollableState>(list(skip: false)).position.jumpTo(0);
      await tester.pump();
      await key.currentState!.backToBoard();
      await tester.pumpAndSettle();
      expect(focusedIn(last), isTrue);
      final rect = tester.getRect(last);
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(700));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
