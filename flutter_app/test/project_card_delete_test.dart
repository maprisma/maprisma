import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/ai_project_center.dart';
import 'package:maprisma_core/maprisma_core.dart' show ServiceError;

import 'project_board_test.dart' show card;

/// Deleting a project from its card (task 094), and from the open project
/// back to the board.
class Store {
  Store(this.projects);
  final List<Map<String, dynamic>> projects;
  final deleted = <Map>[];
  final calls = <String>[];
  String? refuse;
  bool failList = false;
  String listCode = 'feature_unavailable';

  /// A card's Pause answers with this.
  Completer<Map<String, dynamic>>? pause;

  /// The next `list` waits for this.
  Completer<void>? holdList;

  /// The next `get` waits for this, then fails (a read on its way while
  /// the project is deleted).
  Completer<void>? holdGet;
}

Future<GlobalKey<AiProjectCenterPageState>> mount(
  WidgetTester tester,
  Store store,
) async {
  final key = GlobalKey<AiProjectCenterPageState>();
  await tester.binding.setSurfaceSize(const Size(1400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AiProjectCenterPage(
          key: key,
          tr: (s) => s,
          onCall: (op, args) async {
            store.calls.add(op);
            if (op == 'list' && store.failList) {
              throw ServiceError(store.listCode);
            }
            if (op == 'pause' && store.pause != null) {
              return store.pause!.future;
            }
            if (op == 'list' && store.holdList != null) {
              final hold = store.holdList!;
              store.holdList = null;
              await hold.future;
            }
            if (op == 'list') {
              return {
                'projects': store.projects,
                'capabilities': ['board'],
              };
            }
            if (op == 'delete') {
              if (store.refuse case final code?) throw ServiceError(code);
              store.deleted.add(args);
              store.projects.removeWhere((p) => p['id'] == args['id']);
              return {'deleted': true};
            }
            if (op == 'get' && store.holdGet != null) {
              final hold = store.holdGet!;
              store.holdGet = null;
              await hold.future;
              throw ServiceError('project_unknown');
            }
            if (op == 'get') {
              final p = store.projects.firstWhere((p) => p['id'] == args['id']);
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

Finder trashOf(String id) => find.descendant(
  of: find.byKey(ValueKey('project-card-$id')),
  matching: find.byKey(const ValueKey('card-delete')),
);

void main() {
  testWidgets('the trash symbol asks, then deletes the saved project', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final store = Store([card('a'), card('b')]);
    await mount(tester, store);
    expect(find.byTooltip('Delete project'), findsNWidgets(2));
    expect(
      tester.getSemantics(trashOf('a')),
      isSemantics(isButton: true, isEnabled: true, hasTapAction: true),
    );
    await tester.tap(trashOf('a'));
    await tester.pumpAndSettle();
    expect(find.text('Delete saved project?'), findsOneWidget);
    expect(
      find.text(
        'The saved project will be removed. Its working folder is kept.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(store.deleted, [
      {'id': 'a', 'revision': 1},
    ]);
    expect(find.byKey(const ValueKey('project-card-a')), findsNothing);
    expect(find.byKey(const ValueKey('project-card-b')), findsOneWidget);
    handle.dispose();
  });

  testWidgets('Cancel deletes nothing', (tester) async {
    final store = Store([card('a')]);
    await mount(tester, store);
    await tester.tap(trashOf('a'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(store.deleted, isEmpty);
    expect(find.byKey(const ValueKey('project-card-a')), findsOneWidget);
  });

  for (final (name, project) in [
    (
      'running',
      card('r', bucket: 'running', activity: 'running', status: 'running'),
    ),
    (
      'pausing',
      card('p', bucket: 'running', activity: 'stopping', status: 'pausing'),
    ),
    (
      'setting up its team',
      card('s', bucket: 'running', activity: 'setting_up_team'),
    ),
    ('stopping old processes', {...card('o'), 'processes_stopping': true}),
    (
      'planning',
      card('l', bucket: 'running', activity: 'planning', status: 'planning'),
    ),
    (
      'reviewing',
      card('v', bucket: 'running', activity: 'reviewing', status: 'reviewing'),
    ),
  ]) {
    testWidgets('no delete while $name', (tester) async {
      await mount(tester, Store([project]));
      final trash = tester.widget<IconButton>(
        find.byKey(const ValueKey('card-delete')),
      );
      expect(trash.onPressed, isNull);
    });
  }

  testWidgets('a refused delete keeps its reason on the board', (tester) async {
    final store = Store([card('a')])..refuse = 'project_busy';
    await mount(tester, store);
    await tester.tap(trashOf('a'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('This project is already running.'), findsOneWidget);
    expect(find.byKey(const ValueKey('project-card-a')), findsOneWidget);
  });

  testWidgets('Delete project in the open project leads back to the board', (
    tester,
  ) async {
    final store = Store([card('a'), card('b')]);
    final key = await mount(tester, store);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('project-card-a')),
        matching: find.byKey(const ValueKey('card-open')),
      ),
    );
    await tester.pumpAndSettle();
    expect(key.currentState!.projectOpen, isTrue);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete project'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(store.deleted.single['id'], 'a');
    expect(key.currentState!.projectOpen, isFalse);
    expect(find.byKey(const ValueKey('project-card-a')), findsNothing);
    expect(find.byKey(const ValueKey('project-card-b')), findsOneWidget);
  });

  bool focusedIn(Finder target) {
    final focus = FocusManager.instance.primaryFocus;
    return focus?.context != null &&
        find
            .ancestor(
              of: find.byWidget(focus!.context!.widget),
              matching: target,
            )
            .evaluate()
            .isNotEmpty;
  }

  testWidgets('back on the board after a footer delete: the first card has '
      'the keyboard', (tester) async {
    final store = Store([card('a'), card('b'), card('c')]);
    final key = await mount(tester, store);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('project-card-b')),
        matching: find.byKey(const ValueKey('card-open')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete project'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(key.currentState!.projectOpen, isFalse);
    expect(find.byKey(const ValueKey('project-card-b')), findsNothing);
    expect(focusedIn(find.byKey(const ValueKey('project-card-a'))), isTrue);
  });

  testWidgets('the last project deleted from its page: New project has the '
      'keyboard', (tester) async {
    final store = Store([card('a')]);
    await mount(tester, store);
    await tester.tap(find.byKey(const ValueKey('card-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete project'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(focusedIn(find.byKey(const ValueKey('board-new'))), isTrue);
  });

  testWidgets('deleting from the page with unsaved changes never saves them; '
      'Cancel keeps the draft', (tester) async {
    final store = Store([card('a')]);
    final key = await mount(tester, store);
    await tester.tap(find.byKey(const ValueKey('card-open')));
    await tester.pumpAndSettle();
    // An edit that could not even be saved (no title).
    await tester.enterText(find.widgetWithText(TextField, 'Project title'), '');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete project'));
    await tester.pumpAndSettle();
    expect(find.text('Delete saved project?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(store.calls, isNot(contains('save')));
    expect(key.currentState!.projectOpen, isTrue);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Project title'))
          .controller!
          .text,
      '',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Delete project'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(store.calls, isNot(contains('save')));
    expect(store.deleted.single['id'], 'a');
  });

  testWidgets('the board cannot be read: the trash symbol is there but off', (
    tester,
  ) async {
    final store = Store([card('a')]);
    final key = await mount(tester, store);
    store.failList = true;
    await key.currentState!.refresh();
    await tester.pumpAndSettle();
    final trash = find.byKey(const ValueKey('card-delete'));
    expect(trash, findsOneWidget);
    expect(tester.widget<IconButton>(trash).onPressed, isNull);
  });

  testWidgets('a read of the project still on its way when it is deleted '
      'shows no error afterwards', (tester) async {
    final store = Store([card('a'), card('b')]);
    final key = await mount(tester, store);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('project-card-a')),
        matching: find.byKey(const ValueKey('card-open')),
      ),
    );
    await tester.pumpAndSettle();
    // A refresh whose read of the project is held back.
    store.holdGet = Completer<void>();
    final held = store.holdGet!;
    unawaited(key.currentState!.refresh());
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete project'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    // Deleted; the old read is still on its way (the page's own read of
    // the board waits behind it).
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(store.deleted.single['id'], 'a');
    held.complete();
    await tester.pumpAndSettle();
    expect(key.currentState!.projectOpen, isFalse);
    expect(find.text('The project could not be found.'), findsNothing);
  });

  Future<void> openAndAsk(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('project-card-a')),
        matching: find.byKey(const ValueKey('card-open')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete project'));
    await tester.pumpAndSettle();
  }

  testWidgets('a read of the project that fails while the question is open '
      'leaves no error on the board', (tester) async {
    final store = Store([card('a'), card('b')]);
    final key = await mount(tester, store);
    await openAndAsk(tester);
    store.holdGet = Completer<void>()..complete();
    await key.currentState!.refresh();
    await tester.pump();
    expect(find.text('The project could not be found.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(store.deleted.single['id'], 'a');
    expect(key.currentState!.projectOpen, isFalse);
    expect(find.text('The project could not be found.'), findsNothing);
  });

  testWidgets('a board read that fails while the question is open ends with '
      'the read after the delete', (tester) async {
    final store = Store([card('a'), card('b')]);
    final key = await mount(tester, store);
    await openAndAsk(tester);
    store
      ..failList = true
      ..listCode = 'project_unknown';
    await key.currentState!.refresh();
    await tester.pump();
    expect(find.text('The project could not be found.'), findsOneWidget);
    store.failList = false;
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(store.deleted.single['id'], 'a');
    expect(key.currentState!.projectOpen, isFalse);
    expect(find.text('The project could not be found.'), findsNothing);
  });

  testWidgets('another card\'s failed Pause keeps its reason when a project '
      'is deleted from its page meanwhile', (tester) async {
    final store = Store([
      card('a'),
      card(
        'b',
        bucket: 'running',
        activity: 'running',
        status: 'running',
        runId: 'run-1',
        active: {'phase': 'execution', 'position': 0, 'state': 'active'},
      ),
    ]);
    await mount(tester, store);
    store.pause = Completer();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('project-card-b')),
        matching: find.byKey(const ValueKey('card-pause')),
      ),
    );
    await tester.pump();
    await openAndAsk(tester);
    // Pause fails while the question is open; its read of the board waits.
    final list = store.holdList = Completer<void>();
    store.pause!.completeError(ServiceError('project_changed'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(store.deleted.single['id'], 'a');
    // The delete's read waits behind Pause's.
    list.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('project-card-a')), findsNothing);
    expect(
      find.text('This project changed. Reload it before saving.'),
      findsOneWidget,
    );
  });

  testWidgets('another card\'s failed Pause keeps its reason over a read that '
      'failed before the delete', (tester) async {
    final store = Store([
      card('a'),
      card(
        'b',
        bucket: 'running',
        activity: 'running',
        status: 'running',
        runId: 'run-1',
        active: {'phase': 'execution', 'position': 0, 'state': 'active'},
      ),
    ]);
    await mount(tester, store);
    store.pause = Completer();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('project-card-b')),
        matching: find.byKey(const ValueKey('card-pause')),
      ),
    );
    await tester.pump();
    await openAndAsk(tester);
    // Pause fails; its read of the open project fails too and its message
    // takes the place of Pause's reason.
    store.holdGet = Completer<void>()..complete();
    store.pause!.completeError(ServiceError('project_changed'));
    await tester.pumpAndSettle();
    expect(find.text('The project could not be found.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(store.deleted.single['id'], 'a');
    expect(find.byKey(const ValueKey('project-card-a')), findsNothing);
    expect(find.text('The project could not be found.'), findsNothing);
    expect(
      find.text('This project changed. Reload it before saving.'),
      findsOneWidget,
    );
  });
}
