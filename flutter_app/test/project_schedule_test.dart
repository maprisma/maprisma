import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/ai_project_center.dart';
import 'package:maprisma/project_board.dart';
import 'package:maprisma/project_schedule.dart';
import 'package:maprisma_core/maprisma_core.dart' show ServiceError;

import 'project_board_order_test.dart' show marked, inCard;

/// Monday 23 November 2026, 10:00 local.
final monday = DateTime(2026, 11, 23, 10);

/// Tuesday 05:00 local, as the backend writes it (UTC).
final tuesdayFive = DateTime(2026, 11, 24, 5).toUtc().toIso8601String();

Future<void> pumpControl(
  WidgetTester tester, {
  Map<String, dynamic>? schedule,
  String? nextRun,
  bool approved = true,
  required List<Map<String, dynamic>?> sent,
  TimeOfDay? time,
  DateTime? date,
  bool readOnly = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProjectScheduleControl(
            schedule: schedule,
            nextRun: nextRun,
            tr: (s) => s,
            approved: approved,
            now: monday,
            onChanged: readOnly ? null : sent.add,
            pickTime: (_, _) async => time,
            pickDate: (_, _) async => date,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester, String key, String item) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

void main() {
  group('the schedule control (task 101)', () {
    testWidgets('off: choosing Every day sends a schedule', (tester) async {
      final sent = <Map<String, dynamic>?>[];
      await pumpControl(tester, sent: sent);
      expect(find.byKey(const ValueKey('schedule-time')), findsNothing);
      expect(find.byKey(const ValueKey('schedule-summary')), findsNothing);
      await choose(tester, 'schedule-repeat', 'Every day');
      expect(sent, [
        {'repeat': 'daily', 'time': '09:00'},
      ]);
    });

    testWidgets('the summary says when, and when next', (tester) async {
      await pumpControl(
        tester,
        schedule: {'repeat': 'daily', 'time': '05:00'},
        nextRun: tuesdayFive,
        sent: [],
      );
      expect(
        find.text('Every day at 05:00 · next run Tue 05:00'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('schedule-not-approved')), findsNothing);
      await pumpControl(
        tester,
        schedule: {
          'repeat': 'weekdays',
          'time': '17:00',
          'days': [1, 3, 5],
          'until': '2026-12-31',
        },
        nextRun: null,
        approved: false,
        sent: [],
      );
      final summary = tester.widget<Text>(
        find.byKey(const ValueKey('schedule-summary')),
      );
      expect(summary.data, startsWith('On Mon, Wed, Fri at 17:00 · until '));
      expect(summary.data, endsWith(' · The schedule has ended.'));
      expect(
        find.byKey(const ValueKey('schedule-not-approved')),
        findsOneWidget,
      );
    });

    testWidgets('the time picker sets the time', (tester) async {
      final sent = <Map<String, dynamic>?>[];
      await pumpControl(
        tester,
        schedule: {'repeat': 'daily', 'time': '09:00'},
        nextRun: tuesdayFive,
        sent: sent,
        time: const TimeOfDay(hour: 5, minute: 0),
      );
      await tester.tap(find.byKey(const ValueKey('schedule-time')));
      await tester.pumpAndSettle();
      expect(sent, [
        {'repeat': 'daily', 'time': '05:00'},
      ]);
    });

    testWidgets('weekday chips keep at least one day', (tester) async {
      final sent = <Map<String, dynamic>?>[];
      await pumpControl(
        tester,
        schedule: {
          'repeat': 'weekdays',
          'time': '07:00',
          'days': [1],
        },
        nextRun: tuesdayFive,
        sent: sent,
      );
      final monday = tester.widget<FilterChip>(
        find.byKey(const ValueKey('schedule-day-1')),
      );
      expect(monday.selected, isTrue);
      expect(monday.onSelected, isNull);
      await tester.tap(find.byKey(const ValueKey('schedule-day-6')));
      await tester.pumpAndSettle();
      expect(sent.single!['days'], [1, 6]);
    });

    testWidgets('hours, month day and an end date', (tester) async {
      final sent = <Map<String, dynamic>?>[];
      await pumpControl(
        tester,
        schedule: {'repeat': 'hours', 'time': '01:30', 'every': 4},
        nextRun: tuesdayFive,
        sent: sent,
        date: DateTime(2027, 1, 31),
      );
      expect(find.textContaining('Every 4 hours from 01:30'), findsOneWidget);
      await choose(tester, 'schedule-every', 'Every 6 hours');
      expect(sent.removeLast(), {
        'repeat': 'hours',
        'time': '01:30',
        'every': 6,
      });
      await choose(tester, 'schedule-ends', 'Ends on a date');
      expect(sent.removeLast(), {
        'repeat': 'hours',
        'time': '01:30',
        'every': 4,
        'until': '2027-01-31',
      });
      // Another repeat keeps the time and the end.
      await pumpControl(
        tester,
        schedule: {'repeat': 'daily', 'time': '05:00', 'until': '2027-01-31'},
        nextRun: tuesdayFive,
        sent: sent,
      );
      await choose(tester, 'schedule-repeat', 'Every month');
      expect(sent.removeLast(), {
        'repeat': 'monthly',
        'time': '05:00',
        'day': 23,
        'until': '2027-01-31',
      });
      await choose(tester, 'schedule-ends', 'Never ends');
      expect(sent.removeLast(), {'repeat': 'daily', 'time': '05:00'});
      await choose(tester, 'schedule-repeat', 'Off');
      expect(sent.removeLast(), isNull);
    });

    testWidgets('read only: nothing can be changed', (tester) async {
      await pumpControl(
        tester,
        schedule: {'repeat': 'daily', 'time': '05:00'},
        nextRun: tuesdayFive,
        sent: [],
        readOnly: true,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const ValueKey('schedule-time')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<DropdownButton<ScheduleRepeat>>(
              find.byKey(const ValueKey('schedule-repeat')),
            )
            .onChanged,
        isNull,
      );
    });
  });

  group('the board clock and the Goal tab (task 101)', () {
    testWidgets('a scheduled card shows a clock with the next run', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 260,
              child: ProjectCard(
                project: {
                  ...marked('a'),
                  'schedule': {'repeat': 'daily', 'time': '05:00'},
                  'next_run': DateTime.now()
                      .add(const Duration(days: 1))
                      .toUtc()
                      .toIso8601String(),
                },
                tr: (s) => s,
                onOpen: () {},
                onReview: () {},
                onPause: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final clock = find.byKey(const ValueKey('card-schedule'));
      expect(clock, findsOneWidget);
      final next = DateTime.now().add(const Duration(days: 1));
      final day = scheduleWeekdays[next.weekday - 1];
      expect(
        find.descendant(of: clock, matching: find.textContaining(day)),
        findsOneWidget,
      );
      final tip = tester.widget<Tooltip>(
        find.ancestor(of: clock, matching: find.byType(Tooltip)).first,
      );
      expect(tip.message, startsWith('Every day at 05:00 · next run $day '));
      // The card reads it as one line of its label.
      expect(
        tester.getSemantics(clock).label,
        contains('\nNext scheduled run: $day '),
      );
      // Without a schedule: no clock.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 260,
              child: ProjectCard(
                project: marked('b'),
                tr: (s) => s,
                onOpen: () {},
                onReview: () {},
                onPause: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('card-schedule')), findsNothing);
    });

    testWidgets('the Goal tab sends set_schedule and shows the answer', (
      tester,
    ) async {
      final calls = <(String, Map<String, dynamic>)>[];
      var project = {
        ...marked('a'),
        'approval_valid': true,
        'schedule': null,
        'next_run': null,
      };
      String? refuse;
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiProjectCenterPage(
              tr: (s) => s,
              pickTime: (_, _) async => const TimeOfDay(hour: 5, minute: 0),
              onCall: (op, args) async {
                calls.add((op, args));
                if (op == 'list') {
                  return {
                    'projects': [project],
                    'capabilities': ['summary2', 'board', 'order', 'schedule'],
                  };
                }
                if (op == 'set_schedule') {
                  if (refuse case final code?) throw ServiceError(code);
                  project = {
                    ...project,
                    'schedule': args['schedule'],
                    'next_run': args['schedule'] == null ? null : tuesdayFive,
                  };
                  return {
                    'project': {...project, 'brief': 'b'},
                  };
                }
                if (op == 'get') {
                  return {
                    'project': {
                      ...project,
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
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The card has no clock yet.
      expect(find.byKey(const ValueKey('card-schedule')), findsNothing);
      await tester.tap(inCard('a', const ValueKey('card-open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('goal-schedule')), findsOneWidget);
      await choose(tester, 'schedule-repeat', 'Every day');
      expect(calls.last.$1, 'set_schedule');
      expect(calls.last.$2, {
        'id': 'a',
        'schedule': {'repeat': 'daily', 'time': '09:00'},
      });
      expect(calls.map((c) => c.$1), isNot(contains('save')));
      await tester.tap(find.byKey(const ValueKey('schedule-time')));
      await tester.pumpAndSettle();
      expect(calls.last.$2['schedule'], {'repeat': 'daily', 'time': '05:00'});
      expect(
        find.textContaining('Every day at 05:00 · next run '),
        findsOneWidget,
      );
      // A refusal keeps the schedule and says why.
      refuse = 'project_schedule_unavailable';
      await choose(tester, 'schedule-repeat', 'Off');
      expect(
        find.text(
          'Schedules need systemd user timers, which this system does not offer.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('schedule-time')), findsOneWidget);
    });

    testWidgets('an older backend without schedules shows no control', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiProjectCenterPage(
              tr: (s) => s,
              onCall: (op, args) async {
                if (op == 'list') {
                  return {
                    'projects': [marked('a')],
                    'capabilities': ['summary2', 'board', 'order'],
                  };
                }
                if (op == 'get') {
                  return {
                    'project': {
                      ...marked('a'),
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
      await tester.tap(inCard('a', const ValueKey('card-open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('goal-importance')), findsOneWidget);
      expect(find.byKey(const ValueKey('goal-schedule')), findsNothing);
    });
  });
}
