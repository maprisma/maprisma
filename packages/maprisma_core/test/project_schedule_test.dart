import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_core/src/action_rules.dart' show RuleRefused;
import 'package:maprisma_core/src/desktop_schedules.dart';
import 'package:maprisma_core/src/features/ai_project_center.dart';
import 'package:maprisma_core/src/features/project_schedule.dart';
import 'package:maprisma_core/src/features/project_schedule_run.dart';
import 'package:maprisma_core/src/posix_ffi.dart';
import 'package:maprisma_core/src/protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'ai_project_center_test.dart'
    show FakeProjectProcess, TestPosix, errorCode, waitUntil;

/// Central European time: UTC+1, UTC+2 from the last Sunday of March to the
/// last Sunday of October (both at 01:00 UTC), as in Berlin.
final class CentralEuropeanZone implements ScheduleZone {
  const CentralEuropeanZone();
  static DateTime _lastSunday(int year, int month) {
    var day = DateTime.utc(year, month + 1, 0);
    while (day.weekday != DateTime.sunday) {
      day = day.subtract(const Duration(days: 1));
    }
    return day;
  }

  static bool summer(DateTime utc) {
    final start = _lastSunday(utc.year, 3).add(const Duration(hours: 1));
    final end = _lastSunday(utc.year, 10).add(const Duration(hours: 1));
    return !utc.isBefore(start) && utc.isBefore(end);
  }

  @override
  DateTime wall(DateTime instant) {
    final utc = instant.toUtc();
    return utc.add(Duration(hours: summer(utc) ? 2 : 1));
  }

  @override
  DateTime instant(int year, int month, int day, int hour, int minute) {
    final wall = DateTime.utc(year, month, day, hour, minute);
    final asSummer = wall.subtract(const Duration(hours: 2));
    final asWinter = wall.subtract(const Duration(hours: 1));
    if (summer(asSummer)) return asSummer; // also the first of two
    if (!summer(asWinter)) return asWinter;
    // In the spring gap: the same minutes after it.
    return wall.subtract(const Duration(hours: 1));
  }
}

const zone = CentralEuropeanZone();
DateTime utc(int y, int m, int d, [int h = 0, int min = 0]) =>
    DateTime.utc(y, m, d, h, min);

Map<String, dynamic> schedule(Map<String, dynamic> value) =>
    checkSchedule(value, checkUntil: false)!;

/// Records what the plugin asks of the desktop.
final class FakeScheduler implements ProjectScheduler {
  final installs = <String, List<String>>{};
  final removed = <String>[];
  final notes = <(String, String)>[];
  ServiceError? failInstall;
  ServiceError? failRemove;
  ServiceError? failInstalled;
  Duration installDelay = Duration.zero;
  Duration removeDelay = Duration.zero;
  @override
  Future<void> install(String id, List<String> calendar) async {
    await Future<void>.delayed(installDelay);
    if (failInstall != null) throw failInstall!;
    installs[id] = calendar;
  }

  @override
  Future<void> remove(String id) async {
    removed.add(id);
    await Future<void>.delayed(removeDelay);
    if (failRemove != null) throw failRemove!;
    installs.remove(id);
  }

  @override
  Future<Set<String>> installed() async {
    if (failInstalled != null) throw failInstalled!;
    return installs.keys.toSet();
  }

  @override
  void notify(String title, String body) => notes.add((title, body));
}

/// Store writes fail while [fail] is set (a full or broken disk); stat as
/// [TestPosix] answers it.
final class FailingPosix extends Posix {
  bool fail = false;
  final _test = TestPosix();
  @override
  ({int mode, int uid, int size}) stat(int fd) => _test.stat(fd);
  @override
  void atomicWrite(String path, List<int> bytes) {
    if (fail) throw const FileSystemException('disk full');
    super.atomicWrite(path, bytes);
  }
}

