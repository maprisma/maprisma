import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_core/src/features/ai_project_center.dart';
import 'package:maprisma_core/src/features/project_supervisor.dart'
    show projectSupervisorCommand;
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
  Future<void>? stopGate;
  int stopCalls = 0;
  int outputReads = 0;
  int exitReads = 0;
  bool _finished = false;

  /// What [started] answers: the agent's process exists (task 096).
  Future<bool> starts = Future.value(true);
  @override
  Future<bool> get started => starts;
  @override
  Stream<String> get output {
    outputReads++;
    return lines.stream;
  }

  @override
  Future<int> get exitCode {
    exitReads++;
    return exit.future;
  }

  Future<void> finish(String text, [int code = 0]) async {
    if (_finished) return;
    _finished = true;
    if (text.isNotEmpty) lines.add(text);
    await lines.close();
    exit.complete(code);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    // A stop that takes a while (task 096: requests arriving meanwhile).
    await stopGate;
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
  // When set, reading the agent profiles fails through it (task 085).
  List<Map<String, dynamic>> Function()? profilesFail;
  // When set, what the next started agents answer (task 096).
  Future<bool> Function()? startGate;
  // When set and it returns an error, the next launch fails with it.
  ServiceError? Function()? launchFail;
  late List<FakeProjectProcess> processes;
  late List<List<String>> commands;
  late List<String> directories;
  late List<Map<String, String>> environments;

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
    profilesFail = null;
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
    environments = [];
    startGate = null;
    launchFail = null;
    plugin = AiProjectCenterPlugin(
      temporary.path,
      agentProfiles: () {
        final fail = profilesFail;
        if (fail != null) return fail();
        return profiles;
      },
      runtimeProfiles: () => runtimes,
      filesystem: TestPosix(),
      runner: (argv, cwd, environment, input, _, _) async {
        commands.add(argv);
        directories.add(cwd);
        environments.add(environment);
        final failure = launchFail?.call();
        if (failure != null) throw failure;
        final process = FakeProjectProcess();
        final gate = startGate;
        if (gate != null) process.starts = gate();
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
      // Task 098: the answer is the plan, not a note about missing tools.
      expect(commands.single.last, contains('answer with the plan itself'));
      expect(commands.single.last, contains('Do not write files'));
      await processes[0].finish(
        '1. Make the requested change.\n2. Run the acceptance check.',
      );
      await waitUntil(() => processes.length == 2);
      expect(commands[1][1], 'read-only');
      expect(commands[1].last, contains('Check feasibility.'));
      expect(commands[1].last, isNot(contains('answer with the plan itself')));
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
      // The view follows the shared display snapshot: the host's refresh
      // (F5, or a change made through Maprisma) grows the generation.
      plugin.discoveryGeneration++;
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
      // A fresh snapshot is read (not the cached one), and still valid.
      plugin.discoveryGeneration++;
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
      plugin.discoveryGeneration++;
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

  test('a phase env reaches only that phase and overrides the user', () async {
    profiles.single['plan_env'] = {'GOOSE_MODE': 'chat'};
    profiles.single['run_env'] = {'GOOSE_MODE': 'auto'};
    var item = await save(plan: 'The plan.');
    item = await approve(item);
    await plugin.call('run', {'id': item['id'], 'revision': item['revision']});
    await waitUntil(() => processes.length == 1);
    expect(environments.single['GOOSE_MODE'], 'auto');
    await processes.single.finish('Done.');
    await waitUntil(() => plugin.summary()['running'] == 0);
  });

  test('a planning assignment gets the plan env', () async {
    profiles.single['plan_env'] = {'GOOSE_MODE': 'chat'};
    final item = await save();
    await plugin.call('plan', {'id': item['id'], 'revision': item['revision']});
    await waitUntil(() => processes.length == 1);
    expect(environments.single['GOOSE_MODE'], 'chat');
    await processes.single.finish('The plan.');
    await waitUntil(() => plugin.summary()['running'] == 0);
  });

  for (final env in [
    {'LD_PRELOAD': '/tmp/x.so'},
    {'NODE_OPTIONS': '--require=/tmp/x.js'},
    {'PYTHONPATH': '/tmp'},
    {'PATH': '/tmp'},
    {'MAPRISMA_PAGE': 'x'},
    {'CLAUDECODE': '1'},
    {'lower': 'x'},
    {'GOOSE_MODE': 'yolo'},
  ]) {
    test('a profile env ${env.keys.single} is refused', () async {
      profiles.single['plan_env'] = env;
      final item = await save();
      await expectLater(
        plugin.call('plan', {'id': item['id'], 'revision': item['revision']}),
        throwsA(errorCode('project_profile_invalid')),
      );
      expect(commands, isEmpty);
    });
  }

  test('the phase env overrides the user\'s own value', () async {
    await plugin.shutdown();
    plugin = AiProjectCenterPlugin(
      temporary.path,
      agentProfiles: () => profiles,
      filesystem: TestPosix(),
      environment: {'GOOSE_MODE': 'approve', 'KEEP': 'me'},
      runner: (argv, cwd, environment, input, _, _) async {
        commands.add(argv);
        environments.add(environment);
        final process = FakeProjectProcess();
        processes.add(process);
        return process;
      },
    );
    profiles.single['plan_env'] = {'GOOSE_MODE': 'auto'};
    final item = await save();
    await plugin.call('plan', {'id': item['id'], 'revision': item['revision']});
    await waitUntil(() => processes.length == 1);
    expect(environments.single['GOOSE_MODE'], 'auto');
    expect(environments.single['KEEP'], 'me');
    await processes.single.finish('The plan.');
    await waitUntil(() => plugin.summary()['running'] == 0);
  });

  test('a reviewer in execution gets the plan env', () async {
    profiles.single['plan_env'] = {'GOOSE_MODE': 'chat'};
    profiles.single['run_env'] = {'GOOSE_MODE': 'auto'};
    var item = await save(
      plan: 'Implement then review.',
      team: [
        {'agent': 'fixture', 'role': 'lead'},
        {'agent': 'fixture', 'role': 'reviewer'},
      ],
    );
    item = await approve(item);
    await plugin.call('run', {'id': item['id'], 'revision': item['revision']});
    await waitUntil(() => processes.length == 1);
    expect(environments[0]['GOOSE_MODE'], 'auto');
    await processes[0].finish('Lead finished.');
    await waitUntil(() => processes.length == 2);
    expect(environments[1]['GOOSE_MODE'], 'chat');
    await processes[1].finish('CLEAN');
    await waitUntil(() => plugin.summary()['running'] == 0);
  });

  test('an invalid setup env is refused before the project changes', () async {
    profiles.single['setup_env'] = {'NODE_OPTIONS': '--require=/x.js'};
    final item = await save();
    await expectLater(
      plugin.call('setup', {
        'id': item['id'],
        'revision': item['revision'],
        'request': 'A team please.',
        'agent': 'fixture',
      }),
      throwsA(errorCode('project_profile_invalid')),
    );
    expect(commands, isEmpty);
    final after = await project(plugin, item['id'] as String);
    expect(after['revision'], item['revision']);
  });

  test(
    'an old approval stays valid and an empty env table is no change',
    () async {
      final item = await approve(await save(plan: 'The checked plan.'));
      profiles.single['run_env'] = <String, String>{};
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 1);
      await processes.single.finish('Done.');
      await waitUntil(() => plugin.summary()['running'] == 0);
    },
  );

  test('an env change invalidates an already approved plan', () async {
    profiles.single['run_env'] = {'GOOSE_MODE': 'chat'};
    final item = await approve(await save(plan: 'The checked plan.'));
    profiles.single['run_env'] = {'GOOSE_MODE': 'auto'};
    await expectLater(
      plugin.call('run', {'id': item['id'], 'revision': item['revision']}),
      throwsA(errorCode('project_plan_not_approved')),
    );
    expect(commands, isEmpty);
  });

  test('a template that ends option parsing is refused', () async {
    profiles.single['model_option'] = '--model';
    profiles.single['plan_argv'] = ['/fixture/agent', '--', '{prompt}'];
    final item = await save(
      team: [
        {'agent': 'fixture', 'role': 'lead', 'model': 'm'},
      ],
    );
    // Refused before anything starts (the same check as the dispatch's).
    await expectLater(
      plugin.call('plan', {'id': item['id'], 'revision': item['revision']}),
      throwsA(errorCode('project_profile_invalid')),
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
      // The view follows the shared display snapshot: the host's refresh
      // (F5, or a change made through Maprisma) grows the generation.
      plugin.discoveryGeneration++;
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

  group('summary for the Projects tab (task 085)', () {
    Future<void> setStatus(String id, String status, {String? phase}) async {
      await plugin.shutdown();
      final state = File('${plugin.directory}/projects.json');
      final body = jsonDecode(state.readAsStringSync()) as Map;
      for (final item in (body['projects'] as List).cast<Map>()) {
        if (item['id'] == id) {
          item['status'] = status;
          if (phase != null) item['phase'] = phase;
        }
      }
      state.writeAsStringSync(jsonEncode(body));
      plugin = AiProjectCenterPlugin(
        temporary.path,
        agentProfiles: () => profiles,
        runtimeProfiles: () => runtimes,
        filesystem: TestPosix(),
      );
    }

    test('counts each project once, by its bucket', () async {
      await save(title: 'Draft');
      final review = await save(title: 'Review', plan: 'A saved plan.');
      final broken = await save(title: 'Broken', plan: 'A saved plan.');
      await setStatus(review['id'] as String, 'awaiting_review');
      await setStatus(broken['id'] as String, 'failed', phase: 'running');
      final summary = plugin.summary();
      expect(summary['total'], 3);
      expect(summary['drafts'], 1);
      expect(summary['needs_you'], 1);
      expect(summary['waiting'], 1);
      expect(summary['attention_projects'], 1);
      expect(summary['attention'], 1);
      expect(summary['by_agent'], {'fixture': 3});
      final buckets = [
        'attention_projects',
        'needs_you',
        'ready',
        'drafts',
        'finished',
      ];
      final sum =
          buckets.fold<int>(0, (n, k) => n + (summary[k] as int)) +
          (summary['running'] as int) +
          (summary['pausing'] as int);
      expect(sum, 3);
    });

    test(
      'a ready project is Ready while its approval holds, then needs you',
      () async {
        final item = await approve(await save(plan: 'A saved plan.'));
        expect(item['status'], 'ready');
        expect(plugin.summary()['ready'], 1);
        // A launch-affecting profile fact changes outside Maprisma.
        profiles.first['run_argv'] = ['/fixture/agent', 'changed', '{prompt}'];
        // Within the same generation and 60 seconds the display cache holds.
        expect(plugin.summary()['ready'], 1);
        plugin.discoveryGeneration++;
        final summary = plugin.summary();
        expect(summary['ready'], 0);
        expect(summary['needs_you'], 1);
      },
    );

    test('the display snapshot is at most 60 seconds old', () async {
      var now = DateTime(2026);
      plugin.displayClock = () => now;
      await approve(await save(plan: 'A saved plan.'));
      expect(plugin.summary()['ready'], 1);
      profiles.first['run_argv'] = ['/fixture/agent', 'changed', '{prompt}'];
      now = now.add(const Duration(seconds: 59));
      expect(plugin.summary()['ready'], 1);
      now = now.add(const Duration(seconds: 2));
      expect(plugin.summary()['ready'], 0);
    });

    test('a launch refreshes every project\'s derived approval', () async {
      final first = await approve(
        await save(title: 'A', plan: 'A saved plan.'),
      );
      await approve(await save(title: 'B', plan: 'A saved plan.'));
      expect(plugin.summary()['ready'], 2);
      profiles.first['run_argv'] = ['/fixture/agent', 'changed', '{prompt}'];
      // Running A takes a fresh snapshot (and is refused: its approval no
      // longer matches); B's cached approval goes with it.
      await expectLater(
        plugin.call('run', {'id': first['id'], 'revision': first['revision']}),
        throwsA(anything),
      );
      expect(plugin.summary()['ready'], 0);
    });

    test('by_agent counts a project once even in both teams', () async {
      final saved =
          (await plugin.call('save', {
                'title': 'Both teams',
                'brief': 'Build the requested change and verify it.',
                'path': workspace,
                'team': [
                  {'agent': 'fixture', 'role': 'lead'},
                ],
                'plan_team': [
                  {'agent': 'fixture', 'role': 'lead'},
                ],
                'plan': '',
              }))['project']
              as Map<String, dynamic>;
      expect(saved['plan_team'], isNotNull);
      expect(plugin.summary()['by_agent'], {'fixture': 1});
    });

    test(
      'a project whose processes are stopping counts only as pausing',
      () async {
        final item = await save(plan: 'A saved plan.');
        await setStatus(item['id'] as String, 'awaiting_review');
        // A supervisor of an earlier controller still holds the run lock.
        final runs = Directory('${plugin.directory}/runs')
          ..createSync(recursive: true);
        final io = Posix();
        final fd = io.openAt(
          -100,
          '${runs.path}/${item['id']}.lock',
          Posix.noFollow | 0x40 | 0x2,
          0x180,
        );
        addTearDown(() => io.close(fd));
        expect(io.tryFlock(fd, shared: true), isTrue);
        final summary = plugin.summary();
        expect(summary['pausing'], 1);
        expect(summary['waiting'], 0);
        expect(summary['needs_you'], 0);
        expect(summary['attention'], 0);
      },
    );

    test('a store fault is in error, not in the project counts', () async {
      await save(title: 'Saved first');
      // The store's folder becomes unwritable: the next write fails.
      final folder = Directory(plugin.directory);
      Process.runSync('chmod', ['0500', folder.path]);
      addTearDown(() => Process.runSync('chmod', ['0700', folder.path]));
      await expectLater(save(title: 'Not written'), throwsA(anything));
      Process.runSync('chmod', ['0700', folder.path]);
      final small = plugin;
      final summary = small.summary();
      expect(summary['error'], isA<String>());
      expect(summary['attention_projects'], 0);
      expect(summary['attention'], 1);
    });

    test(
      'a later assignment start refreshes another project\'s approval',
      () async {
        final team = [
          {'agent': 'fixture', 'role': 'lead'},
          {'agent': 'fixture', 'role': 'reviewer'},
        ];
        var first = await approve(
          await save(title: 'A', plan: 'The plan.', team: team),
        );
        await approve(await save(title: 'B', plan: 'The plan.'));
        expect(plugin.summary()['ready'], 2);
        await plugin.call('run', {
          'id': first['id'],
          'revision': first['revision'],
        });
        await waitUntil(() => processes.length == 1);
        expect(plugin.summary()['ready'], 1);
        // Changed while the lead runs; the reviewer's start reads it fresh
        // (and is refused), and B's cached approval goes with it.
        profiles.first['run_argv'] = ['/fixture/agent', 'changed', '{prompt}'];
        await processes.single.finish('Lead done.');
        await waitUntil(() => plugin.summary()['running'] == 0);
        first = await project(plugin, first['id'] as String);
        expect(plugin.summary()['ready'], 0);
      },
    );

    test(
      'a failing scan is read once, not for every project and poll',
      () async {
        var now = DateTime(2026);
        plugin.displayClock = () => now;
        for (final title in ['A', 'B', 'C']) {
          await approve(await save(title: title, plan: 'A saved plan.'));
        }
        expect(plugin.summary()['ready'], 3);
        var reads = 0;
        final healthy = List.of(profiles);
        profilesFail = () {
          reads++;
          throw StateError('scan failed');
        };
        plugin.discoveryGeneration++;
        final summary = plugin.summary();
        expect(summary['ready'], 0);
        expect(summary['needs_you'], 3);
        expect(reads, 1);
        now = now.add(const Duration(seconds: 5));
        plugin.summary();
        expect(reads, 1);
        now = now.add(const Duration(seconds: 6));
        plugin.summary();
        expect(reads, 2);
        profilesFail = null;
        profiles = healthy;
      },
    );

    test('an approval right after a failed scan shows as valid', () async {
      var now = DateTime(2026);
      plugin.displayClock = () => now;
      await approve(await save(title: 'A', plan: 'A saved plan.'));
      final healthy = List.of(profiles);
      profilesFail = () => throw StateError('scan failed');
      plugin.discoveryGeneration++;
      expect(plugin.summary()['ready'], 0);
      // The scanner recovers; the user approves another project at once.
      profilesFail = null;
      profiles = healthy;
      now = now.add(const Duration(seconds: 2));
      final b = await approve(await save(title: 'B', plan: 'A saved plan.'));
      expect(b['approval_valid'], isTrue);
      expect(plugin.summary()['ready'], 2);
    });

    test('a clock set back rebuilds the snapshot', () async {
      var now = DateTime(2026, 6);
      plugin.displayClock = () => now;
      await approve(await save(plan: 'A saved plan.'));
      expect(plugin.summary()['ready'], 1);
      profiles.first['run_argv'] = ['/fixture/agent', 'changed', '{prompt}'];
      now = now.subtract(const Duration(hours: 1));
      expect(plugin.summary()['ready'], 0);
    });

    test('a draft never makes the summary read profiles', () async {
      await save();
      var reads = 0;
      final counting = AiProjectCenterPlugin(
        '${temporary.path}/other',
        agentProfiles: () {
          reads++;
          return profiles;
        },
        filesystem: TestPosix(),
      );
      addTearDown(counting.shutdown);
      await counting.call('save', {
        'title': 'Draft',
        'brief': 'Build it.',
        'path': workspace,
        'team': [
          {'agent': 'fixture', 'role': 'lead'},
        ],
        'plan': '',
      });
      final before = reads;
      counting.summary();
      counting.summary();
      expect(reads, before);
    });
  });

  group('board projection (task 087)', () {
    Future<void> edit(String id, void Function(Map item) change) async {
      await plugin.shutdown();
      final state = File('${plugin.directory}/projects.json');
      final body = jsonDecode(state.readAsStringSync()) as Map;
      for (final item in (body['projects'] as List).cast<Map>()) {
        if (item['id'] == id) change(item);
      }
      state.writeAsStringSync(jsonEncode(body));
      plugin = AiProjectCenterPlugin(
        temporary.path,
        agentProfiles: () {
          final fail = profilesFail;
          if (fail != null) return fail();
          return profiles;
        },
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
    }

    Future<List<Map<String, dynamic>>> board() async =>
        ((await plugin.call('list', {}))['projects'] as List)
            .cast<Map<String, dynamic>>();

    Future<Map<String, dynamic>> card(String id) async =>
        (await board()).singleWhere((p) => p['id'] == id);

    test('a card carries the state, the teams and the last event', () async {
      addPartner();
      final item = await save(
        plan: 'A saved plan.',
        team: [
          {'agent': 'fixture', 'role': 'lead'},
          {'agent': 'partner', 'role': 'implementer', 'model': 'known-model'},
          {'agent': 'fixture', 'role': 'reviewer'},
        ],
      );
      final c = await card(item['id'] as String);
      for (final key in [
        'id',
        'title',
        'path',
        'status',
        'revision',
        'updated_at',
        'phase',
        'run_id',
        'stage',
        'activity',
        'second',
        'bucket',
        'approval_valid',
        'needs_reconciliation',
        'processes_stopping',
        'issues',
        'planning',
        'execution',
        'active',
        'setup_agent',
        'setup_error',
        'last_event',
      ]) {
        expect(c.containsKey(key), isTrue, reason: key);
      }
      expect(c['stage'], 'approval');
      expect(c['activity'], 'needs_review');
      expect(c['bucket'], 'needs_you');
      expect(c['issues'], isEmpty);
      // Execution: lead, implementers, reviewer; names from the profiles.
      expect(
        [for (final a in c['execution'] as List) a['role']],
        ['lead', 'implementer', 'reviewer'],
      );
      expect((c['execution'] as List)[1]['name'], 'Partner agent');
      expect((c['execution'] as List)[1]['model'], 'known-model');
      expect((c['execution'] as List)[1]['position'], 1);
      // Planning without its own team: the lead and the reviewer.
      expect(
        [for (final a in c['planning'] as List) a['role']],
        ['lead', 'reviewer'],
      );
      expect(c['last_event'], isA<Map>());
    });

    test(
      'a planning team of its own: an implementer reads contributor',
      () async {
        addPartner();
        final item = await save(plan: 'A saved plan.');
        await edit(item['id'] as String, (p) {
          p['plan_team'] = [
            {'agent': 'fixture', 'role': 'lead', 'access': 'read-only'},
            {'agent': 'partner', 'role': 'implementer', 'access': 'read-only'},
          ];
        });
        final c = await card(item['id'] as String);
        expect(
          [for (final a in c['planning'] as List) a['role']],
          ['lead', 'contributor'],
        );
      },
    );

    test('a broken draft still lists, with its issues', () async {
      final item = await save(plan: '');
      await edit(item['id'] as String, (p) {
        p['team'] = [
          {'agent': 'gone', 'role': 'implementer'},
        ];
        p['brief'] = ' ';
        p['path'] = '${temporary.path}/no-such-folder';
      });
      final c = await card(item['id'] as String);
      expect(
        [for (final i in c['issues'] as List) i['code']],
        ['folder_missing', 'no_lead', 'empty_goal'],
      );
      final member = (c['execution'] as List).single as Map;
      expect(member['name'], 'gone');
      expect(
        [for (final i in member['issues'] as List) i['code']],
        ['agent_unavailable'],
      );
    });

    test('the active assignment: next, active, stopped, stopping', () async {
      final ready = await approve(await save(plan: 'A saved plan.'));
      expect((await card(ready['id'] as String))['active'], {
        'phase': 'execution',
        'position': 0,
        'state': 'next',
      });
      await plugin.call('run', {
        'id': ready['id'],
        'revision': ready['revision'],
      });
      await waitUntil(() => processes.isNotEmpty);
      expect((await card(ready['id'] as String))['active'], {
        'phase': 'execution',
        'position': 0,
        'state': 'active',
      });
      await processes.last.finish('Done.', 1);
      await waitUntil(() => plugin.summary()['running'] == 0);
      final failed = await card(ready['id'] as String);
      expect(failed['status'], 'failed');
      expect((failed['active'] as Map)['state'], 'stopped');
      // A supervisor of an earlier controller still holds the run lock.
      final runs = Directory('${plugin.directory}/runs')
        ..createSync(recursive: true);
      final io = Posix();
      final fd = io.openAt(
        -100,
        '${runs.path}/${ready['id']}.lock',
        Posix.noFollow | 0x40 | 0x2,
        0x180,
      );
      addTearDown(() => io.close(fd));
      expect(io.tryFlock(fd, shared: true), isTrue);
      final stopping = await card(ready['id'] as String);
      expect(stopping['processes_stopping'], isTrue);
      expect((stopping['active'] as Map)['state'], 'stopping');
    });

    test('Approved · blocked: a stopped runtime, then Ready without a new '
        'approval', () async {
      addRuntime();
      final item = await approve(
        await save(
          plan: 'A saved plan.',
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
      final id = item['id'] as String;
      expect((await card(id))['activity'], 'ready_to_run');
      runtimes.single['running'] = false;
      plugin.discoveryGeneration++;
      var c = await card(id);
      expect(c['activity'], 'approved_blocked');
      expect(c['bucket'], 'needs_you');
      expect(c['approval_valid'], isTrue);
      expect(
        [for (final i in c['issues'] as List) i['code']],
        ['runtime_stopped'],
      );
      expect(plugin.summary()['needs_you'], 1);
      expect(plugin.summary()['ready'], 0);
      // The model gone instead: blocked too.
      runtimes.single['running'] = true;
      runtimes.single['models'] = ['other-model'];
      plugin.discoveryGeneration++;
      c = await card(id);
      expect(c['activity'], 'approved_blocked');
      expect(
        [for (final i in c['issues'] as List) i['code']],
        ['model_unavailable'],
      );
      // Fixed: Ready again, the same approval.
      runtimes.single['models'] = ['tiny-model'];
      plugin.discoveryGeneration++;
      c = await card(id);
      expect(c['activity'], 'ready_to_run');
      expect(c['bucket'], 'ready');
      expect(c['revision'], item['revision']);
    });

    test('Approved · blocked: the folder gone', () async {
      final folder = Directory('${temporary.path}/folder')..createSync();
      final item = await approve(
        await save(plan: 'A saved plan.', path: folder.path),
      );
      folder.deleteSync();
      final c = await card(item['id'] as String);
      expect(c['activity'], 'approved_blocked');
      expect(
        [for (final i in c['issues'] as List) i['code']],
        ['folder_missing'],
      );
      folder.createSync();
      // Seen again with the next snapshot (a refresh, a new generation).
      plugin.discoveryGeneration++;
      expect((await card(item['id'] as String))['activity'], 'ready_to_run');
    });

    test('urgency shows and counts but does not sort (task 095)', () async {
      final broken = await save(title: 'Broken', plan: 'A saved plan.');
      await save(title: 'Review', plan: 'A saved plan.');
      await save(title: 'Draft');
      await edit(broken['id'] as String, (p) {
        p['status'] = 'failed';
        p['phase'] = 'running';
      });
      final cards = await board();
      expect(
        [for (final p in cards) p['title']],
        ['Draft', 'Review', 'Broken'],
      );
      expect(cards.last['bucket'], 'attention');
      expect(
        ((await plugin.call('list', {}))['summary']
            as Map)['attention_projects'],
        1,
      );
    });

    test('one profile read for the whole board', () async {
      var reads = 0;
      profilesFail = () {
        reads++;
        return profiles;
      };
      for (final title in ['A', 'B', 'C', 'D']) {
        await approve(await save(title: title, plan: 'A saved plan.'));
      }
      plugin.discoveryGeneration++;
      reads = 0;
      await board();
      expect(reads, 1);
      profilesFail = null;
    });

    test('the team in launch order whatever order it was saved in', () async {
      addPartner();
      final item = await save(
        plan: 'A saved plan.',
        team: [
          {'agent': 'fixture', 'role': 'reviewer'},
          {'agent': 'partner', 'role': 'implementer'},
          {'agent': 'fixture', 'role': 'lead'},
        ],
      );
      final c = await card(item['id'] as String);
      expect(
        [for (final a in c['execution'] as List) a['role']],
        ['lead', 'implementer', 'reviewer'],
      );
      expect([for (final a in c['planning'] as List) a['position']], [0, 1]);
      expect(
        [for (final a in c['planning'] as List) a['role']],
        ['lead', 'reviewer'],
      );
    });

    test('blocked exactly when the launch refuses: a local provider without '
        'its runtime', () async {
      profiles.first['model_option'] = '--model';
      final item = await approve(
        await save(
          plan: 'A saved plan.',
          team: [
            {'agent': 'fixture', 'role': 'lead', 'model': 'local/tiny'},
          ],
        ),
      );
      final id = item['id'] as String;
      expect((await card(id))['activity'], 'ready_to_run');
      // The agent now names `local` a local provider: the run would need its
      // runtime, so the launch refuses.
      profiles.first['local_providers'] = ['local'];
      plugin.discoveryGeneration++;
      final c = await card(id);
      expect(c['activity'], 'approved_blocked');
      expect(
        [for (final i in c['issues'] as List) i['code']],
        ['runtime_required'],
      );
      await expectLater(
        plugin.call('run', {'id': id, 'revision': item['revision']}),
        throwsA(errorCode('project_runtime_required')),
      );
      profiles.first.remove('local_providers');
      plugin.discoveryGeneration++;
      expect((await card(id))['activity'], 'ready_to_run');
    });

    test('each launch issue once, also for several members', () async {
      addRuntime();
      final bound = {
        'agent': 'fixture',
        'runtime': 'runtime',
        'provider': 'local-provider',
        'model': 'tiny-model',
      };
      final item = await approve(
        await save(
          plan: 'A saved plan.',
          team: [
            {...bound, 'role': 'lead'},
            {...bound, 'role': 'reviewer'},
          ],
        ),
      );
      runtimes.single['running'] = false;
      plugin.discoveryGeneration++;
      final c = await card(item['id'] as String);
      expect(c['issues'], [
        {
          'code': 'runtime_stopped',
          'target': 'runtime',
          'node': 'runtime:runtime',
          'fix': 'map',
        },
      ]);
      expect(plugin.summary()['needs_you'], 1);
    });

    test('issue links (task 092): target, map box and fix per code', () async {
      addRuntime();
      var n = 0;
      Future<Map> issueOf(Map<String, dynamic> member) async {
        final item = await save(
          title: 'T${n++}',
          plan: 'A saved plan.',
          team: [
            {'role': 'lead', ...member},
          ],
        );
        plugin.discoveryGeneration++;
        final c = await card(item['id'] as String);
        return ((c['execution'] as List).single['issues'] as List).single
            as Map;
      }

      const bound = {
        'agent': 'fixture',
        'runtime': 'runtime',
        'provider': 'local-provider',
        'model': 'tiny-model',
      };
      // A stopped runtime that is installed: fixed on the map, at its box.
      runtimes.single['running'] = false;
      expect(await issueOf(bound), {
        'code': 'runtime_stopped',
        'target': 'runtime',
        'node': 'runtime:runtime',
        'fix': 'map',
      });
      // Not installed: no box on the map; another runtime in the Team tab.
      runtimes.single['installed'] = false;
      expect(await issueOf(bound), {
        'code': 'runtime_stopped',
        'target': 'runtime',
        'fix': 'team',
      });
      runtimes.single
        ..['installed'] = true
        ..['running'] = true;
      // A model the runtime does not serve: its runtime's box (its models).
      expect(await issueOf({...bound, 'model': 'Other-Model'}), {
        'code': 'model_unavailable',
        'target': 'model',
        'node': 'runtime:runtime',
        'fix': 'map',
      });
      // No model chosen for the runtime: only the Team tab chooses one.
      expect(await issueOf({...bound}..remove('model')), {
        'code': 'model_unavailable',
        'target': 'model',
        'fix': 'team',
      });
      // A permission the agent does not offer.
      profiles.first['access_modes'] = ['read-only'];
      expect(await issueOf({'agent': 'fixture', 'access': 'project-edit'}), {
        'code': 'access_unsupported',
        'target': 'permission',
        'fix': 'team',
      });
      profiles.first.remove('access_modes');
      // A provider the agent's connection does not name: the Team tab.
      expect(await issueOf({...bound, 'provider': 'another-provider'}), {
        'code': 'provider_unavailable',
        'target': 'provider',
        'fix': 'team',
      });
      // Not connected to this runtime at all: connected on the map.
      final bindings = runtimes.single['bindings'] as Map;
      final binding = bindings.remove('fixture');
      expect(await issueOf(bound), {
        'code': 'provider_unavailable',
        'target': 'provider',
        'node': 'runtime:runtime',
        'fix': 'map',
      });
      // ... unless the agent has no provider option: the Team tab.
      final option = profiles.first.remove('provider_option');
      expect(await issueOf(bound), {
        'code': 'provider_unavailable',
        'target': 'provider',
        'fix': 'team',
      });
      profiles.first['provider_option'] = option;
      bindings['fixture'] = binding;
      // A provider without its runtime: chosen in the Team tab.
      expect(
        await issueOf({'agent': 'fixture', 'provider': 'local-provider'}),
        {'code': 'runtime_required', 'target': 'runtime', 'fix': 'team'},
      );
      // A model while the agent has no model option.
      final modelOption = profiles.first.remove('model_option');
      expect(await issueOf({'agent': 'fixture', 'model': 'some-model'}), {
        'code': 'model_unsupported',
        'target': 'model',
        'fix': 'team',
      });
      profiles.first['model_option'] = modelOption;
      // Subagents the agent cannot run.
      expect(
        await issueOf({
          'agent': 'fixture',
          'subagents': ['helper'],
        }),
        {'code': 'subagents_unsupported', 'target': 'agent', 'fix': 'team'},
      );
      // An agent that is gone: another agent in the Team tab.
      expect(await issueOf({'agent': 'gone-agent'}), {
        'code': 'agent_unavailable',
        'target': 'agent',
        'fix': 'team',
      });
    });

    test('project issues link to the Goal and Team tabs', () async {
      final item = await save(plan: 'A saved plan.', team: []);
      Directory(item['path'] as String).deleteSync(recursive: true);
      plugin.discoveryGeneration++;
      final c = await card(item['id'] as String);
      expect(
        c['issues'],
        containsAll([
          {'code': 'folder_missing', 'target': 'folder', 'fix': 'goal'},
          {'code': 'no_lead', 'target': 'team', 'fix': 'team'},
        ]),
      );
    });

    test('a changed folder and an empty goal link to the Goal tab', () async {
      final real = Directory('${Directory(workspace).parent.path}/real')
        ..createSync();
      final linked = Directory('${Directory(workspace).parent.path}/linked')
        ..createSync();
      final item = await save(path: linked.path, plan: 'A saved plan.');
      // The saved folder now leads somewhere else.
      linked.deleteSync();
      Link(linked.path).createSync(real.path);
      final empty =
          (await plugin.call('save', {
                'title': 'No goal',
                'brief': '',
                'path': workspace,
                'team': [
                  {'agent': 'fixture', 'role': 'lead'},
                ],
                'plan': '',
              }))['project']
              as Map<String, dynamic>;
      plugin.discoveryGeneration++;
      expect((await card(item['id'] as String))['issues'], [
        {'code': 'folder_changed', 'target': 'folder', 'fix': 'goal'},
      ]);
      expect((await card(empty['id'] as String))['issues'], [
        {'code': 'empty_goal', 'target': 'goal', 'fix': 'goal'},
      ]);
    });

    test('two stopped runtimes are two issues on the card', () async {
      addRuntime();
      runtimes.add({
        ...runtimes.single,
        'key': 'second',
        'bindings': {
          'fixture': {
            'provider': 'local-provider',
            'models': ['tiny-model'],
          },
        },
      });
      final item = await approve(
        await save(
          plan: 'A saved plan.',
          team: [
            {
              'agent': 'fixture',
              'role': 'lead',
              'runtime': 'runtime',
              'provider': 'local-provider',
              'model': 'tiny-model',
            },
            {
              'agent': 'fixture',
              'role': 'reviewer',
              'runtime': 'second',
              'provider': 'local-provider',
              'model': 'tiny-model',
            },
          ],
        ),
      );
      for (final r in runtimes) {
        r['running'] = false;
      }
      plugin.discoveryGeneration++;
      final c = await card(item['id'] as String);
      expect(
        [for (final i in c['issues'] as List) i['node']],
        ['runtime:runtime', 'runtime:second'],
      );
    });

    test(
      'the summary poll reads no folder; a new snapshot looks again',
      () async {
        for (final title in ['A', 'B', 'C']) {
          await approve(await save(title: title, plan: 'A saved plan.'));
        }
        plugin.summary();
        await board();
        final checks = plugin.folderChecks;
        for (var i = 0; i < 5; i++) {
          plugin.summary();
        }
        await board();
        expect(plugin.folderChecks, checks);
        plugin.discoveryGeneration++;
        plugin.summary();
        expect(plugin.folderChecks, checks + 3);
      },
    );

    test('a list and its summary agree', () async {
      addRuntime();
      await approve(
        await save(
          plan: 'A saved plan.',
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
      await save(title: 'Draft');
      runtimes.single['running'] = false;
      plugin.discoveryGeneration++;
      final listed = await plugin.call('list', {});
      final cards = (listed['projects'] as List).cast<Map>();
      final summary = listed['summary'] as Map;
      for (final bucket in ['needs_you', 'ready', 'drafts']) {
        expect(
          summary[bucket],
          cards.where((c) => c['bucket'] == bucket).length,
          reason: bucket,
        );
      }
    });

    test('no assignment named after a restart without a team step', () async {
      final ready = await approve(await save(plan: 'A saved plan.'));
      final id = ready['id'] as String;
      // An old supervisor (a team setup interrupted by a restart) still
      // holds the lock of a ready project.
      final runs = Directory('${plugin.directory}/runs')
        ..createSync(recursive: true);
      final io = Posix();
      final fd = io.openAt(
        -100,
        '${runs.path}/$id.lock',
        Posix.noFollow | 0x40 | 0x2,
        0x180,
      );
      addTearDown(() => io.close(fd));
      expect(io.tryFlock(fd, shared: true), isTrue);
      final c = await card(id);
      expect(c['activity'], 'stopping');
      expect(c['active'], isNull);
    });

    test(
      'a member that already ran is stopped, not next (a real run)',
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
        final id = item['id'] as String;
        await plugin.call('run', {'id': id, 'revision': item['revision']});
        await waitUntil(() => processes.length == 1);
        await processes.single.finish('Lead done.');
        // The second member is dispatched and running.
        await waitUntil(() => processes.length == 2);
        expect((await card(id))['active'], {
          'phase': 'execution',
          'position': 1,
          'state': 'active',
        });
        item =
            (await plugin.call('pause', {'id': id}))['project']
                as Map<String, dynamic>;
        expect(item['status'], 'paused');
        expect(((await card(id))['active'] as Map)['state'], 'stopped');
      },
    );

    test('stopped right after an assignment ended: the next one; never past '
        'the team', () async {
      final item = await approve(await save(plan: 'A saved plan.'));
      final id = item['id'] as String;
      await edit(id, (p) {
        p['status'] = 'interrupted';
        p['phase'] = 'running';
        p['next_member'] = 0;
        p['assignment_started'] = false;
      });
      expect((await card(id))['active'], {
        'phase': 'execution',
        'position': 0,
        'state': 'next',
      });
      await edit(id, (p) {
        p['assignment_started'] = true;
      });
      expect(((await card(id))['active'] as Map)['state'], 'stopped');
      // A store from before this field: stopped.
      await edit(id, (p) {
        p.remove('assignment_started');
      });
      expect(((await card(id))['active'] as Map)['state'], 'stopped');
      // After the last assignment: nothing left to point at.
      await edit(id, (p) {
        p['next_member'] = 1;
      });
      expect((await card(id))['active'], isNull);
    });

    test(
      'a team setup in between keeps a stopped member stopped (a real run)',
      () async {
        var item = await save(
          plan: '',
          team: [
            {'agent': 'fixture', 'role': 'lead'},
            {'agent': 'fixture', 'role': 'reviewer'},
          ],
        );
        final id = item['id'] as String;
        await plugin.call('plan', {'id': id, 'revision': item['revision']});
        await waitUntil(() => processes.length == 1);
        await processes.single.finish('1. Plan it.');
        await waitUntil(() => processes.length == 2);
        await plugin.call('pause', {'id': id});
        var c = await card(id);
        expect(c['status'], 'paused');
        expect(c['active'], {
          'phase': 'planning',
          'position': 1,
          'state': 'stopped',
        });
        // A team setup runs and ends with a proposal (not applied): the
        // checkpoint comes back as it was.
        item = await project(plugin, id);
        await setupResult(
          item,
          request: 'Use fixture.',
          proposal: {
            'team': [
              {'agent': 'fixture', 'role': 'lead'},
            ],
            'rationale': 'Fine.',
            'warnings': [],
          },
        );
        c = await card(id);
        expect(c['status'], 'paused');
        expect(c['active'], {
          'phase': 'planning',
          'position': 1,
          'state': 'stopped',
        });
      },
    );

    test('an interrupted team setup still stopping names no member', () async {
      final item = await save(plan: 'A saved plan.');
      final id = item['id'] as String;
      await edit(id, (p) {
        p['status'] = 'paused';
        p['phase'] = 'planning';
        p['next_member'] = 0;
        p['events'] = [
          {
            'at': '2026-11-21T10:00:00.000Z',
            'type': 'setup_interrupted',
            'text': 'x',
          },
        ];
      });
      final runs = Directory('${plugin.directory}/runs')
        ..createSync(recursive: true);
      final io = Posix();
      final fd = io.openAt(
        -100,
        '${runs.path}/$id.lock',
        Posix.noFollow | 0x40 | 0x2,
        0x180,
      );
      addTearDown(() => io.close(fd));
      expect(io.tryFlock(fd, shared: true), isTrue);
      final c = await card(id);
      expect(c['activity'], 'stopping');
      expect(c['active'], isNull);
    });

    test('a template the dispatch would refuse shows on the board', () async {
      final item = await approve(await save(plan: 'A saved plan.'));
      profiles.single['run_argv'] = ['/fixture/agent', '--', '{prompt}'];
      plugin.discoveryGeneration++;
      final c = await card(item['id'] as String);
      // The approval itself covers the argv: Approve again, with the reason.
      expect(c['activity'], 'approve_again');
      expect(((c['execution'] as List).single['issues'] as List).single, {
        'code': 'profile_invalid',
        'target': 'profile',
        'fix': 'team',
      });
    });

    test(
      'one answer, one snapshot: the 60-second edge within a list',
      () async {
        var now = DateTime(2026);
        plugin.displayClock = () => now;
        final item = await approve(await save(plan: 'A saved plan.'));
        expect((await card(item['id'] as String))['activity'], 'ready_to_run');
        var reads = 0;
        profilesFail = () {
          reads++;
          // The clock passes the 60 seconds while this list is answered.
          now = now.add(const Duration(seconds: 61));
          return profiles;
        };
        now = now.add(const Duration(seconds: 61));
        await board();
        expect(reads, 1);
        profilesFail = null;
      },
    );

    test(
      'every bucket in the user\'s order, not by urgency or change (task 095)',
      () async {
        final ids = <String, String>{};
        for (final title in [
          'Draft',
          'Review old',
          'Review new',
          'Broken',
          'Done',
          'Ready',
          'Running',
        ]) {
          ids[title] =
              (await save(title: title, plan: 'A saved plan.'))['id'] as String;
        }
        await approve(await card(ids['Ready']!));
        await edit(ids['Broken']!, (p) {
          p['status'] = 'failed';
          p['phase'] = 'running';
        });
        await edit(ids['Done']!, (p) {
          p['status'] = 'completed';
          p['phase'] = 'running';
        });
        await edit(ids['Draft']!, (p) {
          p['status'] = 'draft';
        });
        await edit(ids['Review old']!, (p) {
          p['updated_at'] = '2026-01-01T00:00:00.000Z';
        });
        await edit(ids['Review new']!, (p) {
          p['updated_at'] = '2026-06-01T00:00:00.000Z';
        });
        // Running: a held run lock (an earlier supervisor still stopping).
        final runs = Directory('${plugin.directory}/runs')
          ..createSync(recursive: true);
        final io = Posix();
        final fd = io.openAt(
          -100,
          '${runs.path}/${ids['Running']}.lock',
          Posix.noFollow | 0x40 | 0x2,
          0x180,
        );
        addTearDown(() => io.close(fd));
        expect(io.tryFlock(fd, shared: true), isTrue);
        // Newest on top; the buckets are on the cards, not in the order.
        final cards = await board();
        expect(
          [for (final p in cards) (p['title'], p['bucket'])],
          [
            ('Running', 'running'),
            ('Ready', 'ready'),
            ('Done', 'finished'),
            ('Broken', 'attention'),
            ('Review new', 'needs_you'),
            ('Review old', 'needs_you'),
            ('Draft', 'drafts'),
          ],
        );
      },
    );

    test(
      'a store from before task 095: newest first on equal changes',
      () async {
        for (var n = 0; n < 40; n++) {
          await save(title: 'P$n');
        }
        await plugin.shutdown();
        final state = File('${plugin.directory}/projects.json');
        final body = jsonDecode(state.readAsStringSync()) as Map;
        // Creation order, as the store kept it before, without ranks.
        body['projects'] = (body['projects'] as List).reversed.toList();
        for (final item in (body['projects'] as List).cast<Map>()) {
          item['updated_at'] = '2026-01-01T00:00:00.000Z';
          item.remove('importance');
          item.remove('board_rank');
        }
        state.writeAsStringSync(jsonEncode(body));
        plugin = AiProjectCenterPlugin(
          temporary.path,
          agentProfiles: () => profiles,
          filesystem: TestPosix(),
        );
        final cards = await board();
        expect(
          [for (final p in cards) p['title']],
          [for (var n = 39; n >= 0; n--) 'P$n'],
        );
        expect(cards.every((p) => p['importance'] == 'medium'), isTrue);
      },
    );

    group('board order and importance (task 095)', () {
      Future<List<String>> titles() async => [
        for (final p in await board()) p['title'] as String,
      ];

      Future<void> reopen() async {
        await plugin.shutdown();
        plugin = AiProjectCenterPlugin(
          temporary.path,
          agentProfiles: () => profiles,
          filesystem: TestPosix(),
        );
      }

      Map<String, dynamic> stored() =>
          jsonDecode(
                File('${plugin.directory}/projects.json').readAsStringSync(),
              )
              as Map<String, dynamic>;

      Future<Map<String, String>> three() async => {
        for (final title in ['A', 'B', 'C'])
          title: (await save(title: title))['id'] as String,
      };

      test('new projects go on top; the order survives a reopen', () async {
        final ids = await three();
        expect(await titles(), ['C', 'B', 'A']);
        expect(
          [for (final p in stored()['projects'] as List) p['board_rank']],
          [0, 1, 2],
        );
        // The rank is stored only.
        expect(
          (await project(plugin, ids['A']!)).containsKey('board_rank'),
          isFalse,
        );
        expect((await board()).first.containsKey('board_rank'), isFalse);
        expect(
          [for (final p in stored()['projects'] as List) p['id']],
          [ids['C'], ids['B'], ids['A']],
        );
        await plugin.call('move', {'id': ids['C'], 'before': null});
        await reopen();
        expect(await titles(), ['B', 'A', 'C']);
        await save(title: 'D');
        expect(await titles(), ['D', 'B', 'A', 'C']);
      });

      test('move up, down, to the top and to the end', () async {
        final ids = await three();
        final before = await project(plugin, ids['A']!);
        // A one up (before B).
        var moved = await plugin.call('move', {
          'id': ids['A'],
          'before': ids['B'],
        });
        expect(moved['order'], [ids['C'], ids['A'], ids['B']]);
        expect(await titles(), ['C', 'A', 'B']);
        // C one down (before B, the card after its lower neighbour).
        await plugin.call('move', {'id': ids['C'], 'before': ids['B']});
        expect(await titles(), ['A', 'C', 'B']);
        // B to the top, then A to the end (before absent).
        await plugin.call('move', {'id': ids['B'], 'before': ids['A']});
        expect(await titles(), ['B', 'A', 'C']);
        moved = await plugin.call('move', {'id': ids['A']});
        expect(moved['order'], [ids['B'], ids['C'], ids['A']]);
        // Before itself or where it is already: nothing changes.
        await plugin.call('move', {'id': ids['C'], 'before': ids['C']});
        await plugin.call('move', {'id': ids['C'], 'before': ids['A']});
        expect(await titles(), ['B', 'C', 'A']);
        // Not project content: revision and last change stay.
        final after = await project(plugin, ids['A']!);
        expect(after['revision'], before['revision']);
        expect(after['updated_at'], before['updated_at']);
        expect(after['events'], before['events']);
        await reopen();
        expect(await titles(), ['B', 'C', 'A']);
      });

      test('unknown ids and fields are refused, nothing moves', () async {
        final ids = await three();
        final unknown = '0' * 32;
        for (final params in [
          {'id': unknown},
          {'id': ids['A'], 'before': unknown},
          {'id': 7, 'before': ids['A']},
          {'id': ids['A'], 'before': 7},
        ]) {
          await expectLater(
            plugin.call('move', params),
            throwsA(errorCode('project_unknown')),
            reason: '$params',
          );
        }
        await expectLater(
          plugin.call('move', {'id': ids['A'], 'index': 0}),
          throwsA(isA<FormatException>()),
        );
        expect(await titles(), ['C', 'B', 'A']);
      });

      test('a deleted project leaves the order', () async {
        final ids = await three();
        final b = await project(plugin, ids['B']!);
        await plugin.call('delete', {'id': b['id'], 'revision': b['revision']});
        expect(await titles(), ['C', 'A']);
        expect(
          [for (final p in stored()['projects'] as List) p['id']],
          [ids['C'], ids['A']],
        );
        await expectLater(
          plugin.call('move', {'id': ids['A'], 'before': ids['B']}),
          throwsA(errorCode('project_unknown')),
        );
        await expectLater(
          plugin.call('move', {'id': ids['B']}),
          throwsA(errorCode('project_unknown')),
        );
        expect(await titles(), ['C', 'A']);
      });

      test('importance: Medium when new, set, validated, kept', () async {
        final ids = await three();
        expect((await project(plugin, ids['A']!))['importance'], 'medium');
        expect(
          (await board()).every((p) => p['importance'] == 'medium'),
          isTrue,
        );
        final item = await approve(
          (await plugin.call('save', {
                'id': ids['A'],
                'revision': (await project(plugin, ids['A']!))['revision'],
                'plan': 'A saved plan.',
              }))['project']
              as Map<String, dynamic>,
        );
        expect(item['status'], 'ready');
        final marked =
            (await plugin.call('set_importance', {
                  'id': ids['A'],
                  'importance': 'high',
                }))['project']
                as Map<String, dynamic>;
        expect(marked['importance'], 'high');
        // A mark, not content: revision, approval and last change stay.
        expect(marked['revision'], item['revision']);
        expect(marked['updated_at'], item['updated_at']);
        expect(marked['status'], 'ready');
        expect(marked['approval_valid'], isTrue);
        // It does not move the card.
        expect(await titles(), ['C', 'B', 'A']);
        expect((await board()).last['importance'], 'high');
        await plugin.call('set_importance', {
          'id': ids['B'],
          'importance': 'low',
        });
        for (final params in [
          {'id': ids['C'], 'importance': 'urgent'},
          {'id': ids['C'], 'importance': null},
          {'id': ids['C']},
          {'id': ids['C'], 'importance': 'high', 'revision': 1},
        ]) {
          await expectLater(
            plugin.call('set_importance', params),
            throwsA(isA<FormatException>()),
            reason: '$params',
          );
        }
        await expectLater(
          plugin.call('set_importance', {'id': '0' * 32, 'importance': 'low'}),
          throwsA(errorCode('project_unknown')),
        );
        await reopen();
        expect(
          [for (final p in await board()) p['importance']],
          ['medium', 'low', 'high'],
        );
      });

      test(
        'a stored mark, rank or marker out of range is a corrupt store',
        () async {
          await three();
          await plugin.shutdown();
          final state = File('${plugin.directory}/projects.json');
          final good = state.readAsStringSync();
          for (final (key, value) in <(String, Object?)>[
            ('importance', 'urgent'),
            ('importance', null),
            ('importance', 1),
            ('board_rank', -1),
            ('board_rank', 1.5),
            ('board_rank', '1'),
            ('board_rank', null),
            ('board_order', false),
            ('board_order', null),
            ('board_order', 'yes'),
          ]) {
            final body = jsonDecode(good) as Map;
            if (key == 'board_order') {
              body[key] = value;
            } else {
              (body['projects'] as List).first[key] = value;
            }
            state.writeAsStringSync(jsonEncode(body));
            expect(
              () => AiProjectCenterPlugin(
                temporary.path,
                agentProfiles: () => profiles,
                filesystem: TestPosix(),
              ),
              throwsA(errorCode('project_store_corrupt')),
              reason: '$key $value',
            );
          }
          // Without the rank (an older core's project) it still opens.
          final body = jsonDecode(good) as Map;
          (body['projects'] as List).first.remove('board_rank');
          state.writeAsStringSync(jsonEncode(body));
          await reopen();
          expect(await titles(), hasLength(3));
        },
      );

      test('ranks out of order and tied: by rank, then stored position; '
          'unranked on top', () async {
        await three();
        await plugin.shutdown();
        final state = File('${plugin.directory}/projects.json');
        final body = jsonDecode(state.readAsStringSync()) as Map;
        final stored = body['projects'] as List;
        final ranks = {'A': 2, 'B': 0, 'C': 2};
        for (final p in stored) {
          p['board_rank'] = ranks[p['title']];
        }
        // Stored as C, A, B: C and A tie at rank 2, C stored first.
        stored.sort(
          (a, b) => ['C', 'A', 'B']
              .indexOf(a['title'] as String)
              .compareTo(['C', 'A', 'B'].indexOf(b['title'] as String)),
        );
        final d = Map<String, dynamic>.from(stored.first as Map)
          ..['id'] = 'd' * 32
          ..['title'] = 'D'
          ..remove('board_rank');
        stored.add(d);
        state.writeAsStringSync(jsonEncode(body));
        await reopen();
        expect(await titles(), ['D', 'B', 'C', 'A']);
      });

      test('an older core\'s save keeps the arrangement; its new project '
          'goes on top', () async {
        final ids = await three();
        await plugin.call('move', {'id': ids['A'], 'before': ids['C']});
        await plugin.call('move', {'id': ids['B']});
        expect(await titles(), ['A', 'C', 'B']);
        await plugin.shutdown();
        // What an older core writes: {version, projects}, every project's
        // fields kept, its own new project appended without rank or mark.
        final state = File('${plugin.directory}/projects.json');
        final body = jsonDecode(state.readAsStringSync()) as Map;
        final projects = (body['projects'] as List).cast<Map>();
        final added = Map.of(projects.first)
          ..['id'] = 'f' * 32
          ..['title'] = 'D'
          ..['updated_at'] = '2026-01-01T00:00:00.000Z'
          ..remove('board_rank')
          ..remove('importance');
        state.writeAsStringSync(
          jsonEncode({
            'version': 1,
            'projects': [...projects, added],
          }),
        );
        await reopen();
        expect(await titles(), ['D', 'A', 'C', 'B']);
        expect((await board()).first['importance'], 'medium');
        // The next write ranks them all again.
        await plugin.call('move', {'id': 'f' * 32});
        await reopen();
        expect(await titles(), ['A', 'C', 'B', 'D']);
      });

      test('a store from before task 095: the latest change first', () async {
        final ids = await three();
        await plugin.shutdown();
        final state = File('${plugin.directory}/projects.json');
        final body = jsonDecode(state.readAsStringSync()) as Map;
        // Creation order A, B, C; A changed last, B and C at the same time.
        final byId = {
          for (final p in (body['projects'] as List).cast<Map>()) p['id']: p,
        };
        final times = {
          'A': '2026-03-01T00:00:00.000Z',
          'B': '2026-02-01T00:00:00.000Z',
          'C': '2026-02-01T00:00:00.000Z',
        };
        body['projects'] = [
          for (final title in ['A', 'B', 'C'])
            byId[ids[title]]!
              ..remove('board_rank')
              ..remove('importance')
              ..['updated_at'] = times[title],
        ];
        state.writeAsStringSync(jsonEncode(body));
        await reopen();
        // A first (latest change), then C before B (newest on the tie).
        expect(await titles(), ['A', 'C', 'B']);
      });

      test('a failing store refuses moves and marks cleanly', () async {
        final ids = await three();
        final file = File('${plugin.directory}/projects.json')..deleteSync();
        Directory(file.path).createSync();
        await expectLater(
          plugin.call('move', {'id': ids['A']!, 'before': ids['C']}),
          throwsA(errorCode('project_store_unavailable')),
        );
        expect(await titles(), ['C', 'B', 'A']);
        await expectLater(
          plugin.call('set_importance', {'id': ids['A'], 'importance': 'high'}),
          throwsA(errorCode('project_store_unavailable')),
        );
        expect((await project(plugin, ids['A']!))['importance'], 'medium');
        Directory(file.path).deleteSync();
      });

      test(
        'a failing write of a mark leaves the mark (fresh instance)',
        () async {
          final ids = await three();
          await reopen();
          final file = File('${plugin.directory}/projects.json')..deleteSync();
          Directory(file.path).createSync();
          // The mark's own write fails (no earlier fault).
          await expectLater(
            plugin.call('set_importance', {
              'id': ids['A'],
              'importance': 'high',
            }),
            throwsA(errorCode('project_store_unavailable')),
          );
          expect((await project(plugin, ids['A']!))['importance'], 'medium');
          expect((await board()).last['importance'], 'medium');
          expect(plugin.summary()['error'], 'project_store_unavailable');
          Directory(file.path).deleteSync();
        },
      );

      test('a full store refuses moves and marks, nothing changes', () async {
        final ids = await three();
        final size = File('${plugin.directory}/projects.json').lengthSync();
        await plugin.shutdown();
        plugin = AiProjectCenterPlugin(
          temporary.path,
          agentProfiles: () => profiles,
          filesystem: TestPosix(),
          // 'high' is two bytes shorter than 'medium'.
          storeLimit: size - 3,
        );
        await expectLater(
          plugin.call('move', {'id': ids['A'], 'before': ids['C']}),
          throwsA(errorCode('project_store_full')),
        );
        await expectLater(
          plugin.call('set_importance', {'id': ids['A'], 'importance': 'high'}),
          throwsA(errorCode('project_store_full')),
        );
        expect(await titles(), ['C', 'B', 'A']);
        expect((await project(plugin, ids['A']!))['importance'], 'medium');
        await reopen();
        expect(await titles(), ['C', 'B', 'A']);
        expect((await project(plugin, ids['A']!))['importance'], 'medium');
      });

      test('moved and marked while it runs: kept through the end and a '
          'reopen', () async {
        final ids = await three();
        var item = await project(plugin, ids['A']!);
        item = await approve(
          (await plugin.call('save', {
                'id': item['id'],
                'revision': item['revision'],
                'plan': 'A saved plan.',
              }))['project']
              as Map<String, dynamic>,
        );
        await plugin.call('run', {
          'id': item['id'],
          'revision': item['revision'],
        });
        await waitUntil(() => processes.length == 1);
        expect((await project(plugin, ids['A']!))['status'], 'running');
        await plugin.call('move', {'id': ids['A'], 'before': ids['C']});
        await plugin.call('set_importance', {
          'id': ids['A'],
          'importance': 'high',
        });
        expect(await titles(), ['A', 'C', 'B']);
        await processes.single.finish('Lead finished.');
        await waitUntil(() => plugin.summary()['running'] == 0);
        final done = await project(plugin, ids['A']!);
        expect(done['status'], 'completed');
        expect(done['importance'], 'high');
        expect(await titles(), ['A', 'C', 'B']);
        await reopen();
        expect(await titles(), ['A', 'C', 'B']);
        expect((await project(plugin, ids['A']!))['importance'], 'high');
      });
    });

    test('a fresh attempt starts with no member started', () async {
      var item = await approve(
        await save(
          plan: 'The plan.',
          team: [
            {'agent': 'fixture', 'role': 'lead'},
            {'agent': 'fixture', 'role': 'implementer'},
          ],
        ),
      );
      final id = item['id'] as String;
      Map stored() =>
          ((jsonDecode(
                        File(
                          '${plugin.directory}/projects.json',
                        ).readAsStringSync(),
                      )
                      as Map)['projects']
                  as List)
              .cast<Map>()
              .singleWhere((p) => p['id'] == id);
      expect(stored()['assignment_started'], isFalse);
      await plugin.call('run', {'id': id, 'revision': item['revision']});
      await waitUntil(() => processes.length == 1);
      expect(stored()['assignment_started'], isTrue);
      // Stopped while the lead runs: the next attempt starts fresh.
      await plugin.call('pause', {'id': id});
      expect(stored()['assignment_started'], isTrue);
      item = await project(plugin, id);
      // What the store says each time profiles are read: the dispatch reads
      // them after the fresh attempt was saved, before its first member.
      final seen = <(String, Object?)>[];
      profilesFail = () {
        final p = stored();
        seen.add(('${p['status']}', p['assignment_started']));
        return profiles;
      };
      await plugin.call('plan', {'id': id, 'revision': item['revision']});
      await waitUntil(() => processes.length == 2);
      profilesFail = null;
      // Saved as planning with no member started (a restart there would show
      // the first one as next, not stopped).
      expect(seen, contains(('planning', false)));
      expect(stored()['assignment_started'], isTrue);
    });
  });

  group('messages to a running project (task 096)', () {
    Future<Map<String, dynamic>> message(
      Map<String, dynamic> item,
      String text, {
      String mode = 'queue',
      Object? runId,
      bool? acknowledge,
    }) => plugin.call('message', {
      'id': item['id'],
      'run_id': runId ?? item['run_id'],
      'text': text,
      'mode': mode,
      if (acknowledge != null || mode == 'now')
        'acknowledge_interrupted': acknowledge ?? true,
    });

    int occurrences(String haystack, String needle) =>
        needle.allMatches(haystack).length;

    List<String> eventTypes(Map<String, dynamic> item) => [
      for (final event in item['events'] as List)
        (event as Map)['type'] as String,
    ];

    Future<Map<String, dynamic>> started(
      List<Map<String, dynamic>> team,
    ) async {
      final item = await approve(await save(plan: 'The plan.', team: team));
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      await waitUntil(() => processes.length == 1);
      return project(plugin, item['id'] as String);
    }

    test('Send queues for the next assignment, which gets it exactly once; '
        'the handoff keeps it for later ones', () async {
      final item = await started([
        {'agent': 'fixture', 'role': 'lead'},
        {'agent': 'fixture', 'role': 'implementer'},
        {'agent': 'fixture', 'role': 'reviewer'},
      ]);
      const text = 'Please also update the changelog.';
      final sent = await message(item, text);
      expect(sent['continued'], isFalse);
      expect(sent['reason'], isNull);
      expect((sent['message'] as Map)['state'], 'queued');
      var current = sent['project'] as Map<String, dynamic>;
      expect(current['status'], 'running');
      expect(current['messages_queued'], 1);
      expect(eventTypes(current).last, 'message');
      // The current agent keeps working; the card shows the count.
      expect(processes.single.stopped, isFalse);
      final card = ((await plugin.call('list', {}))['projects'] as List).single;
      expect((card as Map)['messages_queued'], 1);
      expect(occurrences(commands[0].last, text), 0);
      // Task 098: only planning prompts ask for the plan as the answer.
      expect(commands[0].last, isNot(contains('answer with the plan itself')));
      await processes[0].finish('Lead done.');
      await waitUntil(() => processes.length == 2);
      expect(occurrences(commands[1].last, text), 1);
      expect(commands[1].last, contains('Messages from the user'));
      current = await project(plugin, item['id'] as String);
      expect(current['messages_queued'], 0);
      final stored = (current['messages'] as List).single as Map;
      expect(stored['state'], 'delivered');
      expect(stored['delivered_to'], {
        'phase': 'execution',
        'position': 1,
        'agent': 'fixture',
        'role': 'implementer',
      });
      expect(occurrences(current['handoff'] as String, text), 1);
      expect(eventTypes(current), contains('message_delivered'));
      await processes[1].finish('Implemented.');
      await waitUntil(() => processes.length == 3);
      // Later assignments see it once, in the handoff, not as a new message.
      expect(occurrences(commands[2].last, text), 1);
      expect(commands[2].last, isNot(contains('Messages from the user')));
      await processes[2].finish('No findings.');
      await waitUntil(() => plugin.summary()['running'] == 0);
      expect(
        (await project(plugin, item['id'] as String))['status'],
        'completed',
      );
    });

    test('refused when not running, for another run, empty, too long, '
        'invalid or too many', () async {
      final ready = await approve(await save(plan: 'The plan.'));
      await expectLater(
        message(ready, 'Hello', runId: 'none'),
        throwsA(errorCode('project_not_running')),
      );
      final item = await started([
        {'agent': 'fixture', 'role': 'lead'},
      ]);
      await expectLater(
        message(item, 'Hello', runId: 'another-run'),
        throwsA(errorCode('project_changed')),
      );
      await expectLater(
        plugin.call('message', {'id': item['id'], 'text': 'Hello'}),
        throwsA(errorCode('project_changed')),
      );
      await expectLater(
        message(item, '  \n '),
        throwsA(errorCode('project_message_empty')),
      );
      await expectLater(
        message(item, 'ä' * 2049),
        throwsA(errorCode('project_message_too_long')),
      );
      await expectLater(
        message(item, 'Hello', mode: 'later'),
        throwsA(errorCode('project_message_invalid')),
      );
      await expectLater(
        plugin.call('message', {
          'id': item['id'],
          'run_id': item['run_id'],
          'text': 'Hello',
          'extra': true,
        }),
        throwsA(errorCode('project_message_invalid')),
      );
      await expectLater(
        plugin.call('message', {'id': 'unknown', 'run_id': 'x', 'text': 'Hi'}),
        throwsA(errorCode('project_unknown')),
      );
      // The longest allowed message is accepted; the queue is bounded.
      await message(item, 'ä' * 2048);
      for (var i = 1; i < AiProjectCenterPlugin.maxQueuedMessages; i++) {
        await message(item, 'Message $i');
      }
      await expectLater(
        message(item, 'One too many'),
        throwsA(errorCode('project_messages_full')),
      );
      // Ended runs refuse: the run id is still the last one.
      await processes.single.finish('Done.');
      await waitUntil(() => plugin.summary()['running'] == 0);
      final done = await project(plugin, item['id'] as String);
      expect(done['status'], 'completed');
      await expectLater(
        message(done, 'Too late'),
        throwsA(errorCode('project_not_running')),
      );
      // Nothing was delivered: the run had no further assignment.
      expect(done['messages_queued'], AiProjectCenterPlugin.maxQueuedMessages);
      expect(eventTypes(done), contains('message_waiting'));
      expect(commands, hasLength(1));
    });

    test('team setup refuses messages', () async {
      final item = await save();
      await plugin.call('setup', {
        'id': item['id'],
        'revision': item['revision'],
        'request': 'Use fixture.',
        'agent': 'fixture',
      });
      await waitUntil(() => processes.length == 1);
      final current = await project(plugin, item['id'] as String);
      await expectLater(
        message(current, 'Hello'),
        throwsA(errorCode('project_not_running')),
      );
      await processes.single.finish('{}');
      await waitUntil(() => plugin.summary()['running'] == 0);
    });

    test('while pausing, Send queues and Send now is refused', () async {
      final item = await started([
        {'agent': 'fixture', 'role': 'lead'},
      ]);
      processes.single.refuseStop = true;
      await expectLater(
        plugin.call('pause', {'id': item['id']}),
        throwsA(errorCode('project_still_pausing')),
      );
      await expectLater(
        message(item, 'Now, please', mode: 'now'),
        throwsA(errorCode('project_still_pausing')),
      );
      final sent = await message(item, 'When you continue, check the tests.');
      expect((sent['project'] as Map)['messages_queued'], 1);
      processes.single.refuseStop = false;
      var current =
          (await plugin.call('pause', {'id': item['id']}))['project']
              as Map<String, dynamic>;
      expect(current['status'], 'paused');
      await plugin.call('continue', {
        'id': item['id'],
        'revision': current['revision'],
        'acknowledge_interrupted': true,
      });
      await waitUntil(() => processes.length == 2);
      expect(
        occurrences(commands[1].last, 'When you continue, check the tests.'),
        1,
      );
      current = await project(plugin, item['id'] as String);
      expect(current['messages_queued'], 0);
    });

    test('Send now pauses the agent and continues at once with the handoff '
        'and the message', () async {
      final item = await started([
        {'agent': 'fixture', 'role': 'lead'},
        {'agent': 'fixture', 'role': 'implementer'},
      ]);
      processes[0].lines.add('Partial progress.');
      await Future<void>.delayed(Duration.zero);
      const text = 'Stop using the old API, switch to the new one.';
      final sent = await message(item, text, mode: 'now');
      expect(sent['continued'], isTrue, reason: '${sent['reason']}');
      expect(processes[0].stopped, isTrue);
      await waitUntil(() => processes.length == 2);
      // The interrupted lead runs again in a new session.
      expect(commands[1][1], 'workspace-write');
      expect(occurrences(commands[1].last, text), 1);
      expect(commands[1].last, contains('Partial progress.'));
      expect(
        commands[1].last,
        contains('never repeat an uncertain side effect'),
      );
      final current = await project(plugin, item['id'] as String);
      expect(current['status'], 'running');
      expect(current['run_id'], isNot(item['run_id']));
      expect(current['messages_queued'], 0);
      final stored = (current['messages'] as List).single as Map;
      expect(stored['mode'], 'now');
      expect(stored['state'], 'delivered');
      expect((stored['delivered_to'] as Map)['position'], 0);
      final types = eventTypes(current);
      final at = types.lastIndexOf('message');
      expect(types.sublist(at), [
        'message',
        'pausing',
        'paused',
        'continued',
        'assignment',
        'message_delivered',
      ]);
      await processes[1].finish('Lead switched the API.');
      await waitUntil(() => processes.length == 3);
      // The next assignment finds it in the handoff only.
      expect(occurrences(commands[2].last, text), 1);
      await processes[2].finish('Implemented.');
      await waitUntil(() => plugin.summary()['running'] == 0);
    });

    test('Send now that cannot continue keeps the message queued and the '
        'project paused', () async {
      final item = await started([
        {'agent': 'fixture', 'role': 'lead'},
      ]);
      // The adapter changes meanwhile: the continuation needs a new approval.
      final original = profiles.single['run_argv'];
      profiles.single['run_argv'] = ['/fixture/agent', 'changed', '{prompt}'];
      const text = 'Use the staging database.';
      final sent = await message(item, text, mode: 'now');
      expect(sent['continued'], isFalse);
      expect(sent['reason'], 'project_plan_not_approved');
      var current = sent['project'] as Map<String, dynamic>;
      expect(current['status'], 'paused');
      expect(current['messages_queued'], 1);
      expect(eventTypes(current).last, 'message_waiting');
      expect(processes, hasLength(1));
      // Once fixed, the next continuation gets it.
      profiles.single['run_argv'] = original;
      await plugin.call('continue', {
        'id': item['id'],
        'revision': current['revision'],
        'acknowledge_interrupted': true,
      });
      await waitUntil(() => processes.length == 2);
      expect(occurrences(commands[1].last, text), 1);
      current = await project(plugin, item['id'] as String);
      expect(current['messages_queued'], 0);
    });

    test('a launch that never started keeps the message queued', () async {
      final item = await approve(
        await save(
          plan: 'The plan.',
          team: [
            {'agent': 'fixture', 'role': 'lead'},
            {'agent': 'fixture', 'role': 'implementer'},
          ],
        ),
      );
      await plugin.shutdown();
      var launches = 0;
      plugin = AiProjectCenterPlugin(
        temporary.path,
        agentProfiles: () => profiles,
        filesystem: TestPosix(),
        runner: (argv, cwd, environment, input, _, _) async {
          commands.add(argv);
          if (++launches == 2) {
            throw ServiceError('project_agent_unavailable');
          }
          final process = FakeProjectProcess();
          processes.add(process);
          return process;
        },
      );
      var current = await project(plugin, item['id'] as String);
      await plugin.call('run', {
        'id': current['id'],
        'revision': current['revision'],
      });
      await waitUntil(() => processes.length == 1);
      current = await project(plugin, item['id'] as String);
      await message(current, 'Mind the tests.');
      await processes.single.finish('Lead done.');
      await waitUntil(() => plugin.summary()['running'] == 0);
      current = await project(plugin, item['id'] as String);
      expect(current['status'], 'failed');
      expect(current['messages_queued'], 1);
      expect(eventTypes(current), isNot(contains('message_delivered')));
      expect(current['handoff'], isNot(contains('Mind the tests.')));
    });

    test(
      'queued messages survive a restart and reach the continuation',
      () async {
        final item = await started([
          {'agent': 'fixture', 'role': 'lead'},
        ]);
        await message(item, 'Remember the docs.');
        await plugin.shutdown();
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
        var current = await project(plugin, item['id'] as String);
        expect(current['messages_queued'], 1);
        expect(
          ((current['messages'] as List).single as Map)['text'],
          'Remember the docs.',
        );
        await plugin.call('continue', {
          'id': current['id'],
          'revision': current['revision'],
          'acknowledge_interrupted': true,
        });
        await waitUntil(() => processes.length == 2);
        expect(occurrences(commands[1].last, 'Remember the docs.'), 1);
        await processes[1].finish('Done.');
        await waitUntil(() => plugin.summary()['running'] == 0);
        await plugin.shutdown();
        plugin = AiProjectCenterPlugin(
          temporary.path,
          agentProfiles: () => profiles,
          filesystem: TestPosix(),
        );
        current = await project(plugin, item['id'] as String);
        expect(current['messages_queued'], 0);
        expect(
          ((current['messages'] as List).single as Map)['state'],
          'delivered',
        );
      },
    );

    test(
      'a message during planning reaches the next planning assignment',
      () async {
        final item = await save(
          team: [
            {'agent': 'fixture', 'role': 'lead'},
            {'agent': 'fixture', 'role': 'reviewer'},
          ],
        );
        await plugin.call('plan', {
          'id': item['id'],
          'revision': item['revision'],
        });
        await waitUntil(() => processes.length == 1);
        final current = await project(plugin, item['id'] as String);
        await message(current, 'Check the migration risk.');
        await processes[0].finish('1. Do it.');
        await waitUntil(() => processes.length == 2);
        expect(commands[1][1], 'read-only');
        expect(occurrences(commands[1].last, 'Check the migration risk.'), 1);
        final delivered = await project(plugin, item['id'] as String);
        expect(
          ((delivered['messages'] as List).single as Map)['delivered_to'],
          containsPair('phase', 'planning'),
        );
        await processes[1].finish('No findings.');
        await waitUntil(() => plugin.summary()['running'] == 0);
      },
    );

    test('a store that would be too large refuses only the message', () async {
      final item = await approve(await save(plan: 'The plan.'));
      final size = File('${plugin.directory}/projects.json').lengthSync();
      await plugin.shutdown();
      plugin = AiProjectCenterPlugin(
        temporary.path,
        agentProfiles: () => profiles,
        filesystem: TestPosix(),
        storeLimit: size + 3000,
        runner: (argv, cwd, environment, input, _, _) async {
          commands.add(argv);
          final process = FakeProjectProcess();
          processes.add(process);
          return process;
        },
      );
      var current = await project(plugin, item['id'] as String);
      await plugin.call('run', {
        'id': current['id'],
        'revision': current['revision'],
      });
      await waitUntil(() => processes.length == 1);
      current = await project(plugin, item['id'] as String);
      await expectLater(
        message(current, 'x' * 4000),
        throwsA(errorCode('project_store_full')),
      );
      expect(plugin.summary()['error'], isNull);
      expect(processes.single.stopped, isFalse);
      current = await project(plugin, item['id'] as String);
      expect(current['status'], 'running');
      expect(current['messages_queued'], 0);
      await processes.single.finish('Done.');
      await waitUntil(() => plugin.summary()['running'] == 0);
      expect(
        (await project(plugin, item['id'] as String))['status'],
        'completed',
      );
    });

    test('Send now needs the Continue confirmation; Send takes none', () async {
      final item = await started([
        {'agent': 'fixture', 'role': 'lead'},
      ]);
      await expectLater(
        message(item, 'Now.', mode: 'now', acknowledge: false),
        throwsA(errorCode('project_review_changes_first')),
      );
      await expectLater(
        plugin.call('message', {
          'id': item['id'],
          'run_id': item['run_id'],
          'text': 'Now.',
          'mode': 'now',
        }),
        throwsA(errorCode('project_review_changes_first')),
      );
      await expectLater(
        message(item, 'Later.', acknowledge: true),
        throwsA(errorCode('project_message_invalid')),
      );
      // Nothing was stored or stopped.
      final current = await project(plugin, item['id'] as String);
      expect(current['messages'], isEmpty);
      expect(processes.single.stopped, isFalse);
    });

    test('a waiting message can be dropped, a delivered one cannot', () async {
      final item = await started([
        {'agent': 'fixture', 'role': 'lead'},
        {'agent': 'fixture', 'role': 'implementer'},
      ]);
      final first = (await message(item, 'Deliver me.'))['message'] as Map;
      final second = (await message(item, 'Drop me.'))['message'] as Map;
      final dropped =
          (await plugin.call('message_drop', {
                'id': item['id'],
                'message_id': second['id'],
              }))['project']
              as Map<String, dynamic>;
      expect(dropped['messages_queued'], 1);
      expect(eventTypes(dropped).last, 'message_dropped');
      await expectLater(
        plugin.call('message_drop', {
          'id': item['id'],
          'message_id': second['id'],
        }),
        throwsA(errorCode('project_message_unknown')),
      );
      await expectLater(
        plugin.call('message_drop', {'id': item['id']}),
        throwsA(errorCode('project_message_invalid')),
      );
      await processes[0].finish('Lead done.');
      await waitUntil(() => processes.length == 2);
      expect(commands[1].last, contains('Deliver me.'));
      expect(commands[1].last, isNot(contains('Drop me.')));
      await expectLater(
        plugin.call('message_drop', {
          'id': item['id'],
          'message_id': first['id'],
        }),
        throwsA(errorCode('project_message_delivered')),
      );
      await processes[1].finish('Done.');
      await waitUntil(() => plugin.summary()['running'] == 0);
    });

    test('a message left after the run ended can be dropped', () async {
      final item = await started([
        {'agent': 'fixture', 'role': 'lead'},
      ]);
      final sent = (await message(item, 'Too late.'))['message'] as Map;
      await processes.single.finish('Done.');
      await waitUntil(() => plugin.summary()['running'] == 0);
      var current = await project(plugin, item['id'] as String);
      expect(current['status'], 'completed');
      expect(current['messages_queued'], 1);
      current =
          (await plugin.call('message_drop', {
                'id': item['id'],
                'message_id': sent['id'],
              }))['project']
              as Map<String, dynamic>;
      expect(current['messages_queued'], 0);
      expect(current['messages'], isEmpty);
    });

    test('the waiting text of a project is at most 16 KiB', () async {
      final item = await started([
        {'agent': 'fixture', 'role': 'lead'},
      ]);
      for (var i = 0; i < 3; i++) {
        await message(item, '$i' * 4096);
      }
      // 12 KiB wait; 4 KiB more fit exactly, one byte more does not.
      await expectLater(
        message(item, 'x' * 4097),
        throwsA(errorCode('project_message_too_long')),
      );
      final last = (await message(item, 'y' * 4096))['message'] as Map;
      await expectLater(
        message(item, 'z'),
        throwsA(errorCode('project_messages_full')),
      );
      // Dropping one makes room again.
      await plugin.call('message_drop', {
        'id': item['id'],
        'message_id': last['id'],
      });
      await message(item, 'z');
      expect(
        (await project(plugin, item['id'] as String))['messages_queued'],
        4,
      );
    });

    test('the largest prompt with waiting messages stays below one argv '
        'word\'s limit', () async {
      final item = await approve(
        await save(
          plan: 'p' * AiProjectCenterPlugin.maxPlan,
          team: [
            {'agent': 'fixture', 'role': 'lead'},
            // The measured assignment carries the longest instructions.
            {
              'agent': 'fixture',
              'role': 'implementer',
              'instructions': 'i' * 4000,
            },
          ],
        ),
      );
      var current =
          (await plugin.call('save', {
                'id': item['id'],
                'revision': item['revision'],
                'title': 't' * 200,
                'brief': 'b' * (16 * 1024),
              }))['project']
              as Map<String, dynamic>;
      current = await approve(current);
      await plugin.call('run', {
        'id': current['id'],
        'revision': current['revision'],
      });
      await waitUntil(() => processes.length == 1);
      current = await project(plugin, item['id'] as String);
      for (var i = 0; i < 4; i++) {
        await message(current, '$i' * 4096);
      }
      // The lead's output fills the handoff (64 KiB, 16 KiB in the prompt).
      await processes[0].finish('o' * (80 * 1024));
      await waitUntil(() => processes.length == 2);
      final bytes = utf8.encode(commands[1].last).length;
      expect(bytes, lessThan(AiProjectCenterPlugin.maxPromptBytes));
      expect(bytes, lessThan(128 * 1024));
      printOnFailure('largest prompt: $bytes bytes');
      await processes[1].finish('Done.');
      await waitUntil(() => plugin.summary()['running'] == 0);
    });

    test('a spawn that fails in the real supervisor keeps the message '
        'queued', () async {
      await plugin.shutdown();
      final go = File('$workspace/go');
      final lead = File('${temporary.path}/lead-agent')
        ..writeAsStringSync(
          '#!/bin/sh\nwhile [ ! -e "${go.path}" ]; do sleep 0.05; done\n'
          'echo lead done\n',
        );
      // Its interpreter is missing: execve fails, the agent never ran.
      final broken = File('${temporary.path}/broken-agent')
        ..writeAsStringSync('#!/nonexistent/interpreter\n');
      Process.runSync('chmod', ['755', lead.path, broken.path]);
      profiles = [
        {
          'id': 'fixture',
          'name': 'Fixture agent',
          'installed': true,
          'plan_argv': [lead.path, 'read-only', '{prompt}'],
          'run_argv': [lead.path, 'workspace-write', '{prompt}'],
        },
        {
          'id': 'broken',
          'name': 'Broken agent',
          'installed': true,
          'plan_argv': [broken.path, 'read-only', '{prompt}'],
          'run_argv': [broken.path, 'workspace-write', '{prompt}'],
        },
      ];
      plugin = AiProjectCenterPlugin(
        temporary.path,
        agentProfiles: () => profiles,
        filesystem: TestPosix(),
        supervisor: projectSupervisorCommand(),
      );
      final item = await approve(
        await save(
          plan: 'The plan.',
          team: [
            {'agent': 'fixture', 'role': 'lead'},
            {'agent': 'broken', 'role': 'implementer'},
          ],
        ),
      );
      await plugin.call('run', {
        'id': item['id'],
        'revision': item['revision'],
      });
      var current = await project(plugin, item['id'] as String);
      await message(current, 'Mind the tests.');
      go.writeAsStringSync('');
      for (var i = 0; i < 100; i++) {
        current = await project(plugin, item['id'] as String);
        if (current['status'] == 'failed') break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(current['status'], 'failed');
      expect(current['handoff'], contains('lead done'));
      expect(current['messages_queued'], 1);
      expect(current['handoff'], isNot(contains('Mind the tests.')));
      expect(eventTypes(current), isNot(contains('message_delivered')));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a message in the prompt of an agent still starting cannot be '
        'dropped', () async {
      final item = await started([
        {'agent': 'fixture', 'role': 'lead'},
        {'agent': 'fixture', 'role': 'implementer'},
      ]);
      final sent = (await message(item, 'On its way.'))['message'] as Map;
      final gate = Completer<bool>();
      startGate = () => gate.future;
      await processes[0].finish('Lead done.');
      await waitUntil(() => processes.length == 2);
      await expectLater(
        plugin.call('message_drop', {
          'id': item['id'],
          'message_id': sent['id'],
        }),
        throwsA(errorCode('project_message_pending')),
      );
      gate.complete(true);
      await waitUntil(
        () => plugin.summary()['running'] == 1 && processes.length == 2,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final current = await project(plugin, item['id'] as String);
      expect(current['messages_queued'], 0);
      expect(occurrences(current['handoff'] as String, 'On its way.'), 1);
      await expectLater(
        plugin.call('message_drop', {
          'id': item['id'],
          'message_id': sent['id'],
        }),
        throwsA(errorCode('project_message_delivered')),
      );
      await processes[1].finish('Done.');
      await waitUntil(() => plugin.summary()['running'] == 0);
    });

    test('a Pause arriving while Send now stops the agent wins', () async {
      final item = await started([
        {'agent': 'fixture', 'role': 'lead'},
      ]);
      final gate = Completer<void>();
      processes.single.stopGate = gate.future;
      final now = message(item, 'Now, please.', mode: 'now');
      await Future<void>.delayed(Duration.zero);
      final pause = plugin.call('pause', {'id': item['id']});
      gate.complete();
      final sent = await now;
      await pause;
      expect(sent['continued'], isFalse);
      expect(sent['reason'], 'project_changed');
      expect((sent['message'] as Map)['state'], 'queued');
      final current = await project(plugin, item['id'] as String);
      expect(current['status'], 'paused');
      expect(current['messages_queued'], 1);
      expect(processes, hasLength(1));
    });

    test('a message dropped while Send now stops the agent is not '
        'reported as waiting', () async {
      final item = await started([
        {'agent': 'fixture', 'role': 'lead'},
      ]);
      final gate = Completer<void>();
      processes.single.stopGate = gate.future;
      final now = message(item, 'Now, please.', mode: 'now');
      await Future<void>.delayed(Duration.zero);
      final id =
          ((await project(plugin, item['id'] as String))['messages'] as List)
              .single['id'];
      await plugin.call('message_drop', {'id': item['id'], 'message_id': id});
      gate.complete();
      final sent = await now;
      expect(sent['continued'], isFalse);
      expect(sent['reason'], 'project_message_unknown');
      expect(sent['message'], isNull);
      final current = await project(plugin, item['id'] as String);
      expect(current['status'], 'paused');
      expect(eventTypes(current), isNot(contains('message_waiting')));
      expect(processes, hasLength(1));
    });

    test('Send now whose new session fails before its agent started returns '
        'to the paused checkpoint', () async {
      final item = await started([
        {'agent': 'fixture', 'role': 'lead'},
      ]);
      launchFail = () => ServiceError('project_agent_unavailable');
      final sent = await message(item, 'Use the new API.', mode: 'now');
      expect(sent['continued'], isFalse);
      expect(sent['reason'], 'project_agent_unavailable');
      var current = sent['project'] as Map<String, dynamic>;
      expect(current['status'], 'paused');
      expect(current['needs_reconciliation'], isTrue);
      expect(current['messages_queued'], 1);
      final types = eventTypes(current);
      expect(types.sublist(types.length - 2), [
        'continue_failed',
        'message_waiting',
      ]);
      launchFail = null;
      await plugin.call('continue', {
        'id': item['id'],
        'revision': current['revision'],
        'acknowledge_interrupted': true,
      });
      await waitUntil(() => processes.length == 2);
      expect(occurrences(commands.last.last, 'Use the new API.'), 1);
      current = await project(plugin, item['id'] as String);
      expect(current['messages_queued'], 0);
    });

    test(
      'Send now with an unconfirmed stop keeps the message queued',
      () async {
        final item = await started([
          {'agent': 'fixture', 'role': 'lead'},
        ]);
        processes.single.refuseStop = true;
        final sent = await message(item, 'Now.', mode: 'now');
        expect(sent['continued'], isFalse);
        expect(sent['reason'], 'project_still_pausing');
        var current = sent['project'] as Map<String, dynamic>;
        expect(current['status'], 'pausing');
        expect(current['messages_queued'], 1);
        processes.single.refuseStop = false;
        current =
            (await plugin.call('pause', {'id': item['id']}))['project']
                as Map<String, dynamic>;
        expect(current['status'], 'paused');
        await plugin.call('continue', {
          'id': item['id'],
          'revision': current['revision'],
          'acknowledge_interrupted': true,
        });
        await waitUntil(() => processes.length == 2);
        expect(occurrences(commands[1].last, 'Now.'), 1);
      },
    );

    test(
      'the oldest delivered messages make room; waiting ones stay',
      () async {
        final item = await started([
          {'agent': 'fixture', 'role': 'lead'},
          for (var i = 0; i < 7; i++)
            {'agent': 'fixture', 'role': 'implementer'},
        ]);
        var count = 0;
        String? first;
        for (var k = 0; k < 8; k++) {
          for (var i = 0; i < 3; i++) {
            final sent = await message(item, 'Message ${count++}');
            first ??= (sent['message'] as Map)['id'] as String;
          }
          await processes[k].finish('Assignment $k done.');
          if (k < 7) await waitUntil(() => processes.length == k + 2);
        }
        await waitUntil(() => plugin.summary()['running'] == 0);
        final current = await project(plugin, item['id'] as String);
        final messages = (current['messages'] as List).cast<Map>();
        expect(messages, hasLength(AiProjectCenterPlugin.maxMessages));
        expect(messages.map((m) => m['id']), isNot(contains(first)));
        expect(messages.first['text'], 'Message 4');
        expect(messages.where((m) => m['state'] == 'queued'), hasLength(3));
        expect(messages.last['text'], 'Message 23');
      },
    );

    test('an argv prompt over the limit is refused before launch; stdin is '
        'not limited', () async {
      Future<(Map<String, dynamic>, List<String?>)> attempt(bool stdin) async {
        await plugin.shutdown();
        temporary.deleteSync(recursive: true);
        temporary = Directory.current.createTempSync('.project-center-test-');
        workspace = (Directory(
          '${temporary.path}/workspace',
        )..createSync()).path;
        if (stdin) {
          profiles.single
            ..['stdin'] = true
            ..['plan_argv'] = ['/fixture/agent', 'read-only']
            ..['run_argv'] = ['/fixture/agent', 'workspace-write'];
        }
        processes.clear();
        commands.clear();
        final inputs = <String?>[];
        plugin = AiProjectCenterPlugin(
          temporary.path,
          agentProfiles: () => profiles,
          filesystem: TestPosix(),
          promptLimit: 4000,
          runner: (argv, cwd, environment, input, _, _) async {
            commands.add(argv);
            inputs.add(input);
            final process = FakeProjectProcess();
            processes.add(process);
            return process;
          },
        );
        final item = await approve(
          await save(
            plan: 'p' * 2000,
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
        await message(await project(plugin, item['id'] as String), 'm' * 2000);
        await processes[0].finish('Lead done.');
        if (stdin) {
          await waitUntil(() => processes.length == 2);
          await processes[1].finish('Done.');
        }
        await waitUntil(() => plugin.summary()['running'] == 0);
        return (await project(plugin, item['id'] as String), inputs);
      }

      final (refused, _) = await attempt(false);
      expect(refused['status'], 'failed');
      expect(
        (refused['events'] as List).last['text'],
        'project_prompt_too_large',
      );
      expect(refused['messages_queued'], 1);
      expect(commands, hasLength(1));
      final (passed, inputs) = await attempt(true);
      expect(passed['status'], 'completed');
      expect(utf8.encode(inputs[1]!).length, greaterThan(4000));
      expect(passed['messages_queued'], 0);
    });

    for (final refusal in ['prompt', 'authorize']) {
      test(
        'Send now preserves synchronous $refusal refusal and checkpoint',
        () async {
          await plugin.shutdown();
          var deny = false;
          plugin = AiProjectCenterPlugin(
            temporary.path,
            agentProfiles: () => profiles,
            filesystem: TestPosix(),
            promptLimit: refusal == 'prompt'
                ? 2000
                : AiProjectCenterPlugin.maxPromptBytes,
            authorize: (_) {
              if (deny) throw ServiceError('project_policy_refused');
            },
            runner: (argv, cwd, environment, input, _, _) async {
              final process = FakeProjectProcess();
              processes.add(process);
              return process;
            },
          );
          final item = await started([
            {'agent': 'fixture', 'role': 'lead'},
          ]);
          deny = refusal == 'authorize';
          final sent = await message(item, 'm' * 2000, mode: 'now');
          expect(
            sent['reason'],
            refusal == 'prompt'
                ? 'project_prompt_too_large'
                : 'project_policy_refused',
          );
          final current = sent['project'] as Map<String, dynamic>;
          expect(current['status'], 'paused');
          expect(current['needs_reconciliation'], isTrue);
          expect(current['messages_queued'], 1);
          expect(eventTypes(current), contains('continue_failed'));
          expect(eventTypes(current), isNot(contains('failed')));
          expect(processes, hasLength(1));
        },
      );
    }

    for (final shutdown in [false, true]) {
      test(
        'Send now waits for failed startup cleanup (shutdown=$shutdown)',
        () async {
          final item = await started([
            {'agent': 'fixture', 'role': 'lead'},
          ]);
          final starts = Completer<bool>();
          startGate = () => starts.future;
          final now = message(item, 'Wait for cleanup.', mode: 'now');
          var returned = false;
          now.then((_) => returned = true);
          await waitUntil(() => processes.length == 2);
          final cleanup = Completer<void>();
          processes.last.stopGate = cleanup.future;
          starts.complete(false);
          await waitUntil(() => processes.last.stopCalls > 0);
          Future<void>? closing;
          if (shutdown) closing = plugin.shutdown();
          await Future<void>.delayed(const Duration(milliseconds: 30));
          final returnedBeforeCleanup = returned;
          cleanup.complete();
          final sent = await now;
          await closing;
          expect(returnedBeforeCleanup, isFalse);
          expect(sent['continued'], isFalse);
          expect(sent['reason'], 'project_agent_unavailable');
          final current = sent['project'] as Map<String, dynamic>;
          expect(current['status'], 'paused');
          expect(current['messages_queued'], 1);
          if (!shutdown) {
            startGate = null;
            await plugin.call('continue', {
              'id': item['id'],
              'revision': current['revision'],
              'acknowledge_interrupted': true,
            });
            await waitUntil(() => processes.length == 3);
          }
        },
      );
    }

    test(
      'Send now reports pausing when failed startup cleanup is refused',
      () async {
        final item = await started([
          {'agent': 'fixture', 'role': 'lead'},
        ]);
        final starts = Completer<bool>();
        startGate = () => starts.future;
        final now = message(item, 'Keep it queued.', mode: 'now');
        await waitUntil(() => processes.length == 2);
        processes.last.refuseStop = true;
        starts.complete(false);
        final sent = await now;
        processes.last.refuseStop = false;
        expect(sent['reason'], 'project_still_pausing');
        expect((sent['project'] as Map)['status'], 'pausing');
        expect((sent['message'] as Map)['state'], 'queued');
        final paused = await plugin.call('pause', {'id': item['id']});
        expect((paused['project'] as Map)['status'], 'paused');
      },
    );

    test(
      'a cancelled agent that never launched adds no output or handoff',
      () async {
        final starts = Completer<bool>();
        startGate = () => starts.future;
        final item = await started([
          {'agent': 'fixture', 'role': 'lead'},
        ]);
        final pause = plugin.call('pause', {'id': item['id']});
        starts.complete(false);
        final current = (await pause)['project'] as Map;
        expect(current['status'], 'paused');
        expect(current['handoff'], isEmpty);
        expect(processes.single.outputReads, 0);
        expect(processes.single.exitReads, 0);
      },
    );

    for (final stale in [
      'pause',
      'save',
      'continue',
      'plan',
      'run',
      'review',
      'setup',
      'setup_apply',
      'delete',
    ]) {
      test('a refused stale $stale does not cancel Send now', () async {
        final item = await started([
          {'agent': 'fixture', 'role': 'lead'},
        ]);
        final gate = Completer<void>();
        processes.single.stopGate = gate.future;
        final now = message(item, 'Continue despite stale calls.', mode: 'now');
        await Future<void>.delayed(Duration.zero);
        await expectLater(
          plugin.call(stale, {
            'id': item['id'],
            'revision': -1,
            if (stale == 'pause') 'run_id': 'stale',
          }),
          throwsA(errorCode('project_changed')),
        );
        gate.complete();
        final sent = await now;
        expect(sent['continued'], isTrue);
        expect(sent['reason'], isNull);
      });
    }

    for (final detach in [false, true]) {
      test(
        'closing invalidates a Send now waiting on its original pause (detach=$detach)',
        () async {
          final item = await started([
            {'agent': 'fixture', 'role': 'lead'},
          ]);
          final gate = Completer<void>();
          processes.single.stopGate = gate.future;
          final now = message(
            item,
            'Do not restart a retired controller.',
            mode: 'now',
          );
          await Future<void>.delayed(Duration.zero);
          Future<void>? closing;
          if (detach) {
            plugin.detach();
          } else {
            closing = plugin.shutdown();
          }
          gate.complete();
          final sent = await now;
          await closing;
          expect(sent['continued'], isFalse);
          expect(sent['reason'], 'project_center_closed');
          expect((sent['message'] as Map)['state'], 'queued');
          expect(processes, hasLength(1));
        },
      );
    }

    test('failed startup cleanup has a deadline and can be retried', () async {
      final item = await started([
        {'agent': 'fixture', 'role': 'lead'},
      ]);
      final starts = Completer<bool>();
      startGate = () => starts.future;
      final now = message(
        item,
        'Do not return a false paused state.',
        mode: 'now',
      );
      await waitUntil(() => processes.length == 2);
      final cleanup = Completer<void>();
      processes.last.stopGate = cleanup.future;
      starts.complete(false);
      final Map<String, dynamic> sent;
      try {
        sent = await now.timeout(const Duration(seconds: 8));
      } finally {
        cleanup.complete();
      }
      expect(sent['reason'], 'project_still_pausing');
      expect((sent['project'] as Map)['status'], 'pausing');
      final paused = await plugin.call('pause', {'id': item['id']});
      expect((paused['project'] as Map)['status'], 'paused');
    });

    test(
      'an aborted shutdown invalidates Send now for every active project',
      () async {
        final item = await started([
          {'agent': 'fixture', 'role': 'lead'},
        ]);
        final otherPath = Directory('${temporary.path}/other')..createSync();
        final other = await approve(
          await save(path: otherPath.path, plan: 'Other plan.'),
        );
        final otherStart = Completer<bool>();
        startGate = () => otherStart.future;
        await plugin.call('run', {
          'id': other['id'],
          'revision': other['revision'],
        });
        await waitUntil(() => processes.length == 2);
        processes[1].refuseStop = true;
        final gate = Completer<void>();
        processes[0].stopGate = gate.future;
        final now = message(
          item,
          'Do not restart after shutdown.',
          mode: 'now',
        );
        await Future<void>.delayed(Duration.zero);
        // Only Send now's first stop remains held. Shutdown can stop A and
        // fail on B before the waiting Send now resumes.
        processes[0].stopGate = null;
        await expectLater(
          plugin.shutdown(),
          throwsA(errorCode('project_still_pausing')),
        );
        startGate = null;
        gate.complete();
        final sent = await now;
        processes[1].refuseStop = false;
        otherStart.complete(false);
        expect(sent['continued'], isFalse);
        expect(sent['reason'], 'project_changed');
        expect(processes, hasLength(2));
      },
    );

    test(
      'an aborted shutdown invalidates Send now after its attempt left active',
      () async {
        final item = await started([
          {'agent': 'fixture', 'role': 'lead'},
        ]);
        final otherPath = Directory('${temporary.path}/other')..createSync();
        final other = await approve(
          await save(path: otherPath.path, plan: 'Other plan.'),
        );
        final otherStart = Completer<bool>();
        startGate = () => otherStart.future;
        await plugin.call('run', {
          'id': other['id'],
          'revision': other['revision'],
        });
        await waitUntil(() => processes.length == 2);
        final gate = Completer<void>();
        processes[0].stopGate = gate.future;
        processes[1].refuseStop = true;
        final now = message(
          item,
          'Do not restart after shutdown.',
          mode: 'now',
        );
        try {
          await waitUntil(() => processes[0].stopCalls == 1);
          // Send now's stop is still waiting. The execution loop's own stop
          // can finish independently and remove A from _active first.
          processes[0].stopGate = null;
          await processes[0].finish('Partial work.', -15);
          await waitUntil(() => processes[0].stopCalls >= 2);
          await Future<void>.delayed(Duration.zero);
          // A rejected Pause proves A is no longer active without changing
          // its lifecycle token (unlike a successful mutation).
          await expectLater(
            plugin.call('pause', {'id': item['id']}),
            throwsA(errorCode('project_not_running')),
          );
          await expectLater(
            plugin.shutdown(),
            throwsA(errorCode('project_still_pausing')),
          );
          startGate = null;
          gate.complete();
          final sent = await now;
          expect(sent['continued'], isFalse);
          expect(sent['reason'], 'project_changed');
          expect((sent['project'] as Map)['status'], 'paused');
          expect((sent['message'] as Map)['state'], 'queued');
          expect(processes, hasLength(2));
        } finally {
          processes[1].refuseStop = false;
          if (!gate.isCompleted) gate.complete();
          otherStart.complete(false);
          await now;
        }
      },
    );

    test(
      'an end-of-run waiting note alone cannot latch a store fault',
      () async {
        Future<int> attempt(
          String name,
          int limit, {
          required bool bounded,
        }) async {
          await plugin.shutdown();
          processes.clear();
          plugin = AiProjectCenterPlugin(
            '${temporary.path}/$name',
            agentProfiles: () => profiles,
            filesystem: TestPosix(),
            storeLimit: limit,
            runner: (argv, cwd, environment, input, _, _) async {
              final process = FakeProjectProcess();
              processes.add(process);
              return process;
            },
          );
          final item = await started([
            {'agent': 'fixture', 'role': 'lead'},
          ]);
          final folder = Directory('${temporary.path}/$name-other')
            ..createSync();
          final other = await approve(
            await save(path: folder.path, plan: 'Other plan.'),
          );
          await plugin.call('run', {
            'id': other['id'],
            'revision': other['revision'],
          });
          await waitUntil(() => processes.length == 2);
          await message(item, 'Carry over.');
          await processes.first.finish('Done.');
          Map<String, dynamic> current = {};
          for (var i = 0; i < 100; i++) {
            current = await project(plugin, item['id'] as String);
            if (current['status'] == 'completed') break;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(current['status'], 'completed');
          if (bounded) {
            expect(plugin.summary()['error'], isNull);
            expect(processes.last.stopped, isFalse);
            expect(eventTypes(current), isNot(contains('message_waiting')));
            final store =
                jsonDecode(
                      File(
                        '${plugin.directory}/projects.json',
                      ).readAsStringSync(),
                    )
                    as Map;
            final saved =
                (store['projects'] as List).singleWhere(
                      (p) => p['id'] == item['id'],
                    )
                    as Map;
            expect(saved['status'], 'completed');
            expect((saved['messages'] as List).single['state'], 'queued');
          } else {
            expect(eventTypes(current), contains('message_waiting'));
          }
          return File('${plugin.directory}/projects.json').lengthSync();
        }

        // Same-length fixture paths and fixed-size ids. Leave room for the
        // essential checkpoint, but less than one message_waiting event.
        final fullSize = await attempt(
          'measure',
          AiProjectCenterPlugin.maxStore,
          bounded: false,
        );
        await attempt('bounded', fullSize - 80, bounded: true);
      },
    );

    test('Send now bounds an agent startup that never acknowledges', () async {
      final item = await started([
        {'agent': 'fixture', 'role': 'lead'},
      ]);
      final starts = Completer<bool>();
      startGate = () => starts.future;
      final clock = Stopwatch()..start();
      final Map<String, dynamic> sent;
      try {
        sent = await message(
          item,
          'Bound the wait.',
          mode: 'now',
        ).timeout(const Duration(seconds: 15));
      } finally {
        starts.complete(false);
      }
      expect(sent['reason'], 'project_agent_unavailable');
      expect((sent['project'] as Map)['status'], 'paused');
      expect((sent['message'] as Map)['state'], 'queued');
      expect(clock.elapsed, lessThan(const Duration(seconds: 15)));
    });

    test('a store with malformed messages is refused as corrupt', () async {
      final item = await save();
      await plugin.shutdown();
      final file = File('${plugin.directory}/projects.json');
      final original = file.readAsStringSync();
      Map<String, dynamic> queued(String id, [int bytes = 10]) => {
        'id': id,
        'at': '2026-11-22T00:00:00Z',
        'mode': 'queue',
        'text': 'x' * bytes,
        'state': 'queued',
        'run_id': 'r',
      };
      final delivered = {
        ...queued('b' * 32),
        'state': 'delivered',
        'delivered_at': '2026-11-22T00:00:01Z',
        'delivered_to': {
          'phase': 'execution',
          'position': 0,
          'agent': 'fixture',
          'role': 'lead',
        },
      };
      void open(List<Map<String, dynamic>> messages) {
        final data = jsonDecode(original) as Map;
        ((data['projects'] as List).single as Map)['messages'] = messages;
        file.writeAsStringSync(jsonEncode(data));
        plugin = AiProjectCenterPlugin(
          temporary.path,
          agentProfiles: () => profiles,
          filesystem: TestPosix(),
        );
      }

      final malformed = <String, List<Map<String, dynamic>>>{
        'duplicate ids': [queued('a' * 32), queued('a' * 32)],
        'over 16 KiB waiting': [
          for (var i = 0; i < 5; i++) queued('$i' * 32, 4096),
        ],
        'no run id': [
          {...queued('a' * 32)}..remove('run_id'),
        ],
        'delivered without its target': [
          {...delivered}..remove('delivered_to'),
        ],
        'a bad target phase': [
          {
            ...delivered,
            'delivered_to': {
              ...delivered['delivered_to'] as Map,
              'phase': 'setup',
            },
          },
        ],
        'queued with a delivery time': [
          {...queued('a' * 32), 'delivered_at': '2026-11-22T00:00:01Z'},
        ],
        'an unknown field': [
          {...queued('a' * 32), 'extra': 1},
        ],
      };
      for (final entry in malformed.entries) {
        expect(
          () => open(entry.value),
          throwsA(errorCode('project_store_corrupt')),
          reason: entry.key,
        );
      }
      open([queued('a' * 32), delivered]);
      final loaded = await project(plugin, item['id'] as String);
      expect(loaded['messages_queued'], 1);
    });
  });
}
