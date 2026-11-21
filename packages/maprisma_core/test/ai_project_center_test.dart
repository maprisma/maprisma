import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_core/src/features/ai_project_center.dart';
import 'package:maprisma_core/src/posix_ffi.dart';
import 'package:maprisma_core/src/protocol.dart';
import 'package:test/test.dart';

/// The execution sandbox represents host root-owned ancestors as nobody.
/// Normalize those three ancestors only; production always uses plain Posix.
final class TestPosix extends Posix {
  @override
  ({int mode, int uid, int size}) stat(int fd) {
    final info = super.stat(fd);
    final path = Link('/proc/self/fd/$fd').targetSync();
    return (
      mode: info.mode,
      uid: info.uid == 65534 && {'/', '/home', '/tmp'}.contains(path)
          ? 0
          : info.uid,
      size: info.size,
    );
  }
}

final class FakeProjectProcess implements ProjectProcess {
  final lines = StreamController<String>();
  final exit = Completer<int>();
  bool stopped = false;
  bool refuseStop = false;
  bool _finished = false;
  @override
  Stream<String> get output => lines.stream;
  @override
  Future<int> get exitCode => exit.future;
  Future<void> finish(String text, [int code = 0]) async {
    if (_finished) return;
    _finished = true;
    if (text.isNotEmpty) lines.add(text);
    await lines.close();
    exit.complete(code);
  }

  @override
  Future<void> stop() async {
    if (refuseStop) throw ServiceError('project_processes_still_running');
    stopped = true;
    unawaited(finish('', -15));
  }
}

Matcher errorCode(String code) =>
    isA<ServiceError>().having((e) => e.code, 'code', code);

