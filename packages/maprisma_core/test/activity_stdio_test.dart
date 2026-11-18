import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_core/src/agent_progress.dart';
import 'package:maprisma_core/src/ai_activity_log.dart';
import 'package:maprisma_core/src/identity.dart';
import 'package:maprisma_core/src/provider_scans.dart';
import 'package:maprisma_core/src/pty_sessions.dart' show processIdentity;
import 'package:maprisma_core/src/scan_files.dart';
import 'package:maprisma_core/src/settings.dart';
import 'package:test/test.dart';

const entry = 'bin/maprisma-core.dart';

Future<Map<String, dynamic>> rpc(
  Process process,
  StreamIterator<String> lines,
  int id,
  String method, [
  Map<String, dynamic>? params,
]) async {
  process.stdin.writeln(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': ?params,
    }),
  );
  expect(await lines.moveNext().timeout(const Duration(seconds: 20)), isTrue);
  final reply = jsonDecode(lines.current) as Map<String, dynamic>;
  expect(reply['id'], id);
  return reply['result'] as Map<String, dynamic>;
}

void main() {
  late Directory home;
  late AppIdentity identity;
  late SettingsStore settings;

  setUp(() {
    home = Directory.systemTemp.createTempSync('maprisma-activity-stdio-');
    final runtime = Directory('${home.path}/runtime')..createSync();
    identity = AppIdentity(
      environment: {
        'HOME': home.path,
        'XDG_RUNTIME_DIR': runtime.path,
        'PATH': '/nonexistent',
      },
    );
    settings = SettingsStore(identity);
  });
  tearDown(() => home.deleteSync(recursive: true));

  Future<(Process, StreamIterator<String>)> start(
    String executable,
    List<String> args,
  ) async {
    final process = await Process.start(
      executable,
      args,
      environment: identity.environment,
      includeParentEnvironment: false,
    );
    final lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    final errors = process.stderr.transform(utf8.decoder).join();
    addTearDown(() async {
      await process.stdin.close();
      await lines.cancel();
      expect(
        await process.exitCode.timeout(const Duration(seconds: 5)),
        0,
        reason: await errors,
      );
    });
    return (process, lines);
  }

  test('progress stdio initializes and rejects invalid progress', () async {
    final (process, lines) = await start(Platform.resolvedExecutable, [
      entry,
      'activity-mcp',
    ]);
    final initialized = await rpc(process, lines, 1, 'initialize');
    expect(initialized['capabilities'], {'tools': {}});
    final tools = await rpc(process, lines, 2, 'tools/list');
    expect(tools['tools'].single['name'], 'report_progress');
    final reply = await rpc(process, lines, 3, 'tools/call', {
      'name': 'report_progress',
      'arguments': {'step': 'Build', 'done': 3, 'total': 2},
    });
    expect(reply['isError'], true);
  });

  test(
    'reads concurrent instances independently and rejects a reused PID',
    () async {
      final proc = Directory('${home.path}/proc')..createSync();
      final runtime = Directory(
        '${identity.environment['XDG_RUNTIME_DIR']}/maprisma/progress',
      )..createSync(recursive: true);
      final progress = AgentProgress(
        ProviderScans(
          ScanFiles(
            AppIdentity(
              environment: {
                ...identity.environment,
                'MAPRISMA_SCAN_PROC': proc.path,
              },
            ),
          ),
        ),
      );
      Future<(int, String)> fixture(String step) async {
        final process = await Process.start('/usr/bin/sleep', ['30']);
        addTearDown(() async {
          process.kill();
          await process.exitCode;
        });
        final pid = process.pid;
        final birth = processIdentity(pid)!.$3;
        final processFiles = Directory('${proc.path}/$pid')..createSync();
        File('${processFiles.path}/comm').writeAsStringSync('fixture');
        File('${processFiles.path}/cmdline').writeAsStringSync('fixture\x00');
        final report = {
          'step': step,
          'done': 1,
          'total': 2,
          'note': null,
          'at': DateTime.now().toUtc().toIso8601String(),
        };
        File(
          '${runtime.path}/$pid-$birth.json',
        ).writeAsStringSync(jsonEncode(report));
        File(
          '${runtime.path}/$pid-0.json',
        ).writeAsStringSync(jsonEncode(report));
        return (pid, '$pid:$birth');
      }

      final first = await fixture('Build');
      final second = await fixture('Test');
      expect(progress.read('fixture', first.$2)?['step'], 'Build');
      expect(progress.read('fixture', second.$2)?['step'], 'Test');
      expect(progress.read('fixture', '${first.$1}:0'), isNull);
      final rows = progress.snapshot({'fixture'})['fixture']!;
      expect(
        rows.map((row) => row['id']),
        unorderedEquals([first.$2, second.$2]),
      );
    },
  );

  test(
    'progress stdio binds reports to concurrent owners and rejects stale birth',
    () async {
      final launcher = Link('${home.path}/codex')..createSync('/bin/sh');
      Future<(Process, String)> report(String step) async {
        final (agent, lines) = await start(launcher.path, [
          '-c',
          r'"$@"; :',
          'fixture',
          Platform.resolvedExecutable,
          entry,
          'activity-mcp',
        ]);
        final tools = await rpc(agent, lines, 1, 'tools/list');
        expect(tools['tools'].single['name'], 'report_progress');
        final response = await rpc(agent, lines, 2, 'tools/call', {
          'name': 'report_progress',
          'arguments': {'step': step, 'done': 1, 'total': 2},
        });
        expect(response['isError'], isFalse);
        final accepted = jsonDecode(
          response['content'].single['text'] as String,
        );
        expect(accepted, {'accepted': true});
        return (agent, '${agent.pid}:${processIdentity(agent.pid)!.$3}');
      }

      final results = await Future.wait([report('Build'), report('Test')]);
      final progress = AgentProgress(ProviderScans(ScanFiles(identity)));
      expect(progress.read('codex', results[0].$2)?['step'], 'Build');
      expect(progress.read('codex', results[1].$2)?['step'], 'Test');
      expect(
        progress
            .snapshot({'codex'})['codex']!
            .where(
              (row) => results.any((result) => result.$1.pid == row['pid']),
            )
            .map((row) => row['id']),
        unorderedEquals(results.map((row) => row.$2)),
      );

      final agent = results.first.$1;
      final stale = File(
        '${identity.environment['XDG_RUNTIME_DIR']}'
        '/maprisma/progress/${agent.pid}-0.json',
      );
      stale.writeAsStringSync(
        jsonEncode(progress.read('codex', results.first.$2)),
      );
      expect(progress.read('codex', '${agent.pid}:0'), isNull);
    },
  );

  test(
    'history CLI exports TXT and JSON; stdio MCP has the same local fallback',
    () async {
      // Seed the on-disk format directly. The activity-log unit tests cover
      // collection and private writes separately.
      final settingsFile = File(identity.settingsPath);
      settingsFile.parent.createSync(recursive: true);
      settingsFile.writeAsStringSync(
        jsonEncode({'ai_activity_log': true, 'ai_activity_local_topics': true}),
      );
      expect(settings.value(settings.load(), 'ai_activity_local_topics'), true);
      final now = DateTime.now();
      final day = activityDay(now);
      final file = File('${identity.dataDir}/ai-log/$day.jsonl');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'source_kind': 'agent',
          'source': 'fixture',
          'project': 'project',
          'topic': 'editing',
          'started_at': now
              .subtract(const Duration(minutes: 2))
              .toIso8601String(),
          'ended_at': now.toIso8601String(),
          'duration_ms': 120000,
          'files': ['example.dart'],
        }),
      );
      final log = AiActivityLog(ScanFiles(identity), settings);
      final expected = log.report({'from_day': day, 'through_day': day});
      expect(expected['entries'].single['topic'], 'editing');
      Future<String> cli(String format) async {
        final result = await Process.run(
          Platform.resolvedExecutable,
          [
            entry,
            'activity-log',
            '--format',
            format,
            '--from-day',
            day,
            '--through-day',
            day,
          ],
          environment: identity.environment,
          includeParentEnvironment: false,
        ).timeout(const Duration(seconds: 20));
        expect(result.exitCode, 0, reason: result.stderr as String);
        return result.stdout as String;
      }

      expect(jsonDecode(await cli('json')), expected);
      final text = await cli('text');
      expect(text, contains('agent:fixture · project · editing'));
      expect(text, contains('By week'));
      expect(text, isNot(contains(home.path)));
      final (mcp, lines) = await start(Platform.resolvedExecutable, [
        entry,
        'activity-log-mcp',
      ]);
      final initialized = await rpc(mcp, lines, 1, 'initialize');
      expect(initialized['capabilities'], {'tools': {}});
      final tools = await rpc(mcp, lines, 2, 'tools/list');
      expect(tools['tools'].single['name'], 'activity_log_report');
      final report = await rpc(mcp, lines, 3, 'tools/call', {
        'name': 'activity_log_report',
        'arguments': {'from_day': day, 'through_day': day},
      });
      expect(jsonDecode(report['content'].single['text'] as String), expected);
    },
  );
}
