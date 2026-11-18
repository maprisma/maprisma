import 'dart:convert';
import 'dart:io';

import 'package:maprisma_core/src/identity.dart';
import 'package:maprisma_core/src/live_session_activity.dart';
import 'package:maprisma_core/src/provider_scans.dart';
import 'package:maprisma_core/src/pty_sessions.dart' show processIdentity;
import 'package:maprisma_core/src/scan_files.dart';
import 'package:maprisma_core/src/jsonl_session_activity.dart';
import 'package:test/test.dart';

void main() {
  test('reads the latest turn across both JSONL session forms', () {
    final report = jsonlSessionActivity('''
truncated record
{"type":"message","message":{"role":"user","content":"old task"}}
{"type":"assistant","message":{"role":"assistant","content":"old answer"}}
{"type":"user","message":{"role":"user","content":"latest task"}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","name":"test","arguments":{"input":"private"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"},{"type":"tool_use","name":"verify","input":{"path":"private"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"private"}]}}
''', 'fixture');
    expect(report['status'], 'available');
    expect(report['request']['text'], 'latest task');
    expect(report['answers'].single['text'], 'done');
    expect((report['tool_calls'] as List).map((tool) => tool['name']), [
      'test',
      'verify',
    ]);
    expect(report.toString(), isNot(contains('private')));
  });
  test(
    'reads a rollout and attributes only successful patches in the current turn',
    () {
      final report = jsonlSessionActivity(
        r'''
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Old request"}]}}
{"type":"response_item","payload":{"type":"function_call","call_id":"old","name":"old_tool"}}
{"type":"response_item","timestamp":"2026-11-18T18:00:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Update tests"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>private</environment_context>"}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I will update it."}]}}
{"type":"response_item","payload":{"type":"custom_tool_call","call_id":"patch","name":"apply_patch","input":"*** Begin Patch\n*** Update File: test.dart\n*** End Patch"}}
{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"patch","output":"Wall time: 0 seconds\nOutput:\nSuccess. Updated the following files:\nM test.dart"}}
{"type":"response_item","payload":{"type":"custom_tool_call","call_id":"failed","name":"apply_patch","input":"*** Begin Patch\n*** Delete File: ignored.dart\n*** End Patch"}}
{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"failed","output":"Unable to apply patch: private"}}
''',
        'rollout',
        rollout: true,
      );
      expect(report['request'], {
        'at': '2026-11-18T18:00:00.000Z',
        'text': 'Update tests',
      });
      expect(report['answers'].single['text'], 'I will update it.');
      expect(report['tool_calls'], hasLength(2));
      expect(report['tool_calls'].first['status'], 'completed');
      expect(report['edited_files'].single['path'], 'test.dart');
      expect(report.toString(), isNot(contains('ignored.dart')));
      expect(report.toString(), isNot(contains('private')));
    },
  );
  test(
    'live reader resolves a rollout from an agent file descriptor',
    () async {
      final home = Directory.systemTemp.createTempSync('maprisma-rollout-');
      addTearDown(() => home.deleteSync(recursive: true));
      final folder = Directory('${home.path}/sessions/2026/11/18')
        ..createSync(recursive: true);
      final rollout = File('${folder.path}/rollout-fixture.jsonl')
        ..writeAsStringSync(
          jsonEncode({
            'type': 'response_item',
            'payload': {
              'type': 'message',
              'role': 'user',
              'content': [
                {'type': 'input_text', 'text': 'Live request'},
              ],
            },
          }),
        );
      final agent = await Process.start('/usr/bin/bash', [
        '-c',
        r'exec 3<"$1"; exec /usr/bin/sleep 30',
        'fixture',
        rollout.path,
      ]);
      addTearDown(() async {
        agent.kill();
        await agent.exitCode;
      });
      final proc = Directory('${home.path}/proc/${agent.pid}')
        ..createSync(recursive: true);
      File('${proc.path}/comm').writeAsStringSync('fixture');
      File('${proc.path}/cmdline').writeAsStringSync('fixture\x00');
      final scans = ProviderScans(
        ScanFiles(
          AppIdentity(
            environment: {
              'HOME': home.path,
              'MAPRISMA_SCAN_PROC': '${home.path}/proc',
            },
          ),
        ),
      );
      final instance = '${agent.pid}:${processIdentity(agent.pid)!.$3}';
      Map<String, dynamic> result = {};
      for (var attempt = 0; attempt < 40; attempt++) {
        result = liveSessionActivity(scans, 'fixture', instance, {
          'activity_reader': 'codex-jsonl',
          'activity_dir': '~/sessions',
        });
        if (result['request'] != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(result['request'], containsPair('text', 'Live request'));
      expect(result['session_id'], 'rollout-fixture');
    },
  );
}
