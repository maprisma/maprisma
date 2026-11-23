import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/ai_project_center.dart';
import 'package:maprisma/project_board.dart';
import 'package:maprisma_core/maprisma_core.dart' show ServiceError;

import 'project_board_test.dart' show card;

/// The board in the user's order and the importance marks (task 095).
Map<String, dynamic> marked(
  String id, {
  String importance = 'medium',
  String bucket = 'drafts',
}) => {...card(id, bucket: bucket), 'importance': importance};

class Backend {
  Backend(this.projects);
  final List<Map<String, dynamic>> projects;
  final moves = <Map>[];
  final marks = <Map>[];
  final calls = <String>[];
  bool order = true;
  bool failList = false;
  String? refuseMove, refuseMark;

  /// The next `move` waits for this.
  Completer<void>? holdMove;

  /// The next `list` answers what the board was when it was asked, after
  /// this completes.
  Completer<void>? holdList;

  /// The next held `list` fails once released.
  bool failHeldList = false;

  /// The next `get` answers what the project was when it was asked, after
  /// this completes.
  Completer<void>? holdGet;

  /// A card's Pause answers with this.
  Completer<Map<String, dynamic>>? pause;

  /// The next held `get` fails once released.
  bool failHeldGet = false;

  /// `delete` waits for this.
  Completer<void>? holdDelete;
  final deleted = <String>[];

  List<String> get ids => [for (final p in projects) '${p['id']}'];
}

