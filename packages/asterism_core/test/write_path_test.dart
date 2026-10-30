import 'dart:convert';
import 'dart:io';
import 'package:asterism_core/asterism_core.dart';
import 'package:asterism_core/src/connect_apply.dart';
import 'package:asterism_core/src/core_tasks.dart';
import 'package:asterism_core/src/dsh_profile.dart';
import 'package:asterism_core/src/model_downloads.dart';
import 'package:asterism_core/src/model_guard.dart';
import 'package:asterism_core/src/provider_watch.dart';
import 'package:asterism_core/src/pty_sessions.dart';
import 'package:asterism_core/src/sshsig.dart';
import 'package:asterism_core/src/scan_files.dart';
import 'package:asterism_core/src/plan_worker.dart';
import 'package:asterism_core/src/provider_ops.dart';
import 'package:asterism_core/src/provider_scans.dart';
import 'package:test/test.dart';

void main() {
  test('preview, apply through the worker, status, Undo', () async {
    final home = Directory.systemTemp.createTempSync('asterism-write-');
    addTearDown(() => home.deleteSync(recursive: true));
    final config = File('${home.path}/.codex/config.toml')
      ..createSync(recursive: true)
      ..writeAsStringSync('model = "a"\nkeep = 1\n');
    final tasks = CoreTasks([
      Platform.resolvedExecutable,
      '--disable-dart-dev',
      '--packages=.dart_tool/package_config.json',
      'bin/asterism-core.dart',
      'worker',
    ]);
    final connections = CoreConnections(
      ConfigFiles(Posix(), home.path),
      tasks,
      '${home.path}/.config/asterism/connection-backups',
    );
    final preview = connections.keep(
      Plan(
        'codex',
        '',
        '',
        changes: [
          Change(
            config.path,
            'model = "a"\nkeep = 1\n',
            'model = "b"\nkeep = 1\nnew = 2\n',
          ),
        ],
      ),
    );
    expect(preview['plan'], startsWith(coreHandle));
    expect(preview['files'], [
      {'path': '~/.codex/config.toml', 'added': 2, 'removed': 1},
    ]);
    final started = connections.apply(preview['plan'] as String);
    expect(
      () => connections.apply(preview['plan'] as String),
      throwsFormatException,
    );
    final ident = started['task'] as String;
    var status = tasks.status(ident);
    expect(() => tasks.cancel(ident), throwsFormatException);
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (status['state'] == 'running' && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      status = tasks.status(ident);
    }
    expect(status['state'], 'done', reason: '$status');
    final result = status['result'] as Map;
    expect(result['ok'], isTrue);
    expect(result['context_failures'], 0);
    expect(config.readAsStringSync(), 'model = "b"\nkeep = 1\nnew = 2\n');
    final undone = connections.undo(result['undo'] as String);
    expect(undone['restored'], ['~/.codex/config.toml']);
    expect(config.readAsStringSync(), 'model = "a"\nkeep = 1\n');
    expect(
      () => connections.undo(result['undo'] as String),
      throwsFormatException,
    );
  });

  test('a changed file fails the task and writes nothing', () async {
    final home = Directory.systemTemp.createTempSync('asterism-write-');
    addTearDown(() => home.deleteSync(recursive: true));
    final config = File('${home.path}/settings.json')..writeAsStringSync('{}');
    final tasks = CoreTasks([
      Platform.resolvedExecutable,
      '--disable-dart-dev',
      '--packages=.dart_tool/package_config.json',
      'bin/asterism-core.dart',
      'worker',
    ]);
    final connections = CoreConnections(
      ConfigFiles(Posix(), home.path),
      tasks,
      '${home.path}/backups',
    );
    final preview = connections.keep(
      Plan('x', '', '', changes: [Change(config.path, '{}', '{"a": 1}')]),
    );
    config.writeAsStringSync('{"edited": true}');
    final ident =
        connections.apply(preview['plan'] as String)['task'] as String;
    var status = tasks.status(ident);
    while (status['state'] == 'running') {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      status = tasks.status(ident);
    }
    expect(status['state'], 'failed');
    expect(config.readAsStringSync(), '{"edited": true}');
    expect(Directory('${home.path}/backups').existsSync(), isFalse);
  });

  test('empty plans need no worker; unknown handles are refused', () {
    final connections = CoreConnections(
      ConfigFiles(Posix(), '/nonexistent'),
      CoreTasks(['/bin/false']),
      '/nonexistent/backups',
    );
    final preview = connections.keep(Plan('x', '', ''));
    expect(preview['empty'], isTrue);
    expect(connections.apply(preview['plan'] as String), {
      'ok': true,
      'undo': null,
    });
    expect(() => connections.undo('core-unknown'), throwsFormatException);
  });

  test(
    'a DeepSeek Harness insert holding other servers is refused, not rewritten',
    () {
      const profile =
          '- insert:\n'
          '  - id: mcp-a\n'
          "    name: '@deepseek-ai/dsh-mcp-client'\n"
          '    config:\n'
          '      serverName: a\n'
          '  - id: mcp-b\n'
          "    name: '@deepseek-ai/dsh-mcp-client'\n"
          '    config:\n'
          '      serverName: b\n'
          '      when: !!js "() => Date.now()"\n';
      expect(dshMcpServers(profile).keys, ['a', 'b']);
      expect(() => dshMcpText(profile, 'a', null), throwsUnsupportedError);
      // Untouched inserts stay byte for byte; a new server is its own insert.
      final added = dshMcpText(profile, 'c', {
        'transport': 'stdio',
        'command': 'x',
        'args': <String>[],
      });
      expect(added, startsWith('# Your patch layer'));
      expect(added, contains(profile));
      expect(
        added,
        endsWith(
          "      serverName: c\n      transport: stdio\n      command: x\n      args: []\n",
        ),
      );
    },
  );

  test('only a socket of this account on a loopback address is our server', () {
    final net = Directory.systemTemp.createTempSync('asterism-net-');
    addTearDown(() => net.deleteSync(recursive: true));
    const header =
        '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid\n';
    // 8080 on 127.0.0.1 by uid 1000; 9090 on 0.0.0.0 by uid 0; 7070 on 10.0.0.5 by 1000 (not loopback).
    File('${net.path}/tcp').writeAsStringSync(
      '$header'
      '   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000 0 1\n'
      '   1: 00000000:2382 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0 0 2\n'
      '   2: 0500000A:1B9E 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000 0 3\n'
      '   3: 0100007F:1F91 0100007F:9C40 01 00000000:00000000 00:00000000 00000000  1000 0 4\n',
    );
    File('${net.path}/tcp6').writeAsStringSync(
      '$header'
      '   0: 00000000000000000000000001000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1001 0 5\n',
    );
    expect(loopbackListeners(8080, proc: net.path), [1000, 1001]);
    expect(
      ownPort(8080, 1000, proc: net.path),
      isFalse,
    ); // another account listens too
    expect(ownPort(9090, 1000, proc: net.path), isFalse);
    expect(loopbackListeners(7070, proc: net.path), isEmpty);
    expect(
      loopbackListeners(8081, proc: net.path),
      isEmpty,
    ); // connected, not listening
  });

  test('contexts travel as flutter_plan_wire carries them', () {
    final rt = RuntimeRecord('ollama', 'Ollama')..address = '127.0.0.1:11434';
    final plan = Plan(
      'pi',
      'ollama',
      'ollama-local',
      contexts: [
        {'runtime': rt.toJson(), 'model': 'gemma:latest', 'tokens': 8192},
      ],
    );
    final (back, root) = decodePlan(encodePlan(plan, '/tmp/backups'));
    expect(root, '/tmp/backups');
    expect(back.contexts, plan.contexts);
    final odd = Map<String, dynamic>.from(rt.toJson())..['shell'] = 'x';
    plan.contexts[0] = {'runtime': odd, 'model': 'm', 'tokens': 1};
    expect(
      () => decodePlan(encodePlan(plan, '/tmp/backups')),
      throwsFormatException,
    );
  });

  test('processes belong to the local LLM the reference names', () {
    // Expected values from Python's llm_engine.runtime_of.
    const cases = [
      [
        'llama-server',
        ['/usr/bin/llama-server', '--port', '8080'],
        'llamacpp',
      ],
      [
        'python3',
        ['/usr/bin/python3', '/x/llama-server'],
        '',
      ],
      [
        'ollama',
        ['/usr/bin/ollama', 'serve'],
        'ollama',
      ],
      [
        'ollama_llama_se',
        ['/tmp/ollama/runners/llama-server'],
        'llamacpp',
      ],
      [
        'llama-server',
        ['/home/u/.lmstudio/bin/llama-server'],
        'lmstudio',
      ],
      [
        'LM Studio',
        ['/opt/LM Studio/lm-studio'],
        'lmstudio',
      ],
      [
        'VLLM::EngineCor',
        ['python'],
        'vllm',
      ],
      [
        'python3',
        ['python3', '/usr/bin/vllm', 'serve', 'm'],
        'vllm',
      ],
      [
        'python3',
        ['/usr/bin/vllm', 'serve'],
        'vllm',
      ],
      [
        'jan-llama-worke',
        ['/opt/jan/jan-llama-worker'],
        'jan',
      ],
      [
        'koboldcpp',
        ['/opt/koboldcpp-linux'],
        'koboldcpp',
      ],
      [
        'bash',
        ['/bin/bash'],
        '',
      ],
      ['x', <String>[], ''],
    ];
    for (final c in cases) {
      expect(
        GpuUsage.runtimeOf(c[0] as String, [...c[1] as List<String>]),
        c[2],
        reason: '$c',
      );
    }
  });

  test('a download continues only our own staging file with one name', () {
    final dir = Directory.systemTemp.createTempSync('asterism-staging-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final posix = Posix(), files = ModelFiles(posix);
    // New: created exclusively; again: our own file with one name, resumed.
    final fresh = '${dir.path}/a.gguf.part';
    posix.close(files.openStaging(fresh));
    File(fresh).writeAsStringSync('half');
    final fd = files.openStaging(fresh);
    expect(posix.statFull(fd).size, 4);
    posix.close(fd);
    // A link in its place, and a file with a second name, are refused.
    final other = File('${dir.path}/elsewhere')..writeAsStringSync('x');
    Link('${dir.path}/b.gguf.part').createSync(other.path);
    expect(
      () => files.openStaging('${dir.path}/b.gguf.part'),
      throwsStateError,
    );
    expect(posix.hardLink(other.path, '${dir.path}/c.gguf.part'), isTrue);
    expect(
      () => files.openStaging('${dir.path}/c.gguf.part'),
      throwsStateError,
    );
    expect(other.readAsStringSync(), 'x');
    expect(files.ownRegularFile(other.path), isFalse); // two names now
  });

  test('only a compiled release core manages the watcher unit', () async {
    final home = Directory.systemTemp.createTempSync('asterism-watchunit-');
    addTearDown(() => home.deleteSync(recursive: true));
    WatchService service(Map<String, String> env, List<String> worker) {
      final identity = AppIdentity(environment: {'HOME': home.path, ...env});
      final files = ScanFiles(identity);
      return WatchService(
        identity,
        SettingsStore(identity),
        worker,
        ProviderOps(files, ProviderScans(files)),
      );
    }

    const core = '/usr/lib/asterism/lib/asterism-core';
    expect(service({}, [core, 'worker']).binary, core);
    expect(
      service({'ASTERISM_FLUTTER_DEVEL': '1'}, [core, 'worker']).binary,
      isNull,
    );
    expect(service({'ASTERISM_DEVEL': '1'}, [core, 'worker']).binary, isNull);
    expect(
      service({}, ['/usr/bin/dart', 'bin/asterism-core.dart', 'worker']).binary,
      isNull,
    );
    expect(service({}, ['/tmp/x y/asterism-core', 'worker']).binary, isNull);
    // Builds and temporary copies are never installed as the user service.
    for (final path in [
      '/tmp/claude-1000/scratchpad/asterism-core',
      '/var/tmp/asterism-core',
      '/home/u/src/asterism/.flutter-previews/preview-x/flutter_app/build/linux/x64/release/bundle/lib/asterism-core',
      '/home/u/src/asterism/flutter_app/build/linux/x64/release/bundle/lib/asterism-core',
    ]) {
      expect(service({}, [path, 'worker']).binary, isNull, reason: path);
    }
    expect(
      service(
        {'TMPDIR': '/run/user/1000/tmp'},
        ['/run/user/1000/tmp/asterism-core', 'worker'],
      ).binary,
      isNull,
    );
    // Not managed: nothing written, no systemctl.
    final devel = service({'ASTERISM_FLUTTER_DEVEL': '1'}, [core, 'worker']);
    expect(await devel.ensure(true), isFalse);
    expect(File(devel.unitFile).existsSync(), isFalse);
    expect(
      watchUnitText(
        core,
        '/home/u/.config/asterism/providers-with-agents.json',
      ),
      contains(
        'ExecStart=$core provider-watch --config /home/u/.config/asterism/providers-with-agents.json\n',
      ),
    );
  });

  test('stopping a session ends its group, never another session', () async {
    final dir = Directory.systemTemp.createTempSync('asterism-pty-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final sessions = PtySessions();
    bool alive(int pid) {
      try {
        final state = File('/proc/$pid/stat').readAsStringSync();
        return !state.substring(state.lastIndexOf(')') + 2).startsWith('Z');
      } on FileSystemException {
        return false;
      }
    }

    Future<String> readUntil(String ident, String word) async {
      final out = StringBuffer();
      for (var i = 0; i < 200 && !out.toString().contains(word); i++) {
        out.write(sessions.read(ident)['text']);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return out.toString();
    }

    int pidAfter(String text, String word) =>
        int.parse(RegExp('$word (\\d+)').firstMatch(text)![1]!);
    final env = {'PATH': '/usr/bin:/bin'};
    // Running: the leader, its background child; another session left alone.
    var ident = sessions.start(
      't',
      [
        '/bin/sh',
        '-c',
        'sleep 300 & echo CHILD \$!; setsid sleep 300 & echo OTHER \$!; echo END; exec sleep 300',
      ],
      dir.path,
      env,
    );
    var text = await readUntil(ident, 'END');
    final child = pidAfter(text, 'CHILD'), other = pidAfter(text, 'OTHER');
    final leader = sessions.items[ident]!.pid;
    expect([alive(leader), alive(child), alive(other)], [true, true, true]);
    sessions.stop(ident);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect([alive(leader), alive(child)], [false, false]);
    expect(alive(other), isTrue);
    Process.killPid(other, ProcessSignal.sigkill);
    // Ended leader, a background child still in its group: stopped as well.
    ident = sessions.start(
      't',
      // Ignoring SIGHUP, it outlives its leader (the kernel hangs up the group).
      [
        '/bin/sh',
        '-c',
        "(trap '' HUP; exec sleep 300) & echo CHILD \$!; echo END; sleep 1.5",
      ],
      dir.path,
      env,
    );
    text = await readUntil(ident, 'END');
    final orphan = pidAfter(text, 'CHILD');
    for (var i = 0; i < 100 && sessions.read(ident)['exit_code'] == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(alive(orphan), isTrue);
    sessions.stop(ident);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(alive(orphan), isFalse);
  });

  test('add-on signatures are checked as ssh-keygen -Y verify does', () {
    // agent-goose's real MANIFEST.sha256 and SIGNATURE (asterism-addons).
    const signature =
        '-----BEGIN SSH SIGNATURE-----\nU1NIU0lHAAAAAQAAADMAAAALc3NoLWVkMjU1MTkAAAAgQg9md88iTLL4hfUnSN8HmD9TxT\nmOMlNqk6iDOUqvGWgAAAAOYXN0ZXJpc20tYWRkb24AAAAAAAAABnNoYTUxMgAAAFMAAAAL\nc3NoLWVkMjU1MTkAAABAhy0rQkm79ETRzf1aQS9PpEPb1zYziAnKE8MGAv4zzKPCf+RNz/\nh8smZ7CTiLRa0eXvw7zckgsFzGIwmoEIy9DQ==\n-----END SSH SIGNATURE-----\n';
    final manifest = base64.decode(
      'ZGYwNWU2ZTViODYwNzM5ODc0NTFiMDIwMzkzZDZmZjY0ZTg3MWUyNmEzMjgzYzRlMzU0MzA0N2ZkZDI2ZjRjOSAgYWRkb24uanNvbgoyMTMyOWQ4MjMzZDc1N2RhZmYwMWZmOWM0ZjQ1NGJhMTM1YWQyODM0ZWZhOTU2ZWNiYjkzZTAyY2Q0OThlZTdiICBhZ2VudC50b21sCg==',
    );
    const key =
        'AAAAC3NzaC1lZDI1NTE5AAAAIEIPZnfPIkyy+IX1J0jfB5g/U8U5jjJTapOogzlKrxlo';
    final good = utf8.encode(signature);
    expect(sshSignatureOk(manifest, good, 'asterism-addon', key), isTrue);
    expect(
      sshSignatureOk([...manifest, 10], good, 'asterism-addon', key),
      isFalse,
    );
    expect(sshSignatureOk(manifest, good, 'other-namespace', key), isFalse);
    expect(
      sshSignatureOk(
        manifest,
        good,
        'asterism-addon',
        key.replaceFirst('E', 'F'),
      ),
      isFalse,
    );
    // A byte of the signature itself changed (inside the base64 armor).
    final lines = signature.split('\n');
    final body = lines[3];
    final flipped = [
      ...lines.take(3),
      body.replaceRange(10, 11, body[10] == 'A' ? 'B' : 'A'),
      ...lines.skip(4),
    ].join('\n');
    expect(
      sshSignatureOk(manifest, utf8.encode(flipped), 'asterism-addon', key),
      isFalse,
    );
    expect(
      sshSignatureOk(manifest, utf8.encode('garbage'), 'asterism-addon', key),
      isFalse,
    );
  });
}