Future<void> waitUntil(bool Function() predicate) async {
  for (var i = 0; i < 500 && !predicate(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(
    predicate(),
    isTrue,
    reason: 'The operation did not reach its expected state',
  );
}

Future<Map<String, dynamic>> project(
  AiProjectCenterPlugin plugin,
  String id,
) async =>
    (await plugin.call('get', {'id': id}))['project'] as Map<String, dynamic>;

void main() {
  late Directory temporary;
  late String workspace;
  late List<Map<String, dynamic>> profiles;
  late List<Map<String, dynamic>> runtimes;
  late AiProjectCenterPlugin plugin;
  late List<FakeProjectProcess> processes;
  late List<List<String>> commands;
  late List<String> directories;

  Future<Map<String, dynamic>> save({
    String title = 'A project',
    String? path,
    List<Map<String, dynamic>>? team,
    String plan = '',
  }) async =>
      (await plugin.call('save', {
            'title': title,
            'brief': 'Build the requested change and verify it.',
            'path': path ?? workspace,
            'team':
                team ??
                [
                  {'agent': 'fixture', 'role': 'lead'},
                ],
            'plan': plan,
          }))['project']
          as Map<String, dynamic>;

  Future<Map<String, dynamic>> approve(Map<String, dynamic> item) async =>
      (await plugin.call('review', {
            'id': item['id'],
            'revision': item['revision'],
            'approved': true,
          }))['project']
          as Map<String, dynamic>;

  void addPartner({bool installed = true}) {
    profiles.add({
      'id': 'partner',
      'name': 'Partner agent',
      'installed': installed,
      'plan_argv': ['/fixture/partner', 'read-only', '{prompt}'],
      'run_argv': ['/fixture/partner', 'workspace-write', '{prompt}'],
      'model_option': '--model',
      'models': ['known-model'],
    });
  }

  void addRuntime() {
    profiles.first.addAll({
      'provider_option': '--provider',
      'model_option': '--model',
    });
    runtimes.add({
      'key': 'runtime',
      'name': 'Example local runtime',
      'aliases': ['local-engine'],
      'installed': true,
      'running': true,
      'models': ['tiny-model'],
      'bindings': {
        'fixture': {
          'provider': 'local-provider',
          'models': ['tiny-model'],
        },
      },
    });
  }

  Future<Map<String, dynamic>> setupResult(
    Map<String, dynamic> item, {
    required String request,
    required Map<String, dynamic> proposal,
    String target = 'run',
  }) async {
    final count = processes.length;
    await plugin.call('setup', {
      'id': item['id'],
      'revision': item['revision'],
      'request': request,
      'agent': 'fixture',
      'target': target,
    });
    await waitUntil(() => processes.length == count + 1);
    await processes.last.finish(jsonEncode(proposal));
    await waitUntil(() => plugin.summary()['running'] == 0);
    return project(plugin, item['id'] as String);
  }

  setUp(() {
    // The private-store policy requires ancestors owned by root or this user;
    // some sandbox runners expose /tmp as a third-party-owned mount.
    temporary = Directory.current.createTempSync('.project-center-test-');
    workspace = (Directory('${temporary.path}/workspace')..createSync()).path;
    profiles = [
      {
        'id': 'fixture',
        'name': 'Fixture agent',
        'installed': true,
        'plan_argv': ['/fixture/agent', 'read-only', '{prompt}'],
        'run_argv': ['/fixture/agent', 'workspace-write', '{prompt}'],
        'setup_argv': ['/fixture/agent', 'no-tools', '{prompt}'],
      },
    ];
    runtimes = [];
    processes = [];
    commands = [];
    directories = [];
    plugin = AiProjectCenterPlugin(
      temporary.path,
      agentProfiles: () => profiles,
      runtimeProfiles: () => runtimes,
      filesystem: TestPosix(),
      runner: (argv, cwd, environment, input, _, _) async {
        commands.add(argv);
        directories.add(cwd);
        final process = FakeProjectProcess();
        processes.add(process);
        return process;
      },
    );
  });

  tearDown(() async {
    await plugin.shutdown();
    temporary.deleteSync(recursive: true);
  });

  test(
    'projects survive reopen, use private storage, and concurrent owners are refused',
    () async {
      final saved = await save(plan: '1. Implement.\n2. Verify.');
      expect(
        File('${plugin.directory}/projects.json').statSync().mode & 0x1ff,
        0x180,
      );
      expect(Directory(plugin.directory).statSync().mode & 0x1ff, 0x1c0);
      expect(
        () => AiProjectCenterPlugin(
          temporary.path,
          agentProfiles: () => profiles,
          filesystem: TestPosix(),
        ),
        throwsA(errorCode('project_center_busy')),
      );
      await plugin.shutdown();
      plugin = AiProjectCenterPlugin(
        temporary.path,
        agentProfiles: () => profiles,
        filesystem: TestPosix(),
      );
      final reopened = await project(plugin, saved['id'] as String);
      expect(reopened['plan'], saved['plan']);
      expect(reopened['status'], 'awaiting_review');
      expect((await plugin.call('list', {}))['projects'], hasLength(1));
    },
  );

  test(
    'stale edits are refused and a changed brief invalidates exact plan approval',
    () async {
      var item = await save(plan: 'Implement and verify.');
      final stale = Map<String, dynamic>.of(item);
      item = await approve(item);
      expect(item['status'], 'ready');
      await expectLater(
        plugin.call('save', {
          'id': stale['id'],
          'revision': stale['revision'],
          'title': 'Stale change',
        }),
        throwsA(errorCode('project_changed')),
      );
      item =
          (await plugin.call('save', {
                'id': item['id'],
                'revision': item['revision'],
                'brief': 'A changed goal',
              }))['project']
              as Map<String, dynamic>;
      expect(item['approved_version'], isNull);
      expect(item['status'], 'awaiting_review');
      await expectLater(
        plugin.call('run', {'id': item['id'], 'revision': item['revision']}),
        throwsA(errorCode('project_plan_not_approved')),
      );
      expect(commands, isEmpty);
    },
  );

  test(
    'an adapter permission change invalidates an already approved plan',
    () async {
      final item = await approve(await save(plan: 'The checked plan.'));
      profiles.single['run_argv'] = [
        '/fixture/agent',
        'changed-permissions',
        '{prompt}',
      ];
      await expectLater(
        plugin.call('run', {'id': item['id'], 'revision': item['revision']}),
        throwsA(errorCode('project_plan_not_approved')),
      );
      expect(commands, isEmpty);
    },
  );

  test(
    'planning persists intent first, runs read-only reviewers, and never autoexecutes',
    () async {
      final item = await save(
        team: [
          {'agent': 'fixture', 'role': 'lead'},
          {
            'agent': 'fixture',
            'role': 'reviewer',
            'instructions': 'Check feasibility.',
          },
        ],
      );
      await plugin.call('plan', {
        'id': item['id'],
        'revision': item['revision'],
      });
      final stored =
          jsonDecode(
                File('${plugin.directory}/projects.json').readAsStringSync(),
              )
              as Map;
      expect(
        (stored['projects'] as List).single['status'],
        anyOf('planning', 'reviewing'),
      );
      await waitUntil(() => processes.length == 1);
      expect(commands.single[1], 'read-only');
      await processes[0].finish(
        '1. Make the requested change.\n2. Run the acceptance check.',
      );
      await waitUntil(() => processes.length == 2);
      expect(commands[1][1], 'read-only');
      expect(commands[1].last, contains('Check feasibility.'));
      await processes[1].finish('No feasibility findings.');
      await waitUntil(() => plugin.summary()['running'] == 0);
      final finished = await project(plugin, item['id'] as String);
      expect(finished['status'], 'awaiting_review');
      expect(finished['plan'], startsWith('1. Make'));
      expect(finished['output'], 'No feasibility findings.');
      expect(finished['handoff'], contains('No feasibility findings.'));
      expect(finished['approved_version'], isNull);
      expect(commands, hasLength(2));
    },
  );

  test(
    'execution sequences lead and implementer before a read-only reviewer',
    () async {
      var item = await save(
        plan: 'Implement then review.',
        team: [
          {'agent': 'fixture', 'role': 'reviewer'},
          {'agent': 'fixture', 'role': 'implementer'},
          {'agent': 'fixture', 'role': 'lead'},
        ],
      );
      item = await approve(item);
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 1);
      expect(commands[0][1], 'workspace-write');
      await processes[0].finish('Lead finished.');
      await waitUntil(() => processes.length == 2);
      expect(commands[1][1], 'workspace-write');
      expect(commands[1].last, contains('Lead finished.'));
      await processes[1].finish('Implementation finished.');
      await waitUntil(() => processes.length == 3);
      expect(commands[2][1], 'read-only');
      await processes[2].finish('Review evidence.');
      await waitUntil(() => plugin.summary()['running'] == 0);
      item = await project(plugin, item['id'] as String);
      expect(item['status'], 'completed');
      expect(item['next_member'], 3);
      expect(item['handoff'], contains('Review evidence.'));
      expect(directories, everyElement(workspace));
    },
  );

  test(
    'duplicate execution and concurrent writes to one folder are refused',
    () async {
      var first = await approve(await save(plan: 'One plan.'));
      final second = await approve(
        await save(title: 'Another project', plan: 'Another plan.'),
      );
      await plugin.call('run', {
        'id': first['id'],
        'revision': first['revision'],
      });
      await waitUntil(() => processes.length == 1);
      first = await project(plugin, first['id'] as String);
      await expectLater(
        plugin.call('run', {'id': first['id'], 'revision': first['revision']}),
        throwsA(errorCode('project_already_running')),
      );
      await expectLater(
        plugin.call('run', {
          'id': second['id'],
          'revision': second['revision'],
        }),
        throwsA(errorCode('project_folder_busy')),
      );
      await expectLater(
        plugin.call('delete', {
          'id': first['id'],
          'revision': first['revision'],
        }),
        throwsA(errorCode('project_already_running')),
      );
      expect(commands, hasLength(1));
    },
  );

  test(
    'pause ends owned work and continuation requires explicit partial-change review',
    () async {
      var item = await approve(await save(plan: 'Execute this approved plan.'));
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 1);
      processes[0].lines.add('Partial progress.');
      await Future<void>.delayed(Duration.zero);
      item = await project(plugin, item['id'] as String);
      item =
          (await plugin.call('pause', {
                'id': item['id'],
                'revision': item['revision'],
              }))['project']
              as Map<String, dynamic>;
      expect(processes[0].stopped, isTrue);
      expect(item['status'], 'paused');
      expect(item['needs_reconciliation'], isTrue);
      expect(item['checkpoint_kind'], 'handoff');
      expect(item['handoff'], contains('Partial progress.'));
      expect(plugin.summary()['running'], 0);
      await expectLater(
        plugin.call('continue', {
          'id': item['id'],
          'revision': item['revision'],
        }),
        throwsA(errorCode('project_review_changes_first')),
      );
      await plugin.call('continue', {
        'id': item['id'],
        'revision': item['revision'],
        'acknowledge_interrupted': true,
      });
      await waitUntil(() => processes.length == 2);
      expect(commands[1].last, contains('Partial progress.'));
      expect(
        commands[1].last,
        contains('never repeat an uncertain side effect'),
      );
      await processes[1].finish('Remaining work finished.');
      await waitUntil(() => plugin.summary()['running'] == 0);
      expect(
        (await project(plugin, item['id'] as String))['status'],
        'completed',
      );
    },
  );

  test(
    'failed agents preserve output and never dispatch dependent work',
    () async {
      var item = await approve(
        await save(
          plan: 'Execute then review.',
          team: [
            {'agent': 'fixture', 'role': 'lead'},
            {'agent': 'fixture', 'role': 'reviewer'},
          ],
        ),
      );
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 1);
      await processes.single.finish('A real diagnostic.', 9);
      await waitUntil(() => plugin.summary()['running'] == 0);
      item = await project(plugin, item['id'] as String);
      expect(item['status'], 'failed');
      expect(item['output'], 'A real diagnostic.');
      expect(item['next_member'], 0);
      expect(item['needs_reconciliation'], isTrue);
      expect(commands, hasLength(1));
    },
  );

  test(
    'restart marks an active durable record interrupted without replaying it',
    () async {
      final item = await save(plan: 'A saved plan.');
      await plugin.shutdown();
      final state = File('${plugin.directory}/projects.json');
      final body = jsonDecode(state.readAsStringSync()) as Map;
      (body['projects'] as List).single['status'] = 'running';
      (body['projects'] as List).single['phase'] = 'running';
      state.writeAsStringSync(jsonEncode(body));
      plugin = AiProjectCenterPlugin(
        temporary.path,
        agentProfiles: () => profiles,
        filesystem: TestPosix(),
      );
      final recovered = await project(plugin, item['id'] as String);
      expect(recovered['status'], 'interrupted');
      expect(recovered['needs_reconciliation'], isTrue);
      expect(plugin.summary()['attention'], 1);
      expect(commands, isEmpty);
    },
  );

  test('failed intent persistence prevents any agent launch', () async {
    final item = await approve(await save(plan: 'The saved plan.'));
    final file = File('${plugin.directory}/projects.json')..deleteSync();
    Directory(file.path).createSync();
    await expectLater(
      plugin.call('run', {'id': item['id'], 'revision': item['revision']}),
      throwsA(errorCode('project_store_unavailable')),
    );
    expect(commands, isEmpty);
    expect(plugin.summary()['error'], 'project_store_unavailable');
  });

  test(
    'native subagent presets and model flags are validated and kept as argv words',
    () async {
      profiles.single.addAll({
        'native_subagents': true,
        'subagent_option': '--agents',
        'subagent_definitions': {
          'reviewer': {
            'description': 'Review',
            'prompt': 'Read only',
            'tools': ['Read', 'Glob', 'Grep'],
          },
        },
        'model_option': '--model',
      });
      var item = await save(
        plan: 'The plan.',
        team: [
          {
            'agent': 'fixture',
            'role': 'lead',
            'model': 'example/model-v1',
            'subagents': ['reviewer'],
          },
        ],
      );
      item = await approve(item);
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 1);
      expect(
        commands.single,
        containsAllInOrder(['--model', 'example/model-v1', '--agents']),
      );
      final definitions = jsonDecode(commands.single.last) as Map;
      expect(definitions.keys, ['reviewer']);
      expect((definitions['reviewer'] as Map)['tools'], [
        'Read',
        'Glob',
        'Grep',
      ]);
      await processes.single.finish('Done.');
      await waitUntil(() => plugin.summary()['running'] == 0);
    },
  );

  test(
    'an undeclared native subagent cannot be launched or approved',
    () async {
      final item = await save(
        plan: 'The plan.',
        team: [
          {
            'agent': 'fixture',
            'role': 'lead',
            'subagents': ['undeclared'],
          },
        ],
      );
      await expectLater(
        approve(item),
        throwsA(errorCode('project_subagents_unsupported')),
      );
      expect(commands, isEmpty);
    },
  );

  test(
    'UTF-8 output stays bounded and reloadable at a multibyte boundary',
    () async {
      var item = await approve(await save(plan: 'The plan.'));
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 1);
      await processes.single.finish(
        '🙂' * (AiProjectCenterPlugin.maxOutput ~/ 4 + 4),
      );
      await waitUntil(() => plugin.summary()['running'] == 0);
      item = await project(plugin, item['id'] as String);
      expect(
        utf8.encode(item['output'] as String).length,
        lessThanOrEqualTo(AiProjectCenterPlugin.maxOutput),
      );
      expect(item['output'], isNot(contains('�')));
      await plugin.shutdown();
      plugin = AiProjectCenterPlugin(
        temporary.path,
        agentProfiles: () => profiles,
        filesystem: TestPosix(),
      );
      expect(
        (await project(plugin, item['id'] as String))['status'],
        'completed',
      );
    },
  );

  test(
    'missing or changed project folders are refused before a process starts',
    () async {
      var item = await approve(await save(plan: 'The plan.'));
      Directory(workspace).deleteSync();
      final elsewhere = Directory('${temporary.path}/elsewhere')..createSync();
      Link(workspace).createSync(elsewhere.path);
      await expectLater(
        plugin.call('run', {'id': item['id'], 'revision': item['revision']}),
        throwsA(errorCode('project_folder_changed')),
      );
      expect(commands, isEmpty);
    },
  );

  test(
    'an output-stream failure stops the agent and does not dispatch its reviewer',
    () async {
      var item = await approve(
        await save(
          plan: 'Implement and review.',
          team: [
            {'agent': 'fixture', 'role': 'lead'},
            {'agent': 'fixture', 'role': 'reviewer'},
          ],
        ),
      );
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 1);
      processes.single.lines.addError(const FormatException('broken stream'));
      await waitUntil(() => plugin.summary()['running'] == 0);
      item = await project(plugin, item['id'] as String);
      expect(processes.single.stopped, isTrue);
      expect(item['status'], 'failed');
      expect(item['needs_reconciliation'], isTrue);
      expect(commands, hasLength(1));
    },
  );

  test(
    'pause during asynchronous spawn waits for the new process to be stopped',
    () async {
      var item = await approve(await save(plan: 'The plan.'));
      await plugin.shutdown();
      final spawning = Completer<ProjectProcess>();
      plugin = AiProjectCenterPlugin(
        temporary.path,
        agentProfiles: () => profiles,
        filesystem: TestPosix(),
        runner: (argv, cwd, environment, input, _, _) => spawning.future,
      );
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      item = await project(plugin, item['id'] as String);
      final pausing = plugin.call('pause', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => plugin.summary()['pausing'] == 1);
      final process = FakeProjectProcess();
      spawning.complete(process);
      item = (await pausing)['project'] as Map<String, dynamic>;
      expect(process.stopped, isTrue);
      expect(item['status'], 'paused');
      expect(plugin.summary()['running'], 0);
    },
  );

  test(
    'the default managed runner captures a real harmless command completely',
    () async {
      await plugin.shutdown();
      profiles.single['plan_argv'] = [
        '/bin/sh',
        '-c',
        'printf "A complete plan.\\n"',
        '{prompt}',
      ];
      plugin = AiProjectCenterPlugin(
        temporary.path,
        agentProfiles: () => profiles,
        filesystem: TestPosix(),
      );
      var item = await save();
      await plugin.call('plan', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => plugin.summary()['running'] == 0);
      item = await project(plugin, item['id'] as String);
      expect(item['status'], 'awaiting_review');
      expect(item['plan'], contains('A complete plan.'));
      expect(item['output'], contains('A complete plan.'));
    },
  );

  test(
    'default runner pause stops its owned child process before reporting paused',
    () async {
      await plugin.shutdown();
      final childFile = File('${temporary.path}/child-pid');
      profiles.single['run_argv'] = [
        '/bin/sh',
        '-c',
        'sleep 30 & printf "%s" "\$!" > "${childFile.path}"; wait',
        '{prompt}',
      ];
      plugin = AiProjectCenterPlugin(
        temporary.path,
        agentProfiles: () => profiles,
        filesystem: TestPosix(),
      );
      var item = await approve(await save(plan: 'The plan.'));
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(
        () => childFile.existsSync() && childFile.readAsStringSync().isNotEmpty,
      );
      final child = int.parse(childFile.readAsStringSync());
      bool childRuns() {
        final stat = File('/proc/$child/stat');
        if (!stat.existsSync()) return false;
        final state = RegExp(
          r'^\d+ \(.*\) ([A-Z])',
        ).firstMatch(stat.readAsStringSync())?.group(1);
        return state != 'Z' && state != 'X';
      }

      expect(childRuns(), isTrue);
      item = await project(plugin, item['id'] as String);
      item =
          (await plugin.call('pause', {
                'id': item['id'],
                'revision': item['revision'],
              }))['project']
              as Map<String, dynamic>;
      expect(item['status'], 'paused');
      expect(childRuns(), isFalse);
    },
  );

  test('policy is checked again before dispatching a later teammate', () async {
    var item = await approve(
      await save(
        plan: 'Execute and review.',
        team: [
          {'agent': 'fixture', 'role': 'lead'},
          {'agent': 'fixture', 'role': 'reviewer'},
        ],
      ),
    );
    await plugin.shutdown();
    var allowed = true;
    plugin = AiProjectCenterPlugin(
      temporary.path,
      agentProfiles: () => profiles,
      filesystem: TestPosix(),
      authorize: (_) {
        if (!allowed) throw ServiceError('action_refused');
      },
      runner: (argv, cwd, environment, input, _, _) async {
        commands.add(argv);
        final process = FakeProjectProcess();
        processes.add(process);
        return process;
      },
    );
    await plugin.call('run', {'id': item['id'], 'revision': item['revision']});
    await waitUntil(() => processes.length == 1);
    allowed = false;
    await processes.single.finish('First assignment is preserved.');
    await waitUntil(() => plugin.summary()['running'] == 0);
    item = await project(plugin, item['id'] as String);
    expect(item['status'], 'failed');
    expect(item['handoff'], contains('First assignment is preserved.'));
    expect((item['events'] as List).last['text'], 'action_refused');
    expect(commands, hasLength(1));
  });

  test(
    'unconfirmed cleanup retains the folder claim and never reports paused',
    () async {
      var item = await approve(await save(plan: 'The plan.'));
      final other = await approve(
        await save(title: 'Other', plan: 'Other plan.'),
      );
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 1);
      processes.single.refuseStop = true;
      await processes.single.finish(
        'The leader exited, but cleanup is unconfirmed.',
      );
      await waitUntil(() => plugin.summary()['pausing'] == 1);
      item = await project(plugin, item['id'] as String);
      expect(item['status'], 'pausing');
      await expectLater(
        plugin.call('run', {'id': other['id'], 'revision': other['revision']}),
        throwsA(errorCode('project_folder_busy')),
      );
      processes.single.refuseStop = false;
      item =
          (await plugin.call('pause', {
                'id': item['id'],
                'run_id': item['run_id'],
              }))['project']
              as Map<String, dynamic>;
      expect(item['status'], 'paused');
      expect(item['needs_reconciliation'], isTrue);
    },
  );

  test(
    'default runner sends and closes stdin for a declared stdin profile',
    () async {
      await plugin.shutdown();
      profiles.single['stdin'] = true;
      profiles.single['plan_argv'] = [
        '/bin/sh',
        '-c',
        'cat >/dev/null; printf "STDIN EOF"',
      ];
      plugin = AiProjectCenterPlugin(
        temporary.path,
        agentProfiles: () => profiles,
        filesystem: TestPosix(),
      );
      var item = await save();
      await plugin.call('plan', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => plugin.summary()['running'] == 0);
      item = await project(plugin, item['id'] as String);
      expect(item['status'], 'awaiting_review');
      expect(item['plan'], 'STDIN EOF');
    },
  );

  test(
    'ancestor and descendant project roots cannot execute concurrently',
    () async {
      final child = Directory('$workspace/nested')..createSync();
      final first = await approve(await save(plan: 'The root plan.'));
      final nested = await approve(
        await save(title: 'Nested', path: child.path, plan: 'The nested plan.'),
      );
      await plugin.call('run', {
        'id': nested['id'],
        'revision': nested['revision'],
      });
      await waitUntil(() => processes.length == 1);
      await expectLater(
        plugin.call('run', {'id': first['id'], 'revision': first['revision']}),
        throwsA(errorCode('project_folder_busy')),
      );
      await processes.single.finish('Nested work finished.');
      await waitUntil(() => plugin.summary()['running'] == 0);
      await plugin.call('run', {
        'id': first['id'],
        'revision': first['revision'],
      });
      await waitUntil(() => processes.length == 2);
      final freshNested = await approve(
        await project(plugin, nested['id'] as String),
      );
      await expectLater(
        plugin.call('run', {
          'id': freshNested['id'],
          'revision': freshNested['revision'],
        }),
        throwsA(errorCode('project_folder_busy')),
      );
    },
  );

  test(
    'a read-only implementer uses the planning command during execution',
    () async {
      var item = await approve(
        await save(
          plan: 'Inspect the project.',
          team: [
            {'agent': 'fixture', 'role': 'lead', 'access': 'read-only'},
            {'agent': 'fixture', 'role': 'implementer', 'access': 'read-only'},
          ],
        ),
      );
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 1);
      expect(commands.single[1], 'read-only');
      await processes.single.finish('Lead inspection finished.');
      await waitUntil(() => processes.length == 2);
      expect(commands[1][1], 'read-only');
      await processes[1].finish('Read-only checks finished.');
      await waitUntil(() => plugin.summary()['running'] == 0);
      item = await project(plugin, item['id'] as String);
      expect(item['status'], 'completed');
    },
  );

  test(
    'unknown access modes are rejected and reviewers remain read-only',
    () async {
      await expectLater(
        save(
          team: [
            {'agent': 'fixture', 'role': 'lead', 'access': 'unrestricted'},
          ],
        ),
        throwsA(isA<FormatException>()),
      );
      final item = await save(
        team: [
          {'agent': 'fixture', 'role': 'lead'},
          {'agent': 'fixture', 'role': 'reviewer', 'access': 'project-edit'},
        ],
      );
      expect((item['team'] as List).last['access'], 'read-only');
    },
  );

  test(
    'setup uses only its no-tools helper, preserves results, and applies a reviewed team without launching it',
    () async {
      addPartner();
      profiles.first['setup_argv'] = [
        '/fixture/agent',
        '--tools',
        '',
        '{prompt}',
      ];
      var item = await setupResult(
        await save(),
        request: 'Use fixture with partner.',
        proposal: {
          'team': [
            {'agent': 'fixture', 'role': 'lead'},
            {'agent': 'partner', 'role': 'reviewer', 'model': 'known-model'},
          ],
          'rationale': 'The lead implements and the other agent reviews.',
          'warnings': [],
        },
      );
      expect(item['status'], 'draft');
      expect(item['phase'], 'planning');
      expect((item['team'] as List), hasLength(1));
      expect(commands.single, containsAllInOrder(['--tools', '']));
      expect(
        directories.single,
        endsWith('/ai-project-center/setup-workspace'),
      );
      expect(directories.single, isNot(workspace));
      expect(item['setup_output'], contains('rationale'));
      item =
          (await plugin.call('setup_apply', {
                'id': item['id'],
                'revision': item['revision'],
              }))['project']
              as Map<String, dynamic>;
      expect(item['team'], hasLength(2));
      expect(item['approved_version'], isNull);
      expect(commands, hasLength(1));
    },
  );

  test('setup rejects a silently omitted named teammate', () async {
    addPartner();
    final item = await setupResult(
      await save(),
      request: 'Use fixture with partner.',
      proposal: {
        'team': [
          {'agent': 'fixture', 'role': 'lead'},
        ],
        'rationale': 'A lead.',
        'warnings': [],
      },
    );
    expect(item['setup_error'], isNotNull);
    expect(item['setup_proposal'], isNull);
    expect(
      (item['events'] as List).last['text'],
      'project_setup_agent_omitted',
    );
    expect(commands, hasLength(1));
  });

  test(
    'negative setup requests require explicit explained exclusions instead of forcing an unwanted teammate',
    () async {
      addPartner();
      final item = await setupResult(
        await save(),
        request: 'Use fixture; do not use partner.',
        proposal: {
          'team': [
            {'agent': 'fixture', 'role': 'lead'},
          ],
          'rationale': 'Use the requested lead.',
          'warnings': ['Partner is excluded as requested.'],
          'excluded_agents': ['partner'],
        },
      );
      expect(item['status'], 'draft');
      expect((item['setup_proposal'] as Map)['excluded_agents'], ['partner']);
    },
  );

  test(
    'setup refuses unexplained exclusions and invented cloud models',
    () async {
      addPartner();
      var item = await setupResult(
        await save(),
        request: 'Use fixture; not partner.',
        proposal: {
          'team': [
            {'agent': 'fixture', 'role': 'lead'},
          ],
          'rationale': 'The lead.',
          'warnings': [],
          'excluded_agents': ['partner'],
        },
      );
      expect(
        (item['events'] as List).last['text'],
        'project_setup_exclusion_unexplained',
      );
      item = await setupResult(
        item,
        request: 'Use partner.',
        proposal: {
          'team': [
            {'agent': 'partner', 'role': 'lead', 'model': 'invented-model'},
          ],
          'rationale': 'A claimed best model.',
          'warnings': [],
        },
      );
      expect(item['setup_error'], isNotNull);
      expect(
        (item['events'] as List).last['text'],
        'project_setup_model_unknown',
      );
    },
  );

  test(
    'a named uninstalled agent cannot silently disappear from setup',
    () async {
      addPartner(installed: false);
      final item = await setupResult(
        await save(),
        request: 'Use fixture and partner.',
        proposal: {
          'team': [
            {'agent': 'fixture', 'role': 'lead'},
          ],
          'rationale': 'The lead.',
          'warnings': [],
        },
      );
      expect(item['setup_error'], isNotNull);
      expect(
        (item['events'] as List).last['text'],
        'project_agent_unavailable',
      );
      expect((await plugin.call('profiles', {}))['profiles'], hasLength(1));
    },
  );

  test(
    'a requested local runtime must actually be used, never silently replaced by defaults',
    () async {
      addRuntime();
      final item = await setupResult(
        await save(),
        request: 'Use fixture with local-engine.',
        proposal: {
          'team': [
            {'agent': 'fixture', 'role': 'lead'},
          ],
          'rationale': 'Uses its default.',
          'warnings': [],
        },
      );
      expect(item['setup_error'], isNotNull);
      expect(
        (item['events'] as List).last['text'],
        'project_setup_runtime_omitted',
      );
    },
  );

  test(
    'local runtime binding is proposed, reviewed and passed as session flags without changing defaults',
    () async {
      addRuntime();
      var item = await setupResult(
        await save(plan: 'Use the selected local model.'),
        request: 'Use fixture with local-engine.',
        proposal: {
          'team': [
            {
              'agent': 'fixture',
              'role': 'lead',
              'runtime': 'runtime',
              'provider': 'local-provider',
              'model': 'tiny-model',
            },
          ],
          'rationale':
              'This ready local model is suitable; no benchmarks were performed.',
          'warnings': [],
        },
      );
      expect(item['status'], 'awaiting_review');
      item =
          (await plugin.call('setup_apply', {
                'id': item['id'],
                'revision': item['revision'],
              }))['project']
              as Map<String, dynamic>;
      item = await approve(item);
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 2);
      expect(
        commands.last,
        containsAllInOrder([
          '--provider',
          'local-provider',
          '--model',
          'tiny-model',
        ]),
      );
      expect(profiles.first.containsKey('defaultProvider'), isFalse);
      await processes.last.finish('Local work finished.');
      await waitUntil(() => plugin.summary()['running'] == 0);
    },
  );

  test(
    'setup apply refuses a runtime that stopped after the proposal was generated',
    () async {
      addRuntime();
      final item = await setupResult(
        await save(),
        request: 'Use fixture with local-engine.',
        proposal: {
          'team': [
            {
              'agent': 'fixture',
              'role': 'lead',
              'runtime': 'runtime',
              'provider': 'local-provider',
              'model': 'tiny-model',
            },
          ],
          'rationale': 'The runtime is ready.',
          'warnings': [],
        },
      );
      runtimes.single['running'] = false;
      await expectLater(
        plugin.call('setup_apply', {
          'id': item['id'],
          'revision': item['revision'],
        }),
        throwsA(errorCode('project_runtime_unavailable')),
      );
      expect(commands, hasLength(1));
    },
  );

  test(
    'runtime models and provider bindings are checked again at actual launch',
    () async {
      addRuntime();
      var item = await approve(
        await save(
          plan: 'The local plan.',
          team: [
            {
              'agent': 'fixture',
              'role': 'lead',
              'runtime': 'runtime',
              'provider': 'local-provider',
              'model': 'tiny-model',
            },
          ],
        ),
      );
      runtimes.single['running'] = false;
      await expectLater(
        plugin.call('run', {'id': item['id'], 'revision': item['revision']}),
        throwsA(errorCode('project_runtime_unavailable')),
      );
      runtimes.single['running'] = true;
      item =
          (await plugin.call('save', {
                'id': item['id'],
                'revision': item['revision'],
                'team': [
                  {
                    'agent': 'fixture',
                    'role': 'lead',
                    'runtime': 'runtime',
                    'provider': 'wrong-provider',
                    'model': 'tiny-model',
                  },
                ],
              }))['project']
              as Map<String, dynamic>;
      await expectLater(
        approve(item),
        throwsA(errorCode('project_provider_unsupported')),
      );
      expect(commands, isEmpty);
    },
  );

  test('read-only-only profiles refuse a project-edit assignment', () async {
    profiles.first['access_modes'] = ['read-only'];
    final item = await save(plan: 'The plan.');
    await expectLater(
      approve(item),
      throwsA(errorCode('project_access_unsupported')),
    );
    expect(commands, isEmpty);
  });

  test(
    'planning and execution dispatch different saved teams, models and permission commands',
    () async {
      addPartner();
      profiles.first['model_option'] = '--model';
      var item = await save(
        team: [
          {'agent': 'fixture', 'role': 'lead', 'model': 'run-model'},
        ],
      );
      item =
          (await plugin.call('save', {
                'id': item['id'],
                'revision': item['revision'],
                'plan_team': [
                  {'agent': 'partner', 'role': 'lead', 'model': 'known-model'},
                  {
                    'agent': 'fixture',
                    'role': 'implementer',
                    'model': 'planning-model',
                  },
                ],
              }))['project']
              as Map<String, dynamic>;
      await plugin.call('plan', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 1);
      expect(commands[0].first, '/fixture/partner');
      expect(
        commands[0],
        containsAllInOrder(['read-only', '--model', 'known-model']),
      );
      await processes[0].finish('A separately planned implementation.');
      await waitUntil(() => processes.length == 2);
      expect(commands[1][1], 'read-only');
      expect(commands[1], containsAllInOrder(['--model', 'planning-model']));
      await processes[1].finish('Planning contribution verified.');
      await waitUntil(() => plugin.summary()['running'] == 0);
      item = await approve(await project(plugin, item['id'] as String));
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 3);
      expect(commands[2].first, '/fixture/agent');
      expect(commands[2][1], 'workspace-write');
      expect(commands[2], containsAllInOrder(['--model', 'run-model']));
      await processes[2].finish('Execution finished.');
      await waitUntil(() => plugin.summary()['running'] == 0);
    },
  );

  test(
    'setup target plan applies only planning team and recalls separate target requests',
    () async {
      addPartner();
      var item = await setupResult(
        await save(),
        target: 'plan',
        request: 'Use partner for planning.',
        proposal: {
          'team': [
            {'agent': 'partner', 'role': 'lead'},
          ],
          'rationale': 'A planning specialist.',
          'warnings': [],
        },
      );
      expect(commands.single.last, contains('Target: Planning team'));
      expect((item['setup_proposal'] as Map)['target'], 'plan');
      item =
          (await plugin.call('setup_apply', {
                'id': item['id'],
                'revision': item['revision'],
              }))['project']
              as Map<String, dynamic>;
      expect((item['plan_team'] as List).single['agent'], 'partner');
      expect((item['team'] as List).single['agent'], 'fixture');
      item = await setupResult(
        item,
        request: 'Use fixture for implementation.',
        proposal: {
          'team': [
            {'agent': 'fixture', 'role': 'lead'},
          ],
          'rationale': 'The implementer.',
          'warnings': [],
        },
      );
      expect(item['setup_requests'], {
        'plan': 'Use partner for planning.',
        'run': 'Use fixture for implementation.',
      });
      expect((item['plan_team'] as List).single['agent'], 'partner');
    },
  );

  test('setup cannot erase or replay a paused execution checkpoint', () async {
    var item = await approve(await save(plan: 'The approved plan.'));
    await plugin.call('run', {'id': item['id'], 'revision': item['revision']});
    await waitUntil(() => processes.length == 1);
    processes.single.lines.add('Partial existing work.');
    item =
        (await plugin.call('pause', {'id': item['id']}))['project']
            as Map<String, dynamic>;
    final before = jsonEncode(item);
    await expectLater(
      plugin.call('setup', {
        'id': item['id'],
        'revision': item['revision'],
        'request': 'Use fixture.',
      }),
      throwsA(errorCode('project_review_changes_first')),
    );
    expect(jsonEncode(await project(plugin, item['id'] as String)), before);
    expect(commands, hasLength(1));
  });

  test(
    'editing and reapproving interrupted work cannot bypass partial-change acknowledgement',
    () async {
      var item = await approve(await save(plan: 'The plan.'));
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 1);
      processes.single.lines.add('Existing partial-effect evidence.');
      item =
          (await plugin.call('pause', {'id': item['id']}))['project']
              as Map<String, dynamic>;
      item =
          (await plugin.call('save', {
                'id': item['id'],
                'revision': item['revision'],
                'brief': 'A revised goal.',
              }))['project']
              as Map<String, dynamic>;
      item = await approve(item);
      await expectLater(
        plugin.call('run', {'id': item['id'], 'revision': item['revision']}),
        throwsA(errorCode('project_review_changes_first')),
      );
      expect(commands, hasLength(1));
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
        'acknowledge_interrupted': true,
      });
      await waitUntil(() => processes.length == 2);
      expect(commands.last.last, contains('Existing partial-effect evidence.'));
      expect(
        (await project(plugin, item['id'] as String))['output'],
        'Existing partial-effect evidence.',
      );
      await processes.last.finish('The revised task finished.');
      await waitUntil(() => plugin.summary()['running'] == 0);
    },
  );

  test(
    'qualified local provider models cannot bypass runtime binding checks',
    () async {
      profiles.first.addAll({
        'model_option': '--model',
        'local_providers': ['local-provider'],
      });
      final item = await save(
        plan: 'The plan.',
        team: [
          {
            'agent': 'fixture',
            'role': 'lead',
            'model': 'local-provider/tiny-model',
          },
        ],
      );
      await expectLater(
        approve(item),
        throwsA(errorCode('project_runtime_required')),
      );
      expect(commands, isEmpty);
    },
  );

  test(
    'clearing the planning team restores fallback and invalidates prior approval',
    () async {
      addPartner();
      var item = await save(plan: 'The plan.');
      item =
          (await plugin.call('save', {
                'id': item['id'],
                'revision': item['revision'],
                'plan_team': [
                  {'agent': 'partner', 'role': 'lead'},
                ],
              }))['project']
              as Map<String, dynamic>;
      item = await approve(item);
      item =
          (await plugin.call('save', {
                'id': item['id'],
                'revision': item['revision'],
                'plan_team': null,
              }))['project']
              as Map<String, dynamic>;
      expect(item.containsKey('plan_team'), isFalse);
      expect(item['approved_version'], isNull);
      await plugin.call('plan', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 1);
      expect(commands.single.first, '/fixture/agent');
      await processes.single.finish('The fallback lead plan.');
      await waitUntil(() => plugin.summary()['running'] == 0);
    },
  );

  test(
    'saved setup request drafts preserve both targets and invalidate an obsolete proposal',
    () async {
      var item = await setupResult(
        await save(),
        request: 'Use fixture.',
        proposal: {
          'team': [
            {'agent': 'fixture', 'role': 'lead'},
          ],
          'rationale': 'The lead.',
          'warnings': [],
        },
      );
      item =
          (await plugin.call('save', {
                'id': item['id'],
                'revision': item['revision'],
                'setup_requests': {'plan': 'Plan with fixture.'},
              }))['project']
              as Map<String, dynamic>;
      expect(item['setup_requests'], {
        'plan': 'Plan with fixture.',
        'run': 'Use fixture.',
      });
      expect(item['setup_proposal'], isNotNull);
      item =
          (await plugin.call('save', {
                'id': item['id'],
                'revision': item['revision'],
                'setup_requests': {'run': 'Use another setup.'},
              }))['project']
              as Map<String, dynamic>;
      expect(item['setup_proposal'], isNull);
      await expectLater(
        plugin.call('setup_apply', {
          'id': item['id'],
          'revision': item['revision'],
        }),
        throwsA(errorCode('project_setup_proposal_unknown')),
      );
      await plugin.shutdown();
      plugin = AiProjectCenterPlugin(
        temporary.path,
        agentProfiles: () => profiles,
        filesystem: TestPosix(),
      );
      item = await project(plugin, item['id'] as String);
      expect(item['setup_requests'], {
        'plan': 'Plan with fixture.',
        'run': 'Use another setup.',
      });
    },
  );

  test(
    'setup proposal generation preserves the previous execution output and handoff',
    () async {
      var item = await approve(await save(plan: 'The plan.'));
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 1);
      await processes.single.finish('Earlier execution evidence.');
      await waitUntil(() => plugin.summary()['running'] == 0);
      item = await project(plugin, item['id'] as String);
      final handoff = item['handoff'];
      item = await setupResult(
        item,
        request: 'Use fixture.',
        proposal: {
          'team': [
            {'agent': 'fixture', 'role': 'lead'},
          ],
          'rationale': 'A new setup.',
          'warnings': [],
        },
      );
      expect(item['output'], 'Earlier execution evidence.');
      expect(item['handoff'], handoff);
      expect(item['approved_version'], item['plan_version']);
      expect(item['setup_output'], contains('A new setup.'));
    },
  );

  test(
    'setup and replanning retain partial-execution reconciliation until an acknowledged run',
    () async {
      var item = await approve(await save(plan: 'The initial plan.'));
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 1);
      processes.single.lines.add('A partial operation already happened.');
      item =
          (await plugin.call('pause', {'id': item['id']}))['project']
              as Map<String, dynamic>;
      item =
          (await plugin.call('save', {
                'id': item['id'],
                'revision': item['revision'],
                'brief': 'Revise the remaining work.',
              }))['project']
              as Map<String, dynamic>;
      item = await setupResult(
        item,
        request: 'Use fixture.',
        proposal: {
          'team': [
            {'agent': 'fixture', 'role': 'lead'},
          ],
          'rationale': 'The revised team.',
          'warnings': [],
        },
      );
      expect(item['needs_reconciliation'], isTrue);
      item =
          (await plugin.call('setup_apply', {
                'id': item['id'],
                'revision': item['revision'],
              }))['project']
              as Map<String, dynamic>;
      await plugin.call('plan', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 3);
      expect(
        commands.last.last,
        contains('A partial operation already happened.'),
      );
      await processes.last.finish('The revised plan.');
      await waitUntil(() => plugin.summary()['running'] == 0);
      item = await approve(await project(plugin, item['id'] as String));
      expect(item['needs_reconciliation'], isTrue);
      await expectLater(
        plugin.call('run', {'id': item['id'], 'revision': item['revision']}),
        throwsA(errorCode('project_review_changes_first')),
      );
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
        'acknowledge_interrupted': true,
      });
      await waitUntil(() => processes.length == 4);
      expect(
        commands.last.last,
        contains('A partial operation already happened.'),
      );
      await processes.last.finish('The acknowledged remaining work finished.');
      await waitUntil(() => plugin.summary()['running'] == 0);
    },
  );

  // Task 082 external review fixes.

  test(
    'a storage fault still lets Pause stop work and halts every other project',
    () async {
      final second = Directory('${temporary.path}/second')..createSync();
      final a = await approve(await save(plan: 'Plan A.'));
      final b = await approve(
        await save(title: 'B', path: second.path, plan: 'Plan B.'),
      );
      await plugin.call('run', {'id': a['id'], 'revision': a['revision']});
      await plugin.call('run', {'id': b['id'], 'revision': b['revision']});
      await waitUntil(() => processes.length == 2);
      final file = File('${plugin.directory}/projects.json')..deleteSync();
      Directory(file.path).createSync();
      // An unrelated write fails first; running work must stop right away.
      await expectLater(
        save(title: 'C'),
        throwsA(errorCode('project_store_unavailable')),
      );
      expect(processes.every((process) => process.stopped), isTrue);
      final paused =
          (await plugin
                  .call('pause', {'id': a['id']})
                  .catchError(
                    (Object error) =>
                        error is ServiceError &&
                            error.code == 'project_not_running'
                        ? plugin.call('get', {'id': a['id']})
                        : throw error,
                  ))['project']
              as Map<String, dynamic>;
      expect(paused['status'], 'paused');
      await waitUntil(() => plugin.summary()['running'] == 0);
      expect(plugin.summary()['error'], 'project_store_unavailable');
      expect(commands, hasLength(2));
    },
  );

  test('Retry pause asks again after a refused stop', () async {
    var item = await approve(await save(plan: 'The plan.'));
    await plugin.call('run', {'id': item['id'], 'revision': item['revision']});
    await waitUntil(() => processes.length == 1);
    processes.single.refuseStop = true;
    await expectLater(
      plugin.call('pause', {'id': item['id']}),
      throwsA(errorCode('project_still_pausing')),
    );
    item = await project(plugin, item['id'] as String);
    expect(item['status'], 'pausing');
    processes.single.refuseStop = false;
    item =
        (await plugin.call('pause', {
              'id': item['id'],
              'run_id': item['run_id'],
            }))['project']
            as Map<String, dynamic>;
    expect(item['status'], 'paused');
  });

  test('shutdown stops all projects in parallel and can be retried', () async {
    final second = Directory('${temporary.path}/second')..createSync();
    final a = await approve(await save(plan: 'Plan A.'));
    final b = await approve(
      await save(title: 'B', path: second.path, plan: 'Plan B.'),
    );
    await plugin.call('run', {'id': a['id'], 'revision': a['revision']});
    await plugin.call('run', {'id': b['id'], 'revision': b['revision']});
    await waitUntil(() => processes.length == 2);
    for (final process in processes) {
      process.refuseStop = true;
    }
    final started = DateTime.now();
    await expectLater(
      plugin.shutdown(),
      throwsA(errorCode('project_still_pausing')),
    );
    // Both attempts share one deadline instead of adding up.
    expect(DateTime.now().difference(started).inSeconds, lessThan(10));
    expect(
      (await plugin.call('summary', {}))['pausing'] as int,
      greaterThanOrEqualTo(0),
    );
    for (final process in processes) {
      process.refuseStop = false;
    }
    await plugin.shutdown();
    expect(processes.every((process) => process.stopped), isTrue);
  });

  test(
    'project views report approval validity; completed work can be reapproved',
    () async {
      var item = await approve(await save(plan: 'The plan.'));
      expect(item['approval_valid'], isTrue);
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 1);
      await processes.single.finish('Done.');
      await waitUntil(() => plugin.summary()['running'] == 0);
      item = await project(plugin, item['id'] as String);
      expect(item['status'], 'completed');
      profiles.single['permissions'] = 'Changed scope.';
      item = await project(plugin, item['id'] as String);
      expect(item['approval_valid'], isFalse);
      item = await approve(item);
      expect(item['status'], 'ready');
      expect(item['approval_valid'], isTrue);
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 2);
      await processes.last.finish('Done again.');
      await waitUntil(() => plugin.summary()['running'] == 0);
    },
  );

  test(
    'model catalog and served-model refreshes do not invalidate approval',
    () async {
      addRuntime();
      profiles.single['models'] = ['cloud-a'];
      var item = await approve(
        await save(
          plan: 'The plan.',
          team: [
            {
              'agent': 'fixture',
              'role': 'lead',
              'runtime': 'runtime',
              'provider': 'local-provider',
              'model': 'tiny-model',
            },
          ],
        ),
      );
      profiles.single['models'] = ['cloud-a', 'cloud-b'];
      runtimes.single['models'] = ['tiny-model', 'other-model'];
      ((runtimes.single['bindings'] as Map)['fixture'] as Map)['models'] = [
        'tiny-model',
        'other-model',
      ];
      item = await project(plugin, item['id'] as String);
      expect(item['approval_valid'], isTrue);
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 1);
      runtimes.single['models'] = ['tiny-model', 'third-model'];
      await processes.single.finish('Done.');
      await waitUntil(() => plugin.summary()['running'] == 0);
      item = await project(plugin, item['id'] as String);
      expect(item['status'], 'completed');
      // The binding's provider is launch-affecting.
      ((runtimes.single['bindings'] as Map)['fixture'] as Map)['provider'] =
          'another-provider';
      item = await project(plugin, item['id'] as String);
      expect(item['approval_valid'], isFalse);
    },
  );

  test('generating a proposal keeps an approved ready project ready', () async {
    var item = await approve(await save(plan: 'The approved plan.'));
    item = await setupResult(
      item,
      request: 'Use fixture.',
      proposal: {
        'team': [
          {'agent': 'fixture', 'role': 'lead'},
        ],
        'rationale': 'The lead.',
        'warnings': [],
      },
    );
    expect(item['status'], 'ready');
    expect(item['approval_valid'], isTrue);
    expect(item['setup_proposal'], isNotNull);
  });

  test(
    'a failed setup leaves the project and its approval unchanged',
    () async {
      var item = await approve(await save(plan: 'The approved plan.'));
      final count = processes.length;
      await plugin.call('setup', {
        'id': item['id'],
        'revision': item['revision'],
        'request': 'Use fixture.',
        'agent': 'fixture',
      });
      await waitUntil(() => processes.length == count + 1);
      await processes.last.finish('not json', 3);
      await waitUntil(() => plugin.summary()['running'] == 0);
      item = await project(plugin, item['id'] as String);
      expect(item['status'], 'ready');
      expect(item['phase'], 'planning');
      expect(item['setup_error'], 'project_setup_agent_failed');
      expect(item['approval_valid'], isTrue);
    },
  );

  test(
    'applying a stale proposal cannot erase a paused execution checkpoint',
    () async {
      var item = await setupResult(
        await save(plan: 'The approved plan.'),
        request: 'Use fixture.',
        proposal: {
          'team': [
            {'agent': 'fixture', 'role': 'lead'},
          ],
          'rationale': 'The lead.',
          'warnings': [],
        },
      );
      item = await approve(item);
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 2);
      item =
          (await plugin.call('pause', {'id': item['id']}))['project']
              as Map<String, dynamic>;
      expect(item['setup_proposal'], isNotNull);
      final before = jsonEncode(item);
      await expectLater(
        plugin.call('setup_apply', {
          'id': item['id'],
          'revision': item['revision'],
        }),
        throwsA(errorCode('project_review_changes_first')),
      );
      expect(jsonEncode(await project(plugin, item['id'] as String)), before);
    },
  );

  test('a title-only change clears the proposal but keeps approval', () async {
    var item = await setupResult(
      await approve(await save(plan: 'The approved plan.')),
      request: 'Use fixture.',
      proposal: {
        'team': [
          {'agent': 'fixture', 'role': 'lead'},
        ],
        'rationale': 'The lead.',
        'warnings': [],
      },
    );
    expect(item['setup_proposal'], isNotNull);
    item =
        (await plugin.call('save', {
              'id': item['id'],
              'revision': item['revision'],
              'title': 'A renamed project',
            }))['project']
            as Map<String, dynamic>;
    expect(item['setup_proposal'], isNull);
    expect(item['approval_valid'], isTrue);
    expect(item['status'], 'ready');
  });

  test('continuing a setup record requires a stopped setup', () async {
    final item = await save();
    await plugin.shutdown();
    final state = File('${plugin.directory}/projects.json');
    final body = jsonDecode(state.readAsStringSync()) as Map;
    final stored = (body['projects'] as List).single as Map;
    stored['phase'] = 'setup';
    stored['status'] = 'draft';
    stored['setup_request'] = 'Use fixture.';
    stored['setup_agent'] = 'fixture';
    state.writeAsStringSync(jsonEncode(body));
    plugin = AiProjectCenterPlugin(
      temporary.path,
      agentProfiles: () => profiles,
      filesystem: TestPosix(),
      runner: (argv, cwd, environment, input, _, _) async {
        commands.add(argv);
        final process = FakeProjectProcess();
        processes.add(process);
        return process;
      },
    );
    final current = await project(plugin, item['id'] as String);
    await expectLater(
      plugin.call('continue', {
        'id': item['id'],
        'revision': current['revision'],
      }),
      throwsA(errorCode('project_not_paused')),
    );
    expect(commands, isEmpty);
  });

  test(
    'an interrupted setup restores the earlier state after a restart',
    () async {
      var item = await approve(await save(plan: 'The approved plan.'));
      await plugin.call('setup', {
        'id': item['id'],
        'revision': item['revision'],
        'request': 'Use fixture.',
        'agent': 'fixture',
      });
      await waitUntil(() => processes.length == 1);
      final stored = File(
        '${plugin.directory}/projects.json',
      ).readAsStringSync();
      await processes.single.finish('');
      await plugin.shutdown();
      File('${plugin.directory}/projects.json').writeAsStringSync(stored);
      plugin = AiProjectCenterPlugin(
        temporary.path,
        agentProfiles: () => profiles,
        filesystem: TestPosix(),
      );
      item = await project(plugin, item['id'] as String);
      expect(item['status'], 'ready');
      expect(item['setup_error'], 'interrupted');
      expect(item['approval_valid'], isTrue);
    },
  );

  test(
    'a run lock held by an earlier supervisor blocks the project and its folder',
    () async {
      final item = await approve(await save(plan: 'The plan.'));
      final other = await approve(await save(title: 'Other', plan: 'Other.'));
      final runs = Directory('${plugin.directory}/runs')..createSync();
      final lock = File('${runs.path}/${item['id']}.lock')
        ..writeAsStringSync('');
      final io = Posix();
      final fd = io.openAt(-100, lock.path, Posix.noFollow);
      try {
        expect(io.tryFlock(fd, shared: true), isTrue);
        expect(
          (await project(plugin, item['id'] as String))['processes_stopping'],
          isTrue,
        );
        await expectLater(
          plugin.call('run', {'id': item['id'], 'revision': item['revision']}),
          throwsA(errorCode('project_still_pausing')),
        );
        await expectLater(
          plugin.call('run', {
            'id': other['id'],
            'revision': other['revision'],
          }),
          throwsA(errorCode('project_folder_busy')),
        );
      } finally {
        io.close(fd);
      }
      await plugin.call('run', {
        'id': other['id'],
        'revision': other['revision'],
      });
      await waitUntil(() => processes.length == 1);
      await processes.single.finish('Done.');
      await waitUntil(() => plugin.summary()['running'] == 0);
    },
  );

  test(
    'a named agent without a project profile needs an explained exclusion',
    () async {
      profiles.add({
        'id': 'gemini',
        'name': 'Gemini CLI',
        'aliases': ['Gemini'],
        'installed': true,
        'project_supported': false,
      });
      var item = await setupResult(
        await save(),
        request: 'Use Fixture agent with Gemini.',
        proposal: {
          'team': [
            {'agent': 'fixture', 'role': 'lead'},
          ],
          'rationale': 'The lead.',
          'warnings': [],
        },
      );
      expect(item['setup_proposal'], isNull);
      expect(item['setup_error'], 'project_setup_agent_omitted');
      item = await setupResult(
        item,
        request: 'Use Fixture agent with Gemini.',
        proposal: {
          'team': [
            {'agent': 'fixture', 'role': 'lead'},
          ],
          'rationale': 'The lead.',
          'warnings': ['Gemini has no managed project profile.'],
          'excluded_agents': ['gemini'],
        },
      );
      expect(item['setup_proposal'], isNotNull);
      expect(
        ((await plugin.call('profiles', {}))['profiles'] as List).map(
          (profile) => (profile as Map)['id'],
        ),
        isNot(contains('gemini')),
      );
    },
  );

  test('a template that ends option parsing is refused', () async {
    profiles.single['model_option'] = '--model';
    profiles.single['plan_argv'] = ['/fixture/agent', '--', '{prompt}'];
    final item = await save(
      team: [
        {'agent': 'fixture', 'role': 'lead', 'model': 'm'},
      ],
    );
    await plugin.call('plan', {'id': item['id'], 'revision': item['revision']});
    await waitUntil(() => plugin.summary()['running'] == 0);
    expect(
      (await project(plugin, item['id'] as String))['events'].last['text'],
      'project_profile_invalid',
    );
    expect(commands, isEmpty);
  });

  test(
    'renewing approval keeps a paused checkpoint and resumes at its assignment',
    () async {
      var item = await approve(
        await save(
          plan: 'The plan.',
          team: [
            {'agent': 'fixture', 'role': 'lead'},
            {'agent': 'fixture', 'role': 'implementer'},
          ],
        ),
      );
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 1);
      await processes.single.finish('Lead done.');
      await waitUntil(() => processes.length == 2);
      item =
          (await plugin.call('pause', {'id': item['id']}))['project']
              as Map<String, dynamic>;
      expect(item['status'], 'paused');
      expect(item['next_member'], 1);
      profiles.single['permissions'] = 'Changed scope.';
      item = await project(plugin, item['id'] as String);
      expect(item['approval_valid'], isFalse);
      item = await approve(item);
      expect(item['status'], 'paused');
      expect(item['approval_valid'], isTrue);
      await plugin.call('continue', {
        'id': item['id'],
        'revision': item['revision'],
        'acknowledge_interrupted': true,
      });
      await waitUntil(() => processes.length == 3);
      expect(
        commands.last,
        isNot(contains(contains('Your role: lead'))),
        reason: 'the completed lead assignment must not run again',
      );
      await processes.last.finish('Implementer done.');
      await waitUntil(() => plugin.summary()['running'] == 0);
    },
  );

  test(
    'an unconfirmed setup cleanup keeps its snapshot until the stop is confirmed',
    () async {
      var item = await approve(await save(plan: 'The approved plan.'));
      await plugin.call('setup', {
        'id': item['id'],
        'revision': item['revision'],
        'request': 'Use fixture.',
        'agent': 'fixture',
      });
      await waitUntil(() => processes.length == 1);
      processes.single.refuseStop = true;
      await processes.single.finish('not json', 3);
      await waitUntil(() => plugin.summary()['pausing'] == 1);
      item = await project(plugin, item['id'] as String);
      expect(item['phase'], 'setup');
      processes.single.refuseStop = false;
      item =
          (await plugin.call('pause', {'id': item['id']}))['project']
              as Map<String, dynamic>;
      expect(item['status'], 'ready');
      expect(item['phase'], 'planning');
      expect(item['approval_valid'], isTrue);
      expect(item['setup_error'], isNotNull);
    },
  );

  test('concurrent shutdown calls share one attempt', () async {
    final item = await approve(await save(plan: 'The plan.'));
    await plugin.call('run', {'id': item['id'], 'revision': item['revision']});
    await waitUntil(() => processes.length == 1);
    processes.single.refuseStop = true;
    final first = plugin.shutdown();
    final second = plugin.shutdown();
    await expectLater(first, throwsA(errorCode('project_still_pausing')));
    await expectLater(second, throwsA(errorCode('project_still_pausing')));
    processes.single.refuseStop = false;
    await plugin.shutdown();
  });

  test(
    'a full store stops running work and the unsaved result fails visibly',
    () async {
      final second = Directory('${temporary.path}/second')..createSync();
      final a = await approve(await save(plan: 'Plan A.'));
      final b = await approve(
        await save(title: 'B', path: second.path, plan: 'Plan B.'),
      );
      final size = File('${plugin.directory}/projects.json').lengthSync();
      await plugin.shutdown();
      plugin = AiProjectCenterPlugin(
        temporary.path,
        agentProfiles: () => profiles,
        filesystem: TestPosix(),
        storeLimit: size + 6000,
        runner: (argv, cwd, environment, input, _, _) async {
          commands.add(argv);
          final process = FakeProjectProcess();
          processes.add(process);
          return process;
        },
      );
      final ra = await project(plugin, a['id'] as String);
      final rb = await project(plugin, b['id'] as String);
      await plugin.call('run', {'id': ra['id'], 'revision': ra['revision']});
      await plugin.call('run', {'id': rb['id'], 'revision': rb['revision']});
      await waitUntil(() => processes.length == 2);
      // A's result outgrows the store.
      await processes.first.finish('x' * 20000);
      await waitUntil(() => processes.every((process) => process.stopped));
      await waitUntil(() => plugin.summary()['running'] == 0);
      // A's result could not be saved: the fault stays visible, nothing
      // completed silently, and B was stopped instead of running unsaved.
      expect(plugin.summary()['error'], 'project_store_full');
      final failed = await project(plugin, a['id'] as String);
      expect(failed['status'], 'failed');
      expect((failed['events'] as List).last['text'], 'project_store_full');
      expect(
        (await project(plugin, b['id'] as String))['status'],
        isNot('completed'),
      );
      await expectLater(
        save(title: 'C'),
        throwsA(errorCode('project_store_full')),
      );
      expect(plugin.summary()['error'], 'project_store_full');
      final current = await project(plugin, b['id'] as String);
      await plugin.call('delete', {
        'id': current['id'],
        'revision': current['revision'],
      });
      expect(plugin.summary()['error'], isNull);
    },
  );

  test(
    'a retired controller never writes over its replacement store',
    () async {
      final spawning = Completer<ProjectProcess>();
      await plugin.shutdown();
      final retired = AiProjectCenterPlugin(
        temporary.path,
        agentProfiles: () => profiles,
        filesystem: TestPosix(),
        runner: (argv, cwd, environment, input, _, _) => spawning.future,
      );
      var item = await retired.call('save', {
        'title': 'Old',
        'brief': 'Goal.',
        'path': workspace,
        'team': [
          {'agent': 'fixture', 'role': 'lead'},
        ],
        'plan': 'Plan.',
      });
      final old = item['project'] as Map<String, dynamic>;
      await retired.call('plan', {
        'id': old['id'],
        'revision': old['revision'],
      });
      retired.detach();
      plugin = AiProjectCenterPlugin(
        temporary.path,
        agentProfiles: () => profiles,
        filesystem: TestPosix(),
      );
      await save(title: 'Replacement');
      final before = File(
        '${plugin.directory}/projects.json',
      ).readAsStringSync();
      final process = FakeProjectProcess();
      spawning.complete(process);
      await process.finish('Late plan.');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        File('${plugin.directory}/projects.json').readAsStringSync(),
        before,
      );
      expect(before, contains('Replacement'));
    },
  );

  test('a launch withdrawn by Pause is a pause, not a failure', () async {
    final starting = Completer<void>();
    final release = Completer<void>();
    await plugin.shutdown();
    plugin = AiProjectCenterPlugin(
      temporary.path,
      agentProfiles: () => profiles,
      filesystem: TestPosix(),
      runner: (argv, cwd, environment, input, _, mayLaunch) async {
        starting.complete();
        await release.future;
        if (!mayLaunch()) throw ServiceError('project_launch_withdrawn');
        commands.add(argv);
        final process = FakeProjectProcess();
        processes.add(process);
        return process;
      },
    );
    final item = await approve(await save(plan: 'The plan.'));
    await plugin.call('run', {'id': item['id'], 'revision': item['revision']});
    await starting.future;
    final pausing = plugin.call('pause', {'id': item['id']});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    release.complete();
    final paused = (await pausing)['project'] as Map<String, dynamic>;
    expect(paused['status'], 'paused');
    expect(commands, isEmpty);
  });
}