Future<GlobalKey<AiProjectCenterPageState>> mount(
  WidgetTester tester,
  Backend backend, {
  Size size = const Size(1400, 900),
  String Function(String)? tr,
  ({String command, String name})? agent,
}) async {
  final key = GlobalKey<AiProjectCenterPageState>();
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AiProjectCenterPage(
          key: key,
          tr: tr ?? (s) => s,
          agent: agent,
          onCall: (op, args) async {
            backend.calls.add(op);
            if (op == 'delete') {
              await backend.holdDelete?.future;
              backend.deleted.add('${args['id']}');
              backend.projects.removeWhere((p) => p['id'] == args['id']);
              return {'deleted': true};
            }
            if (op == 'list') {
              if (backend.failList) throw ServiceError('feature_unavailable');
              final answer = {
                'projects': [
                  for (final p in backend.projects) {...p},
                ],
                'capabilities': [
                  'summary2',
                  'board',
                  if (backend.order) 'order',
                ],
              };
              if (backend.holdList case final hold?) {
                backend.holdList = null;
                await hold.future;
                if (backend.failHeldList) {
                  backend.failHeldList = false;
                  throw ServiceError('feature_unavailable');
                }
              }
              return answer;
            }
            if (op == 'pause' && backend.pause != null) {
              return backend.pause!.future;
            }
            if (op == 'move') {
              backend.moves.add(args);
              if (backend.holdMove case final hold?) {
                backend.holdMove = null;
                await hold.future;
              }
              if (backend.refuseMove case final code?) throw ServiceError(code);
              final p = backend.projects.firstWhere(
                (p) => p['id'] == args['id'],
              );
              backend.projects.remove(p);
              final before = args['before'];
              final at = before == null
                  ? backend.projects.length
                  : backend.projects.indexWhere((p) => p['id'] == before);
              backend.projects.insert(at, p);
              return {'order': backend.ids};
            }
            if (op == 'set_importance') {
              backend.marks.add(args);
              if (backend.refuseMark case final code?) throw ServiceError(code);
              final p = backend.projects.firstWhere(
                (p) => p['id'] == args['id'],
              );
              p['importance'] = args['importance'];
              return {
                'project': {...p, 'brief': 'b'},
              };
            }
            if (op == 'save' && args['id'] == null) {
              // A new project goes on top.
              final p = {...marked('n'), 'title': args['title']};
              backend.projects.insert(0, p);
              return {
                'project': {
                  ...p,
                  'brief': args['brief'],
                  'plan': '',
                  'team': args['team'],
                  'events': [],
                  'plan_version': 0,
                  'approved_version': null,
                },
              };
            }
            if (op == 'get') {
              final p = {
                ...backend.projects.firstWhere((p) => p['id'] == args['id']),
              };
              if (backend.holdGet case final hold?) {
                backend.holdGet = null;
                await hold.future;
                if (backend.failHeldGet) {
                  backend.failHeldGet = false;
                  throw ServiceError('feature_unavailable');
                }
              }
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

Finder cardOf(String id) => find.byKey(ValueKey('project-card-$id'));

Finder inCard(String id, Key key) =>
    find.descendant(of: cardOf(id), matching: find.byKey(key));

/// The shown cards, in reading order (rows, then columns).
List<String> shown(WidgetTester tester, List<String> ids) {
  final there = [
    for (final id in ids)
      if (cardOf(id).evaluate().isNotEmpty) id,
  ];
  Offset at(String id) => tester.getTopLeft(cardOf(id));
  there.sort((a, b) {
    final dy = at(a).dy.compareTo(at(b).dy);
    return dy != 0 ? dy : at(a).dx.compareTo(at(b).dx);
  });
  return there;
}

/// Drags [from] by its grip onto the card [onto] with the mouse.
Future<void> drag(
  WidgetTester tester,
  String from,
  String onto, {
  bool settle = true,
}) async {
  final gesture = await tester.startGesture(
    tester.getCenter(inCard(from, const ValueKey('card-move'))),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.moveBy(const Offset(20, 20));
  await tester.pump();
  await gesture.moveTo(tester.getCenter(cardOf(onto)));
  await tester.pump();
  // The drop place is shown while it hovers, and the other places faintly.
  expect(find.byKey(const ValueKey('card-drop')), findsOneWidget);
  expect(find.byKey(const ValueKey('card-gap')), findsWidgets);
  await gesture.up();
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

FocusNode focusOf(WidgetTester tester, String id) => tester
    .widget<InkWell>(
      find.descendant(of: cardOf(id), matching: find.byType(InkWell)).first,
    )
    .focusNode!;

/// A chip of the filter row (it scrolls sideways when the row is long).
Future<void> tapChip(WidgetTester tester, String key) async {
  final chip = find.byKey(ValueKey('board-$key'));
  await tester.ensureVisible(chip);
  await tester.pumpAndSettle();
  await tester.tap(chip);
}

Future<void> ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  const all = ['a', 'b', 'c', 'd'];

  testWidgets('the board shows the backend\'s order, not the most urgent '
      'first', (tester) async {
    final backend = Backend([
      marked('a'),
      marked('b', bucket: 'attention'),
      marked('c', bucket: 'running'),
    ]);
    await mount(tester, backend);
    expect(shown(tester, ['a', 'b', 'c']), ['a', 'b', 'c']);
  });

  testWidgets('a card dropped on another moves there and sends move', (
    tester,
  ) async {
    final backend = Backend([for (final id in all) marked(id)]);
    await mount(tester, backend);
    // From before c: after it (before d).
    await drag(tester, 'a', 'c');
    expect(backend.moves.last, {'id': 'a', 'before': 'd'});
    expect(shown(tester, all), ['b', 'c', 'a', 'd']);
    // From behind b: before it.
    await drag(tester, 'd', 'b');
    expect(backend.moves.last, {'id': 'd', 'before': 'b'});
    expect(shown(tester, all), ['d', 'b', 'c', 'a']);
    // After the last card: the end.
    await drag(tester, 'd', 'a');
    expect(backend.moves.last, {'id': 'd', 'before': null});
    expect(shown(tester, all), ['b', 'c', 'a', 'd']);
    // Moves read nothing again.
    expect(backend.calls.where((c) => c == 'list'), hasLength(1));
  });

  testWidgets('the card moves at once and then takes the answer\'s order', (
    tester,
  ) async {
    final backend = Backend([for (final id in all) marked(id)]);
    await mount(tester, backend);
    final answer = backend.holdMove = Completer();
    await drag(tester, 'd', 'a', settle: false);
    expect(shown(tester, all), ['d', 'a', 'b', 'c']);
    // Another client moved c to the top meanwhile.
    final c = backend.projects.removeAt(2);
    backend.projects.insert(0, c);
    answer.complete();
    await tester.pumpAndSettle();
    expect(backend.ids, ['c', 'd', 'a', 'b']);
    expect(shown(tester, all), ['c', 'd', 'a', 'b']);
  });

  testWidgets('with a filter a drop names the shown card, or the next one of '
      'the whole order', (tester) async {
    // Drafts a, b, c among two ready ones.
    final backend = Backend([
      marked('a'),
      marked('x', bucket: 'ready'),
      marked('b'),
      marked('c'),
      marked('y', bucket: 'ready'),
    ]);
    await mount(tester, backend);
    await tapChip(tester, 'filter-drafts');
    await tester.pumpAndSettle();
    expect(cardOf('x'), findsNothing);
    // After b: before the next shown card, c.
    await drag(tester, 'a', 'b');
    expect(backend.moves.last, {'id': 'a', 'before': 'c'});
    expect(backend.ids, ['x', 'b', 'a', 'c', 'y']);
    // After the last shown card: before the next one of the whole order.
    await drag(tester, 'b', 'c');
    expect(backend.moves.last, {'id': 'b', 'before': 'y'});
    expect(backend.ids, ['x', 'a', 'c', 'b', 'y']);
    expect(shown(tester, ['a', 'b', 'c']), ['a', 'c', 'b']);
    // Before a shown card: that card.
    await drag(tester, 'b', 'a');
    expect(backend.moves.last, {'id': 'b', 'before': 'a'});
    expect(backend.ids, ['x', 'b', 'a', 'c', 'y']);
  });

  testWidgets('a refused move puts the card back and keeps the reason', (
    tester,
  ) async {
    final backend = Backend([for (final id in all) marked(id)])
      ..refuseMove = 'project_unknown';
    await mount(tester, backend);
    final answer = backend.holdMove = Completer();
    await drag(tester, 'a', 'c', settle: false);
    expect(shown(tester, all), ['b', 'c', 'a', 'd']);
    final lists = backend.calls.where((c) => c == 'list').length;
    // Back at once, before the board is read again.
    final list = backend.holdList = Completer();
    answer.complete();
    await tester.pumpAndSettle();
    expect(shown(tester, all), all);
    expect(find.text('The project could not be found.'), findsOneWidget);
    // The board is read again; the reason stays through that read.
    list.complete();
    await tester.pumpAndSettle();
    expect(backend.calls.where((c) => c == 'list'), hasLength(lists + 1));
    expect(shown(tester, all), all);
    expect(find.text('The project could not be found.'), findsOneWidget);
  });

  testWidgets('a read from before a move does not put the card back', (
    tester,
  ) async {
    final backend = Backend([for (final id in all) marked(id)]);
    final key = await mount(tester, backend);
    final list = backend.holdList = Completer();
    unawaited(key.currentState!.refresh());
    await tester.pump();
    await drag(tester, 'd', 'a');
    expect(shown(tester, all), ['d', 'a', 'b', 'c']);
    list.complete();
    await tester.pumpAndSettle();
    expect(shown(tester, all), ['d', 'a', 'b', 'c']);
  });

  testWidgets('Ctrl+Up / Down / Home / End move the card with the keyboard', (
    tester,
  ) async {
    final backend = Backend([for (final id in all) marked(id)]);
    await mount(tester, backend);
    focusOf(tester, 'b').requestFocus();
    await tester.pump();
    await ctrl(tester, LogicalKeyboardKey.arrowUp);
    expect(backend.moves.last, {'id': 'b', 'before': 'a'});
    expect(shown(tester, all), ['b', 'a', 'c', 'd']);
    // The keyboard stays with the card.
    expect(focusOf(tester, 'b').hasFocus, isTrue);
    await ctrl(tester, LogicalKeyboardKey.arrowDown);
    expect(backend.moves.last, {'id': 'b', 'before': 'c'});
    await ctrl(tester, LogicalKeyboardKey.end);
    expect(backend.moves.last, {'id': 'b', 'before': null});
    expect(shown(tester, all), ['a', 'c', 'd', 'b']);
    await ctrl(tester, LogicalKeyboardKey.home);
    expect(backend.moves.last, {'id': 'b', 'before': 'a'});
    expect(shown(tester, all), ['b', 'a', 'c', 'd']);
    expect(focusOf(tester, 'b').hasFocus, isTrue);
    // Already on top: nothing is sent.
    final sent = backend.moves.length;
    await ctrl(tester, LogicalKeyboardKey.arrowUp);
    await ctrl(tester, LogicalKeyboardKey.home);
    expect(backend.moves, hasLength(sent));
  });

  testWidgets('the whole card is dragged; separators show the places', (
    tester,
  ) async {
    final backend = Backend([for (final id in all) marked(id)]);
    await mount(tester, backend);
    // The grip only shows that a card can be dragged: no Move menu.
    expect(find.byTooltip('Move'), findsNWidgets(4));
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    expect(find.text('Move to top'), findsNothing);
    // Grabbed anywhere on the card (here near its top left corner, away from
    // its buttons), not only by the grip.
    final gesture = await tester.startGesture(
      tester.getTopLeft(cardOf('d')) + const Offset(40, 16),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(20, 20));
    await tester.pump();
    // While it is dragged, every other card shows the gaps it can go to.
    expect(find.byKey(const ValueKey('card-gap')), findsNWidgets(6));
    expect(find.byKey(const ValueKey('card-drop')), findsNothing);
    await gesture.moveTo(tester.getCenter(cardOf('a')));
    await tester.pump();
    expect(find.byKey(const ValueKey('card-drop')), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(backend.moves.last, {'id': 'd', 'before': 'a'});
    expect(shown(tester, all), ['d', 'a', 'b', 'c']);
    expect(find.byKey(const ValueKey('card-gap')), findsNothing);
    // By touch, a long press picks the card up (a swipe scrolls the board).
    final touch = await tester.startGesture(
      tester.getTopLeft(cardOf('c')) + const Offset(40, 16),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await touch.moveTo(tester.getCenter(cardOf('d')));
    await tester.pump();
    expect(find.byKey(const ValueKey('card-drop')), findsOneWidget);
    await touch.up();
    await tester.pumpAndSettle();
    expect(backend.moves.last, {'id': 'c', 'before': 'd'});
    expect(shown(tester, all), ['c', 'd', 'a', 'b']);
    // A click on a card's button stays a click.
    await tester.tap(inCard('b', const ValueKey('card-open')));
    await tester.pumpAndSettle();
    expect(backend.moves, hasLength(2));
  });

  testWidgets('the mark sets the importance and the card shows it', (
    tester,
  ) async {
    final backend = Backend([marked('a'), marked('b', importance: 'low')]);
    await mount(tester, backend);
    expect(inCard('a', const ValueKey('card-importance-medium')), findsOne);
    expect(inCard('b', const ValueKey('card-importance-low')), findsOne);
    expect(find.byTooltip('Importance'), findsWidgets);
    await tester.tap(inCard('a', const ValueKey('card-importance-menu')));
    await tester.pumpAndSettle();
    expect(find.text('High'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('importance-high')));
    await tester.pumpAndSettle();
    expect(backend.marks, [
      {'id': 'a', 'importance': 'high'},
    ]);
    expect(inCard('a', const ValueKey('card-importance-high')), findsOne);
    // A mark does not move the card.
    expect(shown(tester, ['a', 'b']), ['a', 'b']);
  });

  testWidgets('a refused mark goes back and keeps the reason', (tester) async {
    final backend = Backend([marked('a')])
      ..refuseMark = 'project_store_unavailable';
    await mount(tester, backend);
    await tester.tap(find.byKey(const ValueKey('card-importance-menu')));
    await tester.pumpAndSettle();
    // Back at once, before the board is read again.
    final list = backend.holdList = Completer();
    await tester.tap(find.byKey(const ValueKey('importance-low')));
    await tester.pumpAndSettle();
    expect(backend.marks.single['importance'], 'low');
    expect(find.byKey(const ValueKey('card-importance-medium')), findsOne);
    list.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('card-importance-medium')), findsOne);
    expect(
      find.text(
        'The saved project store is unavailable. Check the saved state before continuing.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('the Goal tab sets the importance at once, without a draft', (
    tester,
  ) async {
    final backend = Backend([marked('a'), marked('b')]);
    final key = await mount(tester, backend);
    await tester.tap(inCard('a', const ValueKey('card-open')));
    await tester.pumpAndSettle();
    final selector = find.byKey(const ValueKey('goal-importance'));
    expect(selector, findsOneWidget);
    String status() => tester
        .widget<Text>(find.byKey(const ValueKey('project-status-line')))
        .data!;
    // Set on its own: no unsaved changes.
    await tester.tap(find.descendant(of: selector, matching: find.text('Low')));
    await tester.pumpAndSettle();
    expect(backend.marks.single, {'id': 'a', 'importance': 'low'});
    expect(status(), isNot(contains('Unsaved changes')));
    backend.marks.clear();
    // Typing first: the mark does not save or drop the edit.
    await tester.enterText(
      find.widgetWithText(TextField, 'Project title'),
      'Edited',
    );
    await tester.pump();
    await tester.tap(
      find.descendant(of: selector, matching: find.text('High')),
    );
    await tester.pumpAndSettle();
    expect(backend.marks, [
      {'id': 'a', 'importance': 'high'},
    ]);
    expect(backend.calls, isNot(contains('save')));
    final title = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Project title'),
    );
    expect(title.controller!.text, 'Edited');
    expect(tester.widget<SegmentedButton<BoardImportance>>(selector).selected, {
      BoardImportance.high,
    });
    // Discard the edit: the board shows the new mark.
    key.currentState!.backToBoard();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(inCard('a', const ValueKey('card-importance-high')), findsOne);
  });

  testWidgets('a new project has no importance selector until it is saved', (
    tester,
  ) async {
    final backend = Backend([marked('a')]);
    await mount(tester, backend);
    await tester.tap(find.byKey(const ValueKey('board-new')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('goal-importance')), findsNothing);
  });

  testWidgets('the board filters by importance, with counts', (tester) async {
    final backend = Backend([
      marked('a', importance: 'high'),
      marked('b'),
      marked('c', importance: 'low', bucket: 'ready'),
      marked('d'),
    ]);
    await mount(tester, backend);
    Future<void> choose(String code) async {
      await tapChip(tester, 'importance');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('board-importance-$code')));
      await tester.pumpAndSettle();
    }

    await tapChip(tester, 'importance');
    await tester.pumpAndSettle();
    expect(find.text('High 1'), findsOneWidget);
    expect(find.text('Medium 2'), findsOneWidget);
    expect(find.text('Low 1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('board-importance-medium')));
    await tester.pumpAndSettle();
    expect(shown(tester, all), ['b', 'd']);
    // The chip names the choice; the bucket counts stay the whole board's.
    expect(find.text('Medium 2'), findsOneWidget);
    expect(find.text('All 4'), findsOneWidget);
    expect(find.text('Drafts 3'), findsOneWidget);
    // Both filters apply.
    await tapChip(tester, 'filter-ready');
    await tester.pumpAndSettle();
    expect(find.text('No projects here.'), findsOneWidget);
    // All clears both.
    await tapChip(tester, 'filter-all');
    await tester.pumpAndSettle();
    expect(shown(tester, all), all);
    expect(find.text('Importance'), findsOneWidget);
    // Chosen again clears; so does the chip's ×.
    await choose('high');
    expect(shown(tester, all), ['a']);
    await choose('high');
    expect(shown(tester, all), all);
    await choose('low');
    expect(shown(tester, all), ['c']);
    await tester.tap(find.byTooltip('All'));
    await tester.pumpAndSettle();
    expect(shown(tester, all), all);
  });

  testWidgets('a read shows the backend\'s order even while a card has the '
      'keyboard', (tester) async {
    final backend = Backend([marked('a'), marked('b')]);
    final key = await mount(tester, backend);
    focusOf(tester, 'a').requestFocus();
    await tester.pump();
    // Another client added a project and moved b up.
    backend.projects
      ..insert(0, marked('n'))
      ..insert(1, backend.projects.removeAt(2));
    await key.currentState!.refresh();
    await tester.pumpAndSettle();
    expect(shown(tester, ['a', 'b', 'n']), ['n', 'b', 'a']);
  });

  testWidgets('a new project saved on its page is on top when the board is '
      'back, with the keyboard', (tester) async {
    final backend = Backend([marked('a'), marked('b')]);
    final key = await mount(tester, backend);
    focusOf(tester, 'b').requestFocus();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('board-new')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Project title'),
      'N',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Project goal'), 'g');
    await tester.enterText(
      find.widgetWithText(TextField, 'Working folder'),
      '/tmp/n',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save project'));
    await tester.pumpAndSettle();
    expect(backend.ids, ['n', 'a', 'b']);
    await key.currentState!.backToBoard();
    await tester.pumpAndSettle();
    expect(shown(tester, ['a', 'b', 'n']), ['n', 'a', 'b']);
    expect(focusOf(tester, 'n').hasFocus, isTrue);
  });

  for (final size in [const Size(480, 360), const Size(800, 600)]) {
    testWidgets('mark and handle fit a card at $size with large text', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final backend = Backend([
        {...marked('a', importance: 'high'), 'title': 'A long title ' * 4},
        marked('b', importance: 'low'),
        marked('c'),
      ]);
      await mount(tester, backend, size: size);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('card-move')), findsWidgets);
      await tapChip(tester, 'importance');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the board cannot be read: the handle and the mark are off', (
    tester,
  ) async {
    final backend = Backend([marked('a'), marked('b')]);
    final key = await mount(tester, backend);
    backend.failList = true;
    await key.currentState!.refresh();
    await tester.pumpAndSettle();
    final move = tester.widget<Draggable<String>>(
      find
          .ancestor(
            of: cardOf('a'),
            matching: find.byWidgetPredicate((w) => w is Draggable<String>),
          )
          .first,
    );
    expect(move.maxSimultaneousDrags, 0);
    expect(find.byKey(const ValueKey('card-importance-menu')), findsNothing);
    expect(
      find.byKey(const ValueKey('card-importance-medium')),
      findsNWidgets(2),
    );
    focusOf(tester, 'b').requestFocus();
    await tester.pump();
    await ctrl(tester, LogicalKeyboardKey.arrowUp);
    expect(backend.moves, isEmpty);
  });

  testWidgets('an older backend without order: no handle, no mark to set', (
    tester,
  ) async {
    final backend = Backend([marked('a'), marked('b')])..order = false;
    await mount(tester, backend);
    expect(find.byKey(const ValueKey('card-move')), findsNothing);
    expect(find.byWidgetPredicate((w) => w is Draggable<String>), findsNothing);
    expect(find.byKey(const ValueKey('card-importance-menu')), findsNothing);
    focusOf(tester, 'b').requestFocus();
    await tester.pump();
    await ctrl(tester, LogicalKeyboardKey.arrowUp);
    expect(backend.moves, isEmpty);
    expect(shown(tester, ['a', 'b']), ['a', 'b']);
  });

  testWidgets('an older backend without importance shows no mark', (
    tester,
  ) async {
    final backend = Backend([card('a'), card('b')])..order = false;
    await mount(tester, backend);
    expect(find.byType(ImportanceMark), findsNothing);
    expect(find.byKey(const ValueKey('board-importance')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('card-open')).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('goal-importance')), findsNothing);
  });

  group('review round 1', () {
    testWidgets('a read begun before a mark does not put the old one back', (
      tester,
    ) async {
      final backend = Backend([marked('a'), marked('b')]);
      final key = await mount(tester, backend);
      final list = backend.holdList = Completer();
      unawaited(key.currentState!.refresh());
      await tester.pump();
      await tester.tap(inCard('a', const ValueKey('card-importance-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('importance-high')));
      await tester.pumpAndSettle();
      expect(backend.marks.single['importance'], 'high');
      list.complete();
      await tester.pumpAndSettle();
      expect(inCard('a', const ValueKey('card-importance-high')), findsOne);
    });

    testWidgets('a read of the open project begun before a mark keeps the '
        'Goal tab\'s choice', (tester) async {
      final backend = Backend([marked('a')]);
      final key = await mount(tester, backend);
      await tester.tap(inCard('a', const ValueKey('card-open')));
      await tester.pumpAndSettle();
      final get = backend.holdGet = Completer();
      unawaited(key.currentState!.refresh());
      await tester.pump();
      final selector = find.byKey(const ValueKey('goal-importance'));
      await tester.tap(
        find.descendant(of: selector, matching: find.text('High')),
      );
      await tester.pumpAndSettle();
      expect(backend.marks.single['importance'], 'high');
      get.complete();
      await tester.pumpAndSettle();
      expect(
        tester.widget<SegmentedButton<BoardImportance>>(selector).selected,
        {BoardImportance.high},
      );
    });

    testWidgets('opening a project marked meanwhile shows the new mark', (
      tester,
    ) async {
      final backend = Backend([marked('a')]);
      await mount(tester, backend);
      final get = backend.holdGet = Completer();
      await tester.tap(inCard('a', const ValueKey('card-open')));
      await tester.pump();
      // The page reads the project (a progress bar runs meanwhile).
      Future<void> wait() async {
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await tester.tap(inCard('a', const ValueKey('card-importance-menu')));
      await wait();
      await tester.tap(find.byKey(const ValueKey('importance-low')));
      await wait();
      expect(backend.marks.single['importance'], 'low');
      get.complete();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SegmentedButton<BoardImportance>>(
              find.byKey(const ValueKey('goal-importance')),
            )
            .selected,
        {BoardImportance.low},
      );
    });

    testWidgets('a read begun while a move was on its way does not undo it', (
      tester,
    ) async {
      final backend = Backend([marked('a'), marked('b'), marked('c')]);
      final key = await mount(tester, backend);
      final answer = backend.holdMove = Completer();
      await drag(tester, 'c', 'a', settle: false);
      final list = backend.holdList = Completer();
      unawaited(key.currentState!.refresh());
      await tester.pump();
      answer.complete();
      await tester.pumpAndSettle();
      expect(shown(tester, ['a', 'b', 'c']), ['c', 'a', 'b']);
      list.complete();
      await tester.pumpAndSettle();
      expect(shown(tester, ['a', 'b', 'c']), ['c', 'a', 'b']);
    });

    testWidgets('an older read\'s failure keeps a refused move\'s reason', (
      tester,
    ) async {
      final backend = Backend([for (final id in all) marked(id)])
        ..refuseMove = 'project_unknown';
      final key = await mount(tester, backend);
      final list = backend.holdList = Completer();
      backend.failHeldList = true;
      unawaited(key.currentState!.refresh());
      await tester.pump();
      await drag(tester, 'a', 'c');
      expect(find.text('The project could not be found.'), findsOneWidget);
      // The older read fails, then the move's own read succeeds.
      list.complete();
      await tester.pumpAndSettle();
      expect(find.text('The project could not be found.'), findsOneWidget);
      expect(find.text('The project operation failed.'), findsNothing);
      expect(shown(tester, all), all);
    });

    testWidgets('a refused move to the end brings the card back into view', (
      tester,
    ) async {
      final ids = [for (var i = 0; i < 30; i++) 'c$i'];
      final backend = Backend([for (final id in ids) marked(id)])
        ..refuseMove = 'project_store_unavailable';
      await mount(tester, backend);
      final answer = backend.holdMove = Completer();
      focusOf(tester, 'c0').requestFocus();
      await tester.pump();
      await ctrl(tester, LogicalKeyboardKey.end);
      // At the end, in view.
      expect(cardOf('c0').hitTestable(), findsOneWidget);
      answer.complete();
      await tester.pumpAndSettle();
      expect(cardOf('c0').hitTestable(), findsOneWidget);
      expect(tester.getTopLeft(cardOf('c0')).dy, lessThan(300));
    });

    testWidgets('the Goal tab\'s importance fits 480 × 360 with large text '
        'and long words', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final backend = Backend([marked('a')]);
      await mount(
        tester,
        backend,
        size: const Size(480, 360),
        tr: (s) => '$s $s',
      );
      final open = find.byKey(const ValueKey('card-open'));
      await tester.ensureVisible(open);
      await tester.pumpAndSettle();
      await tester.tap(open);
      await tester.pumpAndSettle();
      final selector = find.byKey(const ValueKey('goal-importance'));
      await tester.ensureVisible(selector);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(selector, findsOneWidget);
    });

    testWidgets('under the agent chip, Move to top and to end judge the whole '
        'board', (tester) async {
      Map<String, dynamic> other(String id) => {
        ...card(
          id,
          execution: [
            {
              'phase': 'execution',
              'position': 0,
              'agent': 'codex',
              'name': 'Codex',
              'role': 'lead',
              'issues': <Map>[],
            },
          ],
        ),
        'importance': 'medium',
      };
      final backend = Backend([
        other('h'),
        marked('a'),
        marked('b'),
        other('z'),
      ]);
      await mount(
        tester,
        backend,
        agent: (command: 'claude', name: 'Claude Code'),
      );
      expect(cardOf('h'), findsNothing);
      focusOf(tester, 'a').requestFocus();
      await tester.pump();
      await ctrl(tester, LogicalKeyboardKey.home);
      expect(backend.moves.last, {'id': 'a', 'before': 'h'});
      focusOf(tester, 'b').requestFocus();
      await tester.pump();
      await ctrl(tester, LogicalKeyboardKey.end);
      expect(backend.moves.last, {'id': 'b', 'before': null});
      expect(backend.ids, ['a', 'h', 'z', 'b']);
    });

    testWidgets('the Goal tab\'s importance is off while the project is being '
        'deleted', (tester) async {
      final backend = Backend([marked('a'), marked('b')]);
      await mount(tester, backend);
      await tester.tap(inCard('a', const ValueKey('card-open')));
      await tester.pumpAndSettle();
      final held = backend.holdDelete = Completer();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete project'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pump();
      final selector = find.byKey(const ValueKey('goal-importance'));
      expect(
        tester
            .widget<SegmentedButton<BoardImportance>>(selector)
            .onSelectionChanged,
        isNull,
      );
      held.complete();
      await tester.pumpAndSettle();
      expect(backend.deleted, ['a']);
      expect(backend.marks, isEmpty);
    });

    testWidgets(
      'a dragged card that a read takes off the board moves nowhere',
      (tester) async {
        final backend = Backend([marked('a'), marked('b'), marked('c')]);
        final key = await mount(tester, backend);
        await tapChip(tester, 'filter-drafts');
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(inCard('c', const ValueKey('card-move'))),
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveBy(const Offset(20, 20));
        await tester.pump();
        await gesture.moveTo(tester.getCenter(cardOf('a')));
        await tester.pump();
        expect(find.byKey(const ValueKey('card-drop')), findsOneWidget);
        // c leaves the filter while it hovers over a.
        backend.projects[2] = marked('c', bucket: 'ready');
        await key.currentState!.refresh();
        await tester.pump();
        expect(find.byKey(const ValueKey('card-drop')), findsNothing);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(backend.moves, isEmpty);
      },
    );

    testWidgets('the importance filter sits right after All', (tester) async {
      final backend = Backend([marked('a')]);
      await mount(tester, backend, size: const Size(1200, 800));
      final chip = find.byKey(const ValueKey('board-importance'));
      expect(
        tester.getTopLeft(chip).dx,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('board-filter-running')))
              .dx,
        ),
      );
      expect(chip.hitTestable(), findsOneWidget);
    });
  });

  group('review round 2', () {
    Future<void> frames(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    const store =
        'The saved project store is unavailable. Check the saved state before continuing.';

    testWidgets('a held read of the open project that fails keeps a refused '
        'mark\'s reason', (tester) async {
      final backend = Backend([marked('a')])..refuseMark = 'project_store_full';
      final key = await mount(tester, backend);
      await tester.tap(inCard('a', const ValueKey('card-open')));
      await tester.pumpAndSettle();
      final get = backend.holdGet = Completer();
      backend.failHeldGet = true;
      unawaited(key.currentState!.refresh());
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('goal-importance')),
          matching: find.text('High'),
        ),
      );
      await tester.pump();
      expect(find.text(store), findsOneWidget);
      get.complete();
      await tester.pumpAndSettle();
      expect(find.text(store), findsOneWidget);
      expect(find.text('The project operation failed.'), findsNothing);
    });

    testWidgets('an opening read that fails keeps a refused move\'s reason', (
      tester,
    ) async {
      final backend = Backend([marked('a'), marked('b')])
        ..refuseMove = 'project_unknown';
      await mount(tester, backend);
      final get = backend.holdGet = Completer();
      backend.failHeldGet = true;
      await tester.tap(inCard('a', const ValueKey('card-open')));
      await tester.pump();
      // While a is being read, b's move is refused.
      await drag(tester, 'b', 'a', settle: false);
      await frames(tester);
      expect(backend.moves.single, {'id': 'b', 'before': 'a'});
      expect(find.text('The project could not be found.'), findsOneWidget);
      get.complete();
      await tester.pumpAndSettle();
      expect(find.text('The project could not be found.'), findsOneWidget);
      expect(find.text('The project operation failed.'), findsNothing);
    });

    testWidgets('a refusal between the scroll and the focus: the card keeps '
        'the keyboard', (tester) async {
      final ids = [for (var i = 0; i < 30; i++) 'c$i'];
      final backend = Backend([for (final id in ids) marked(id)])
        ..refuseMove = 'project_store_unavailable';
      await mount(tester, backend);
      // From the end of the board to the top (Ctrl+Home), refused.
      await tester.scrollUntilVisible(
        cardOf('c29'),
        400,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      final answer = backend.holdMove = Completer();
      focusOf(tester, 'c29').requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      // The board scrolls to the top; the focus would follow a frame later.
      await tester.pump();
      answer.complete();
      await tester.pumpAndSettle();
      expect(backend.moves.single, {'id': 'c29', 'before': 'c0'});
      expect(cardOf('c29').hitTestable(), findsOneWidget);
      expect(focusOf(tester, 'c29').hasFocus, isTrue);
    });

    testWidgets('the Goal tab\'s importance is off while a card action on the '
        'project runs', (tester) async {
      final pause = Completer<Map<String, dynamic>>();
      final backend = Backend([
        {
          ...card(
            'r',
            bucket: 'running',
            activity: 'running',
            status: 'running',
            runId: 'run-1',
            active: {'phase': 'execution', 'position': 0, 'state': 'active'},
          ),
          'importance': 'medium',
        },
      ])..pause = pause;
      await mount(tester, backend);
      await tester.tap(find.byKey(const ValueKey('card-pause')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('card-open')));
      await frames(tester);
      expect(
        tester
            .widget<SegmentedButton<BoardImportance>>(
              find.byKey(const ValueKey('goal-importance')),
            )
            .onSelectionChanged,
        isNull,
      );
      pause.complete({});
      await frames(tester);
    });
  });
}