void main() {
  group('calendar (task 101)', () {
    test('validation keeps each repeat to its own fields', () {
      final today = utc(2026, 11, 23);
      expect(
        checkSchedule({'repeat': 'daily', 'time': '05:00'}, today: today),
        {'repeat': 'daily', 'time': '05:00'},
      );
      expect(checkSchedule(null), isNull);
      expect(
        checkSchedule({
          'repeat': 'weekdays',
          'time': '07:15',
          'days': [5, 1, 3],
        }),
        {
          'repeat': 'weekdays',
          'time': '07:15',
          'days': [1, 3, 5],
        },
      );
      for (final bad in <Object?>[
        'daily',
        {'repeat': 'daily'},
        {'repeat': 'daily', 'time': '24:00'},
        {'repeat': 'daily', 'time': '5:00'},
        {'repeat': 'daily', 'time': '05:00\n'},
        {'repeat': 'daily', 'time': '05:00; rm -rf ~'},
        {
          'repeat': 'daily',
          'time': '05:00',
          'days': [1],
        },
        {'repeat': 'daily', 'time': '05:00', 'command': 'x'},
        {'repeat': 'yearly', 'time': '05:00'},
        {'repeat': 'weekdays', 'time': '05:00', 'days': <int>[]},
        {
          'repeat': 'weekdays',
          'time': '05:00',
          'days': [1, 1],
        },
        {
          'repeat': 'weekdays',
          'time': '05:00',
          'days': [0],
        },
        {
          'repeat': 'weekdays',
          'time': '05:00',
          'days': ['1'],
        },
        {
          'repeat': 'weekly',
          'time': '05:00',
          'days': [1, 2],
        },
        {'repeat': 'hours', 'time': '05:00', 'every': 5},
        {'repeat': 'hours', 'time': '05:00'},
        {'repeat': 'monthly', 'time': '05:00', 'day': 32},
        {'repeat': 'monthly', 'time': '05:00', 'day': 0},
        {'repeat': 'daily', 'time': '05:00', 'until': '2026-02-30'},
        {'repeat': 'daily', 'time': '05:00', 'until': '2026-11-22'},
        {'repeat': 'daily', 'time': '05:00', 'until': '"2027-01-01"'},
      ]) {
        expect(
          () => checkSchedule(bad, today: today),
          throwsA(errorCode('project_schedule_invalid')),
          reason: '$bad',
        );
      }
    });

    test('every day keeps its wall-clock time across DST', () {
      final daily = schedule({'repeat': 'daily', 'time': '05:00'});
      // Winter (UTC+1), the spring change, summer (UTC+2).
      expect(
        nextScheduledRun(daily, utc(2026, 3, 27, 12), zone: zone),
        utc(2026, 3, 28, 4),
      );
      expect(
        nextScheduledRun(daily, utc(2026, 3, 28, 4), zone: zone),
        utc(2026, 3, 29, 3),
      );
      expect(
        nextScheduledRun(daily, utc(2026, 10, 24, 12), zone: zone),
        utc(2026, 10, 25, 4),
      );
    });

    test('a time in the spring gap runs after it, an autumn one once', () {
      final night = schedule({'repeat': 'daily', 'time': '02:30'});
      // 29 March 2026: 02:30 does not exist; 03:30 CEST is 01:30 UTC.
      final spring = nextScheduledRun(night, utc(2026, 3, 28, 12), zone: zone);
      expect(spring, utc(2026, 3, 29, 1, 30));
      expect(
        nextScheduledRun(night, spring!, zone: zone),
        utc(2026, 3, 30, 0, 30),
      );
      // 25 October 2026: 02:30 happens twice; it runs at the first one.
      final autumn = nextScheduledRun(night, utc(2026, 10, 24, 12), zone: zone);
      expect(autumn, utc(2026, 10, 25, 0, 30));
      expect(
        nextScheduledRun(night, autumn!, zone: zone),
        utc(2026, 10, 26, 1, 30),
      );
      // The second 02:30 of that night belongs to the first one.
      expect(
        latestScheduledRun(night, utc(2026, 10, 25, 1, 45), zone: zone),
        autumn,
      );
    });

    test('every few hours restarts each day at its first time', () {
      final hours = schedule({'repeat': 'hours', 'time': '01:30', 'every': 4});
      // 1:30, 5:30, ..., 21:30 local (summer: UTC+2).
      expect(
        nextScheduledRun(hours, utc(2026, 6, 1, 4), zone: zone),
        utc(2026, 6, 1, 7, 30),
      );
      expect(
        nextScheduledRun(hours, utc(2026, 6, 1, 19, 30), zone: zone),
        utc(2026, 6, 1, 23, 30),
      );
      expect(
        latestScheduledRun(hours, utc(2026, 6, 1, 7, 29), zone: zone),
        utc(2026, 6, 1, 3, 30),
      );
      expect(scheduleCalendar(hours), ['*-*-* 01/4:30:00']);
    });

    test('weekdays and one day a week', () {
      final weekdays = schedule({
        'repeat': 'weekdays',
        'time': '17:00',
        'days': [1, 3, 5],
      });
      // Monday 23 November 2026, after five: Wednesday.
      expect(
        nextScheduledRun(weekdays, utc(2026, 11, 23, 17), zone: zone),
        utc(2026, 11, 25, 16),
      );
      expect(scheduleCalendar(weekdays), ['Mon,Wed,Fri *-*-* 17:00:00']);
      final weekly = schedule({
        'repeat': 'weekly',
        'time': '09:00',
        'days': [7],
      });
      expect(
        nextScheduledRun(weekly, utc(2026, 11, 23), zone: zone),
        utc(2026, 11, 29, 8),
      );
      expect(scheduleCalendar(weekly), ['Sun *-*-* 09:00:00']);
    });

    test('a month without the day runs on its last day', () {
      final last = schedule({'repeat': 'monthly', 'time': '05:00', 'day': 31});
      expect(
        nextScheduledRun(last, utc(2026, 4, 1), zone: zone),
        utc(2026, 4, 30, 3),
      );
      expect(
        nextScheduledRun(last, utc(2027, 2, 1), zone: zone),
        utc(2027, 2, 28, 4),
      );
      expect(
        nextScheduledRun(last, utc(2028, 2, 1), zone: zone),
        utc(2028, 2, 29, 4),
      );
      expect(
        nextScheduledRun(last, utc(2026, 5, 1), zone: zone),
        utc(2026, 5, 31, 3),
      );
      expect(scheduleCalendar(last), [
        '*-01,03,05,07,08,10,12-31 05:00:00',
        '*-02,04,06,09,11~01 05:00:00',
      ]);
      final thirty = schedule({
        'repeat': 'monthly',
        'time': '05:00',
        'day': 30,
      });
      expect(
        nextScheduledRun(thirty, utc(2026, 2, 1), zone: zone),
        utc(2026, 2, 28, 4),
      );
      expect(scheduleCalendar(thirty), [
        '*-01,03,04,05,06,07,08,09,10,11,12-30 05:00:00',
        '*-02~01 05:00:00',
      ]);
      final fifteen = schedule({
        'repeat': 'monthly',
        'time': '23:59',
        'day': 15,
      });
      expect(scheduleCalendar(fifteen), ['*-*-15 23:59:00']);
    });

    test('until is the last day with a run', () {
      final ending = schedule({
        'repeat': 'daily',
        'time': '05:00',
        'until': '2026-11-24',
      });
      expect(
        nextScheduledRun(ending, utc(2026, 11, 23, 12), zone: zone),
        utc(2026, 11, 24, 4),
      );
      expect(
        nextScheduledRun(ending, utc(2026, 11, 24, 5), zone: zone),
        isNull,
      );
      expect(
        scheduleEndedAt(ending, utc(2026, 11, 24, 4), zone: zone),
        isFalse,
      );
      expect(scheduleEndedAt(ending, utc(2026, 11, 25, 4), zone: zone), isTrue);
      expect(describeSchedule(ending), 'every day at 05:00 until 2026-11-24');
    });

    test('the process zone gives a real instant', () {
      final daily = schedule({'repeat': 'daily', 'time': '05:00'});
      final now = DateTime.now().toUtc();
      final next = nextScheduledRun(daily, now)!;
      expect(next.isAfter(now), isTrue);
      expect(next.difference(now).inHours, lessThanOrEqualTo(25));
      expect(next.toLocal().hour, 5);
      expect(next.toLocal().minute, 0);
    });
  });

  group('systemd user timers (task 101)', () {
    late Directory temporary;
    late String units;
    late List<List<String>> calls;
    late bool systemctlFails;
    late Set<String> failing; // verbs whose systemctl call fails
    late List<String> command;
    late SystemdUserScheduler scheduler;
    const id = '0123456789abcdef0123456789abcdef';
    const store = '00112233aabbccdd';

    setUp(() {
      temporary = Directory.current.createTempSync('.schedule-units-test-');
      units = p.join(temporary.path, 'systemd', 'user');
      calls = [];
      systemctlFails = false;
      failing = {};
      command = ['/opt/maprisma/features/ai-project-center/plugin'];
      scheduler = SystemdUserScheduler(
        unitDir: units,
        store: store,
        environment: {
          'PATH': '/usr/bin:relative/bin:/home/u/.local/bin',
          'XDG_DATA_HOME': '/home/u/data "100%" \$HOME',
          'HOME': '/home/u',
        },
        command: () => command,
        systemctl: (args) async {
          calls.add(args);
          if (systemctlFails) return (false, 'failed');
          if (failing.contains(args.first)) {
            return (false, 'Failed to ${args.first} unit: Access denied');
          }
          // systemd's enable: the wants link.
          if (args.first == 'enable') {
            final wants = Directory(p.join(units, 'timers.target.wants'))
              ..createSync(recursive: true);
            final link = Link(p.join(wants.path, args[1]));
            if (!link.existsSync()) link.createSync(p.join(units, args[1]));
          }
          return (true, '');
        },
        notifier: (_, _) => true,
        posix: TestPosix(),
      );
    });

    tearDown(() => temporary.deleteSync(recursive: true));

    test('unit text quotes every word; no title or newline reaches it', () {
      final service = scheduleServiceText(
        id,
        [r'/opt/my "app" 100% $HOME\x', 'arg;rm -rf ~'],
        {'PATH': '/usr/bin', 'XDG_DATA_HOME': '/data/"q" 5%'},
        store: store,
      );
      expect(service, startsWith(scheduleMarker));
      expect(
        service,
        contains(
          r'ExecStart="/opt/my \"app\" 100%% $$HOME\\x" "arg;rm -rf ~" "schedule-run" "'
          '$id"',
        ),
      );
      expect(service, contains(r'Environment="XDG_DATA_HOME=/data/\"q\" 5%%"'));
      expect(
        service,
        contains('Environment="MAPRISMA_FEATURE_PROCESS=ai-project-center"'),
      );
      // A value with a newline is left out, a command word refused.
      expect(
        scheduleServiceText(
          id,
          ['/opt/app'],
          {'PATH': '/usr/bin\nExecStart=/x'},
          store: store,
        ),
        isNot(contains('ExecStart=/x')),
      );
      expect(
        () => scheduleServiceText(
          id,
          ['/opt/app\nExecStartPre=/bin/x'],
          {},
          store: store,
        ),
        throwsA(errorCode('project_schedule_unavailable')),
      );
      expect(
        () => scheduleServiceText('../../x', ['/opt/app'], {}, store: store),
        throwsA(errorCode('project_schedule_unavailable')),
      );
      expect(
        () => scheduleServiceText(id, ['relative/app'], {}, store: store),
        throwsA(errorCode('project_schedule_unavailable')),
      );
      expect(
        () => scheduleTimerText(id, [
          '*-*-* 05:00:00\nExecStart=/bin/sh',
        ], store: store),
        throwsA(errorCode('project_schedule_unavailable')),
      );
      final timer = scheduleTimerText(id, [
        '*-*-* 05:00:00',
        '*-02~01 05:00:00',
      ], store: store);
      // A store tag that is no tag is refused too.
      expect(
        () => scheduleTimerText(id, ['*-*-* 05:00:00'], store: '\n[Service]'),
        throwsA(errorCode('project_schedule_unavailable')),
      );
      expect(timer, startsWith(scheduleMarker));
      expect(
        timer,
        allOf(
          contains('OnCalendar=*-*-* 05:00:00\nOnCalendar=*-02~01 05:00:00\n'),
          contains('Persistent=true'),
          contains('Unit=maprisma-project-$id.service'),
          contains('WantedBy=timers.target'),
        ),
      );
    });

    test(
      'install writes, enables and starts; unchanged installs nothing',
      () async {
        await scheduler.install(id, ['*-*-* 05:00:00']);
        final timer = File(p.join(units, 'maprisma-project-$id.timer'));
        final service = File(p.join(units, 'maprisma-project-$id.service'));
        expect(timer.readAsStringSync(), contains('OnCalendar=*-*-* 05:00:00'));
        final text = service.readAsStringSync();
        expect(
          text,
          contains(
            'ExecStart="/opt/maprisma/features/ai-project-center/plugin" "schedule-run" "$id"',
          ),
        );
        // Relative PATH entries are dropped; quotes and % are escaped.
        expect(
          text,
          contains('Environment="PATH=/usr/bin:/home/u/.local/bin"'),
        );
        expect(
          text,
          contains(r'Environment="XDG_DATA_HOME=/home/u/data \"100%%\" $HOME"'),
        );
        expect(calls, [
          ['daemon-reload'],
          ['enable', 'maprisma-project-$id.timer'],
          ['restart', 'maprisma-project-$id.timer'],
        ]);
        expect(await scheduler.installed(), {id});
        calls.clear();
        await scheduler.install(id, ['*-*-* 05:00:00']);
        expect(calls, isEmpty);
        await scheduler.install(id, ['*-*-* 06:00:00']);
        expect(calls, hasLength(3));
        expect(timer.readAsStringSync(), contains('OnCalendar=*-*-* 06:00:00'));
        calls.clear();
        await scheduler.remove(id);
        expect(calls, [
          ['disable', '--now', 'maprisma-project-$id.timer'],
          ['daemon-reload'],
        ]);
        expect(timer.existsSync() || service.existsSync(), isFalse);
        expect(await scheduler.installed(), isEmpty);
      },
    );

    test(
      'a unit Maprisma did not write is never overwritten or removed',
      () async {
        Directory(units).createSync(recursive: true);
        final foreign = File(p.join(units, 'maprisma-project-$id.service'))
          ..writeAsStringSync('[Service]\nExecStart=/usr/bin/true\n');
        await expectLater(
          scheduler.install(id, ['*-*-* 05:00:00']),
          throwsA(errorCode('project_schedule_unavailable')),
        );
        expect(
          foreign.readAsStringSync(),
          '[Service]\nExecStart=/usr/bin/true\n',
        );
        expect(
          File(p.join(units, 'maprisma-project-$id.timer')).existsSync(),
          isFalse,
        );
        expect(calls, isEmpty);
        await scheduler.remove(id);
        expect(foreign.existsSync(), isTrue);
        expect(await scheduler.installed(), isEmpty);
        // A link (even to a managed text) is not followed.
        foreign.deleteSync();
        final target = File(p.join(temporary.path, 'elsewhere'))
          ..writeAsStringSync('$scheduleMarker\n$scheduleStoreLine$store\n');
        Link(
          p.join(units, 'maprisma-project-$id.service'),
        ).createSync(target.path);
        await expectLater(
          scheduler.install(id, ['*-*-* 05:00:00']),
          throwsA(errorCode('project_schedule_unavailable')),
        );
        expect(
          target.readAsStringSync(),
          '$scheduleMarker\n$scheduleStoreLine$store\n',
        );
        // Another store's timer (another data folder, a test's) is not ours:
        // not listed, not removed, not overwritten.
        Link(p.join(units, 'maprisma-project-$id.service')).deleteSync();
        final other = '1' * 32;
        final theirs = File(p.join(units, 'maprisma-project-$other.timer'))
          ..writeAsStringSync(
            '$scheduleMarker\n${scheduleStoreLine}ffffffffffffffff\n',
          );
        expect(await scheduler.installed(), isEmpty);
        await scheduler.remove(other);
        expect(theirs.existsSync(), isTrue);
        await expectLater(
          scheduler.install(other, ['*-*-* 05:00:00']),
          throwsA(errorCode('project_schedule_unavailable')),
        );
        expect(calls, isEmpty);
      },
    );

    test(
      'a failed first install leaves nothing; no program is refused',
      () async {
        systemctlFails = true;
        await expectLater(
          scheduler.install(id, ['*-*-* 05:00:00']),
          throwsA(errorCode('project_schedule_unavailable')),
        );
        expect(Directory(units).listSync().whereType<File>(), isEmpty);
        systemctlFails = false;
        final none = SystemdUserScheduler(
          unitDir: units,
          store: store,
          environment: const {},
          command: () => null,
          systemctl: (args) async => (true, ''),
          posix: TestPosix(),
        );
        await expectLater(
          none.install(id, ['*-*-* 05:00:00']),
          throwsA(errorCode('project_schedule_unavailable')),
        );
      },
    );
    // Task 103: what AI Agents Map 2.1.1-2.1.4 fixed in its systemd timers.
    test(
      'a timer whose disable --now fails keeps its files and is reported',
      () async {
        await scheduler.install(id, ['*-*-* 05:00:00']);
        final timer = File(p.join(units, 'maprisma-project-$id.timer'));
        final service = File(p.join(units, 'maprisma-project-$id.service'));
        calls.clear();
        failing = {'disable'};
        await expectLater(
          scheduler.remove(id),
          throwsA(
            isA<ServiceError>()
                .having((e) => e.code, 'code', 'project_schedule_unavailable')
                .having((e) => e.reason, 'reason', contains('Access denied')),
          ),
        );
        // Still running for systemd, so still Maprisma's: the next removal
        // tries again.
        expect(timer.existsSync() && service.existsSync(), isTrue);
        expect(await scheduler.installed(), {id});
        expect(calls, [
          ['disable', '--now', 'maprisma-project-$id.timer'],
        ]);
        failing = {'daemon-reload'};
        await expectLater(
          scheduler.remove(id),
          throwsA(errorCode('project_schedule_unavailable')),
        );
        failing = {};
        expect(await scheduler.installed(), isEmpty);
      },
    );

    test('a rewrite systemd refuses puts the previous timer back', () async {
      await scheduler.install(id, ['*-*-* 05:00:00']);
      final timer = File(p.join(units, 'maprisma-project-$id.timer'));
      failing = {'restart'};
      await expectLater(
        scheduler.install(id, ['*-*-* 06:00:00']),
        throwsA(errorCode('project_schedule_unavailable')),
      );
      // The store keeps the old schedule; so do the files systemd reads.
      expect(timer.readAsStringSync(), contains('OnCalendar=*-*-* 05:00:00'));
      expect(timer.readAsStringSync(), isNot(contains('06:00:00')));
    });

    test(
      'an unreadable unit folder is an error, not "no timers"; a large one is read whole',
      () async {
        await scheduler.install(id, ['*-*-* 05:00:00']);
        for (var i = 0; i < 2000; i++) {
          File(p.join(units, 'other-$i.service')).writeAsStringSync('');
        }
        expect(await scheduler.installed(), {id});
        Process.runSync('chmod', ['000', units]);
        addTearDown(() => Process.runSync('chmod', ['700', units]));
        await expectLater(
          scheduler.installed(),
          throwsA(errorCode('project_schedule_unavailable')),
        );
        Process.runSync('chmod', ['700', units]);
        Directory(units).deleteSync(recursive: true);
        expect(await scheduler.installed(), isEmpty);
      },
    );

    test(
      'agy 103 r1 #2: an unreadable unit folder is no "nothing to remove"',
      () async {
        await scheduler.install(id, ['*-*-* 05:00:00']);
        calls.clear();
        Process.runSync('chmod', ['000', units]);
        addTearDown(() => Process.runSync('chmod', ['700', units]));
        // Dart's typeSync says "not found" here; the timer still runs.
        await expectLater(
          scheduler.remove(id),
          throwsA(errorCode('project_schedule_unavailable')),
        );
        await expectLater(
          scheduler.install(id, ['*-*-* 06:00:00']),
          throwsA(errorCode('project_schedule_unavailable')),
        );
        expect(calls, isEmpty);
        Process.runSync('chmod', ['700', units]);
        await scheduler.remove(id);
        expect(await scheduler.installed(), isEmpty);
        // A folder that is not there: nothing to remove.
        Directory(units).deleteSync(recursive: true);
        await scheduler.remove(id);
      },
      skip: Platform.environment['USER'] == 'root' ? 'root reads it' : false,
    );

    test(
      'agy 103 r2 #2: a unit file not removed because its folder closed meanwhile is said',
      () async {
        await scheduler.install(id, ['*-*-* 05:00:00']);
        final closing = SystemdUserScheduler(
          unitDir: units,
          store: store,
          environment: const {},
          command: () => command,
          systemctl: (args) async {
            // The folder loses its search right while systemd stops the timer.
            if (args.first == 'disable')
              Process.runSync('chmod', ['000', units]);
            return (true, '');
          },
          posix: TestPosix(),
        );
        addTearDown(() => Process.runSync('chmod', ['700', units]));
        await expectLater(
          closing.remove(id),
          throwsA(errorCode('project_schedule_unavailable')),
        );
        Process.runSync('chmod', ['700', units]);
        expect(await scheduler.installed(), {id});
      },
      skip: Platform.environment['USER'] == 'root' ? 'root reads it' : false,
    );

    test(
      'agy 103 r1 #3: a timer started next to a left-over service is stopped before its file goes',
      () async {
        await scheduler.install(id, ['*-*-* 05:00:00']);
        // A removal that went half way: the service stays, the timer is gone.
        File(p.join(units, 'maprisma-project-$id.timer')).deleteSync();
        calls.clear();
        failing = {'restart'};
        await expectLater(
          scheduler.install(id, ['*-*-* 06:00:00']),
          throwsA(errorCode('project_schedule_unavailable')),
        );
        final timerName = 'maprisma-project-$id.timer';
        // enable went through, so it may run: disable --now comes first,
        // and no file of a timer systemd may run is deleted before it.
        final disable = calls.indexWhere(
          (c) => c.first == 'disable' && c.contains(timerName),
        );
        expect(disable, isNonNegative, reason: '$calls');
        expect(calls.indexWhere((c) => c.first == 'enable'), lessThan(disable));
        expect(
          calls.skip(disable + 1).where((c) => c.first == 'restart'),
          isEmpty,
        );
        expect(await scheduler.installed(), isEmpty);
      },
    );
  });

  group('scheduled runs of a project (task 101)', () {
    late Directory temporary;
    late String workspace;
    late List<Map<String, dynamic>> profiles;
    late List<FakeProjectProcess> processes;
    late List<List<String>> commands;
    late FakeScheduler scheduler;
    late DateTime now;
    late AiProjectCenterPlugin plugin;
    String? refuseAgent;

    AiProjectCenterPlugin open({ProjectScheduler? use, Duration? poll}) =>
        AiProjectCenterPlugin(
          temporary.path,
          agentProfiles: () => profiles,
          filesystem: TestPosix(),
          requestPoll: poll,
          scheduler: use ?? scheduler,
          zone: zone,
          clock: () => now,
          authorize: (agent) {
            if (agent == refuseAgent) throw RuleRefused('Never start $agent.');
          },
          runner: (argv, cwd, environment, input, _, _) async {
            commands.add(argv);
            final process = FakeProjectProcess();
            processes.add(process);
            return process;
          },
        );

    setUp(() {
      temporary = Directory.current.createTempSync('.schedule-run-test-');
      workspace = (Directory('${temporary.path}/workspace')..createSync()).path;
      profiles = [
        {
          'id': 'fixture',
          'name': 'Fixture agent',
          'installed': true,
          'plan_argv': ['/fixture/agent', 'read-only', '{prompt}'],
          'run_argv': ['/fixture/agent', 'workspace-write', '{prompt}'],
        },
      ];
      processes = [];
      commands = [];
      scheduler = FakeScheduler();
      refuseAgent = null;
      // Monday 23 November 2026, 10:00 local (UTC+1).
      now = utc(2026, 11, 23, 9);
      plugin = open();
    });

    tearDown(() async {
      await plugin.shutdown();
      temporary.deleteSync(recursive: true);
    });

    Future<Map<String, dynamic>> saved({
      String title = 'Check my e-mails',
    }) async =>
        (await plugin.call('save', {
              'title': title,
              'brief': 'Read the new e-mails and summarise them.',
              'path': workspace,
              'team': [
                {'agent': 'fixture', 'role': 'lead'},
              ],
              'plan': '1. Read.\n2. Summarise.',
            }))['project']
            as Map<String, dynamic>;

    Future<Map<String, dynamic>> approved() async {
      final item = await saved();
      return (await plugin.call('review', {
            'id': item['id'],
            'revision': item['revision'],
            'approved': true,
          }))['project']
          as Map<String, dynamic>;
    }

    Future<Map<String, dynamic>> get(String id) async =>
        (await plugin.call('get', {'id': id}))['project']
            as Map<String, dynamic>;

    const daily = {'repeat': 'daily', 'time': '05:00'};

    Future<Map<String, dynamic>> scheduled(
      Map<String, dynamic> item, [
      Map<String, dynamic> value = daily,
    ]) async =>
        (await plugin.call('set_schedule', {
              'id': item['id'],
              'schedule': value,
            }))['project']
            as Map<String, dynamic>;

    List<String> events(Map<String, dynamic> item) => [
      for (final e in item['events'] as List) '${e['type']}',
    ];

    test(
      'set_schedule is a setting: timer, next run, no new revision',
      () async {
        final item = await approved();
        final set = await scheduled(item);
        expect(set['revision'], item['revision']);
        expect(set['updated_at'], item['updated_at']);
        expect(set['events'], item['events']);
        expect(set['approval_valid'], isTrue);
        expect(set['schedule'], daily);
        // Tomorrow 05:00 local, 04:00 UTC.
        expect(set['next_run'], utc(2026, 11, 24, 4).toIso8601String());
        expect(scheduler.installs[item['id']], ['*-*-* 05:00:00']);
        final card =
            ((await plugin.call('list', {}))['projects'] as List).single;
        expect(card['schedule'], daily);
        expect(card['next_run'], set['next_run']);
        // Kept across a reopen.
        await plugin.shutdown();
        plugin = open();
        expect((await get(item['id'] as String))['schedule'], daily);
        // Off: the timer goes.
        final off =
            (await plugin.call('set_schedule', {
                  'id': item['id'],
                  'schedule': null,
                }))['project']
                as Map<String, dynamic>;
        expect(off['schedule'], isNull);
        expect(off['next_run'], isNull);
        expect(scheduler.removed, [item['id']]);
      },
    );

    test('set_schedule refusals change nothing', () async {
      final item = await approved();
      for (final bad in <Map<String, dynamic>>[
        {'id': item['id']},
        {'id': item['id'], 'schedule': daily, 'revision': 1},
        {
          'id': item['id'],
          'schedule': {
            'repeat': 'daily',
            'time': '05:00',
            'until': '2026-11-22',
          },
        },
        {
          'id': item['id'],
          'schedule': {'repeat': 'daily', 'time': '5 o\'clock'},
        },
      ]) {
        await expectLater(
          plugin.call('set_schedule', bad),
          throwsA(errorCode('project_schedule_invalid')),
        );
      }
      await expectLater(
        plugin.call('set_schedule', {'id': '0' * 32, 'schedule': daily}),
        throwsA(errorCode('project_unknown')),
      );
      scheduler.failInstall = ServiceError('project_schedule_unavailable');
      await expectLater(
        scheduled(item),
        throwsA(errorCode('project_schedule_unavailable')),
      );
      expect((await get(item['id'] as String))['schedule'], isNull);
      await plugin.shutdown();
      // Without a desktop scheduler there is no schedule.
      plugin = AiProjectCenterPlugin(
        temporary.path,
        agentProfiles: () => profiles,
        filesystem: TestPosix(),
      );
      await expectLater(
        scheduled(item),
        throwsA(errorCode('project_schedule_unavailable')),
      );
    });

    test('deleting a project removes its timer', () async {
      final item = await scheduled(await approved());
      await plugin.call('delete', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => scheduler.removed.contains(item['id']));
    });

    test('a timer runs the approved plan, again after completion', () async {
      final item = await scheduled(await approved());
      final id = item['id'] as String;
      // Tuesday 05:00:00.3 local.
      now = utc(2026, 11, 24, 4, 0).add(const Duration(milliseconds: 300));
      expect(await plugin.scheduledRun(id, now), 'started');
      expect(commands.single[1], 'workspace-write');
      var running = await get(id);
      expect(running['status'], 'running');
      expect(events(running), contains('schedule_started'));
      expect(
        running['schedule_last_slot'],
        utc(2026, 11, 24, 4).toIso8601String(),
      );
      // A second trigger for the same planned run (overlapping triggers).
      expect(await plugin.scheduledRun(id, now), 'duplicate');
      await processes.single.finish('Two new e-mails.');
      await waitUntil(() => plugin.idle);
      expect((await get(id))['status'], 'completed');
      // The next day: the completed project runs again with its approval.
      now = utc(2026, 11, 25, 4, 0);
      expect(await plugin.scheduledRun(id, now), 'started');
      expect(commands, hasLength(2));
      await processes.last.finish('Nothing new.');
      await waitUntil(() => plugin.idle);
      expect(scheduler.notes, isEmpty);
    });

    test('a run still working is skipped and recorded, not notified', () async {
      final item = await scheduled(await approved());
      final id = item['id'] as String;
      await plugin.call('run', {'id': id, 'revision': item['revision']});
      now = utc(2026, 11, 24, 4);
      expect(await plugin.scheduledRun(id, now), 'running');
      final skipped = await get(id);
      expect(events(skipped).last, 'schedule_skipped');
      expect(
        (skipped['events'] as List).last['text'],
        contains('still running'),
      );
      expect(commands, hasLength(1));
      expect(scheduler.notes, isEmpty);
      await processes.single.finish('done');
      await waitUntil(() => plugin.idle);
    });

    test(
      'without a valid approval it does not run and tells the user',
      () async {
        // Awaiting review: never approved.
        final draft = await scheduled(
          await saved(title: 'Not approved "x"; y'),
        );
        now = utc(2026, 11, 24, 4);
        expect(
          await plugin.scheduledRun(draft['id'] as String, now),
          'project_plan_not_approved',
        );
        expect(commands, isEmpty);
        expect(
          events(await get(draft['id'] as String)).last,
          'schedule_skipped',
        );
        expect(scheduler.notes.single.$1, contains('did not run'));
        expect(scheduler.notes.single.$2, startsWith('Not approved "x"; y: '));
        // Approved, then the plan changed: the approval no longer fits.
        var item = await approved();
        item = await scheduled(item);
        item =
            (await plugin.call('save', {
                  'id': item['id'],
                  'revision': item['revision'],
                  'plan': 'A different plan.',
                }))['project']
                as Map<String, dynamic>;
        now = utc(2026, 11, 25, 4);
        expect(
          await plugin.scheduledRun(item['id'] as String, now),
          'project_plan_not_approved',
        );
        expect(commands, isEmpty);
        expect(scheduler.notes, hasLength(2));
      },
    );

    test('an agent that is gone skips the run with a reason', () async {
      final item = await scheduled(await approved());
      profiles.clear();
      now = utc(2026, 11, 24, 4);
      final code = await plugin.scheduledRun(item['id'] as String, now);
      expect(code, isNot('started'));
      expect(commands, isEmpty);
      final after = await get(item['id'] as String);
      expect(after['status'], 'ready');
      expect(events(after).last, 'schedule_skipped');
      expect(scheduler.notes, hasLength(1));
    });

    test('a refused rule skips the run without failing the project', () async {
      final item = await scheduled(await approved());
      refuseAgent = 'fixture';
      now = utc(2026, 11, 24, 4);
      expect(
        await plugin.scheduledRun(item['id'] as String, now),
        'action_refused',
      );
      final after = await get(item['id'] as String);
      expect(after['status'], 'ready');
      expect(commands, isEmpty);
      expect(scheduler.notes.single.$2, contains('Never start fixture.'));
    });

    test(
      'a paused run waits for the user; the end removes the timer',
      () async {
        var item = await approved();
        item = await scheduled(item, {
          'repeat': 'daily',
          'time': '05:00',
          'until': '2026-11-24',
        });
        final id = item['id'] as String;
        await plugin.call('run', {'id': id, 'revision': item['revision']});
        await waitUntil(() => processes.isNotEmpty);
        await plugin.call('pause', {'id': id});
        await waitUntil(() => plugin.idle);
        now = utc(2026, 11, 24, 4);
        expect(
          await plugin.scheduledRun(id, now),
          'project_review_changes_first',
        );
        expect(commands, hasLength(1));
        expect(scheduler.notes, hasLength(1));
        // After its last day.
        now = utc(2026, 11, 25, 4);
        expect(await plugin.scheduledRun(id, now), 'ended');
        expect(events(await get(id)).last, 'schedule_ended');
        expect((await get(id))['next_run'], isNull);
        await waitUntil(() => scheduler.removed.contains(id));
      },
    );

    test('a trigger from before the schedule was set does not run', () async {
      final item = await scheduled(await approved());
      // A Persistent catch-up for 05:00 today (set at 10:00).
      expect(
        await plugin.scheduledRun(
          item['id'] as String,
          utc(2026, 11, 23, 9, 30),
        ),
        'duplicate',
      );
      expect(commands, isEmpty);
    });

    test(
      'reconciliation writes missing timers and removes stale ones',
      () async {
        final item = await scheduled(await approved());
        await plugin.shutdown();
        scheduler.installs.clear();
        scheduler.installs['f' * 32] = ['*-*-* 01:00:00'];
        plugin = open();
        await waitUntil(() => scheduler.installs.containsKey(item['id']));
        expect(scheduler.installs.containsKey('f' * 32), isFalse);
        expect(scheduler.removed, contains('f' * 32));
      },
    );

    test(
      'the spool: a request is claimed once; hostile files are dropped',
      () async {
        final item = await scheduled(await approved());
        final id = item['id'] as String;
        final spool = p.join(plugin.directory, 'schedule');
        now = utc(2026, 11, 24, 4).add(const Duration(seconds: 1));
        final request = writeScheduleRequest(
          temporary.path,
          id,
          now,
          posix: TestPosix(),
        );
        expect(File(request).statSync().mode & 0x1ff, 0x180);
        expect(Directory(spool).statSync().mode & 0x1ff, 0x1c0);
        // Hostile neighbours: a link, another id inside, a future time, a
        // large file, a name that is no request.
        final target = File(p.join(temporary.path, 'target'))
          ..writeAsStringSync(
            jsonEncode({'id': id, 'at': now.toIso8601String()}),
          );
        Link(
          p.join(spool, '$id.0000000000000001.request'),
        ).createSync(target.path);
        File(p.join(spool, '$id.0000000000000002.request')).writeAsStringSync(
          jsonEncode({'id': 'a' * 32, 'at': now.toIso8601String()}),
        );
        File(p.join(spool, '$id.0000000000000003.request')).writeAsStringSync(
          jsonEncode({'id': id, 'at': '2027-01-01T00:00:00Z'}),
        );
        File(p.join(spool, '$id.0000000000000004.request')).writeAsStringSync(
          '{"id":"$id","at":"${now.toIso8601String()}","x":"${'y' * 2000}"}',
        );
        File(p.join(spool, 'other')).writeAsStringSync('ignored');
        // The request and the four dropped ones: all work done (task 103).
        expect(await plugin.takeScheduleRequests(), 5);
        expect(commands, hasLength(1));
        expect(target.existsSync(), isTrue);
        expect(Directory(spool).listSync().map((e) => p.basename(e.path)), [
          'other',
        ]);
        // A claimed request left by an owner that died is handled again, the
        // planned run is not repeated.
        File(p.join(spool, '$id.0000000000000005.taken')).writeAsStringSync(
          jsonEncode({'id': id, 'at': now.toIso8601String()}),
        );
        expect(await plugin.takeScheduleRequests(), 1);
        expect(commands, hasLength(1));
        await processes.single.finish('done');
        await waitUntil(() => plugin.idle);
      },
    );

    test('a trigger hands over to the running owner', () async {
      final item = await scheduled(await approved());
      final id = item['id'] as String;
      now = utc(2026, 11, 24, 4);
      // The owner polls its spool like the app's backend does.
      final poll = Timer.periodic(
        const Duration(milliseconds: 20),
        (_) => unawaited(plugin.takeScheduleRequests()),
      );
      addTearDown(poll.cancel);
      var opened = 0;
      final result = await scheduleTrigger(
        id: id,
        dataDirectory: temporary.path,
        open: () {
          opened++;
          return open(); // busy: the plugin above owns the store
        },
        serve: (_) async => fail('not the owner'),
        clock: () => now,
        step: const Duration(milliseconds: 10),
        posix: TestPosix(),
      );
      expect(result, 'handed_over');
      expect(opened, greaterThan(0));
      await waitUntil(() => commands.length == 1);
      expect(events(await get(id)), contains('schedule_started'));
      await processes.single.finish('done');
      await waitUntil(() => plugin.idle);
    });

    test('a trigger with no owner answering withdraws its request', () async {
      final item = await scheduled(await approved());
      final notes = <String>[];
      final result = await scheduleTrigger(
        id: item['id'] as String,
        dataDirectory: temporary.path,
        open: () => open(),
        serve: (_) async => fail('not the owner'),
        wait: const Duration(milliseconds: 100),
        step: const Duration(milliseconds: 10),
        notify: (title, body) => notes.add(title),
        posix: TestPosix(),
      );
      expect(result, 'timeout');
      expect(notes, hasLength(1));
      expect(
        Directory(p.join(plugin.directory, 'schedule')).listSync(),
        isEmpty,
      );
      expect(commands, isEmpty);
    });

    test('with Maprisma closed the trigger owns the store and runs', () async {
      final item = await scheduled(await approved());
      final id = item['id'] as String;
      await plugin.shutdown();
      now = utc(2026, 11, 24, 4);
      // A slow timer check at the owner's start delays the request: the
      // owner waits for it instead of ending first.
      scheduler.installDelay = const Duration(milliseconds: 300);
      AiProjectCenterPlugin? owner;
      final trigger = scheduleTrigger(
        id: id,
        dataDirectory: temporary.path,
        // Polling its spool as CoreService's owner does.
        open: () => owner = open(poll: const Duration(milliseconds: 5)),
        serve: (center) =>
            serveScheduledRuns(center, poll: const Duration(milliseconds: 10)),
        clock: () => now,
        posix: TestPosix(),
      );
      await waitUntil(() => processes.isNotEmpty);
      // While it owns the store nobody else can.
      expect(open, throwsA(errorCode('project_center_busy')));
      await processes.single.finish('Two new e-mails.');
      expect(await trigger, 'owner');
      expect(owner!.idle, isTrue);
      plugin = open();
      final after = await get(id);
      expect(after['status'], 'completed');
      expect(events(after), contains('schedule_started'));
      expect(
        Directory(p.join(plugin.directory, 'schedule')).listSync(),
        isEmpty,
      );
    });

    // Task 103: the bookkeeping AI Agents Map 2.1.1-2.1.4 fixed.
    test('a timer that cannot be removed is recorded and told, not hidden', () async {
      final item = await scheduled(await approved());
      final id = item['id'] as String;
      scheduler.failRemove = ServiceError(
        'project_schedule_unavailable',
        'systemctl disable --now failed: Access denied',
      );
      final off =
          (await plugin.call('set_schedule', {
                'id': id,
                'schedule': null,
              }))['project']
              as Map<String, dynamic>;
      expect(off['schedule'], isNull);
      expect(events(off).last, 'schedule_timer_failed');
      expect(
        (off['events'] as List).last['text'],
        'The timer of its schedule could not be removed (systemctl disable --now failed: Access denied). Maprisma tries again at its next start.',
      );
      expect(off['revision'], item['revision']);
      expect(scheduler.notes, [
        (
          'Maprisma: a project schedule needs attention',
          'Check my e-mails: The timer of its schedule could not be removed. Maprisma tries again at its next start.',
        ),
      ]);
      // The timer is still there: its next trigger tries again; the same
      // reason is neither recorded nor told twice.
      expect(scheduler.installs.containsKey(id), isTrue);
      expect(await plugin.scheduledRun(id, now), 'no_schedule');
      await waitUntil(() => scheduler.removed.length == 2);
      expect(
        events(await get(id)).where((e) => e == 'schedule_timer_failed'),
        hasLength(1),
      );
      expect(scheduler.notes, hasLength(1));
      // Deleted while its timer cannot go: told, too.
      final other = await saved(title: 'Other');
      await scheduled(other);
      await plugin.call('delete', {
        'id': other['id'],
        'revision': other['revision'],
      });
      await waitUntil(() => scheduler.notes.length == 2);
      expect(
        scheduler.notes.last.$2,
        'The timer of its schedule could not be removed. Maprisma tries again at its next start.',
      );
      // Once it can, it goes.
      scheduler.failRemove = null;
      expect(await plugin.scheduledRun(id, now), 'no_schedule');
      await waitUntil(() => !scheduler.installs.containsKey(id));
    });

    test('reconciliation tells what it could not do', () async {
      final item = await scheduled(await approved());
      final id = item['id'] as String;
      await plugin.shutdown();
      scheduler.installs.clear();
      scheduler.failInstall = ServiceError(
        'project_schedule_unavailable',
        'systemctl enable failed',
      );
      plugin = open();
      await waitUntil(() => scheduler.notes.isNotEmpty);
      expect(
        scheduler.notes.single.$1,
        'Maprisma: a project schedule needs attention',
      );
      expect(
        scheduler.notes.single.$2,
        'Check my e-mails: The timer of its schedule could not be set up, so it does not run on time. Maprisma tries again at its next start.',
      );
      await waitUntil(() => plugin.idle);
      final after = await get(id);
      expect(events(after).last, 'schedule_timer_failed');
      expect(
        (after['events'] as List).last['text'],
        contains('could not be set up (systemctl enable failed)'),
      );
      // A unit folder that cannot be read is no "nothing to remove".
      await plugin.shutdown();
      scheduler
        ..failInstall = null
        ..notes.clear()
        ..failInstalled = ServiceError(
          'project_schedule_unavailable',
          'the unit folder cannot be read: Permission denied',
        );
      plugin = open();
      await waitUntil(() => scheduler.notes.isNotEmpty);
      expect(
        scheduler.notes.single.$2,
        'Maprisma cannot read the folder of its timers (~/.config/systemd/user). Timers it no longer needs stay until it can.',
      );
      // The wanted timer is still written.
      await waitUntil(() => scheduler.installs.containsKey(id));
    });

    test(
      'a claimed request an owner could not handle stays for the next one',
      () async {
        final item = await scheduled(await approved());
        final id = item['id'] as String;
        await plugin.shutdown();
        now = utc(2026, 11, 24, 4).add(const Duration(seconds: 1));
        writeScheduleRequest(temporary.path, id, now, posix: TestPosix());
        // The owner's start keeps the schedule chain busy; it closes before
        // the request's turn comes.
        scheduler.installDelay = const Duration(milliseconds: 200);
        plugin = open();
        final taking = plugin.takeScheduleRequests();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await plugin.shutdown();
        expect(await taking, 0);
        final spool = p.join(plugin.directory, 'schedule');
        expect(Directory(spool).listSync().map((e) => p.basename(e.path)), [
          matches(RegExp('^$id\\.[0-9a-f]{16}\\.taken\$')),
        ]);
        expect(commands, isEmpty);
        // The next owner runs it, once.
        scheduler.installDelay = Duration.zero;
        plugin = open();
        expect(await plugin.takeScheduleRequests(), 1);
        expect(commands, hasLength(1));
        expect(Directory(spool).listSync(), isEmpty);
        expect(events(await get(id)), contains('schedule_started'));
        await processes.single.finish('done');
        await waitUntil(() => plugin.idle);
      },
    );

    test(
      'the spool is read whole: other entries hide no request; drafts go',
      () async {
        final item = await scheduled(await approved());
        final id = item['id'] as String;
        final spool = p.join(plugin.directory, 'schedule');
        now = utc(2026, 11, 24, 4).add(const Duration(seconds: 1));
        writeScheduleRequest(temporary.path, id, now, posix: TestPosix());
        for (var i = 0; i < 1500; i++) {
          File(p.join(spool, 'junk-$i')).writeAsStringSync('');
        }
        // Directories named like requests never fill a look.
        for (var i = 0; i < 70; i++) {
          Directory(
            p.join(spool, '$id.${i.toRadixString(16).padLeft(16, '0')}.taken'),
          ).createSync();
        }
        // A draft a dead trigger left an hour ago, and one being written.
        final old = File(p.join(spool, '.$id.00000000000000aa.request.tmp'))
          ..writeAsStringSync('{"id"');
        old.setLastModifiedSync(
          DateTime.now().subtract(const Duration(hours: 1)),
        );
        final fresh = File(p.join(spool, '.$id.00000000000000bb.request.tmp'))
          ..writeAsStringSync('{"id"');
        expect(await plugin.takeScheduleRequests(), 1);
        expect(commands, hasLength(1));
        expect(old.existsSync(), isFalse);
        expect(fresh.existsSync(), isTrue);
        await processes.single.finish('done');
        await waitUntil(() => plugin.idle);
      },
    );

    test(
      'agy 103 r1 #1: a removal is awaited in the chain; set_schedule after it keeps its timer',
      () async {
        final item = await scheduled(await approved());
        final id = item['id'] as String;
        // Off, but the timer stays (systemd refused).
        scheduler.failRemove = ServiceError(
          'project_schedule_unavailable',
          'x',
        );
        await plugin.call('set_schedule', {'id': id, 'schedule': null});
        expect(scheduler.installs.containsKey(id), isTrue);
        scheduler
          ..failRemove = null
          ..removeDelay = const Duration(milliseconds: 150);
        // The timer fires (no schedule: it goes) and the user sets one again.
        final trigger = plugin.scheduledRun(id, now);
        final set = plugin.call('set_schedule', {'id': id, 'schedule': daily});
        expect(await trigger, 'no_schedule');
        await set;
        // Long enough for a removal that ran outside the chain to land.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(scheduler.removed, [id, id]);
        expect(scheduler.installs.containsKey(id), isTrue);
        expect((await get(id))['schedule'], isNotNull);
      },
    );

    test(
      'agy 103 r1 #1: the headless owner is not idle while a timer is removed',
      () async {
        scheduler.removeDelay = const Duration(milliseconds: 200);
        const gone = 'ffffffffffffffffffffffffffffffff';
        final trigger = plugin.scheduledRun(gone, now);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(plugin.idle, isFalse);
        expect(await trigger, 'no_schedule');
        expect(plugin.idle, isTrue);
      },
    );

    test(
      'agy 103 r1 #1: an ended schedule is recorded once while its timer cannot go',
      () async {
        final item = await scheduled(await approved(), {
          ...daily,
          'until': '2026-11-24',
        });
        final id = item['id'] as String;
        scheduler.failRemove = ServiceError(
          'project_schedule_unavailable',
          'x',
        );
        for (final day in [26, 27, 28]) {
          now = utc(2026, 11, day, 4).add(const Duration(seconds: 1));
          expect(await plugin.scheduledRun(id, now), 'ended');
        }
        final kinds = events(await get(id));
        expect(kinds.where((e) => e == 'schedule_ended'), hasLength(1));
        expect(kinds.where((e) => e == 'schedule_timer_failed'), hasLength(1));
        expect(scheduler.removed, hasLength(3));
      },
    );

    test(
      'agy 103 r1 #4: systemd\'s reason is one bounded line in the event',
      () async {
        final item = await scheduled(await approved());
        final id = item['id'] as String;
        scheduler.failRemove = ServiceError(
          'project_schedule_unavailable',
          'Job for maprisma-project-$id.timer failed.\n'
              'See "systemctl --user status" (x).\t\x00\x1b[31m${'y' * 2000}',
        );
        await plugin.call('set_schedule', {'id': id, 'schedule': null});
        final text = ((await get(id))['events'] as List).last['text'] as String;
        expect(text, isNot(matches(RegExp(r'[\x00-\x1f\x7f]'))));
        expect(text.length, lessThan(400));
        expect(
          text,
          startsWith(
            'The timer of its schedule could not be removed (Job for maprisma-project-$id.timer failed. See "systemctl --user status" (x).',
          ),
        );
        expect(text, endsWith('…). Maprisma tries again at its next start.'));
        // The store still opens.
        await plugin.shutdown();
        plugin = open();
        expect(events(await get(id)).last, 'schedule_timer_failed');
      },
    );

    test(
      'agy 103 r1 #5: broken requests count as work; none hides a good one',
      () async {
        final item = await scheduled(await approved());
        final id = item['id'] as String;
        final spool = p.join(plugin.directory, 'schedule');
        Directory(spool).createSync(recursive: true);
        for (var i = 0; i < 70; i++) {
          File(
            p.join(
              spool,
              '$id.${i.toRadixString(16).padLeft(16, '0')}.request',
            ),
          ).writeAsStringSync('not json');
        }
        // A look that only removed broken entries is no quiet one.
        expect(await plugin.takeScheduleRequests(), greaterThan(0));
        for (var i = 0; i < 1000; i++) {
          File(
            p.join(
              spool,
              '$id.${(i + 100).toRadixString(16).padLeft(16, '0')}.request',
            ),
          ).writeAsStringSync('not json');
        }
        now = utc(2026, 11, 24, 4).add(const Duration(seconds: 1));
        writeScheduleRequest(temporary.path, id, now, posix: TestPosix());
        await serveScheduledRuns(
          plugin,
          poll: const Duration(milliseconds: 1),
          stop: Future<void>.delayed(const Duration(seconds: 20)),
        );
        expect(commands, hasLength(1));
        plugin = open();
      },
    );

    test(
      'agy 103 r2 #1: an entry that cannot be removed is no work; the headless owner ends',
      () async {
        final item = await scheduled(await approved());
        final id = item['id'] as String;
        final spool = p.join(plugin.directory, 'schedule');
        Directory(spool).createSync(recursive: true);
        final stuck = File(p.join(spool, '$id.${'0' * 16}.taken'))
          ..writeAsStringSync('not json');
        Process.runSync('chmod', ['500', spool]);
        addTearDown(() => Process.runSync('chmod', ['700', spool]));
        expect(await plugin.takeScheduleRequests(), 0);
        expect(stuck.existsSync(), isTrue);
        await serveScheduledRuns(
          plugin,
          poll: const Duration(milliseconds: 1),
          stop: Future<void>.delayed(const Duration(seconds: 10)),
        ).timeout(const Duration(seconds: 5));
        Process.runSync('chmod', ['700', spool]);
        plugin = open();
      },
      skip: Platform.environment['USER'] == 'root' ? 'root writes it' : false,
    );

    for (final mode in ['000', '500']) {
      test(
        'agy 103 r3 #1: a request left in a $mode spool is not "handed over"',
        () async {
          final item = await scheduled(await approved());
          final spool = p.join(plugin.directory, 'schedule');
          addTearDown(() => Process.runSync('chmod', ['700', spool]));
          final notes = <String>[];
          final result = await scheduleTrigger(
            id: item['id'] as String,
            dataDirectory: temporary.path,
            open: () {
              // The request is written; now the folder closes.
              Process.runSync('chmod', [mode, spool]);
              return open(); // busy: the plugin above owns the store
            },
            serve: (_) async => fail('not the owner'),
            wait: const Duration(milliseconds: 100),
            step: const Duration(milliseconds: 10),
            notify: (title, body) => notes.add(body),
            posix: TestPosix(),
          );
          expect(result, 'timeout');
          expect(notes, [
            'The scheduled run could not be handed over to Maprisma. Its timer starts it again at the next planned time.',
          ]);
        },
        skip: Platform.environment['USER'] == 'root' ? 'root writes it' : false,
      );
    }

    test(
      'agy 103 r3 #2: a spool that cannot be changed stops serving, told once',
      () async {
        final item = await scheduled(await approved());
        final id = item['id'] as String;
        now = utc(2026, 11, 24, 4).add(const Duration(seconds: 1));
        writeScheduleRequest(temporary.path, id, now, posix: TestPosix());
        final spool = p.join(plugin.directory, 'schedule');
        Process.runSync('chmod', ['500', spool]);
        addTearDown(() => Process.runSync('chmod', ['700', spool]));
        scheduler.notes.clear();
        for (var look = 0; look < 3; look++) {
          expect(await plugin.takeScheduleRequests(), 0);
        }
        expect(scheduler.notes.map((n) => n.$2), [
          'Maprisma cannot use the folder of its scheduled runs, so it starts none until it is opened again.',
        ]);
        expect(commands, isEmpty);
        // The next start (permissions back) serves it.
        Process.runSync('chmod', ['700', spool]);
        await plugin.shutdown();
        plugin = open();
        expect(await plugin.takeScheduleRequests(), 1);
        await waitUntil(() => commands.length == 1);
        await processes.single.finish('done');
        await waitUntil(() => plugin.idle);
      },
      skip: Platform.environment['USER'] == 'root' ? 'root writes it' : false,
    );

    test(
      'agy 103 r3 #3: an entry that cannot be claimed stops serving instead of taking places',
      () async {
        final item = await scheduled(await approved());
        final id = item['id'] as String;
        final spool = p.join(plugin.directory, 'schedule');
        Directory(spool).createSync(recursive: true);
        now = utc(2026, 11, 24, 4).add(const Duration(seconds: 1));
        final stuck = '$id.${'0' * 16}';
        File(p.join(spool, '$stuck.request')).writeAsStringSync('{}');
        Directory(p.join(spool, '$stuck.taken')).createSync();
        scheduler.notes.clear();
        expect(await plugin.takeScheduleRequests(), 0);
        expect(await plugin.takeScheduleRequests(), 0);
        expect(scheduler.notes, hasLength(1));
        expect(File(p.join(spool, '$stuck.request')).existsSync(), isTrue);
      },
    );

    test(
      'agy 103 r4 #1: a spool that cannot be opened stops serving, told once; the headless owner shuts down',
      () async {
        final item = await scheduled(await approved());
        final id = item['id'] as String;
        now = utc(2026, 11, 24, 4).add(const Duration(seconds: 1));
        writeScheduleRequest(temporary.path, id, now, posix: TestPosix());
        final spool = p.join(plugin.directory, 'schedule');
        Process.runSync('chmod', ['000', spool]);
        addTearDown(() => Process.runSync('chmod', ['700', spool]));
        scheduler.notes.clear();
        for (var look = 0; look < 3; look++) {
          expect(await plugin.takeScheduleRequests(), 0);
        }
        expect(scheduler.notes.map((n) => n.$2), [
          'Maprisma cannot use the folder of its scheduled runs, so it starts none until it is opened again.',
        ]);
        // The headless owner: no throw, a clean shutdown.
        await plugin.shutdown();
        plugin = open();
        await serveScheduledRuns(
          plugin,
          poll: const Duration(milliseconds: 1),
          stop: Future<void>.delayed(const Duration(seconds: 10)),
        ).timeout(const Duration(seconds: 5));
        expect(commands, isEmpty);
        Process.runSync('chmod', ['700', spool]);
        plugin = open(); // the store was let go: it opens again
      },
      skip: Platform.environment['USER'] == 'root' ? 'root reads it' : false,
    );

    test(
      'agy 103 r1 #6: a timer report never stops running work when the store is full',
      () async {
        final runner = await approved();
        final item = await scheduled(await saved(title: 'Other'));
        final id = item['id'] as String;
        // Off while its timer stays: the timer is still there.
        scheduler.failRemove = ServiceError(
          'project_schedule_unavailable',
          'x',
        );
        await plugin.call('set_schedule', {'id': id, 'schedule': null});
        await plugin.shutdown();
        final path = p.join(plugin.directory, 'projects.json');
        final size = File(path).lengthSync();
        plugin = AiProjectCenterPlugin(
          temporary.path,
          agentProfiles: () => profiles,
          filesystem: TestPosix(),
          scheduler: scheduler,
          zone: zone,
          clock: () => now,
          storeLimit: size + 1200,
          runner: (argv, cwd, environment, input, _, _) async {
            commands.add(argv);
            final process = FakeProjectProcess();
            processes.add(process);
            return process;
          },
        );
        await waitUntil(() => plugin.idle);
        final current = await get(runner['id'] as String);
        await plugin.call('run', {
          'id': runner['id'],
          'revision': current['revision'],
        });
        await waitUntil(() => processes.isNotEmpty);
        // Room for a report or two, not for six (about 300 bytes each, each
        // with another reason, so none is the same as the last).
        expect(size + 1200 - File(path).lengthSync(), greaterThan(150));
        final tries = scheduler.removed.length;
        for (var i = 0; i < 6; i++) {
          scheduler.failRemove = ServiceError(
            'project_schedule_unavailable',
            '$i${'z' * 189}',
          );
          await plugin.scheduledRun(id, now);
          await waitUntil(() => scheduler.removed.length == tries + i + 1);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(processes.single.stopped, isFalse);
        expect((await get(runner['id'] as String))['status'], 'running');
        await processes.single.finish('done');
        await waitUntil(() => plugin.idle);
      },
    );

    test(
      'agy 103 r1 #7: closed while the spool is read, nothing is claimed',
      () async {
        final item = await scheduled(await approved());
        final id = item['id'] as String;
        now = utc(2026, 11, 24, 4).add(const Duration(seconds: 1));
        final request = writeScheduleRequest(
          temporary.path,
          id,
          now,
          posix: TestPosix(),
        );
        final taking = plugin.takeScheduleRequests();
        plugin.detach();
        expect(await taking, 0);
        expect(File(request).existsSync(), isTrue);
        expect(commands, isEmpty);
        plugin = open();
      },
    );

    test(
      'agy 103 r1 #8: a scheduled run dropped for a storage fault is told',
      () async {
        final failing = FailingPosix();
        final item = await scheduled(await approved());
        final id = item['id'] as String;
        await plugin.shutdown();
        plugin = AiProjectCenterPlugin(
          temporary.path,
          agentProfiles: () => profiles,
          filesystem: failing,
          scheduler: scheduler,
          zone: zone,
          clock: () => now,
        );
        await waitUntil(() => plugin.idle);
        failing.fail = true;
        await expectLater(
          plugin.call('set_importance', {'id': id, 'importance': 'high'}),
          throwsA(errorCode('project_store_unavailable')),
        );
        now = utc(2026, 11, 24, 4).add(const Duration(seconds: 1));
        writeScheduleRequest(temporary.path, id, now, posix: TestPosix());
        scheduler.notes.clear();
        expect(await plugin.takeScheduleRequests(), 1);
        expect(scheduler.notes, [
          (
            'Maprisma: a scheduled project did not run',
            'Check my e-mails: Maprisma could not record the scheduled run. Open its Projects page to check the project.',
          ),
        ]);
        failing.fail = false;
      },
    );

    test('a request that cannot be written is told, not lost silently', () async {
      final item = await scheduled(await approved());
      final notes = <(String, String)>[];
      // The store folder is a file: no spool can be made.
      final broken = p.join(temporary.path, 'broken');
      Directory(broken).createSync();
      File(p.join(broken, 'ai-project-center')).writeAsStringSync('');
      final result = await scheduleTrigger(
        id: item['id'] as String,
        dataDirectory: broken,
        open: () => fail('no owner without a request'),
        serve: (_) async => fail('not the owner'),
        notify: (title, body) => notes.add((title, body)),
        posix: TestPosix(),
      );
      expect(result, 'unwritten');
      expect(notes, [
        (
          'Maprisma: a scheduled project did not run',
          'The scheduled run could not be handed over to Maprisma. Its timer starts it again at the next planned time.',
        ),
      ]);
    });
  });
}
