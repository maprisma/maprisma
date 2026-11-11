import 'dart:convert';
import 'dart:io';
import 'package:maprisma_core/src/connect_apply.dart';
import 'package:maprisma_core/src/core_tasks.dart' show encodePlan;
import 'package:maprisma_core/src/plan_worker.dart';
import 'package:maprisma_core/src/posix_ffi.dart';
import 'package:maprisma_core/src/skills_web.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _commit = 'c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00';
final _skillMd = utf8.encode('---\nname: pdf\ndescription: Reads PDFs.\n---\n');
final _runSh = utf8.encode('echo hi\n');
final _tree = {
  'tree': [
    {
      'path': 'skills/pdf/SKILL.md',
      'type': 'blob',
      'mode': '100644',
      'size': 40,
      'sha': gitBlobId(_skillMd),
    },
    {
      'path': 'skills/pdf/scripts/run.sh',
      'type': 'blob',
      'mode': '100755',
      'size': 10,
      'sha': gitBlobId(_runSh),
    },
    {'path': 'skills/pdf/link', 'type': 'blob', 'mode': '120000', 'size': 4},
  ],
};

final _urls = <String>[];
List<int>? _servedRunSh;

Future<List<int>> _get(String url, int limit, String accept) async {
  _urls.add(url);
  if (url == commitUrl('someone/skills')) return utf8.encode('$_commit\n');
  if (url.startsWith('https://api.github.com/repos/someone/skills/')) {
    return utf8.encode(jsonEncode(_tree));
  }
  if (url.endsWith('/skills/pdf/SKILL.md')) return _skillMd;
  if (url.endsWith('/skills/pdf/scripts/run.sh')) return _servedRunSh ?? _runSh;
  throw StateError('not expected: $url');
}

void main() {
  late Directory home;
  late String staging;
  final posix = Posix();
  setUp(() {
    _urls.clear();
    _servedRunSh = null;
    home = Directory.systemTemp.createTempSync('maprisma-skills-web-');
    staging = p.join(home.path, '.cache/maprisma/skill-staging');
  });
  tearDown(() => home.deleteSync(recursive: true));

  Future<(Plan, Map<String, dynamic>)> fetched() async {
    final result = await fetchSkill(
      'someone/skills',
      'pdf',
      staging,
      posix,
      get: _get,
    );
    final target = p.join(home.path, '.agents/skills/pdf');
    return (
      Plan(
        '',
        '',
        'pdf',
        filesStaged: [
          for (final f in result['files'] as List)
            (
              p.join(target, f[0] as String),
              f[1] as String,
              f[2] as String,
              f[3] as bool,
            ),
        ],
      ),
      result,
    );
  }

  test('fetched into staging, written by the worker, undone', () async {
    final (plan, result) = await fetched();
    expect(result['description'], 'Reads PDFs.');
    expect(result['scripts'], ['scripts/run.sh']);
    expect(
      [for (final f in result['files'] as List) f[0]],
      ['SKILL.md', 'scripts/run.sh'],
    );
    final staged = (result['files'] as List).first[1] as String;
    expect(File(staged).statSync().mode & 0x1ff, 0x180);
    final backups = p.join(home.path, '.config/maprisma/connection-backups');
    final applied = await applyPlan(
      encodePlan(plan, backups),
      posix,
      home.path,
      stagingRoot: staging,
    );
    final script = File(p.join(home.path, '.agents/skills/pdf/scripts/run.sh'));
    expect(script.readAsStringSync(), 'echo hi\n');
    expect(script.statSync().mode & 0x40, 0x40);
    expect(Directory(p.dirname(staged)).existsSync(), isFalse);
    final restored = ConfigFiles(
      posix,
      home.path,
    ).undo(applied['backup'] as String);
    expect(restored, isNotNull);
    expect(script.existsSync(), isFalse);
  });

  test('a staged file changed since the review is not written', () async {
    final (plan, result) = await fetched();
    File((result['files'] as List).first[1] as String).writeAsStringSync('x');
    expect(
      () => applyPlan(
        encodePlan(plan, p.join(home.path, 'backups')),
        posix,
        home.path,
        stagingRoot: staging,
      ),
      throwsStateError,
    );
    expect(
      File(p.join(home.path, '.agents/skills/pdf/SKILL.md')).existsSync(),
      isFalse,
    );
  });

  test('only files in the staging folder, and only plain entries', () async {
    final (plan, _) = await fetched();
    final outside = Plan(
      '',
      '',
      'pdf',
      filesStaged: [(p.join(home.path, 'x'), '/etc/hostname', '0' * 64, false)],
    );
    expect(
      () => applyPlan(
        encodePlan(outside, p.join(home.path, 'backups')),
        posix,
        home.path,
        stagingRoot: staging,
      ),
      throwsStateError,
    );
    final body = jsonDecode(utf8.decode(encodePlan(plan, '/tmp/b'))) as Map;
    for (final bad in [
      [
        ['relative', '/x', '0' * 64, false],
      ],
      [
        ['/a', '/x', 'nothex', false],
      ],
      [
        ['/a', '/x', '0' * 64, 'yes'],
      ],
      'not a list',
    ]) {
      expect(
        () =>
            decodePlan(utf8.encode(jsonEncode({...body, 'files_staged': bad}))),
        throwsFormatException,
      );
    }
  });

  test('refused: bad repository or id, a skill without SKILL.md', () async {
    expect(
      () => fetchSkill('no-slash', 'pdf', staging, posix, get: _get),
      throwsFormatException,
    );
    expect(
      () => fetchSkill('someone/skills', 'x\n', staging, posix, get: _get),
      throwsFormatException,
    );
    expect(
      () => fetchSkill('someone/skills', 'docx', staging, posix, get: _get),
      throwsFormatException,
    );
  });

  test('every file comes from one resolved commit', () async {
    final result = await fetchSkill('someone/skills', 'pdf', staging, posix, get: _get);
    expect(result['commit'], _commit);
    expect(_urls.first, commitUrl('someone/skills'));
    expect(_urls.skip(1).every((u) => u.contains(_commit)), isTrue);
    expect(_urls.any((u) => u.contains('/HEAD')), isTrue); // only the commit lookup
    expect(_urls.skip(1).any((u) => u.contains('/HEAD')), isFalse);
  });

  test('a file of another version is refused', () async {
    _servedRunSh = utf8.encode('echo changed\n'); // the branch moved meanwhile
    await expectLater(
      fetchSkill('someone/skills', 'pdf', staging, posix, get: _get),
      throwsA(isA<FormatException>()),
    );
  });

  test('Git blob id', () {
    // `printf 'hello\n' | git hash-object --stdin`
    expect(gitBlobId(utf8.encode('hello\n')), 'ce013625030ba8dba906f756967f9e9ca394464a');
  });
}
