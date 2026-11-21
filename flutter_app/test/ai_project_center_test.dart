import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/ai_project_center.dart';
import 'package:maprisma/project_center_indicator.dart';
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
          onBack: onBack ?? () {},
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

  testWidgets('indicator exposes real run counts and disconnected status', (
    tester,
  ) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectCenterIndicator(
            summary: const {'running': 2, 'pausing': 1, 'waiting': 1},
            tr: (s) => s,
            onOpen: () => opened = true,
          ),
        ),
      ),
    );
    expect(find.text('3'), findsOneWidget);
    expect(
      find.byTooltip(
        'AI Project Center · 2 projects running · 1 projects pausing · 1 projects need attention',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byType(IconButton));
    expect(opened, true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectCenterIndicator(
            summary: const {'running': 2, 'connected': false},
            tr: (s) => s,
            onOpen: () {},
          ),
        ),
      ),
    );
    expect(
      find.byTooltip('AI Project Center · status unavailable'),
      findsOneWidget,
    );
    expect(find.text('2'), findsNothing);
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
