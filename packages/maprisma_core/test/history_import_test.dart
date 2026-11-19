import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:maprisma_core/maprisma_core.dart';
import 'package:maprisma_core/src/adapters.dart';
import 'package:maprisma_core/src/ai_activity_log.dart';
import 'package:maprisma_core/src/history_import.dart';
import 'package:maprisma_core/src/history_topic.dart';
import 'package:maprisma_core/src/reports_generate.dart';
import 'package:maprisma_core/src/reports_sqlite.dart';
import 'package:maprisma_core/src/scan_files.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  late AppIdentity identity;
  late SettingsStore settings;
  late AiActivityLog log;
  final now = DateTime.utc(2026, 11, 19, 12);
  setUp(() {
    home = Directory.systemTemp.createTempSync('history-fixture-');
    identity = AppIdentity(environment: {'HOME': home.path});
    settings = SettingsStore(identity)
      ..update({
        'values': {'ai_activity_log': true},
      });
    log = AiActivityLog(ScanFiles(identity), settings);
  });
  tearDown(() => home.deleteSync(recursive: true));
  Adapter adapter(String form, {String command = 'fixture'}) => Adapter({
    'command': command,
    'name': 'Fixture $command',
    'sessions': {
      'activity_reader': form,
      'activity_dir': '${home.path}/sessions',
    },
  });
  File session(List<Map> rows, {String name = 'session.jsonl'}) {
    final f = File('${home.path}/sessions/$name')
      ..createSync(recursive: true)
      ..writeAsStringSync(rows.map(jsonEncode).join('\n'));
    f.setLastModifiedSync(now);
    return f;
  }

  HistoryImporter importer(String form) =>
      HistoryImporter(log, [adapter(form)], {'fixture'}, now: now);
  Map report() => log.report({}, now: now);
  Map user(String at, String text) => {
    'type': 'user',
    'timestamp': at,
    'cwd': '/work/project',
    'message': {'role': 'user', 'content': text},
  };
  Map assistant(String at, int input) => {
    'type': 'assistant',
    'timestamp': at,
    'message': {
      'id': at,
      'role': 'assistant',
      'model': 'fixture-model',
      'usage': {'input_tokens': input, 'output_tokens': 5},
      'content': [
        {
          'type': 'tool_use',
          'name': 'Edit',
          'input': {'file_path': '/work/project/test_file.dart'},
        },
      ],
    },
  };

  test('sanitization runs before truncation and covers secret classes', () {
    for (final secret in [
      'sk-abcdefghijklmnopqrstuvwxyz',
      'ghp_abcdefghijklmnopqrstuvwxyz',
      'github_pat_abcdefghijklmnopqrstuvwxyz',
      'glpat-abcdefghijklmnopqrstuvwxyz',
      'AIza0123456789abcdefghijklmnop',
      'AKIAABCDEFGHIJKLMNOP',
      'ASIAABCDEFGHIJKLMNOP',
      'xoxb-abcdefghijklmnop',
      'hf_abcdefghijklmnopqrstuvwxyz',
      'npm_abcdefghijklmnopqrstuvwxyz',
      'pypi-abcdefghijklmnopqrstuvwxyz',
      'Bearer ABCDEFGHIJK',
      'Basic ABCDEFGHIJK',
      'password=ABCDE',
      'token: ABCDE',
      'key="ABCDE"',
      'secret=ABCDE',
      'hello@example.com',
      'eyJabcdefgh.abcdefghijklmnop.abcdefghi',
      'a' * 40,
      '-----BEGIN PRIVATE KEY----- ABCDE -----END PRIVATE KEY-----',
    ]) {
      final clean = sanitizeTopic('Question $secret about a model')!;
      expect(clean, contains('…'), reason: secret);
      expect(clean, isNot(contains(secret)), reason: secret);
    }
    expect(
      sanitizeTopic('a' * 115 + ' sk-abcdefghijklmnopqrstuvwxyz'),
      isNot(contains('sk-')),
    );
    expect(
      sanitizeTopic('Read /home/person/work/notes.txt and ~/private/other.txt'),
      'Read notes.txt and other.txt',
    );
    expect(sanitizeTopic('first\u202esecond\nthird'), 'first second third');
    expect(sanitizeTopic('😀' * 121)!.runes.length, 120);
    final url = sanitizeTopic(
      'https://person:credential@example.test/path?token=secretvalue&ok=yes',
    )!;
    expect(url, isNot(contains('credential')));
    expect(url, isNot(contains('secretvalue')));
  });

  test(
    'Claude spans, running skip, subagents, topics, edits and reimport',
    () async {
      final file = session([
        user('2026-11-19T09:00:00Z', 'Fix tests with token=hidden'),
        assistant('2026-11-19T09:05:00Z', 10),
        user('2026-11-19T10:00:00Z', 'Second task'),
        assistant('2026-11-19T10:05:00Z', 20),
        user('2026-11-19T11:59:50Z', 'Still running'),
      ], name: 'project/main.jsonl');
      session([
        user('2026-11-19T09:00:00Z', 'subagent'),
      ], name: 'project/agent-child.jsonl');
      session([
        user('2026-11-19T09:00:00Z', 'subagent'),
      ], name: 'project/subagents/child.jsonl');
      final first = await importer('claude-files').run();
      expect(first['added'], 2);
      expect(first['sources'].single['sessions'], 1);
      final rows = report()['entries'] as List;
      expect(rows.every((r) => r['origin'] == 'history'), isTrue);
      expect(rows.last['topic'], 'Fix tests with …');
      expect(rows.last['files'], ['test_file.dart']);
      expect(rows.last['tokens_in'], 10);
      expect(rows.first['started_at'], '2026-11-19T10:00:00.000Z');
      expect((await importer('claude-files').run())['added'], 0);
      final lines = file
          .readAsLinesSync()
          .map((line) => jsonDecode(line) as Map)
          .toList();
      lines.insert(4, assistant('2026-11-19T10:10:00Z', 5));
      file.writeAsStringSync(lines.map(jsonEncode).join('\n'));
      file.setLastModifiedSync(now);
      expect((await importer('claude-files').run())['updated'], 1);
      expect(
        File('${identity.cacheDir}/claude-sessions.json').existsSync(),
        isFalse,
      );
    },
  );

  test('Codex cumulative deltas and subagent metadata', () async {
    Map meta(Object source) => {
      'type': 'session_meta',
      'payload': {'id': 'id/hashed', 'cwd': '/work/project', 'source': source},
    };
    Map tokens(String at, int n) => {
      'type': 'event_msg',
      'timestamp': at,
      'payload': {
        'type': 'token_count',
        'info': {
          'total_token_usage': {'input_tokens': n, 'output_tokens': n ~/ 2},
        },
      },
    };
    Map request(String at) => {
      'type': 'event_msg',
      'timestamp': at,
      'payload': {'type': 'user_message', 'message': 'Work'},
    };
    session([
      meta('cli'),
      request('2026-11-19T09:00:00Z'),
      tokens('2026-11-19T09:05:00Z', 100),
      request('2026-11-19T10:00:00Z'),
      tokens('2026-11-19T10:05:00Z', 140),
    ], name: 'a/rollout-main.jsonl');
    session([
      meta({'subagent': true}),
      request('2026-11-19T09:00:00Z'),
    ], name: 'a/rollout-child.jsonl');
    expect((await importer('codex-jsonl').run())['added'], 2);
    final rows = report()['entries'] as List;
    expect(rows.map((r) => r['tokens_in']), [40, 100]);
    expect(rows.first['session'], matches(RegExp(r'^[a-f0-9]{64}$')));
  });

  test('Pi files and disabled request topics', () async {
    settings.update({
      'values': {'ai_activity_import_topics': false},
    });
    session([
      {'type': 'session', 'id': 'pi-id', 'cwd': '/work/project'},
      {
        'type': 'message',
        'timestamp': '2026-11-19T09:00:00Z',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'Private task'},
          ],
        },
      },
      {
        'type': 'message',
        'timestamp': '2026-11-19T09:05:00Z',
        'message': {
          'role': 'assistant',
          'usage': {'input': 12, 'output': 3},
          'content': [
            {
              'type': 'toolCall',
              'name': 'write',
              'arguments': {'path': '/work/project/main.dart'},
            },
          ],
        },
      },
    ]);
    expect((await importer('pi-files').run())['added'], 1);
    expect(report()['entries'].single['topic'], 'editing');
    expect(report()['entries'].single['tokens_in'], 12);
  });

  test(
    'live and history preserve each other and supersede short and zero bursts',
    () async {
      log.observe({
        'agent:fixture',
      }, observedAt: DateTime.utc(2026, 11, 19, 9, 1));
      log.observe({}, observedAt: DateTime.utc(2026, 11, 19, 9, 2));
      session([
        user('2026-11-19T09:00:00Z', 'Imported'),
        assistant('2026-11-19T09:05:00Z', 10),
      ], name: 'project/main.jsonl');
      await importer('claude-files').run();
      expect(report()['entries'], hasLength(1));
      log.observe({
        'agent:fixture',
      }, observedAt: DateTime.utc(2026, 11, 19, 9, 3));
      log.observe({}, observedAt: DateTime.utc(2026, 11, 19, 9, 3));
      expect(report()['entries'], hasLength(1));
      log.observe({'agent:other'}, observedAt: DateTime.utc(2026, 11, 19, 10));
      log.observe({}, observedAt: DateTime.utc(2026, 11, 19, 10, 1));
      expect(report()['entries'], hasLength(2));
      expect((report()['entries'] as List).last['topic'], 'Imported');
    },
  );

  test(
    'observe buffers lock contention and groups midnight spans by start day',
    () {
      final io = log.files.posix;
      final dir = io.privateDirectory(log.directory);
      final fd = io.openAt(dir, '.lock', 2 | 0x40 | Posix.noFollow, 0x180);
      io.lockExclusive(fd);
      log.observe({
        'agent:fixture',
      }, observedAt: DateTime(2026, 11, 18, 23, 59));
      log.observe({}, observedAt: DateTime(2026, 11, 19, 0, 1));
      expect(report()['entries'], isEmpty);
      io.close(fd);
      io.close(dir);
      log.observe({}, observedAt: now);
      expect(report()['entries'], hasLength(1));
      expect(File('${log.directory}/2026-11-18.jsonl').existsSync(), isTrue);
      expect(report()['by_day'].single['key'], '2026-11-18');
    },
  );

  test('throttle, separate import lock, switches and error codes', () async {
    session([
      user('2026-11-19T09:00:00Z', 'Import'),
    ], name: 'project/main.jsonl');
    await importer('claude-files').run();
    expect(await importer('claude-files').run(auto: true), {
      'skipped': 'throttled',
    });
    expect((await importer('claude-files').run())['added'], 0);
    final io = log.files.posix,
        dir = log.files.posix.privateDirectory(log.directory);
    final fd = io.openAt(dir, '.import.lock', 2 | Posix.noFollow, 0x180);
    io.lockExclusive(fd);
    await expectLater(
      importer('claude-files').run(),
      throwsA(
        isA<ServiceError>().having((e) => e.code, 'code', 'import_running'),
      ),
    );
    io.close(fd);
    io.close(dir);
    settings.update({
      'values': {'ai_activity_import': false},
    });
    await expectLater(
      importer('claude-files').run(),
      throwsA(isA<ServiceError>().having((e) => e.code, 'code', 'import_off')),
    );
  });

  test(
    'missing corrupt unsupported and SQLite unavailable are explicit',
    () async {
      final missing = await importer('pi-files').run();
      expect(missing['sources'].single['status'], 'unavailable');
      session([
        {'invalid': true},
      ]);
      File('${home.path}/sessions/session.jsonl').writeAsStringSync('broken');
      expect(
        (await importer('pi-files').run())['sources'].single['status'],
        'corrupt',
      );
      expect(
        (await importer('other-form').run())['sources'].single['status'],
        'unsupported',
      );
      final db = ReportsSqlite('${home.path}/sessions/conversation.db');
      db.exec(
        'CREATE TABLE steps (idx INTEGER,step_type INTEGER,status INTEGER,step_format INTEGER,step_payload BLOB)',
      );
      db.close();
      expect(
        (await importer('trajectory-sqlite').run())['sources'].single['status'],
        'partial',
      );
    },
  );

  test(
    'generator suppresses previously imported request topics immediately',
    () async {
      session([
        user('2026-11-19T09:00:00Z', 'Sensitive previous topic'),
      ], name: 'project/main.jsonl');
      await importer('claude-files').run();
      settings.update({
        'values': {'ai_activity_import_topics': false},
      });
      String? prompt;
      await generateTopicReport(
        log,
        {},
        (value) async {
          prompt = value;
          return '{"title":"Report","topics":[{"name":"Work","summary":"Done","ids":[1]}],"text":"Done"}';
        },
        beforeRun: () {},
        language: 'en',
        now: now,
      );
      expect(prompt, isNot(contains('Sensitive previous topic')));
      expect(prompt, contains('"topic":null'));
    },
  );
  test(
    'large Codex files keep head metadata and establish a tail token baseline',
    () async {
      Map tokens(String at, int n) => {
        'type': 'event_msg',
        'timestamp': at,
        'payload': {
          'type': 'token_count',
          'info': {
            'total_token_usage': {'input_tokens': n, 'output_tokens': n ~/ 2},
          },
        },
      };
      final file = session([
        {
          'type': 'session_meta',
          'payload': {'id': 'large', 'cwd': '/work/project', 'source': 'cli'},
        },
      ], name: 'rollout-large.jsonl');
      file.writeAsStringSync('${file.readAsStringSync()}\n');
      final handle = file.openSync(mode: FileMode.append);
      handle.truncateSync(65 << 20);
      handle.setPositionSync(65 << 20);
      final tail = [
        tokens('2026-11-19T09:00:00Z', 1000),
        {
          'type': 'event_msg',
          'timestamp': '2026-11-19T10:00:00Z',
          'payload': {'type': 'user_message', 'message': 'Complete span'},
        },
        tokens('2026-11-19T10:05:00Z', 1040),
      ].map(jsonEncode).join('\n');
      handle.writeStringSync('\n$tail');
      handle.closeSync();
      file.setLastModifiedSync(now);
      final result = await importer('codex-jsonl').run();
      expect(result['added'], 1);
      expect(result['sources'].single['status'], 'partial');
      expect(report()['entries'].single['tokens_in'], 40);
      expect(report()['entries'].single['project'], 'project');
    },
  );

  test(
    'resumed sessions never import spans whose start lies before the window',
    () async {
      session([
        user('2026-10-01T09:00:00Z', 'Old task'),
        assistant('2026-10-01T09:05:00Z', 10),
        user('2026-11-19T09:00:00Z', 'New task'),
      ], name: 'project/main.jsonl');
      final result = await importer('claude-files').run(days: 1);
      expect(result['added'], 1);
      expect(result['skipped'], 1);
      expect(report()['entries'].single['topic'], 'New task');
      expect(File('${log.directory}/2026-10-01.jsonl').existsSync(), isFalse);
    },
  );

  test(
    'turning logging off while waiting for the day lock writes no history',
    () async {
      final io = log.files.posix,
          dir = log.files.posix.privateDirectory(log.directory);
      final fd = io.openAt(dir, '.lock', 2 | 0x40 | Posix.noFollow, 0x180);
      io.lockExclusive(fd);
      session([
        user('2026-11-19T09:00:00Z', 'Work'),
      ], name: 'project/main.jsonl');
      final pending = importer('claude-files').run();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      settings.update({
        'values': {'ai_activity_log': false},
      });
      io.close(fd);
      io.close(dir);
      await expectLater(
        pending,
        throwsA(isA<ServiceError>().having((e) => e.code, 'code', 'log_off')),
      );
      expect(report()['entries'], isEmpty);
      expect(File('${log.directory}/.import-state.json').existsSync(), isFalse);
    },
  );

  test(
    'history crossing midnight supersedes rows stored on its end day',
    () async {
      final start = DateTime(2026, 11, 18, 23, 50),
          end = DateTime(2026, 11, 19, 0, 10);
      log.observe({'agent:fixture'}, observedAt: DateTime(2026, 11, 19, 0, 1));
      log.observe({}, observedAt: DateTime(2026, 11, 19, 0, 2));
      session([
        user(start.toUtc().toIso8601String(), 'Over midnight'),
        assistant(end.toUtc().toIso8601String(), 10),
      ], name: 'project/main.jsonl');
      expect((await importer('claude-files').run())['added'], 1);
      expect(report()['entries'], hasLength(1));
      expect(report()['entries'].single['origin'], 'history');
    },
  );
  test(
    'a full day keeps existing entries and reports skipped imports as partial',
    () async {
      session([
        user('2026-11-19T09:00:00Z', 'Seed'),
      ], name: 'project/main.jsonl');
      await importer('claude-files').run();
      final original = Map<String, dynamic>.from(report()['entries'].single);
      final rows = <Map<String, dynamic>>[];
      final files = List.generate(30, (i) => 'file_${i}_${'z' * 55}');
      var bytes = 0;
      for (var i = 0; i < 3000; i++) {
        final at = DateTime.utc(2026, 11, 19, 0).add(Duration(milliseconds: i));
        final row = {
          ...original,
          'id': 'history:agent:fixture:seed:${at.microsecondsSinceEpoch}',
          'session': 'seed',
          'started_at': at.toIso8601String(),
          'ended_at': at.toIso8601String(),
          'duration_ms': 0,
          'files': files,
        };
        final size = utf8.encode(jsonEncode(row)).length + 1;
        if (bytes + size > (2 << 20)) break;
        rows.add(row);
        bytes += size;
      }
      // Keep filling with small rows until even a minimal new entry cannot fit.
      for (var i = 0; i < 20; i++) {
        final at = DateTime.utc(2026, 11, 19, 1).add(Duration(milliseconds: i));
        final row = {
          ...original,
          'id': 'history:agent:fixture:small:${at.microsecondsSinceEpoch}',
          'session': 'small',
          'started_at': at.toIso8601String(),
          'ended_at': at.toIso8601String(),
          'duration_ms': 0,
        };
        final size = utf8.encode(jsonEncode(row)).length + 1;
        if (bytes + size > (2 << 20)) break;
        rows.add(row);
        bytes += size;
      }
      final path = File('${log.directory}/${activityDay(now.toLocal())}.jsonl');
      path.writeAsStringSync('${rows.map(jsonEncode).join('\n')}\n');
      final result = await importer('claude-files').run();
      expect(result['added'], 0);
      expect(result['skipped'], 1);
      expect(result['sources'].single['status'], 'partial');
      expect(path.lengthSync(), lessThanOrEqualTo(2 << 20));
      final oldTime = DateTime.utc(2000);
      path.setLastModifiedSync(oldTime);
      log.observe({
        'agent:overflow',
      }, observedAt: now.subtract(const Duration(minutes: 10)));
      log.observe({}, observedAt: now.subtract(const Duration(minutes: 5)));
      log.observe({}, observedAt: now);
      expect(path.lastModifiedSync().toUtc(), oldTime);

      expect(
        log.report({}, now: now)['by_source'].single['count'],
        rows.length,
      );
    },
  );

  test(
    'an import writes only beneath ai-log and leaves agent files intact',
    () async {
      final file = session([
        user('2026-11-19T09:00:00Z', 'Read only'),
      ], name: 'project/main.jsonl');
      final bytes = file.readAsBytesSync();
      final before = home
          .listSync(recursive: true, followLinks: false)
          .map((f) => f.path)
          .toSet();
      await importer('claude-files').run();
      final added = home
          .listSync(recursive: true, followLinks: false)
          .map((f) => f.path)
          .toSet()
          .difference(before);
      expect(
        added.where(
          (path) =>
              path != identity.dataDir &&
              !path.startsWith(log.directory) &&
              !log.directory.startsWith('$path/'),
        ),
        isEmpty,
      );
      expect(file.readAsBytesSync(), bytes);
      expect(
        File('${identity.cacheDir}/claude-sessions.json').existsSync(),
        false,
      );
    },
  );
  test(
    'source metadata is readable with logging off and the constructor never imports',
    () {
      settings.update({
        'values': {'ai_activity_log': false},
      });
      final folder = Directory('${home.path}/.claude/projects/p')
        ..createSync(recursive: true);
      File('${folder.path}/session.jsonl').writeAsStringSync(
        jsonEncode(user('2026-11-19T09:00:00Z', 'Read only')),
      );
      final core = CoreService(
        environment: identity.environment,
        migrate: false,
      );
      final data = core.dispatch('activitylog.report', {});
      expect(
        (data['import_sources'] as List).any(
          (s) => s['source'] == 'agent:claude' && s['supported'] == true,
        ),
        isTrue,
      );
      expect(Directory(log.directory).existsSync(), false);
      expect(
        () => core.dispatch('activitylog.import', {}),
        throwsA(isA<ServiceError>().having((e) => e.code, 'code', 'log_off')),
      );
      expect(Directory(log.directory).existsSync(), false);
    },
  );

  test(
    'the real private worker imports and throttles across service restarts',
    () async {
      final workAt = DateTime.now().toUtc().subtract(const Duration(hours: 1));
      final folder = Directory('${home.path}/.claude/projects/p')
        ..createSync(recursive: true);
      final file = File('${folder.path}/session.jsonl')
        ..writeAsStringSync(
          [
            user(workAt.toIso8601String(), 'Worker span'),
            assistant(
              workAt.add(const Duration(minutes: 5)).toIso8601String(),
              10,
            ),
          ].map(jsonEncode).join('\n'),
        );
      file.setLastModifiedSync(DateTime.now());
      Future<Map<String, dynamic>> call(
        Process process,
        StreamIterator<String> lines,
        int id,
        String method,
        Map params,
      ) async {
        process.stdin.writeln(
          jsonEncode({
            'protocol': protocolVersion,
            'id': id,
            'method': method,
            'params': params,
          }),
        );
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 30)),
          true,
        );
        final value = jsonDecode(lines.current) as Map<String, dynamic>;
        expect(value.containsKey('error'), false, reason: value.toString());
        return value['result'] as Map<String, dynamic>;
      }

      final process = await Process.start(
        Platform.resolvedExecutable,
        [
          '--packages=${Directory.current.path}/.dart_tool/package_config.json',
          'bin/maprisma-core.dart',
        ],
        environment: identity.environment,
        includeParentEnvironment: false,
      );
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      addTearDown(() async {
        await process.stdin.close();
        await lines.cancel();
        process.kill();
        await process.exitCode;
      });
      final started = await call(process, lines, 1, 'activitylog.import', {
        'auto': true,
      });
      Map status = {};
      for (var i = 0; i < 200; i++) {
        status = await call(process, lines, i + 2, 'tasks.status', {
          'task': started['task'],
        });
        if (status['state'] != 'running') break;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(status['state'], 'done', reason: status.toString());
      expect(status['result']['added'], 1, reason: status.toString());
      final restarted = CoreService(
        environment: identity.environment,
        migrate: false,
      );
      expect(restarted.dispatch('activitylog.import', {'auto': true}), {
        'skipped': 'throttled',
      });
      expect(
        () => restarted.dispatch('activitylog.import', {'days': 8}),
        throwsA(
          isA<ServiceError>().having((e) => e.code, 'code', 'invalid_request'),
        ),
      );
    },
  );
  test(
    'the guarded SQLite loader distinguishes missing, corrupt and unavailable',
    () {
      final path = '${home.path}/conversation.db';
      expect(openHistoryDatabase(log.files, path).status, 'missing');
      final db = ReportsSqlite(path);
      db.exec('CREATE TABLE steps (idx INTEGER)');
      db.close();
      final loaded = openHistoryDatabase(log.files, path);
      expect(loaded.status, 'ok');
      loaded.database!.close();
      expect(
        openHistoryDatabase(
          log.files,
          path,
          open: (_) => throw ArgumentError('libsqlite3 unavailable'),
        ).status,
        'unavailable',
      );
      File('$path-wal').writeAsStringSync('broken');
      expect(openHistoryDatabase(log.files, path).status, 'corrupt');
    },
  );
  test('history SQLite interrupts an excessive query within its budget', () {
    final path = '${home.path}/budget.db';
    final fixture = ReportsSqlite(path);
    fixture.exec('CREATE TABLE fixture (id INTEGER)');
    fixture.close();
    final result = openHistoryDatabase(
      log.files,
      path,
      budget: const Duration(milliseconds: 5),
    );
    expect(result.status, 'ok');
    final watch = Stopwatch()..start();
    try {
      expect(
        () => result.database!.query(
          'WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000000) SELECT sum(x) FROM n',
        ),
        throwsA(isA<ServiceError>()),
      );
      expect(watch.elapsedMilliseconds, lessThan(2000));
    } finally {
      result.database!.close();
    }
  });
  test(
    'an active import never blocks observe and rejects a second importer',
    () async {
      session([
        user('2026-11-19T09:00:00Z', 'Imported work'),
        assistant('2026-11-19T09:05:00Z', 10),
      ], name: 'project/main.jsonl');
      final active = importer('claude-files').run();
      final second = importer('claude-files').run();
      log.observe({'agent:other'}, observedAt: DateTime.utc(2026, 11, 19, 10));
      log.observe({}, observedAt: DateTime.utc(2026, 11, 19, 10, 5));
      await expectLater(
        second,
        throwsA(
          isA<ServiceError>().having((e) => e.code, 'code', 'import_running'),
        ),
      );
      await active;
      expect(report()['entries'], hasLength(2));
      expect((report()['entries'] as List).map((r) => r['origin']).toSet(), {
        'live',
        'history',
      });
    },
  );

  test(
    'a leading tail fragment grows an existing span without replacing its token count',
    () async {
      session([
        {
          'type': 'session_meta',
          'payload': {'id': 'large', 'cwd': '/work/project', 'source': 'cli'},
        },
        {
          'type': 'event_msg',
          'timestamp': '2026-11-19T08:00:00Z',
          'payload': {'type': 'user_message', 'message': 'Original start'},
        },
        {
          'type': 'event_msg',
          'timestamp': '2026-11-19T08:05:00Z',
          'payload': {
            'type': 'token_count',
            'info': {
              'total_token_usage': {'input_tokens': 100, 'output_tokens': 50},
            },
          },
        },
      ], name: 'rollout-large.jsonl');
      await importer('codex-jsonl').run();
      final original = Map<String, dynamic>.from(report()['entries'].single);
      await log.mergeHistory({...original, 'ended_at': '2026-11-19T09:05:00Z'});
      final file = File('${home.path}/sessions/rollout-large.jsonl');
      file.writeAsStringSync(
        '${jsonEncode({
          'type': 'session_meta',
          'payload': {'id': 'large', 'cwd': '/work/project', 'source': 'cli'},
        })}\n',
      );
      final handle = file.openSync(mode: FileMode.append);
      handle.truncateSync(65 << 20);
      handle.setPositionSync(65 << 20);
      final tail = [
        {
          'type': 'event_msg',
          'timestamp': '2026-11-19T09:00:00Z',
          'payload': {
            'type': 'token_count',
            'info': {
              'total_token_usage': {'input_tokens': 1000, 'output_tokens': 500},
            },
          },
        },
        {
          'type': 'event_msg',
          'timestamp': '2026-11-19T09:10:00Z',
          'payload': {
            'type': 'token_count',
            'info': {
              'total_token_usage': {'input_tokens': 1020, 'output_tokens': 510},
            },
          },
        },
      ].map(jsonEncode).join('\n');
      handle.writeStringSync('\n$tail');
      handle.closeSync();
      file.setLastModifiedSync(now);
      final result = await importer('codex-jsonl').run();
      expect(result['added'], 0);
      expect(result['updated'], 1);
      expect(report()['entries'].single['id'], original['id']);
      expect(report()['entries'].single['tokens_in'], 100);
      expect(report()['entries'].single['started_at'], original['started_at']);
    },
  );
  test(
    'review: prefixed secrets and padded tokens are removed without damaging paths',
    () {
      for (final secret in [
        'DB_PASSWORD=mysecret123',
        'GITHUB_TOKEN=abc12345',
        'OPENAI_API_KEY=localtest1',
        'CLIENT_SECRET=foo12345',
        'accessToken=secret123',
        'clientSecret=mysecret',
        'dbPassword=hunter2',
        '${'a' * 30}==',
        '${'b' * 31}=',
      ]) {
        expect(
          sanitizeTopic('Fix $secret today'),
          'Fix … today',
          reason: secret,
        );
      }
      expect(
        sanitizeTopic('Fix src/lib/main.dart and read/write for Asian users'),
        'Fix src/lib/main.dart and read/write for Asian users',
      );
      final url = sanitizeTopic(
        'Check https://example.com/a/b?token=secretvalue&ok=yes',
      )!;
      expect(url, contains('https://example.com/a/b?'));
      expect(url, contains('ok=yes'));
      expect(url, isNot(contains('secretvalue')));

      for (final topic in [
        'https://app.example.com/cb#access_token=mysecret123',
        'https://example.com/hook?sk-abcdefghijklmnopqrstuvwxyz',
        'https://example.com/hook?0123456789abcdef0123456789abcdef',
        'https://example.com/hook?eyJabcdefgh.abcdefghijklmnop.abcdefghi',
        'https://example.com/hook?hello@example.com',
        'https://app.example.com/login?next=postgres://admin:mysecret123@localhost:5432/app',
        'https://app.example.com/#redis://:mysecret123@127.0.0.1:6379',
        'https://example.com/#sk-abcdefghijklmnopqrstuvwxyz',
        'https://example.com/?api-key=mysecret123',
        'postgres://admin:mysecret123@localhost:5432/app',
        'redis://:mysecret123@127.0.0.1:6379',
        'SESSION=0123456789abcdef0123456789abcdef',
        'AUTH=dGVzdDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2==',
      ]) {
        final clean = sanitizeTopic(topic)!;
        expect(clean, isNot(contains('mysecret123')));
        expect(clean, isNot(contains('eyJabcdefgh')));
        expect(clean, isNot(contains('hello@example.com')));
        expect(clean, isNot(contains('sk-abcdefghijklmnopqrstuvwxyz')));
        expect(clean, isNot(contains('0123456789abcdef0123456789abcdef')));
        expect(
          clean,
          isNot(contains('dGVzdDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2')),
        );
      }
      expect(
        sanitizeTopic(
          'https://docs.example.com/guides/getting/started/configuration',
        ),
        'https://docs.example.com/guides/getting/started/configuration',
      );
      expect(
        sanitizeTopic('claude-opus-4-1-20250805-thinking'),
        'claude-opus-4-1-20250805-thinking',
      );
    },
  );

  test(
    'review: imported labels are canonical before storage and reimport',
    () async {
      final turn = assistant('2026-11-19T09:05:00Z', 10);
      final message = turn['message'] as Map;
      message['model'] = 'claude-opus-4-1-20250805-thinking';
      message['content'] = [
        for (final name in [
          'auth_service.dart',
          'token.ts',
          'api_key.py',
          '.env',
          'my notes.txt',
          'allowed.dart',
        ])
          {
            'type': 'tool_use',
            'name': 'Edit',
            'input': {'file_path': '/work/$name'},
          },
      ];
      session([
        user('2026-11-19T09:00:00Z', 'Fix labels'),
        turn,
      ], name: 'project/main.jsonl');
      expect((await importer('claude-files').run())['added'], 1);
      expect(report()['entries'].single['files'], ['allowed.dart']);
      expect(
        report()['entries'].single['model'],
        'claude-opus-4-1-20250805-thinking',
      );
      final raw = File('${log.directory}/2026-11-19.jsonl').readAsStringSync();
      expect(raw, isNot(contains('auth_service.dart')));
      final again = await importer('claude-files').run();
      expect(again['added'], 0);
      expect(again['updated'], 0);
    },
  );

  test(
    'review: a partial merge preserves metadata and totals and unions edited files',
    () async {
      session([
        user('2026-11-19T09:00:00Z', 'Original request'),
        assistant('2026-11-19T09:05:00Z', 10000),
      ], name: 'project/main.jsonl');
      await importer('claude-files').run();
      final original = Map<String, dynamic>.from(report()['entries'].single);
      final result = await log.mergeHistory(
        {
          ...original,
          'started_at': '2026-11-19T09:01:00Z',
          'ended_at': '2026-11-19T09:10:00Z',
          'topic': 'Later request',
          'model': null,
          'project': null,
          'tokens_in': 50,
          'files': ['other.dart'],
        },
        leadingPartial: true,
        now: now,
      );
      expect(result.status, 'updated');
      final row = report()['entries'].single;
      for (final key in [
        'id',
        'started_at',
        'topic',
        'model',
        'project',
        'tokens_in',
      ]) {
        expect(row[key], original[key], reason: key);
      }
      expect(row['files'], ['test_file.dart', 'other.dart']);
      expect(
        (await log.mergeHistory({
          ...row,
          'tokens_in': 1,
          'files': ['third.dart'],
        })).status,
        'updated',
      );
      expect(report()['entries'].single['tokens_in'], 10000);
      expect(report()['entries'].single['files'], hasLength(3));
    },
  );

  test('review: Codex context belongs to the next span', () async {
    Map context(String at, String model) => {
      'type': 'turn_context',
      'timestamp': at,
      'payload': {'model': model},
    };
    Map request(String at) => {
      'type': 'event_msg',
      'timestamp': at,
      'payload': {'type': 'user_message', 'message': 'Work'},
    };
    session([
      context('2026-11-19T09:00:00Z', 'first-model'),
      request('2026-11-19T09:00:01Z'),
      context('2026-11-19T10:00:00Z', 'second-model'),
      request('2026-11-19T10:00:01Z'),
    ], name: 'rollout-context.jsonl');
    await importer('codex-jsonl').run();
    final rows = report()['entries'] as List;
    expect(rows.last['model'], 'first-model');
    expect(rows.first['model'], 'second-model');
  });

  test('review: malformed trajectory steps keep a partial timing span', () async {
    final file = File('${home.path}/sessions/conversation.db')
      ..createSync(recursive: true);
    final db = ReportsSqlite(file.path);
    db.exec(
      'CREATE TABLE steps (idx INTEGER, step_type INTEGER, status INTEGER, step_format INTEGER, step_payload BLOB)',
    );
    db.exec("INSERT INTO steps VALUES (0,14,3,0,X'0F'),(1,132,3,0,X'0F')");
    db.close();
    final later = DateTime.now().add(const Duration(minutes: 10));
    final result = await HistoryImporter(
      log,
      [adapter('trajectory-sqlite')],
      {'fixture'},
      now: later,
    ).run();
    expect(result['added'], 1);
    expect(result['sources'].single['status'], 'partial');
  });
  test(
    'review: an oversized first line keeps valid resumed tail spans partial',
    () async {
      final file = session([
        user('2026-11-19T08:00:00Z', 'x' * 70000),
      ], name: 'project/main.jsonl');
      final handle = file.openSync(mode: FileMode.append);
      handle.truncateSync(65 << 20);
      handle.setPositionSync(65 << 20);
      handle.writeStringSync(
        '\n${[assistant('2026-11-19T09:00:00Z', 10), user('2026-11-19T10:00:00Z', 'Resumed request'), assistant('2026-11-19T10:05:00Z', 20)].map(jsonEncode).join('\n')}',
      );
      handle.closeSync();
      file.setLastModifiedSync(now);
      final result = await importer('claude-files').run();
      expect(result['added'], 1);
      expect(result['sources'].single['status'], 'partial');
      expect(report()['entries'].single['topic'], 'Resumed request');
      file.renameSync('${home.path}/sessions/rollout-large.jsonl');
      final codex = await importer('codex-jsonl').run();
      expect(codex['added'], 0);
      expect(codex['sources'].single['status'], 'partial');
    },
  );
  test(
    'topic redaction stays bounded on long identifiers and unfinished PEM',
    () {
      final clock = Stopwatch()..start();
      expect(sanitizeTopic('word-' * 100000)!.runes.length, 120);
      expect(
        sanitizeTopic('-----BEGIN PRIVATE KEY----- ${'word-' * 100000}'),
        '…',
      );
      expect(clock.elapsedMilliseconds, lessThan(2000));
    },
  );
  test(
    'observe finds the previous calendar day after the Berlin spring DST change',
    () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          '--packages=${Directory.current.path}/.dart_tool/package_config.json',
          'test/support/activity_log_dst.dart',
          home.path,
        ],
        environment: {...Platform.environment, 'TZ': 'Europe/Berlin'},
        includeParentEnvironment: false,
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(jsonDecode(result.stdout as String), {
        'superseded': true,
        'entries': 1,
      });
    },
  );

  for (final includeCorrupt in [false, true]) {
    test(
      'source errors cannot be downgraded by older files, corrupt=$includeCorrupt',
      () async {
        final root = Directory('${home.path}/sessions')..createSync();
        if (includeCorrupt) {
          File('${root.path}/newest.db')
            ..writeAsStringSync('broken SQLite file')
            ..setLastModifiedSync(now);
        }
        final unavailable = ReportsSqlite('${root.path}/unavailable.db');
        unavailable.exec('CREATE TABLE unrelated (value INTEGER)');
        unavailable.close();
        File(
          '${root.path}/unavailable.db',
        ).setLastModifiedSync(now.subtract(const Duration(minutes: 1)));
        final partial = ReportsSqlite('${root.path}/partial.db');
        partial.exec(
          'CREATE TABLE steps (idx INTEGER, step_type INTEGER, status INTEGER, step_format INTEGER, step_payload BLOB)',
        );
        partial.close();
        File(
          '${root.path}/partial.db',
        ).setLastModifiedSync(now.subtract(const Duration(minutes: 2)));
        final result = await importer('trajectory-sqlite').run();
        expect(
          result['sources'].single['status'],
          includeCorrupt ? 'corrupt' : 'unavailable',
        );
      },
    );
  }

  test(
    'invalid numeric timestamps skip only their records and mark the file partial',
    () async {
      session([
        user('2026-11-19T09:00:00Z', 'Valid request'),
        for (final bad in [1763553600000000000, 1e30, -1, 'not a timestamp'])
          {
            ...user('2026-11-19T09:01:00Z', 'Invalid request'),
            'timestamp': bad,
          },
        assistant('2026-11-19T09:05:00Z', 10),
      ], name: 'project/main.jsonl');
      final result = await importer('claude-files').run();
      expect(result['added'], 1);
      expect(result['sources'].single['status'], 'partial');
      final row = report()['entries'].single;
      expect(row['topic'], 'Valid request');
      expect(row['tokens_in'], 10);
      expect(row['ended_at'], '2026-11-19T09:05:00.000Z');
    },
  );

  for (final alreadySuperseded in [false, true]) {
    test(
      'a growing midnight span leaves unchanged end-day files untouched, superseded=$alreadySuperseded',
      () async {
        final source = alreadySuperseded ? 'agent:fixture' : 'agent:other';
        log.observe({source}, observedAt: DateTime(2026, 11, 19, 0, 1));
        log.observe({}, observedAt: DateTime(2026, 11, 19, 0, 2));
        final start = DateTime(2026, 11, 18, 23, 50),
            end = DateTime(2026, 11, 19, 0, 10);
        final file = session([
          user(start.toUtc().toIso8601String(), 'Midnight work'),
          assistant(end.toUtc().toIso8601String(), 10),
        ], name: 'project/main.jsonl');
        await importer('claude-files').run();
        final other = File('${log.directory}/2026-11-19.jsonl');
        final contents = other.readAsStringSync();
        expect(
          jsonDecode(contents.trim())['superseded_by'] != null,
          alreadySuperseded,
        );
        final fixedTime = DateTime.utc(2000);
        other.setLastModifiedSync(fixedTime);
        file.writeAsStringSync(
          '\n${jsonEncode(assistant(end.add(const Duration(minutes: 1)).toUtc().toIso8601String(), 5))}',
          mode: FileMode.append,
        );
        file.setLastModifiedSync(now);
        expect((await importer('claude-files').run())['updated'], 1);
        expect(other.readAsStringSync(), contents);
        expect(other.lastModifiedSync().toUtc(), fixedTime);
      },
    );
  }
}
