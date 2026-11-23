import 'dart:io';
import 'package:test/test.dart';
import 'package:maprisma_core/src/agent_start.dart' show isAgentSessionVar;
import 'package:maprisma_core/src/adapters.dart';
import 'package:maprisma_core/src/adapter_assets.g.dart';
import 'package:maprisma_core/src/identity.dart';
import 'package:maprisma_core/src/scan_files.dart';

void main() {
  test(
    'project setup cannot launch a different command or omit its prompt',
    () {
      const base = {'command': 'worker', 'name': 'Worker'};
      for (final setup in [
        ['sh', '{prompt}'],
        ['worker'],
        ['worker', '--prompt={prompt}'],
        ['worker', '{prompt}', '{prompt}'],
      ]) {
        expect(
          () => Adapter({
            ...base,
            'project': {
              'plan': ['worker', '{prompt}'],
              'run': ['worker', '{prompt}'],
              'setup': setup,
              'permissions': 'Read only',
            },
          }),
          throwsA(isA<AdapterError>()),
        );
      }
    },
  );

  test('Pi managed project profile grants only read and search tools', () {
    final profile = builtinAdapters()
        .firstWhere((adapter) => adapter.command == 'pi')
        .table('project');
    expect(profile['access_modes'], ['read-only']);
    for (final key in ['plan', 'run']) {
      final argv = (profile[key] as List).cast<String>();
      expect(argv[argv.indexOf('--tools') + 1], 'read,grep,find,ls');
      expect(
        argv,
        containsAll(['--no-mcp', '--no-extensions', '--no-approve']),
      );
    }
    expect(profile['setup'], contains('--no-tools'));
    expect(profile['setup'], contains('--no-context-files'));
  });

  test('all shipped adapters parse and their keys remain strictly typed', () {
    final adapters = builtinAdapters();
    expect(adapters.length, builtinAdapterSources.length);
    expect(adapters.map((a) => a.command).toSet().length, adapters.length);
    for (final a in adapters) {
      expect(a.icon, isA<String>());
    }
    const base = {'command': 'test-agent', 'name': 'Test Agent'};
    for (final e in (adapterSchema['TOP'] as Map).entries) {
      final wrong = switch (e.value) {
        'text' => true,
        'true/false' => 'yes',
        'a list of texts' => [1],
        'a table' => [],
        'tables' => [1],
        _ => null,
      };
      expect(
        () => Adapter({...base, e.key: wrong}),
        throwsA(isA<AdapterError>()),
        reason: e.key,
      );
    }
    expect(
      () => Adapter({...base, 'unknown': 1}),
      throwsA(isA<AdapterError>()),
    );
  });
  test('[project.env] takes plan/run/setup tables of safe variables', () {
    Map<String, dynamic> withEnv(Object env) => {
      'command': 'x',
      'name': 'X',
      'project': {
        'plan': ['x', '{prompt}'],
        'run': ['x', '{prompt}'],
        'permissions': 'p',
        'env': env,
      },
    };
    final ok = Adapter(
      withEnv({
        'plan': {'GOOSE_MODE': 'auto'},
        'run': {'GOOSE_MODE': 'auto'},
      }),
    );
    expect(ok.table('project')['env'], isA<Map>());
    // Copilot's switches: only "false" (an exported "true" is turned off).
    expect(
      Adapter(
        withEnv({
          'plan': {
            for (final name in [
              'COPILOT_ALLOW_ALL',
              'COPILOT_ASSISTED_APPROVAL',
              'COPILOT_AUTO_UPDATE',
              'GITHUB_COPILOT_PROMPT_MODE_EXTENSIONS',
              'GITHUB_COPILOT_PROMPT_MODE_REPO_HOOKS',
              'GITHUB_COPILOT_PROMPT_MODE_WORKSPACE_MCP',
            ])
              name: 'false',
          },
        }),
      ).table('project')['env'],
      isA<Map>(),
    );
    expect(isAgentSessionVar('CLAUDE_RELAUNCH_SESSION_ADD_DIRS'), isTrue);
    expect(isAgentSessionVar('CLAUDE_BG_SESSION_PERMISSION_RULES'), isTrue);
    for (final bad in [
      {
        'review': {'A': 'b'},
      },
      {'plan': 'A=b'},
      {
        'plan': {'LD_PRELOAD': '/x.so'},
      },
      {
        'plan': {'XDG_CONFIG_HOME': '/x'},
      },
      {
        'plan': {'HOME': '/x'},
      },
      {
        'plan': {'lower': 'x'},
      },
      {
        'plan': {'A': 1},
      },
    ]) {
      expect(
        () => Adapter(withEnv(bad)),
        throwsA(isA<AdapterError>()),
        reason: '$bad',
      );
    }
  });
  test('an [ask] or [task] marked verified = false is not used by the app', () {
    const base = {'command': 'x', 'name': 'X'};
    final a = Adapter({
      ...base,
      'ask': {
        'argv': ['x', '-p', '{prompt}'],
        'verified': false,
      },
      'task': {
        'argv': ['x', '{prompt}'],
      },
    });
    expect(a.table('ask'), isEmpty);
    expect(a.table('task')['argv'], ['x', '{prompt}']);
    expect(
      () => Adapter({
        ...base,
        'task': {
          'argv': ['x', '{prompt}'],
          'verified': 'no',
        },
      }),
      throwsA(isA<AdapterError>()),
    );
    // The documentation-only entries of the shipped adapters stay out.
    final gemini = builtinAdapters().firstWhere((a) => a.command == 'gemini');
    expect(gemini.table('task'), isEmpty);
    expect(gemini.table('ask'), isEmpty);
    final hermes = builtinAdapters().firstWhere((a) => a.command == 'hermes');
    expect(hermes.table('ask'), isNotEmpty);
    expect(hermes.table('task'), isEmpty);
  });
  test(
    'prompt/configure declarations never select a shell or embedded template',
    () {
      for (final data in [
        {
          'ask': {
            'argv': ['sh', '{prompt}'],
          },
        },
        {
          'ask': {
            'argv': ['x', 'embedded{prompt}'],
          },
        },
        {
          'configure': [
            {
              'label': 'bad',
              'argv': ['sh'],
            },
          ],
        },
        {
          'start': ['\x00'],
        },
        {
          'closed': {'home_env': 'x=y'},
        },
        {
          'advise': {
            'argv': ['x'],
            'model': ['--model', '{model}'],
          },
        },
      ]) {
        expect(
          () => Adapter({'command': 'x', 'name': 'X', ...data}),
          throwsA(isA<AdapterError>()),
        );
      }
    },
  );
  test(
    'bounded adapter read refuses links FIFOs malformed UTF8 and huge files',
    () {
      final home = Directory.systemTemp.createTempSync(
        'maprisma-adapter-test-',
      );
      try {
        final file = File('${home.path}/a.toml')
          ..writeAsStringSync('command="x"\nname="X"');
        expect(Adapter.load(file.path).command, 'x');
        Link('${home.path}/link.toml').createSync(file.path);
        expect(
          () => Adapter.load('${home.path}/link.toml'),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          Process.runSync('/usr/bin/mkfifo', [
            '${home.path}/fifo.toml',
          ]).exitCode,
          0,
        );
        expect(
          () => Adapter.load('${home.path}/fifo.toml'),
          throwsA(isA<FileSystemException>()),
        );
        file.writeAsBytesSync([255, 254]);
        expect(() => Adapter.load(file.path), throwsFormatException);
        file.writeAsStringSync('x' * (adapterMaxBytes + 1));
        expect(
          () => Adapter.load(file.path),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        home.deleteSync(recursive: true);
      }
    },
  );
  test(
    'scan files cap reads and directory enumeration without creating files',
    () {
      final home = Directory.systemTemp.createTempSync('maprisma-scan-test-');
      try {
        final io = ScanFiles(AppIdentity(environment: {'HOME': home.path}));
        expect(io.list('~/missing'), isEmpty);
        expect(home.listSync(), isEmpty);
        for (var i = 0; i < 20; i++) {
          File('${home.path}/f$i').writeAsStringSync('12345');
        }
        expect(io.list('~', limit: 3).length, 3);
        expect(io.text('~/f0', limit: 4), null);
        Link('${home.path}/linked').createSync('${home.path}/f0');
        expect(io.text('~/linked'), null);
        expect(io.text('~/auth.json'), null);
        expect(io.json('~/missing'), isEmpty);
      } finally {
        home.deleteSync(recursive: true);
      }
    },
  );
}
