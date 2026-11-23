import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
        ...working(status: 'draft', state: 'stopped'),
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
    expect(
      projectWork(null, {...draft, 'status': 'planning'}, tr)?.headline,
      'AI is drafting the plan',
    );
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
  });

  testWidgets('the strip shows headline, who, step, time and output', (
    tester,
  ) async {
    final card = working(output: 'Inspecting lib/\nComparing the routes');
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
  });

  testWidgets('while the lead drafts, the page says so and the plan box '
      'explains why it is empty', (tester) async {
    final planning = {...page.project(status: 'planning'), 'plan': ''};
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

  test('the bar is still under flutter test', () {
    expect(WorkingBar.animate, isFalse);
  });
}
