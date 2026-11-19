import 'dart:io';

import 'package:maprisma_core/src/ai_activity_log.dart';
import 'package:maprisma_core/src/identity.dart';
import 'package:maprisma_core/src/scan_files.dart';
import 'package:maprisma_core/src/settings.dart';
import 'package:test/test.dart';

void main() {
  test(
    'local log is opt-in, filters sources, reports spans and prunes days',
    () {
      final home = Directory.systemTemp.createTempSync(
        'maprisma-activity-log-',
      );
      addTearDown(() => home.deleteSync(recursive: true));
      final identity = AppIdentity(environment: {'HOME': home.path});
      final settings = SettingsStore(identity);
      final log = AiActivityLog(ScanFiles(identity), settings);
      log.observe({'agent:fixture'}, observedAt: DateTime(2026, 11, 18, 10));
      log.observe({}, observedAt: DateTime(2026, 11, 18, 11));
      expect(Directory('${identity.dataDir}/ai-log').existsSync(), isFalse);

      settings.update({
        'values': {'ai_activity_log': true},
      });
      log.observe({
        'agent:fixture',
        'agent:/absolute/token',
      }, observedAt: DateTime(2026, 11, 18, 12));
      log.observe({}, observedAt: DateTime(2026, 11, 18, 13));
      final report = log.report({}, now: DateTime(2026, 11, 18));
      expect(report['entries'], hasLength(1));
      expect(report['entries'].single['source'], 'fixture');
      expect(report['entries'].single['tokens_in'], isNull);
      expect(report['by_day'].single['duration_ms'], 3600000);
      expect(report['by_week'].single['count'], 1);

      expect(settings.value(settings.load(), 'ai_activity_log_days'), 7);
      log.observe({}, observedAt: DateTime(2026, 11, 24));
      expect(
        File('${identity.dataDir}/ai-log/2026-11-18.jsonl').existsSync(),
        isTrue,
      );
      log.observe({}, observedAt: DateTime(2026, 11, 25));
      expect(
        File('${identity.dataDir}/ai-log/2026-11-18.jsonl').existsSync(),
        isFalse,
      );
    },
  );
  test('an explicitly stored two-day setting survives the default change', () {
    final home = Directory.systemTemp.createTempSync('maprisma-log-retention-');
    addTearDown(() => home.deleteSync(recursive: true));
    final identity = AppIdentity(environment: {'HOME': home.path});
    final settings = SettingsStore(identity)
      ..update({
        'values': {'ai_activity_log_days': 2},
      });
    expect(SettingsStore(identity).load()['ai_activity_log_days'], 2);
    expect(settings.load()['ai_activity_log_days'], 2);
  });
  test('token totals use deltas from the same session', () {
    final home = Directory.systemTemp.createTempSync('maprisma-usage-log-');
    addTearDown(() => home.deleteSync(recursive: true));
    final identity = AppIdentity(environment: {'HOME': home.path});
    final settings = SettingsStore(identity)
      ..update({
        'values': {'ai_activity_log': true},
      });
    final log = AiActivityLog(ScanFiles(identity), settings);
    var input = 100;
    ActivityUsage usage(String _) => (
      session: 'private/session',
      model: 'fixture-model',
      input: input,
      output: 20,
    );
    log.observe(
      {'agent:fixture'},
      usageFor: usage,
      observedAt: DateTime(2026, 11, 18, 12),
    );
    input = 114;
    log.observe({}, usageFor: usage, observedAt: DateTime(2026, 11, 18, 13));
    final report = log.report({}, now: DateTime(2026, 11, 18));
    expect(report['entries'].single['tokens_in'], 14);
    expect(report['by_day'].single['tokens_out'], 0);
    expect(report['by_day'].single['usage_unknown'], 0);
    expect(report.toString(), isNot(contains('private/session')));
  });
}
