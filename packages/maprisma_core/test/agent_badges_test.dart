import 'dart:io';

import 'package:maprisma_core/src/adapters.dart';
import 'package:maprisma_core/src/agent_badges.dart';
import 'package:maprisma_core/src/agent_details.dart' show usageTime;
import 'package:maprisma_core/src/costs.dart';
import 'package:maprisma_core/src/identity.dart';
import 'package:maprisma_core/src/scan_files.dart';
import 'package:maprisma_core/src/session_readers.dart';
import 'package:maprisma_core/src/usage_readers.dart';
import 'package:test/test.dart';

/// The badge in an agent's map box: limits that are old or that the
/// collector kept past a failed probe do not look current; one paid per
/// token also gets what is left of the day's limit as a battery; sessions
/// whose own store says they cost money count as paid per token.
void main() {
  final now = DateTime.utc(2026, 11, 5, 12);
  String at(Duration ago) => now.subtract(ago).toIso8601String();
  const levels = (0.75, 0.9);
  String tr(String s) => s;

  test('a limit without a valid reset expires with an old record', () {
    final fresh = {
      'label': 'Week',
      'percent': 0.5,
      'resets_at': null,
      'measured_at': at(const Duration(minutes: 5)),
    };
    final old = {...fresh, 'measured_at': at(const Duration(minutes: 31))};
    final unknown = {...fresh, 'measured_at': null};
    expect(currentLimits([fresh], now), [fresh]);
    expect(currentLimits([old], now), isEmpty);
    expect(battery([old], levels, now), isNull);
    expect(currentLimits([unknown], now), [unknown]); // no time: as before
    // A reset still to come keeps it, but it is no longer current.
    final reset = {
      ...old,
      'resets_at': now.add(const Duration(hours: 2)).toIso8601String(),
    };
    expect(currentLimits([reset], now), [reset]);
    expect(
      limitsStale([reset], now)?.measured,
      DateTime.parse(old['measured_at'] as String),
    );
    expect(limitsStale([fresh], now), isNull);
    expect(
      batteryTip([reset], now, tr),
      contains('these numbers may be out of date'),
    );
    expect(batteryTip([fresh], now, tr), isNot(contains('out of date')));
  });

  test("the collector's own stale flag marks the battery stale", () {
    final kept = {
      'label': 'Session',
      'percent': 0.2,
      'resets_at': now.add(const Duration(hours: 1)).toIso8601String(),
      'measured_at': at(const Duration(minutes: 2)),
      'stale': true,
    };
    expect(battery([kept], levels, now), isNotNull);
    expect(limitsStale([kept], now), isNotNull);
    expect(
      batteryTip(
        [
          {...kept, 'measured_at': null},
        ],
        now,
        tr,
      ),
      endsWith('These numbers may be out of date.'),
    );
  });

  test('usage record times: ISO, seconds, milliseconds', () {
    final t = DateTime.utc(2026, 11, 5, 13, 34, 17);
    expect(usageTime('2026-11-05T13:34:17+00:00'), t);
    expect(usageTime(t.millisecondsSinceEpoch), t);
    expect(usageTime(t.millisecondsSinceEpoch ~/ 1000), t);
    expect(usageTime(0), isNull);
    expect(usageTime('nonsense'), isNull);
    expect(usageTime(null), isNull);
  });

  test("a cost per token also has what is left of the day's limit", () {
    final low = costBadge(10, 100, 'usd', null, levels, tr);
    expect(low['kind'], 'cost');
    expect(low['left'], 0.9);
    expect(low['colour'], 'green');
    expect(low['label'], contains(r'$10'));
    final edge = costBadge(90, 100, 'usd', null, levels, tr);
    expect((edge['left'], edge['colour']), (0.1, 'red')); // a tenth: red
    expect(costBadge(130, 100, 'usd', null, levels, tr)['left'], 0.0);
    expect(
      costBadge(1, 0, 'usd', null, levels, tr).containsKey('left'),
      isFalse,
    );
  });

  test('sessions that say they cost money: paid per token, not for a plan', () {
    bool pays({
      List limits = const [],
      String plan = '',
      Map record = const {},
      bool billed = false,
    }) => paysPerToken(
      limits: limits,
      plan: plan,
      usageRecord: record,
      access: const {
        'how': 'x',
        'files': ['.hermes/auth.json'],
      },
      home: '/nonexistent',
      environment: const {},
      billed: billed,
    );
    expect(pays(), isFalse);
    expect(pays(billed: true), isTrue);
    expect(pays(billed: true, plan: 'Plus'), isFalse);
    expect(
      pays(
        billed: true,
        limits: [
          {'percent': 0.1},
        ],
      ),
      isFalse,
    );
    expect(
      pays(billed: true, record: {'usageStatusText': 'Sign-in expired'}),
      isFalse,
    );
  });

  test("money in the agent's own sessions is what says it pays per token", () {
    final home = Directory.systemTemp.createTempSync('badges-billed');
    addTearDown(() => home.deleteSync(recursive: true));
    final db = '${home.path}/.local/share/opencode/opencode.db';
    Directory('${home.path}/.local/share/opencode').createSync(recursive: true);
    final ms = DateTime.now().millisecondsSinceEpoch;
    String rows(double first, double second) =>
        'CREATE TABLE session_v2(id TEXT, parent_id TEXT, agent TEXT, '
        'directory TEXT, time_created INTEGER, time_updated INTEGER, '
        'model TEXT, tokens_input INTEGER, tokens_output INTEGER, '
        'tokens_reasoning INTEGER, tokens_cache_read INTEGER, '
        'tokens_cache_write INTEGER, cost REAL, summary_additions INTEGER, '
        'summary_deletions INTEGER);'
        'CREATE TABLE session_message(session_id TEXT, time_created INTEGER);'
        "INSERT INTO session_v2 VALUES('a', NULL, 'build', '/p', $ms, $ms, "
        "'claude-sonnet-4-5', 1000, 200, 0, 0, 0, $first, 0, 0);"
        "INSERT INTO session_v2 VALUES('b', NULL, 'build', '/p', $ms, $ms, "
        "'gpt-5.5', 500, 100, 0, 0, 0, $second, 0, 0);";
    final opencode = builtinAdapters().firstWhere(
      (a) => a.command == 'opencode',
    );
    expect(SessionReaders.keepsCosts(opencode), isTrue);
    expect(
      SessionReaders.keepsCosts(
        builtinAdapters().firstWhere((a) => a.command == 'codex'),
      ),
      isFalse,
    );
    final files = ScanFiles(
      AppIdentity(environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin'}),
    );
    // A plan's or a local LLM's use: no money in the store.
    Process.runSync('sqlite3', [db, rows(0, 0)]);
    expect(UsageReaders(files).costs(opencode)!['billed'], 0.0);
    File(db).deleteSync();
    // A provider billing per token: what each session cost.
    Process.runSync('sqlite3', [db, rows(0.25, 0.5)]);
    final spent = UsageReaders(files).costs(opencode)!;
    expect(spent['billed'], 0.75);
    expect(
      paysPerToken(
        limits: const [],
        plan: '',
        usageRecord: const {},
        access: opencode.table('access'),
        home: home.path,
        environment: const {},
        billed: (spent['billed'] as num) > 0,
      ),
      isTrue,
    );
  });

  test("Hermes' estimated cost is no bill, its actual cost is", () {
    final home = Directory.systemTemp.createTempSync('badges-hermes');
    addTearDown(() => home.deleteSync(recursive: true));
    Directory('${home.path}/.hermes').createSync(recursive: true);
    final s = DateTime.now().millisecondsSinceEpoch / 1000;
    Process.runSync('sqlite3', [
      '${home.path}/.hermes/state.db',
      'CREATE TABLE sessions(id TEXT, parent_session_id TEXT, cwd TEXT, '
          'title TEXT, started_at REAL, ended_at REAL, last_activity_at REAL, '
          'model TEXT, input_tokens INTEGER, output_tokens INTEGER, '
          'reasoning_tokens INTEGER, cache_read_tokens INTEGER, '
          'cache_write_tokens INTEGER, estimated_cost_usd REAL, '
          'actual_cost_usd REAL);'
          'CREATE TABLE messages(session_id TEXT, timestamp REAL);'
          "INSERT INTO sessions VALUES('e', NULL, '/p', NULL, $s, NULL, $s, "
          "'claude-opus-5-5', 10, 1, 0, 0, 0, 0.2, NULL);",
    ]);
    final hermes = builtinAdapters().firstWhere((a) => a.command == 'hermes');
    final files = ScanFiles(
      AppIdentity(environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin'}),
    );
    final estimated = SessionReaders(files).read(hermes);
    expect(estimated.values.single.cost, closeTo(0.2, 1e-9)); // its API value
    expect(estimated.values.single.estimated, isTrue);
    expect(UsageReaders(files).costs(hermes)!['billed'], 0.0);
    Process.runSync('sqlite3', [
      '${home.path}/.hermes/state.db',
      "INSERT INTO sessions VALUES('a', NULL, '/p', NULL, $s, NULL, $s, "
          "'claude-opus-5-5', 10, 1, 0, 0, 0, 0.4, 0.3);",
    ]);
    expect(UsageReaders(files).costs(hermes)!['billed'], closeTo(0.3, 1e-9));
  });
}
