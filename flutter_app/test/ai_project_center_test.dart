import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/ai_project_center.dart';
import 'package:maprisma/main_tabs.dart';
import 'package:maprisma/window_popup.dart';

Map<String, dynamic> project({String status = 'draft'}) => {
  'id': 'project-1',
  'title': 'Saved project',
  'brief': 'Build a useful project',
  'path': '/tmp/project',
  'team': [
    {'agent': 'test-agent', 'role': 'lead', 'instructions': ''},
  ],
  'plan': 'Make the change and check the result.',
  'status': status,
  'revision': 1,
  'plan_version': 1,
  'approved_version': null,
  'events': <Object>[],
};

Future<void> mount(
  WidgetTester tester,
  ProjectCenterCall call, {
  GlobalKey<AiProjectCenterPageState>? key,
  VoidCallback? onBack,
  bool embedded = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1100, 850));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AiProjectCenterPage(
          key: key,
          onCall: call,
          tr: (s) => s,
          onBack: embedded ? null : onBack ?? () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('unconfirmed pause can be retried for the same run', (
    tester,
  ) async {
    var saved = {...project(status: 'pausing'), 'run_id': 'attempt-1'};
    Map<String, dynamic>? stopped;
    await mount(tester, (operation, params) async {
      if (operation == 'list') {
        return {
          'projects': [saved],
        };
      }
      if (operation == 'profiles') return {'profiles': []};
      if (operation == 'pause') {
        stopped = {...params};
        saved = {...saved, 'status': 'paused', 'revision': 2};
      }
      return {'project': saved};
    });
    await tester.tap(find.text('Saved project'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Retry pause'));
    await tester.pumpAndSettle();
    expect(stopped, {'id': 'project-1', 'revision': 1, 'run_id': 'attempt-1'});
    expect(find.text('Paused'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'the folder picker keeps the popup open and preserves the draft',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final chosen = Completer<String?>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiProjectCenterPage(
              onCall: (operation, params) async => {
                'projects': [],
                'profiles': [],
              },
              tr: (text) => text,
              onBack: () {},
              chooseFolder: () => chosen.future,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Project title'),
        'A saved idea',
      );
      final picker = find.widgetWithText(TextButton, 'Choose folder');
      await tester.ensureVisible(picker);
      await tester.pumpAndSettle();
      await tester.tap(picker);
      await tester.pump();
      expect(PopupGuard.busy, isTrue);
      chosen.complete('/tmp/chosen-project');
      await tester.pumpAndSettle();
      expect(PopupGuard.busy, isFalse);
      expect(find.text('A saved idea'), findsOneWidget);
      expect(find.text('/tmp/chosen-project'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('the Projects tab shows the counts and the store fault', (
    tester,
  ) async {
    MainTab? chosen;
    Future<void> show(Map<String, dynamic> summary, {bool compact = false}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MainTabs(
                selected: MainTab.map,
                summary: summary,
                tr: (s) => s,
                compact: compact,
                onSelect: (tab) => chosen = tab,
              ),
            ),
          ),
        );
    await show(const {
      'running': 2,
      'pausing': 1,
      'needs_you': 1,
      'attention': 4,
      'attention_projects': 3,
      'error': 'store unreadable',
    });
    expect(
      find.byTooltip(
        'Projects · 3 running · 1 need you · 3 need attention · '
        'The project list has a problem',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('tab-projects-fault')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('tab-projects-attention')),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('tab-projects')));
    expect(chosen, MainTab.projects);
    await tester.tap(find.byKey(const ValueKey('ai-map-open')));
    expect(chosen, MainTab.map);
    // An older backend: waiting stands for needs you, attention as it is.
    await show(const {'running': 0, 'waiting': 2, 'attention': 1});
    expect(
      find.byTooltip('Projects · 2 need you · 1 need attention'),
      findsOneWidget,
    );
    // Narrow: one dot.
    await show(const {'running': 1}, compact: true);
    expect(find.byKey(const ValueKey('tab-projects-dot')), findsOneWidget);
    expect(find.byKey(const ValueKey('tab-projects-running')), findsNothing);
    // Disconnected: status unavailable, never zero or old counts.
    await show(const {'running': 2, 'connected': false});
    expect(find.byTooltip('Projects · status unavailable'), findsOneWidget);
    expect(find.text('2'), findsNothing);
  });

  test('the start tab is decided by setup, the saved tab, then projects', () {
    const some = {'total': 2, 'connected': true};
    expect(
      startTab(setupNeeded: true, saved: 'projects', summary: some),
      MainTab.map,
    );
    expect(
      startTab(setupNeeded: false, saved: 'map', summary: some),
      MainTab.map,
    );
    expect(
      startTab(setupNeeded: false, saved: 'projects', summary: null),
      MainTab.projects,
    );
    expect(
      startTab(setupNeeded: false, saved: null, summary: some),
      MainTab.projects,
    );
    expect(
      startTab(setupNeeded: false, saved: null, summary: const {'total': 0}),
      MainTab.map,
    );
    // Not read in time: the AI Map.
    expect(
      startTab(setupNeeded: false, saved: null, summary: null),
      MainTab.map,
    );
    expect(
      startTab(
        setupNeeded: false,
        saved: null,
        summary: const {'total': 3, 'connected': false},
      ),
      MainTab.map,
    );
  });

  testWidgets('a discard waits until the departure commits', (tester) async {
    final key = GlobalKey<AiProjectCenterPageState>();
    await mount(
      tester,
      (op, args) async => {'projects': [], 'profiles': []},
      key: key,
      embedded: true,
    );
    expect(find.widgetWithText(TextButton, 'Back'), findsNothing);
    await tester.enterText(
      find.widgetWithText(TextField, 'Project title'),
      'A new goal',
    );
    final leaving = key.currentState!.prepareLeave();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Discard'));
    await tester.pumpAndSettle();
    final commit = await leaving;
    expect(commit, isNotNull);
    // Not yet taken: a later question (stop running agents?) may cancel.
    expect(find.text('A new goal'), findsOneWidget);
    commit!();
    await tester.pumpAndSettle();
    expect(find.text('A new goal'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a click into a field is not a change', (tester) async {
    final key = GlobalKey<AiProjectCenterPageState>();
    await mount(
      tester,
      (op, args) async => {'projects': [], 'profiles': []},
      key: key,
      embedded: true,
    );
    await tester.tap(find.widgetWithText(TextField, 'Project title'));
    await tester.pump();
    final leaving = key.currentState!.prepareLeave();
    await tester.pump();
    expect(find.text('Save project changes?'), findsNothing);
    expect(await leaving, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a save while leaving locks the page until it ends', (
    tester,
  ) async {
    final key = GlobalKey<AiProjectCenterPageState>();
    final saving = Completer<Map<String, dynamic>>();
    await mount(
      tester,
      (op, args) async {
        if (op == 'save') return saving.future;
        return {'projects': [], 'profiles': []};
      },
      key: key,
      embedded: true,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Project title'),
      'A new goal',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Project goal'),
      'Build it.',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Working folder'),
      '/tmp',
    );
    final leaving = key.currentState!.prepareLeave();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();
    // Saving: locked, and a second departure asks nothing.
    expect(key.currentState!.busy, isTrue);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Project title'))
          .enabled,
      isFalse,
    );
    expect(await key.currentState!.prepareLeave(), isNull);
    saving.complete({
      'project': {...project(), 'title': 'A new goal'},
    });
    await tester.pumpAndSettle();
    expect(await leaving, isNotNull);
    expect(key.currentState!.busy, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a refresh asked for while reading follows the read', (
    tester,
  ) async {
    final key = GlobalKey<AiProjectCenterPageState>();
    Completer<Map<String, dynamic>>? hold;
    var lists = 0;
    await mount(
      tester,
      (op, args) async {
        if (op == 'list') {
          lists++;
          final wait = hold;
          if (wait != null) return wait.future;
        }
        return {'projects': [], 'profiles': []};
      },
      key: key,
      embedded: true,
    );
    final before = lists;
    hold = Completer();
    unawaited(key.currentState!.refresh());
    await tester.pump();
    final blocked = hold;
    hold = null;
    // F5 while that read runs: one more read afterwards, not dropped, and
    // its future ends only after that read (the counts follow it).
    var done = false;
    unawaited(key.currentState!.refresh().then((_) => done = true));
    await tester.pump();
    expect(lists, before + 1);
    expect(done, isFalse);
    blocked.complete({'projects': [], 'profiles': []});
    await tester.pumpAndSettle();
    expect(lists, before + 2);
    expect(done, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a tab button can be used by assistive technology', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    MainTab? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MainTabs(
            selected: MainTab.projects,
            summary: const {'running': 1},
            tr: (s) => s,
            onSelect: (tab) => chosen = tab,
          ),
        ),
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Projects · 1 running')),
      isSemantics(
        label: 'Projects · 1 running',
        isButton: true,
        isSelected: true,
        hasTapAction: true,
        isEnabled: true,
      ),
    );
    tester.semantics.tap(find.semantics.byLabel('AI Map'));
    await tester.pump();
    expect(chosen, MainTab.map);
    handle.dispose();
  });

  testWidgets('unsaved goal survives cancelled navigation', (tester) async {
    var left = false;
    final key = GlobalKey<AiProjectCenterPageState>();
    await mount(
      tester,
      (op, args) async => {'projects': [], 'profiles': []},
      key: key,
      onBack: () => left = true,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Project title'),
      'A new goal',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Back'));
    await tester.pumpAndSettle();
    expect(find.text('Save project changes?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(left, false);
    expect(find.text('A new goal'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('approval precedes execution of the exact saved revision', (
    tester,
  ) async {
    var saved = project();
    final writes = <(String, Map<String, dynamic>)>[];
    await mount(tester, (op, args) async {
      if (op == 'list') {
        return {
          'projects': [saved],
        };
      }
      if (op == 'profiles') {
        return {
          'profiles': [
            {
              'id': 'test-agent',
              'name': 'Test agent',
              'plan_argv': ['test', '--read-only'],
              'run_argv': ['test', '--workspace'],
              'permissions': 'Workspace only',
            },
          ],
        };
      }
      if (op == 'get') return {'project': saved};
      writes.add((op, {...args}));
      if (op == 'review') {
        saved = {
          ...saved,
          'approved_version': 1,
          'revision': 2,
          'status': 'ready',
        };
      }
      if (op == 'run') saved = {...saved, 'status': 'running', 'revision': 3};
      return {'project': saved};
    });
    await tester.tap(find.text('Saved project'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Run project'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Approve plan'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, 'Approve plan').last);
    await tester.pumpAndSettle();
    expect(writes.single.$1, 'review');
    expect(writes.single.$2, {
      'id': 'project-1',
      'revision': 1,
      'approved': true,
    });
    await tester.tap(find.widgetWithText(FilledButton, 'Run project'));
    await tester.pumpAndSettle();
    expect(writes.last.$1, 'run');
    expect(writes.last.$2['revision'], 2);
    expect(find.text('Running'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('continue requires explicit review of interrupted side effects', (
    tester,
  ) async {
    var saved = project(status: 'interrupted');
    Map<String, dynamic>? continuation;
    await mount(tester, (op, args) async {
      if (op == 'list') {
        return {
          'projects': [saved],
        };
      }
      if (op == 'profiles') return {'profiles': []};
      if (op == 'continue') {
        continuation = {...args};
        saved = {...saved, 'status': 'running'};
      }
      return {'project': saved};
    });
    await tester.tap(find.text('Saved project'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue project'));
    await tester.pumpAndSettle();
    expect(continuation, null);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(continuation, null);
    await tester.tap(find.widgetWithText(FilledButton, 'Continue project'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I reviewed the existing changes'));
    await tester.pumpAndSettle();
    expect(continuation!['acknowledge_interrupted'], true);
    await tester.pumpWidget(const SizedBox());
  });

  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) serve(
    Map<String, dynamic> Function() current, {
    List<Map<String, dynamic>> profiles = const [],
    void Function(String operation, Map<String, dynamic> params)? seen,
  }) => (operation, params) async {
    seen?.call(operation, params);
    if (operation == 'list') {
      return {
        'projects': [current()],
      };
    }
    if (operation == 'profiles') return {'profiles': profiles};
    return {'project': current()};
  };

  FilledButton buttonFor(WidgetTester tester, String label) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, label));

  testWidgets('an invalid stored approval can be renewed for a ready project', (
    tester,
  ) async {
    final saved = {
      ...project(status: 'ready'),
      'approved_version': 1,
      'approval_valid': false,
    };
    await mount(tester, serve(() => saved));
    await tester.tap(find.text('Saved project'));
    await tester.pumpAndSettle();
    expect(buttonFor(tester, 'Approve plan').onPressed, isNotNull);
    expect(buttonFor(tester, 'Run project').onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a completed project with a valid approval can be reapproved', (
    tester,
  ) async {
    final saved = {
      ...project(status: 'completed'),
      'approved_version': 1,
      'approval_valid': true,
    };
    final operations = <String>[];
    await mount(
      tester,
      serve(() => saved, seen: (operation, _) => operations.add(operation)),
    );
    await tester.tap(find.text('Saved project'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Approve plan'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Approve plan'),
      ),
    );
    await tester.pumpAndSettle();
    expect(operations, contains('review'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a stale unsupported access mode is shown disabled, not crashed',
    (tester) async {
      final saved = {
        ...project(status: 'awaiting_review'),
        'team': [
          {
            'agent': 'test-agent',
            'role': 'lead',
            'instructions': '',
            'access': 'project-edit',
          },
        ],
      };
      await mount(
        tester,
        serve(
          () => saved,
          profiles: [
            {
              'id': 'test-agent',
              'name': 'Test agent',
              'access_modes': ['read-only'],
            },
          ],
        ),
      );
      await tester.tap(find.text('Saved project'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Team'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.text('Choose a supported access mode before saving.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('setup failures and still-stopping processes are explained', (
    tester,
  ) async {
    final saved = {
      ...project(status: 'ready'),
      'approved_version': 1,
      'approval_valid': true,
      'setup_error': 'project_setup_agent_failed',
      'processes_stopping': true,
    };
    await mount(tester, serve(() => saved));
    await tester.tap(find.text('Saved project'));
    await tester.pumpAndSettle();
    expect(
      find.text('Some agent processes are still stopping. Try again shortly.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Setup'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Team setup ended without a proposal. The project is unchanged.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
