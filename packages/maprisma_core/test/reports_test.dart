import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:maprisma_core/maprisma_core.dart';
import 'package:maprisma_core/src/ai_activity_log.dart';
import 'package:maprisma_core/src/reports_generate.dart';
import 'package:maprisma_core/src/reports_library.dart';
import 'package:maprisma_core/src/reports_sqlite.dart';
import 'package:maprisma_core/src/scan_files.dart';
import 'package:test/test.dart';

final _draft = <String, dynamic>{
  'title': 'Résumé de la journée',
  'from_day': '2026-11-19',
  'through_day': '2026-11-19',
  'filters': {'project': 'fixture'},
  'helper': 'local-helper',
  'generated_at': '2026-11-19T10:00:00Z',
  'entry_count': 1,
  'total_entries': 1,
  'capped': false,
  'topics': [
    {'name': 'Édition 100%', 'summary': 'Fichiers mis à jour.', 'spans': 1},
  ],
  'text': 'Préparation terminée.',
};

Matcher _code(String code) =>
    throwsA(isA<ServiceError>().having((e) => e.code, 'code', code));

void main() {
  late Directory home;
  late AppIdentity identity;
  late String root;
  late String path;
  late ReportsLibrary library;

  setUp(() {
    home = Directory.systemTemp.createTempSync('maprisma-reports-');
    identity = AppIdentity(environment: {'HOME': home.path});
    root = identity.dataDir;
    library = ReportsLibrary(root);
    path = '${library.directory}/reports.db';
  });
  tearDown(() => home.deleteSync(recursive: true));

  test('library CRUD, literal search, Unicode and private modes', () {
    expect(library.list('', null)['reports'], isEmpty);
    final report = library.save(_draft, 'Küche', 'Notatka_1');
    final id = report['id'] as int;
    expect(report['text'], 'Préparation terminée.');
    expect(library.get(id), report);
    expect(library.list('%', null)['reports'], hasLength(1));
    expect(library.list('_', null)['reports'], hasLength(1));
    expect(library.list(r'\', null)['reports'], isEmpty);
    expect(library.list('mis à jour', null)['reports'], isEmpty);
    expect(library.update(id, title: 'Rapport', note: '')['note'], isNull);
    expect(library.list('_', null)['reports'], isEmpty);
    expect(File(path).statSync().mode & 0x1ff, 0x180);
    expect(Directory(library.directory).statSync().mode & 0x1ff, 0x1c0);
    expect(library.delete(id), isTrue);
    expect(() => library.get(id), _code('report_not_found'));
    expect(() => library.delete(id), _code('report_not_found'));
  });

  test('cursor remains stable when a newer report is saved', () {
    for (var i = 0; i < 52; i++) {
      library.save(_draft, 'Report $i', null);
    }
    final first = library.list('', null);
    expect(first['reports'], hasLength(50));
    library.save(_draft, 'New report', null);
    final second = library.list('', first['next_cursor'] as int);
    expect((second['reports'] as List).map((r) => r['id']), [2, 1]);
    expect(second['next_cursor'], isNull);
  });

  test('corruption moves aside the original with WAL and SHM', () {
    Directory(library.directory).createSync(recursive: true);
    File(path).writeAsStringSync('bad database');
    for (final extension in ['-wal', '-shm']) {
      File('$path$extension').writeAsStringSync(extension);
    }
    expect(() => library.list('', null), _code('reports_db_corrupt'));
    final moved = library.moveAside();
    expect(File(moved).readAsStringSync(), 'bad database');
    final suffix = moved.substring(path.length);
    for (final extension in ['-wal', '-shm']) {
      expect(File('$path$extension$suffix').readAsStringSync(), extension);
      expect(File('$path$extension').existsSync(), isFalse);
    }
    expect(library.list('', null)['reports'], isEmpty);
  });

  test('an external SQLite writer yields a typed busy refusal', () {
    library.save(_draft, 'Report', null);
    final writer = ReportsSqlite(path)..exec('BEGIN IMMEDIATE');
    try {
      expect(
        () => library.save(_draft, 'Locked', null),
        _code('reports_db_locked'),
      );
    } finally {
      writer.close();
    }
  });

  test('a newer WAL-mode library is read-only and creates no files', () {
    final report = library.save(_draft, 'Newer library', null);
    final db = ReportsSqlite(path);
    db.exec('PRAGMA user_version=3');
    db.close();
    final before = Directory(
      library.directory,
    ).listSync().map((f) => f.path).toSet();
    expect(before, {path});
    expect(library.list('', null)['read_only'], isTrue);
    expect(library.list('', null)['schema_version'], 3);
    expect(library.get(report['id'] as int), report);
    expect(
      () => library.delete(report['id'] as int),
      _code('reports_db_read_only'),
    );
    expect(
      Directory(library.directory).listSync().map((f) => f.path).toSet(),
      before,
    );
  });

  test('a newer schema in a live WAL can be read without its SHM', () {
    library.save(_draft, 'Original', null);
    final db = ReportsSqlite(path);
    try {
      db.exec('PRAGMA user_version=3');
      final copy = ReportsLibrary('$root/copy');
      Directory(copy.directory).createSync(recursive: true);
      final target = '${copy.directory}/reports.db';
      File(path).copySync(target);
      File('$path-wal').copySync('$target-wal');
      final result = copy.list('', null);
      expect(result['schema_version'], 3);
      expect(result['read_only'], isTrue);
      expect(result['reports'], hasLength(1));
      expect(File('$target-shm').existsSync(), isFalse);
    } finally {
      db.close();
    }
  });

  test('two concurrent writers each save one report', () async {
    final directory = root;
    final results = await Future.wait([
      Isolate.run(() => ReportsLibrary(directory).save(_draft, 'One', null)),
      Isolate.run(() => ReportsLibrary(directory).save(_draft, 'Two', null)),
    ]);
    expect(results.map((r) => r['id']).toSet(), {1, 2});
    expect(library.list('', null)['reports'], hasLength(2));
  });

  test('refuses symlinks in the main file, sidecars and library directory', () {
    Directory(library.directory).createSync(recursive: true);
    final outside = File('${home.path}/outside')..writeAsStringSync('original');
    for (final name in [path, '$path-wal', '$path-shm']) {
      final link = Link(name)..createSync(outside.path);
      try {
        expect(() => library.list('', null), _code('reports_db_unavailable'));
        expect(() => library.moveAside(), _code('reports_db_unavailable'));
        expect(outside.readAsStringSync(), 'original');
      } finally {
        link.deleteSync();
      }
    }
    Directory(library.directory).deleteSync();
    Link(library.directory).createSync(home.path);
    expect(() => library.list('', null), _code('reports_db_unavailable'));
  });

  test(
    'the worker input stays sanitized and metrics are computed from entry ids',
    () async {
      final settings = SettingsStore(identity)
        ..update({
          'values': {'ai_activity_log': true},
        });
      final log = AiActivityLog(ScanFiles(identity), settings);
      final started = DateTime.now().subtract(const Duration(minutes: 4));
      log.observe(
        {'agent:fixture'},
        observedAt: started,
        workingDirectories: {'agent:fixture': '/private/parent/project'},
      );
      log.observe({}, observedAt: started.add(const Duration(minutes: 1)));
      var calls = 0, gates = 0;
      final report = await generateTopicReport(
        log,
        reportParameters({
          'helper': 'local-helper',
          'focus': '<ignore>\u0000',
          'project': 'project',
        }),
        (prompt) async {
          expect(utf8.encode(prompt).length, lessThan(200 * 1024));
          expect(prompt, contains('"id":1'));
          expect(prompt, contains('"project":"project"'));
          expect(prompt, isNot(contains('/private/parent')));
          expect(prompt, isNot(contains('<ignore>')));
          if (++calls == 1) return 'invalid';
          return jsonEncode({
            'title': 'Report',
            'topics': [
              {
                'name': 'Activity',
                'summary': 'One span.',
                'ids': [1, 1, 99],
                'spans': 99,
              },
            ],
            'text': 'Done.',
          });
        },
        beforeRun: () => gates++,
        language: 'en',
      );
      expect(gates, 2);
      expect(report['entry_count'], 1);
      expect(report['total_entries'], 1);
      expect(report['topics'].single, {
        'name': 'Activity',
        'summary': 'One span.',
        'sources': ['agent:fixture'],
        'projects': ['project'],
        'spans': 1,
        'elapsed_ms': 60000,
        'tokens_in': null,
        'tokens_out': null,
        'usage_unknown': 1,
      });
      final filters = {'helper': 'local-helper'};
      await expectLater(
        generateTopicReport(
          log,
          filters,
          (_) async => '{}',
          beforeRun: () {},
          language: 'en',
        ),
        _code('bad_answer'),
      );
      await expectLater(
        generateTopicReport(
          log,
          filters,
          (_) async => throw StateError('should never call helper'),
          beforeRun: () => throw ServiceError('online_blocked'),
          language: 'en',
        ),
        _code('online_blocked'),
      );
      await expectLater(
        generateTopicReport(
          log,
          {...filters, 'source': 'other'},
          (_) async => throw StateError('should never call helper'),
          beforeRun: () {},
          language: 'en',
        ),
        _code('no_entries'),
      );
      expect(File(path).existsSync(), isFalse);
    },
  );

  test('only a boolean opt-in allows reports online', () {
    expect(reportRules(identity), (allowed: false, broken: false));
    final dir = Directory('${home.path}/.config/maprisma-ai')
      ..createSync(recursive: true);
    final rules = File('${dir.path}/settings.json');
    for (final (value, result) in [
      ('{}', (allowed: false, broken: false)),
      ('{"ask_ai":{"data":[]}}', (allowed: false, broken: true)),
      (
        '{"ask_ai":{"data":{"maprisma.activity_log_online":"true"}}}',
        (allowed: false, broken: true),
      ),
      (
        '{"ask_ai":{"level":"answers","data":{"maprisma.activity_log_online":true}}}',
        (allowed: true, broken: false),
      ),
      (' ' * (64 * 1024 + 1), (allowed: false, broken: true)),
    ]) {
      rules.writeAsStringSync(value);
      expect(reportRules(identity), result);
    }
  });

  test(
    'the private worker checks current permission and keeps a large draft by handle',
    () async {
      final config = Directory('${home.path}/.config/maprisma-ai')
        ..createSync(recursive: true);
      final rule = File('${config.path}/settings.json');
      void online(bool value) {
        rule.writeAsStringSync(
          jsonEncode({
            'ask_ai': {
              'data': {'maprisma.activity_log_online': value},
            },
          }),
        );
      }

      final bin = Directory('${home.path}/bin')..createSync();
      final claude = File('${bin.path}/claude')
        ..writeAsStringSync(r'''#!/bin/sh
if [ "$1" = "--version" ]; then
  printf '%s\n' '2.0.0 (Claude Code)'
  exit 0
fi
printf '%s\n' "$@" > "$HOME/report-argv"
cat > "$HOME/report-prompt"
cat "$HOME/answer.json"
''');
      File('${home.path}/.claude.json').writeAsStringSync('{}');
      final answer = File('${home.path}/answer.json')
        ..writeAsStringSync(
          jsonEncode({
            'title': 'Fixture report',
            'topics': [
              {
                'name': 'Fixture topic',
                'summary': 'One entry',
                'ids': [1, 1],
              },
            ],
            'text': 'x' * (70 * 1024),
          }),
        );
      final settings = SettingsStore(identity)
        ..update({
          'values': {'ai_activity_log': true},
        });
      final log = AiActivityLog(ScanFiles(identity), settings);
      void record() {
        final at = DateTime.now();
        log.observe({
          'agent:fixture',
        }, observedAt: at.subtract(const Duration(seconds: 20)));
        log.observe({}, observedAt: at);
      }

      record();
      final worker = File('${bin.path}/report-worker')
        ..writeAsStringSync(r'''#!/bin/sh
while [ ! -f "$HOME/release-worker" ]; do sleep 0.02; done
exec "$TEST_DART" --disable-dart-dev --packages=.dart_tool/package_config.json bin/maprisma-core.dart "$@"
''');
      for (final file in [claude, worker]) {
        Posix().chmodPath(file.path, 0x1c0);
      }
      final marker = File('${home.path}/release-worker');
      final environment = {
        ...identity.environment,
        'XDG_CONFIG_HOME': '${home.path}/.config',
        'XDG_DATA_HOME': '${home.path}/.local/share',
        'XDG_CACHE_HOME': '${home.path}/.cache',
        'XDG_STATE_HOME': '${home.path}/.local/state',
        'PATH': '${bin.path}:/usr/bin:/bin',
        'MAPRISMA_DESKTOP': 'generic',
        'MAPRISMA_CORE_WORKER': worker.path,
        'TEST_DART': Platform.resolvedExecutable,
      };
      final process = await Process.start(
        Platform.resolvedExecutable,
        [
          '--disable-dart-dev',
          '--packages=.dart_tool/package_config.json',
          'bin/maprisma-core.dart',
        ],
        environment: environment,
        includeParentEnvironment: false,
      );
      final replies = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = process.stderr.transform(utf8.decoder).join();
      var request = 0;
      Future<Map> call(
        String method, [
        Map<String, dynamic> params = const {},
      ]) async {
        process.stdin.writeln(
          jsonEncode({
            'id': ++request,
            'protocol': protocolVersion,
            'method': method,
            'params': params,
          }),
        );
        await process.stdin.flush();
        expect(
          await replies.moveNext().timeout(const Duration(seconds: 12)),
          isTrue,
        );
        final result = jsonDecode(replies.current) as Map;
        expect(result['id'], request);
        return result;
      }

      Future<Map> generate() async =>
          call('reports.generate', {'helper': 'claude'});

      Future<Map> finish(String task) async {
        for (var i = 0; i < 200; i++) {
          final reply =
              (await call('tasks.status', {'task': task}))['result'] as Map;
          if (reply['state'] == 'done') return reply['result'] as Map;
          expect(reply['state'], 'running', reason: '$reply');
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        throw StateError('Report did not complete');
      }

      try {
        online(false);
        expect((await generate())['error']['code'], 'online_blocked');
        online(true);
        final helpers =
            (await call('reports.helpers'))['result']['helpers'] as List;
        expect(helpers.map((h) => h['command']), contains('claude'));
        final revoked = (await generate())['result']['task'] as String;
        online(false);
        marker.createSync();
        expect(await finish(revoked), {
          'error': 'online_blocked',
          'code': 'online_blocked',
        });
        expect(File('${home.path}/report-prompt').existsSync(), isFalse);

        online(true);
        marker.deleteSync();
        final vanished = (await generate())['result']['task'] as String;
        Directory('${identity.dataDir}/ai-log').deleteSync(recursive: true);
        marker.createSync();
        expect(await finish(vanished), {
          'error': 'no_entries',
          'code': 'no_entries',
        });
        expect(File('${home.path}/report-prompt').existsSync(), isFalse);

        record();
        final generated = await finish(
          (await generate())['result']['task'] as String,
        );
        expect(generated['draft']['text'], hasLength(70 * 1024));
        expect(generated['draft']['topics'][0]['spans'], 1);
        final argv = File('${home.path}/report-argv').readAsLinesSync();
        expect(argv, containsAll(['-p', '--tools', '--strict-mcp-config']));
        expect(argv[argv.indexOf('--tools') + 1], isEmpty);
        expect(
          File('${home.path}/report-prompt').readAsStringSync(),
          contains('"id":1'),
        );
        final saved =
            (await call('reports.save', {
                  'draft_id': generated['draft_id'] as String,
                  'title': 'Saved fixture',
                }))['result']['report']
                as Map;
        expect(saved['text'], hasLength(70 * 1024));
        expect(saved['title'], 'Saved fixture');

        answer.writeAsStringSync('{}');
        final rejected = await finish(
          (await generate())['result']['task'] as String,
        );
        expect(rejected, {'error': 'bad_answer', 'code': 'bad_answer'});
        expect((await call('reports.list'))['result']['reports'], hasLength(1));
      } finally {
        marker.createSync();
        await process.stdin.close();
        await replies.cancel();
        expect(await process.exitCode, 0, reason: await errors);
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'CLI exports all formats and history MCP exposes only report reads',
    () async {
      final report = library.save(_draft, 'CLI report', null);
      final service = CoreService(
        environment: identity.environment,
        migrate: false,
      );
      addTearDown(service.dispose);
      expect(
        () => service.dispatch('reports.generate', {'helper': 'unknown'}),
        _code('no_helper'),
      );
      expect(
        () => service.dispatch('reports.save', {
          'draft_id': 'unknown',
          'title': 'Invalid',
        }),
        _code('draft_unknown'),
      );
      final env = {
        ...Platform.environment,
        'HOME': identity.home,
        'XDG_DATA_HOME': '${identity.home}/.local/share',
      };
      final args = [
        '--disable-dart-dev',
        '--packages=.dart_tool/package_config.json',
        'bin/maprisma-core.dart',
      ];
      Future<ProcessResult> cli(List<String> rest) async {
        final result = await Process.run(Platform.resolvedExecutable, [
          ...args,
          'reports',
          ...rest,
        ], environment: env);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return result;
      }

      final id = '${report['id']}';
      expect((await cli(['list'])).stdout, contains('CLI report'));
      expect((await cli(['show', id])).stdout, contains('Édition'));
      expect(
        (await cli(['export', id, '--format', 'text'])).stdout,
        contains('CLI report'),
      );
      expect(
        (await cli(['export', id, '--format', 'markdown'])).stdout,
        startsWith('# CLI report'),
      );
      expect(
        jsonDecode(
          (await cli(['export', id, '--format', 'json'])).stdout as String,
        ),
        report,
      );

      final mcp = await Process.start(Platform.resolvedExecutable, [
        ...args,
        'activity-log-mcp',
      ], environment: env);
      final lines = mcp.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .toList();
      final errors = mcp.stderr.transform(utf8.decoder).join();
      for (final (method, params) in [
        ('tools/list', <String, Object>{}),
        (
          'tools/call',
          {
            'name': 'reports_list',
            'arguments': {'query': 'CLI'},
          },
        ),
        (
          'tools/call',
          {
            'name': 'reports_get',
            'arguments': {'id': report['id']},
          },
        ),
        (
          'tools/call',
          {
            'name': 'reports_get',
            'arguments': {'id': 999},
          },
        ),
      ]) {
        mcp.stdin.writeln(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': method,
            'params': params,
          }),
        );
      }
      await mcp.stdin.close();
      expect(await mcp.exitCode, 0, reason: await errors);
      final replies = (await lines)
          .map((line) => jsonDecode(line)['result'])
          .toList();
      expect((replies[0]['tools'] as List).map((tool) => tool['name']), [
        'activity_log_report',
        'reports_list',
        'reports_get',
      ]);
      expect(replies[1]['isError'], isFalse);
      expect(jsonDecode(replies[2]['content'][0]['text'])['report'], report);
      expect(replies[3]['isError'], isTrue);
      expect(
        jsonDecode(replies[3]['content'][0]['text'])['code'],
        'report_not_found',
      );
    },
  );
}
