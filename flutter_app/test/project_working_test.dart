import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/ai_project_center.dart';
import 'package:maprisma/project_working.dart';

import 'ai_project_center_test.dart' as page show project, mount;
import 'project_board_test.dart' as board show card, showBoard;

/// "Show that the AI is working" (task 098).
String tr(String s) => s;

final now = DateTime.utc(2026, 11, 23, 10, 12);

Map<String, dynamic> member(String phase, int position, String role) => {
  'phase': phase,
  'position': position,
  'agent': 'claude',
  'name': 'Claude Code',
  'role': role,
  'issues': <Map>[],
};

Map<String, dynamic> working({
  String status = 'planning',
  String phase = 'planning',
  int position = 0,
  String state = 'active',
  String activity = 'planning',
  String output = '',
}) {
  final members = [member(phase, 0, 'lead'), member(phase, 1, 'reviewer')];
  return {
    ...board.card(
      'a',
      bucket: 'running',
      activity: activity,
      stage: 'plan',
      status: status,
      active: {'phase': phase, 'position': position, 'state': state},
      execution: phase == 'execution' ? members : const [],
    ),
    if (phase == 'planning') 'planning': members,
    'events': [
      {'at': '2026-11-23T10:00:00.000Z', 'type': 'started', 'text': 'Go.'},
      {
        'at': '2026-11-23T10:09:00.000Z',
        'type': 'assignment',
        'text': 'Claude Code: lead',
      },
      {'at': '2026-11-23T10:10:00.000Z', 'type': 'message', 'text': 'Hi'},
    ],
    'output': output,
  };
}

