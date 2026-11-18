import 'dart:io';

import 'package:maprisma_core/src/agent_activity_report.dart';
import 'package:maprisma_core/src/agent_progress.dart';
import 'package:maprisma_core/src/identity.dart';
import 'package:maprisma_core/src/provider_scans.dart';
import 'package:maprisma_core/src/scan_files.dart';
import 'package:test/test.dart';

void main() {
  test('timeline orders changes, groups tests and skips generated files', () {
    final home = Directory.systemTemp.createTempSync('maprisma-timeline-');
    addTearDown(() => home.deleteSync(recursive: true));
    final work = Directory('${home.path}/work')..createSync();
    final generated = Directory('${work.path}/build')..createSync();
    final now = DateTime.now();
    final scan = ScanFiles(AppIdentity(environment: {'HOME': home.path}));
    void touch(String path, int minutes) {
      File(path)
        ..writeAsStringSync('fixture')
        ..setLastModifiedSync(now.subtract(Duration(minutes: minutes)));
    }

    touch('${work.path}/main.dart', 8);
    touch('${work.path}/main_test.dart', 4);
    touch('${generated.path}/artifact', 1);
    final groups = activityTimeline(
      {home.path, work.path},
      scan,
      now.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch / 1000,
    );
    expect(groups.map((group) => group['kind']), ['editing', 'testing']);
    expect(groups.expand((group) => group['files'] as List), hasLength(2));
  });

  test('phase prefers completion and running tests', () {
    expect(
      activityPhase(
        request: true,
        progress: null,
        timeline: [],
        testing: false,
      ),
      'planning',
    );
    expect(
      activityPhase(
        request: false,
        progress: null,
        timeline: [],
        testing: true,
      ),
      'testing',
    );
    expect(
      activityPhase(
        request: false,
        progress: {'done': 2, 'total': 2},
        timeline: [],
        testing: true,
      ),
      'finished',
    );
  });

  test('stuck evidence requires sustained unchanged CPU samples', () {
    final tracker = ActivityIdle();
    int? sample(int ms, {int cpu = 0}) => tracker.observe(
      'fixture',
      evidence: 'waiting',
      ticks: [cpu],
      active: true,
      elapsedMs: ms,
    );
    for (var ms = 0; ms < 600000; ms += 10000) {
      expect(sample(ms), isNull);
    }
    expect(sample(600000), 600000);
    expect(sample(610000, cpu: 1), isNull);
    expect(sample(1220000, cpu: 1), isNull);
  });

  test('MCP exposes the configured activity tool only', () async {
    final progress = AgentProgress(ProviderScans(ScanFiles(AppIdentity())));
    const request = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'};
    final reportOnly = await activityMcpReply(
      request,
      progress,
      {},
      logReport: (_) => {},
    );
    final progressOnly = await activityMcpReply(request, progress, {});
    String name(Map<String, Object?>? reply) =>
        ((reply!['result'] as Map)['tools'] as List).single['name'] as String;
    expect(name(reportOnly), 'activity_log_report');
    expect(name(progressOnly), 'report_progress');
  });
  test('MCP validates progress and rejects an unbound caller', () async {
    final progress = AgentProgress(ProviderScans(ScanFiles(AppIdentity())));
    Future<Map<String, Object?>?> reply(Map<String, Object> args) =>
        activityMcpReply(
          {
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'tools/call',
            'params': {'name': 'report_progress', 'arguments': args},
          },
          progress,
          {},
        );
    expect(
      ((await reply({'step': 'Build', 'done': 2, 'total': 1}))!['result']
          as Map)['isError'],
      true,
    );
    expect(
      ((await reply({'step': 'Build', 'done': 0, 'total': 1}))!['result']
          as Map)['isError'],
      true,
    );
  });
}
