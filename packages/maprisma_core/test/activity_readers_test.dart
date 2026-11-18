import 'dart:io';

import 'package:maprisma_core/src/activity_readers.dart';
import 'package:maprisma_core/src/adapters.dart';
import 'package:maprisma_core/src/agent_catalog.dart';
import 'package:maprisma_core/src/agent_details.dart';
import 'package:maprisma_core/src/desktop.dart';
import 'package:maprisma_core/src/identity.dart';
import 'package:maprisma_core/src/scan_files.dart';
import 'package:maprisma_core/src/service_i18n.dart';
import 'package:maprisma_core/src/settings.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  late Directory fakeProc;
  late Map<String, String> env;

  ActivityReaders makeReaders() {
    final identity = AppIdentity(environment: env);
    final files = ScanFiles(identity);
    final details = DetailReaders(
      files,
      GenericDesktop(env),
      ServiceI18n(identity, SettingsStore(identity)),
    );
    return ActivityReaders(files, details);
  }

  File writeHome(String rel, String text) => File('${home.path}/$rel')
    ..createSync(recursive: true)
    ..writeAsStringSync(text);

  void writeProc(
    int pid,
    String comm,
    List<String> argv, {
    int startedAgoSeconds = 60,
  }) {
    final dir = Directory('${fakeProc.path}/$pid')..createSync(recursive: true);
    File('${dir.path}/comm').writeAsStringSync('$comm\n');
    File('${dir.path}/cmdline').writeAsStringSync('${argv.join('\x00')}\x00');
    File(
      '${dir.path}/stat',
    ).writeAsStringSync('$pid ($comm) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1\n');
    Directory('${dir.path}/fd').createSync();
    if (startedAgoSeconds > 0) {
      Process.runSync('touch', [
        '-d',
        '$startedAgoSeconds seconds ago',
        dir.path,
      ]);
    }
  }

  AgentRecord recordFor(String command) {
    final adapter = builtinAdapters().firstWhere((a) => a.command == command);
    return AgentRecord(adapter, name: adapter.name, icon: '', installed: true);
  }

  setUp(() {
    home = Directory.systemTemp.createTempSync('activity-readers-');
    fakeProc = Directory('${home.path}/proc')..createSync();
    env = {
      'HOME': home.path,
      'XDG_CONFIG_HOME': '${home.path}/.config',
      'XDG_DATA_HOME': '${home.path}/.local/share',
      'XDG_STATE_HOME': '${home.path}/.local/state',
      'MAPRISMA_SCAN_PROC': fakeProc.path,
      'PATH': '/usr/bin:/bin',
    };
  });

  tearDown(() => home.deleteSync(recursive: true));

  test('newestMtime sees SQLite -wal writes when main .sqlite is stale', () {
    final readers = makeReaders();
    final db = writeHome('.codex/state_5.sqlite', 'db');
    final wal = writeHome('.codex/state_5.sqlite-wal', 'wal');
    final oldTime = DateTime.now().subtract(const Duration(hours: 2));
    final freshTime = DateTime.now().subtract(const Duration(seconds: 1));
    db.setLastModifiedSync(oldTime);
    wal.setLastModifiedSync(freshTime);

    final newest = readers.details.newestMtime(['~/.codex/state_5.sqlite']);
    expect(newest, isNotNull);
    expect(newest!.difference(freshTime).inSeconds.abs(), lessThanOrEqualTo(1));
  });

  test('isJsonlTurnActive tracks claude-jsonl and codex-jsonl turn boundaries', () {
    expect(
      ActivityReaders.isJsonlTurnActive(
        'claude-jsonl',
        '{"type":"user","message":{"role":"user","content":"hi"}}\n'
            '{"type":"api-request"}\n',
      ),
      isTrue,
    );
    expect(
      ActivityReaders.isJsonlTurnActive(
        'claude-jsonl',
        '{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use"}}\n',
      ),
      isTrue,
    );
    expect(
      ActivityReaders.isJsonlTurnActive(
        'claude-jsonl',
        '{"type":"user","message":{"role":"user","content":"hi"}}\n'
            '{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn"}}\n'
            '{"type":"system","subtype":"turn_duration"}\n'
            '{"type":"cost-state"}\n'
            '{"type":"last-prompt"}\n',
      ),
      isFalse,
    );
    expect(
      ActivityReaders.isJsonlTurnActive(
        'codex-jsonl',
        '{"type":"event_msg","payload":{"type":"task_started"}}\n',
      ),
      isTrue,
    );
    expect(
      ActivityReaders.isJsonlTurnActive(
        'codex-jsonl',
        '{"type":"event_msg","payload":{"type":"task_started"}}\n'
            '{"type":"event_msg","payload":{"type":"task_complete"}}\n',
      ),
      isFalse,
    );
  });

  test(
    'snapshot detects active turns during long pauses and ignores chrome-native-host',
    () {
      writeProc(1001, 'claude', [
        '/opt/claude-code/bin/claude',
        '--chrome-native-host',
      ]);
      writeProc(1002, 'claude', [
        '/opt/claude-code/bin/claude',
        '--a',
        '--b',
        '--c',
        '--chrome-native-host',
      ]);
      final readers = makeReaders();
      final claude = recordFor('claude');
      final codex = recordFor('codex');

      // Only --chrome-native-host running -> 0 instances, not working.
      var (_, act) = readers.snapshot([claude, codex]);
      expect(act['claude']['instances'], 0);
      expect(act['claude']['working'], isFalse);

      // Real claude + codex processes with active turns written 25s ago (>8s mtime window, 0% CPU).
      writeProc(2001, 'claude', ['/home/uwe/.local/bin/claude']);
      writeProc(2002, 'codex', [
        '/home/uwe/.local/bin/codex',
        'exec',
        'review',
      ]);
      final ago25 = DateTime.now().subtract(const Duration(seconds: 25));

      void backdateDirs() {
        for (final dir in [
          '${home.path}/.claude/projects',
          '${home.path}/.claude/projects/-proj',
          '${home.path}/.codex/sessions',
          '${home.path}/.codex/sessions/2026',
          '${home.path}/.codex/sessions/2026/11',
          '${home.path}/.codex/sessions/2026/11/18',
        ]) {
          Process.runSync('touch', ['-d', '25 seconds ago', dir]);
        }
      }

      final claudeFile = writeHome(
        '.claude/projects/-proj/session.jsonl',
        '{"type":"user","message":{"role":"user","content":"audit"}}\n'
            '{"type":"api-request"}\n',
      )..setLastModifiedSync(ago25);
      final codexFile = writeHome(
        '.codex/sessions/2026/11/18/rollout.jsonl',
        '{"type":"event_msg","payload":{"type":"task_started"}}\n',
      )..setLastModifiedSync(ago25);
      backdateDirs();

      (_, act) = readers.snapshot([claude, codex]);
      expect(act['claude']['instances'], 1);
      expect(act['claude']['working'], isTrue);
      expect(act['codex']['instances'], 1);
      expect(act['codex']['working'], isTrue);

      // Once both turns finish (and >8s old), working returns to false.
      claudeFile
        ..writeAsStringSync(
          '{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn"}}\n'
          '{"type":"system","subtype":"turn_duration"}\n'
          '{"type":"cost-state"}\n',
        )
        ..setLastModifiedSync(ago25);
      codexFile
        ..writeAsStringSync(
          '{"type":"event_msg","payload":{"type":"task_started"}}\n'
          '{"type":"event_msg","payload":{"type":"task_complete"}}\n',
        )
        ..setLastModifiedSync(ago25);
      backdateDirs();

      (_, act) = readers.snapshot([claude, codex]);
      expect(act['claude']['working'], isFalse);
      expect(act['codex']['working'], isFalse);
    },
  );

  test(
    'stale interrupted transcript does not light a newly opened idle instance, while concurrent active turn still lights',
    () {
      final claude = recordFor('claude');
      final ago40 = DateTime.now().subtract(const Duration(seconds: 40));
      final ago20 = DateTime.now().subtract(const Duration(seconds: 20));

      // Stale interrupted transcript from 40s ago, while idle claude started now (0s ago).
      writeProc(3001, 'claude', [
        '/home/uwe/.local/bin/claude',
      ], startedAgoSeconds: 0);
      final stale = writeHome(
        '.claude/projects/-proj/stale.jsonl',
        '{"type":"user","message":{"role":"user","content":"old"}}\n'
            '{"type":"api-request"}\n',
      )..setLastModifiedSync(ago40);
      for (final dir in [
        '${home.path}/.claude/projects',
        '${home.path}/.claude/projects/-proj',
      ]) {
        Process.runSync('touch', ['-d', '40 seconds ago', dir]);
      }
      var (_, act) = makeReaders().snapshot([claude]);
      expect(act['claude']['instances'], 1);
      expect(act['claude']['working'], isFalse);

      // Add an earlier live process (60s ago) plus a newer completed session (20s ago):
      // the concurrent active session (40s ago, after PID start) must NOT be masked.
      writeProc(3002, 'claude', [
        '/home/uwe/.local/bin/claude',
      ], startedAgoSeconds: 60);
      stale.setLastModifiedSync(ago40);
      writeHome(
        '.claude/projects/-proj/finished.jsonl',
        '{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn"}}\n'
            '{"type":"system","subtype":"turn_duration"}\n',
      ).setLastModifiedSync(ago20);
      for (final dir in [
        '${home.path}/.claude/projects',
        '${home.path}/.claude/projects/-proj',
      ]) {
        Process.runSync('touch', ['-d', '20 seconds ago', dir]);
      }
      (_, act) = makeReaders().snapshot([claude]);
      expect(act['claude']['working'], isTrue);
    },
  );
}
