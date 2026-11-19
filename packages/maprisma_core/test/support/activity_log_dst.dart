import 'dart:convert';
import 'dart:io';

import 'package:maprisma_core/maprisma_core.dart';
import 'package:maprisma_core/src/ai_activity_log.dart';
import 'package:maprisma_core/src/scan_files.dart';

Future<void> main(List<String> args) async {
  if (DateTime(2026, 3, 30).difference(DateTime(2026, 3, 29)) !=
      const Duration(hours: 23)) {
    throw StateError('The fixture must run with TZ=Europe/Berlin');
  }
  final identity = AppIdentity(environment: {'HOME': args.single});
  final settings = SettingsStore(identity)
    ..update({
      'values': {'ai_activity_log': true},
    });
  final log = AiActivityLog(ScanFiles(identity), settings);
  final start = DateTime(2026, 3, 29, 23, 50);
  final end = DateTime(2026, 3, 30, 0, 20);
  final saved = await log.mergeHistory({
    'version': 1,
    'origin': 'history',
    'session': 'dst',
    'source_kind': 'agent',
    'source': 'fixture',
    'started_at': start.toUtc().toIso8601String(),
    'ended_at': end.toUtc().toIso8601String(),
    'duration_ms': end.difference(start).inMilliseconds,
    'files': <String>[],
  });
  log.observe({'agent:fixture'}, observedAt: DateTime(2026, 3, 30, 0, 15));
  log.observe({}, observedAt: DateTime(2026, 3, 30, 0, 16));
  final rows = File(
    '${log.directory}/2026-03-30.jsonl',
  ).readAsLinesSync().map((line) => jsonDecode(line) as Map).toList();
  stdout.writeln(
    jsonEncode({
      'superseded': rows.single['superseded_by'] == saved.row!['id'],
      'entries': (log.report({}, now: end)['entries'] as List).length,
    }),
  );
}