Future<void> show(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

void main() {
  test('the headline names what the agent does', () {
    String? headline(Map<String, dynamic> card) =>
        projectWork(card, card, tr)?.headline;
    expect(headline(working()), 'AI is drafting the plan');
    expect(headline(working(position: 1)), 'AI is checking the plan');
    expect(
      headline(working(status: 'running', phase: 'execution')),
      'AI is working on the project',
    );
    expect(
      headline(working(status: 'reviewing', phase: 'execution', position: 1)),
      'AI is reviewing the changes',
    );
    expect(
      headline(working(status: 'pausing', state: 'stopping')),
      'Stopping the agent',
    );
    expect(
      headline({
        ...working(status: 'planning', state: 'stopped'),
        'phase': 'setup',
        'active': null,
        'activity': 'setting_up_team',
      }),
      'AI is setting up the team',
    );
    // Nothing works: no strip.
    for (final state in ['stopped', 'next']) {
      expect(headline(working(status: 'paused', state: state)), isNull);
    }
    expect(headline({...working(status: 'completed'), 'active': null}), isNull);
    // Without the board: from the status alone.
    final draft = page.project();
    expect(projectWork(null, draft, tr), isNull);
    String? alone(Map<String, dynamic> fields) =>
        projectWork(null, {...draft, ...fields}, tr)?.headline;
    expect(
      alone({'status': 'planning', 'phase': 'planning'}),
      'AI is drafting the plan',
    );
    expect(
      alone({'status': 'reviewing', 'phase': 'planning'}),
      'AI is checking the plan',
    );
    expect(
      alone({'status': 'reviewing', 'phase': 'running'}),
      'AI is reviewing the changes',
    );
    // A team setup runs as status planning, phase setup.
    expect(
      alone({'status': 'planning', 'phase': 'setup'}),
      'AI is setting up the team',
    );
    expect(
      projectWork(null, {
        ...draft,
        'status': 'planning',
        'phase': 'setup',
        'output': 'old run',
        'setup_output': 'Choosing models',
      }, tr)?.output,
      'Choosing models',
    );
    // Old processes still stopping: also without an active assignment.
    expect(
      alone({'status': 'paused', 'processes_stopping': true}),
      'Stopping the agent',
    );
    expect(
      headline({
        ...working(status: 'ready', state: 'stopped'),
        'active': null,
        'activity': 'stopping',
        'processes_stopping': true,
      }),
      'Stopping the agent',
    );
    // A paused team setup: stopping, no active assignment.
    expect(
      headline({
        ...working(status: 'pausing'),
        'active': null,
        'phase': 'setup',
        'activity': 'stopping',
      }),
      'Stopping the agent',
    );
  });

  test('the project view decides, the card only says who', () {
    // The card (list) is older than the project (get, a change's answer).
    final staleActive = working(status: 'running', phase: 'execution');
    expect(
      projectWork(staleActive, {...staleActive, 'status': 'paused'}, tr),
      isNull,
    );
    final justStarted = {
      ...working(status: 'ready', state: 'next'),
      'active': null,
    };
    expect(
      projectWork(justStarted, {
        ...justStarted,
        'status': 'planning',
        'phase': 'planning',
      }, tr)?.headline,
      'AI is drafting the plan',
    );
  });

  test('stopping a team setup still names the setup and its helper', () {
    final project = {
      ...page.project(status: 'pausing'),
      'phase': 'setup',
      'setup_agent': {'agent': 'claude', 'name': 'Claude Code'},
      'output': 'old run',
      'setup_output': 'Choosing models',
      'events': [
        {'at': '2026-11-23T10:09:00.000Z', 'type': 'setup_started', 'text': ''},
        {
          'at': '2026-11-23T10:09:01.000Z',
          'type': 'assignment',
          'text': 'Claude Code: setup',
        },
      ],
    };
    final work = projectWork(null, project, tr)!;
    expect(work.headline, 'Stopping the agent');
    expect(work.detail, 'Claude Code');
    expect(work.output, 'Choosing models');
    expect(work.since, DateTime.utc(2026, 11, 23, 10, 9));
    // A failed setup ends its attempt: its assignment is not the stopping one.
    final failed = projectWork(null, {
      ...page.project(status: 'draft'),
      'processes_stopping': true,
      'events': [
        {
          'at': '2026-11-23T10:09:01.000Z',
          'type': 'assignment',
          'text': 'Claude Code: setup',
        },
        {'at': '2026-11-23T10:10:00.000Z', 'type': 'setup_failed', 'text': ''},
      ],
    }, tr)!;
    expect(failed.detail, isNull);
  });

  testWidgets('output of the previous attempt or agent is not shown', (
    tester,
  ) async {
    Future<void> poll(Map<String, dynamic> card) => show(
      tester,
      ProjectWorking(card: card, project: card, tr: tr, now: now),
    );
    // Continued: no dispatch yet, the stored output is the last attempt's.
    final continued = {
      ...working(status: 'running', phase: 'execution', state: 'next'),
      'events': [
        {'at': '2026-11-23T10:11:00.000Z', 'type': 'continued', 'text': ''},
      ],
      'output': 'Old interrupted line',
    };
    await poll(continued);
    expect(find.byKey(const ValueKey('working-output')), findsNothing);
    // The first poll after the dispatch already has the new agent's lines.
    await poll({
      ...continued,
      'events': [
        ...continued['events'] as List,
        {
          'at': '2026-11-23T10:11:05.000Z',
          'type': 'assignment',
          'text': 'Claude Code: lead',
        },
      ],
      'output': 'Inspecting the repo',
    });
    expect(find.text('Inspecting the repo'), findsOneWidget);
  });

  test('the time counts from this attempt, not an older assignment', () {
    final card = {
      ...working(status: 'running', phase: 'execution', state: 'next'),
      'active': {'phase': 'execution', 'position': 0, 'state': 'active'},
      'events': [
        {
          'at': '2026-11-23T08:00:00.000Z',
          'type': 'assignment',
          'text': 'A: lead',
        },
        {'at': '2026-11-23T08:30:00.000Z', 'type': 'finished', 'text': 'Done.'},
        {'at': '2026-11-23T10:11:30.000Z', 'type': 'started', 'text': 'Go.'},
      ],
    };
    final work = projectWork(card, card, tr)!;
    expect(work.since, DateTime.utc(2026, 11, 23, 10, 11, 30));
    expect(work.key, isNull);
    expect(workingFor(work.since, now, tr), 'just started');
    // Without the board the event names agent and role, translated.
    final alone = projectWork(null, {
      ...page.project(status: 'running'),
      'phase': 'running',
      'events': [
        {
          'at': '2026-11-23T10:00:00.000Z',
          'type': 'assignment',
          'text': 'Codex: reviewer',
        },
      ],
    }, tr)!;
    expect(alone.detail, 'Codex · Reviewer');
    expect(alone.headline, 'AI is reviewing the changes');
  });

  test('time and the latest output line', () {
    final since = DateTime.utc(2026, 11, 23, 10);
    expect(
      workingFor(since, since.add(const Duration(seconds: 50)), tr),
      'just started',
    );
    expect(
      workingFor(since, since.add(const Duration(minutes: 3)), tr),
      'for 3 min',
    );
    expect(
      workingFor(since, since.add(const Duration(minutes: 125)), tr),
      'for 2 h 5 min',
    );
    expect(workingFor(null, since, tr), '');
    expect(
      lastOutputLine('Reading files\n\x1B[32mWriting the plan\x1B[0m\r\n  \n'),
      'Writing the plan',
    );
    expect(lastOutputLine(' \n '), isNull);
    expect(lastOutputLine('x' * 400)!.length, 301);
    // OSC with BEL or ST (title, hyperlink) leaves no payload behind.
    expect(
      lastOutputLine(
        '\x1B]0;Working\x1B\\See \x1B]8;;https://x\x07here\x1B]8;;\x07',
      ),
      'See here',
    );
  });

  testWidgets('the strip shows headline, who, step, time and output', (
    tester,
  ) async {
    // The stored output is still the previous agent's: not shown.
    var card = working(output: 'The previous agent said this');
    await show(
      tester,
      ProjectWorking(card: card, project: card, tr: tr, now: now),
    );
    expect(find.byKey(const ValueKey('working-bar')), findsOneWidget);
    expect(find.text('AI is drafting the plan…'), findsOneWidget);
    expect(
      find.text('Claude Code · Lead agent · step 1 of 2 · for 3 min'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('working-output')), findsNothing);
    // This agent writes: its latest line.
    card = working(output: 'Inspecting lib/\nComparing the routes');
    await show(
      tester,
      ProjectWorking(card: card, project: card, tr: tr, now: now),
    );
    expect(find.text('Comparing the routes'), findsOneWidget);
    // Compact: no output line.
    await show(
      tester,
      ProjectWorking(
        card: card,
        project: card,
        tr: tr,
        now: now,
        compact: true,
      ),
    );
    expect(find.byKey(const ValueKey('working-output')), findsNothing);
    // Paused: nothing.
    final paused = working(status: 'paused', state: 'stopped');
    await show(
      tester,
      ProjectWorking(card: paused, project: paused, tr: tr, now: now),
    );
    expect(find.byKey(const ValueKey('working-bar')), findsNothing);
    expect(find.byKey(const ValueKey('working-headline')), findsNothing);
  });

  testWidgets('a board card shows the bar only while an agent works', (
    tester,
  ) async {
    await board.showBoard(tester, [
      working(status: 'running', phase: 'execution', activity: 'running'),
      working(status: 'paused', state: 'stopped', activity: 'paused'),
      board.card('c'),
    ]);
    expect(find.byKey(const ValueKey('working-bar')), findsOneWidget);
    // Old processes still stopping, no active assignment: the bar stays.
    await board.showBoard(tester, [
      {
        ...board.card('d', status: 'ready', activity: 'stopping'),
        'processes_stopping': true,
      },
    ]);
    expect(find.byKey(const ValueKey('working-bar')), findsOneWidget);
  });

  testWidgets('the strip fits a narrow window with large text', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final card = working(status: 'running', phase: 'execution');
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 400),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: ProjectWorking(
              card: card,
              project: card,
              tr: tr,
              now: now,
              compact: true,
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('AI is working on the project…'), findsOneWidget);
  });

  testWidgets('the bar moves unless animations are off', (tester) async {
    WorkingBar.animate = true;
    addTearDown(() => WorkingBar.animate = false);
    LinearProgressIndicator bar() =>
        tester.widget(find.byKey(const ValueKey('working-bar')));
    await show(tester, const WorkingBar());
    expect(bar().value, isNull);
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(body: WorkingBar()),
        ),
      ),
    );
    expect(bar().value, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a team setup does not promise a plan', (tester) async {
    final setup = {
      ...page.project(status: 'planning'),
      'phase': 'setup',
      'plan': '',
    };
    await page.mount(tester, (operation, params) async {
      if (operation == 'list') {
        return {
          'projects': [setup],
        };
      }
      if (operation == 'profiles') return {'profiles': []};
      return {'project': setup};
    });
    await tester.tap(find.text('Saved project'));
    await tester.pumpAndSettle();
    expect(find.text('AI is setting up the team…'), findsOneWidget);
    await tester.tap(find.text('Plan').last);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'The AI is drafting the plan. It appears here when the agent is done.',
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('while the lead drafts, the page says so and the plan box '
      'explains why it is empty', (tester) async {
    final planning = {
      ...page.project(status: 'planning'),
      'phase': 'planning',
      'plan': '',
    };
    await page.mount(tester, (operation, params) async {
      if (operation == 'list') {
        return {
          'projects': [planning],
        };
      }
      if (operation == 'profiles') return {'profiles': []};
      return {'project': planning};
    });
    await tester.tap(find.text('Saved project'));
    await tester.pumpAndSettle();
    expect(find.text('AI is drafting the plan…'), findsOneWidget);
    await tester.tap(find.text('Plan').last);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'The AI is drafting the plan. It appears here when the agent is done.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  skipPlanningTests();

  test('the bar is still under flutter test', () {
    expect(WorkingBar.animate, isFalse);
  });
}

/// Skip planning (task 099).
void skipPlanningTests() {
  testWidgets('Skip planning asks, then saves the fixed plan, approves and '
      'runs', (tester) async {
    var saved = {...page.project(), 'plan': '', 'plan_version': 0};
    final calls = <String>[];
    Map<String, dynamic>? savedParams;
    await page.mount(tester, (operation, params) async {
      if (operation == 'list') {
        return {
          'projects': [saved],
        };
      }
      if (operation == 'profiles') return {'profiles': []};
      if (const {'save', 'review', 'run'}.contains(operation)) {
        calls.add(operation);
        expect(params['revision'], saved['revision']);
        if (operation == 'save') {
          savedParams = {...params};
          saved = {
            ...saved,
            'plan': params['plan'],
            'plan_version': 1,
            'status': 'awaiting_review',
          };
        }
        if (operation == 'review') {
          expect(params['approved'], isTrue);
          saved = {...saved, 'approved_version': 1, 'status': 'ready'};
        }
        if (operation == 'run') saved = {...saved, 'status': 'running'};
        saved = {...saved, 'revision': (saved['revision'] as int) + 1};
      }
      return {'project': saved};
    });
    await tester.tap(find.text('Saved project'));
    await tester.pumpAndSettle();
    // Cancel changes nothing.
    await tester.tap(find.widgetWithText(FilledButton, 'Skip planning'));
    await tester.pumpAndSettle();
    expect(find.text('Skip planning?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, 'Skip planning'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip planning and run'));
    await tester.pumpAndSettle();
    expect(calls, ['save', 'review', 'run']);
    expect(savedParams!['plan'], AiProjectCenterPageState.skippedPlan);
    expect(saved['status'], 'running');
    // Running: no second skip.
    final skip = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Skip planning'),
    );
    expect(skip.onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Skip planning waits for stopping agents and reviewed changes, '
      'and a failed save leaves the page unchanged', (tester) async {
    var shown = {...page.project(), 'plan': '', 'processes_stopping': true};
    await page.mount(tester, (operation, params) async {
      if (operation == 'list') {
        return {
          'projects': [shown],
        };
      }
      if (operation == 'profiles') return {'profiles': []};
      if (operation == 'save') throw StateError('folder gone');
      return {'project': shown};
    });
    await tester.tap(find.text('Saved project'));
    await tester.pumpAndSettle();
    FilledButton skip() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Skip planning'),
    );
    expect(skip().onPressed, isNull);
    shown = {
      ...shown,
      'processes_stopping': false,
      'needs_reconciliation': true,
    };
    await tester.tap(find.text('Goal').last);
    await tester.pumpAndSettle();
    final state = tester.state<AiProjectCenterPageState>(
      find.byType(AiProjectCenterPage),
    );
    await state.refresh();
    await tester.pumpAndSettle();
    expect(skip().onPressed, isNull);
    shown = {...shown, 'needs_reconciliation': false};
    await state.refresh();
    await tester.pumpAndSettle();
    expect(skip().onPressed, isNotNull);
    // The save fails: no "Unsaved changes" from the restored plan box.
    await tester.tap(find.widgetWithText(FilledButton, 'Skip planning'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip planning and run'));
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('typing a plan after other edits turns Skip planning off', (
    tester,
  ) async {
    final shown = {...page.project(), 'plan': ''};
    await page.mount(tester, (operation, params) async {
      if (operation == 'list') {
        return {
          'projects': [shown],
        };
      }
      if (operation == 'profiles') return {'profiles': []};
      return {'project': shown};
    });
    await tester.tap(find.text('Saved project'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Another title');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plan').last);
    await tester.pumpAndSettle();
    FilledButton skip() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Skip planning'),
    );
    expect(skip().onPressed, isNotNull);
    await tester.enterText(find.byType(TextField).last, 'My own plan');
    await tester.pump();
    expect(skip().onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Skip planning is offered only without a plan', (tester) async {
    await page.mount(tester, (operation, params) async {
      if (operation == 'list') {
        return {
          'projects': [page.project()],
        };
      }
      if (operation == 'profiles') return {'profiles': []};
      return {'project': page.project()};
    });
    await tester.tap(find.text('Saved project'));
    await tester.pumpAndSettle();
    final skip = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Skip planning'),
    );
    expect(skip.onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
