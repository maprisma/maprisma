import 'dart:convert';
import 'dart:io';
import 'package:maprisma_core/src/core_jobs.dart';
import 'package:maprisma_core/src/core_tasks.dart';
import 'package:maprisma_core/src/model_downloads.dart' show DownloadError;
import 'package:maprisma_core/src/plan_worker.dart' show withRetries;
import 'package:maprisma_core/src/posix_ffi.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String path;
  final posix = Posix();
  setUp(() {
    dir = Directory.systemTemp.createTempSync('maprisma-jobs-');
    path = '${dir.path}/state/maprisma/jobs.json';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  CoreTasks tasks() => CoreTasks(const ['false']);

  test(
    'a running download is kept, and listed as interrupted after a restart',
    () {
      final running = tasks();
      running.items['t1'] = CoreTask('models.download', null)..fraction = 0.42;
      running.items['t2'] = CoreTask('models.search', null);
      final jobs = CoreJobs(path, running, posix);
      jobs.record('t1', 'models.download', {
        'key': 'llamacpp',
        'repo': 'org/repo',
        'file': 'm.gguf',
        'size': 10,
      }, 'm.gguf · llama.cpp');
      jobs.record('t2', 'models.search', {'query': 'x'}, 'not durable');
      expect(File(path).statSync().mode & 0x1ff, 0x180);
      expect(jobs.list().single['state'], 'running');
      expect(jobs.list().single['fraction'], 0.42);

      // The app ended: a new core lists it as interrupted.
      final again = CoreJobs(path, tasks(), posix);
      final listed = again.list().single;
      expect(listed['state'], 'interrupted');
      expect(listed['title'], 'm.gguf · llama.cpp');
      expect(again.take(listed['id'])['params'], {
        'key': 'llamacpp',
        'repo': 'org/repo',
        'file': 'm.gguf',
        'size': 10,
      });

      // Continued: the new task replaces it; when that ends, the file goes.
      final later = tasks();
      later.items['t9'] = CoreTask('models.download', null);
      final third = CoreJobs(path, later, posix);
      third.record(
        't9',
        'models.download',
        third.take(listed['id'])['params'] as Map<String, dynamic>,
        'm.gguf · llama.cpp',
        replaces: listed['id'] as String,
      );
      expect(third.list().map((j) => j['state']), ['running']);
      later.items['t9']!.state = 'done';
      expect(third.list(), isEmpty);
      expect(File(path).existsSync(), isFalse);
    },
  );

  test('discard forgets an interrupted job; odd files are not trusted', () {
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode([
          {
            'id': 'aaaaaaaaaaaa',
            'operation': 'models.pull',
            'params': {'key': 'ollama', 'name': 'gemma'},
            'title': 'gemma · Ollama',
            'fraction': 7,
          },
          {
            'id': 'bbbbbbbbbbbb',
            'operation': 'system.move_apply',
            'params': {},
            'title': 'not a download',
          },
          {
            'id': '../x',
            'operation': 'models.pull',
            'params': {},
            'title': 't',
          },
          'junk',
        ]),
      );
    final jobs = CoreJobs(path, tasks(), posix);
    final listed = jobs.list();
    expect(listed.map((j) => j['id']), ['aaaaaaaaaaaa']);
    expect(listed.single['fraction'], 1.0);
    expect(() => jobs.discard('bbbbbbbbbbbb'), throwsFormatException);
    jobs.discard('aaaaaaaaaaaa');
    expect(jobs.list(), isEmpty);
    expect(File(path).existsSync(), isFalse);

    Link(path).createSync('/etc/hostname');
    expect(CoreJobs(path, tasks(), posix).list(), isEmpty);
  });

  test('one download per .part file', () {
    final part = '${dir.path}/m.gguf.part';
    final a = posix.openAt(-100, part, 0x2 | 0x40, 0x1a4);
    final b = posix.openAt(-100, part, 0x2);
    expect(posix.tryLockExclusive(a), isTrue);
    expect(posix.tryLockExclusive(b), isFalse);
    posix.close(a);
    expect(posix.tryLockExclusive(b), isTrue);
    posix.close(b);
  });

  test('a broken-off download is tried again; a refusal is not', () async {
    var calls = 0;
    final waits = <int>[];
    final result = await withRetries(
      'models.download',
      () async {
        calls++;
        if (calls < 3) throw DownloadError('download failed: reset');
        return 'ok';
      },
      waits.add,
      sleep: (_) async {},
    );
    expect(result, 'ok');
    expect(calls, 3);
    expect(waits.first, 5);
    expect(waits.where((w) => w == 15), isNotEmpty);
    calls = 0;
    await expectLater(
      withRetries(
        'models.download',
        () async {
          calls++;
          throw StateError('the download is larger than announced');
        },
        waits.add,
        sleep: (_) async {},
      ),
      throwsStateError,
    );
    expect(calls, 1);
    calls = 0;
    await expectLater(
      withRetries(
        'models.search',
        () async {
          calls++;
          throw const SocketException('down');
        },
        waits.add,
        sleep: (_) async {},
      ),
      throwsA(isA<SocketException>()),
    );
    expect(calls, 1);
    calls = 0;
    await expectLater(
      withRetries(
        'models.pull',
        () async {
          calls++;
          throw const SocketException('down');
        },
        (_) {},
        sleep: (_) async {},
      ),
      throwsA(isA<SocketException>()),
    );
    expect(calls, 6);
  });
}
