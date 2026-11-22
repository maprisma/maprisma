import 'dart:async';
import 'dart:io';

import 'package:maprisma_core/src/features/ai_project_center.dart';
import 'package:maprisma_core/src/features/project_supervisor.dart';
import 'package:maprisma_core/src/posix_ffi.dart';
import 'package:maprisma_core/src/protocol.dart';
import 'package:maprisma_core/src/pty_sessions.dart' show processIdentity;
import 'package:test/test.dart';

Matcher errorCode(String code) =>
    isA<ServiceError>().having((e) => e.code, 'code', code);

bool alive(int pid) {
  try {
    final raw = File('/proc/$pid/stat').readAsStringSync();
    final state = raw.substring(
      raw.lastIndexOf(')') + 2,
      raw.lastIndexOf(')') + 3,
    );
    return state != 'Z' && state != 'X';
  } on FileSystemException {
    return false;
  }
}

Future<List<int>> pids(File file, {bool single = false}) async {
  for (var i = 0; i < 300; i++) {
    if (file.existsSync()) {
      final words = file.readAsStringSync().trim().split(RegExp(r'\s+'));
      if (words.length >= (single ? 1 : 2) &&
          words.every((w) => int.tryParse(w) != null)) {
        return words.map(int.parse).toList();
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('The fixture did not report its process ids');
}

/// Ends a supervisor of a test: EOF (it stops its tree), then a kill.
Future<void> stopSupervisor(Process process) async {
  await process.stdin.close().catchError((Object _) {});
  try {
    await process.exitCode.timeout(const Duration(seconds: 20));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
  }
}

void main() {
  late Directory temporary;
  late String lock;
  final supervisor = projectSupervisorCommand();

  setUp(() {
    temporary = Directory.current.createTempSync('.project-supervisor-test-');
    lock = '${temporary.path}/run.lock';
    File(lock).writeAsStringSync('');
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  test('the development checkout resolves its own supervisor entry point', () {
    expect(supervisor, isNotNull);
    expect(supervisor!.last, 'supervise');
  });

  test(
    'a fast leader exit still ends descendants that left its session and group',
    () async {
      final file = File('${temporary.path}/pids');
      // Both children change session; one also ignores SIGTERM. The leader
      // exits immediately, so no process-group member stays to anchor polling.
      final process = await SupervisedProjectProcess.start(
        supervisor!,
        [
          '/bin/sh',
          '-c',
          'setsid sleep 60 & a=\$!; '
              '(trap "" TERM; exec setsid sleep 61) & b=\$!; '
              'echo "\$a \$b" > "${file.path}"; echo done',
        ],
        temporary.path,
        {'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin'},
        null,
        lock,
      );
      final output = process.output.join();
      expect(await process.exitCode, 0);
      expect(await output, contains('done'));
      for (final pid in await pids(file)) {
        expect(alive(pid), isFalse, reason: 'descendant $pid survived');
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('stop ends a running tree, including a double-forked daemon', () async {
    final file = File('${temporary.path}/pids');
    final process = await SupervisedProjectProcess.start(
      supervisor!,
      [
        '/bin/sh',
        '-c',
        '(setsid sh -c "sleep 62 & echo \\\$! > ${file.path}.d" &) ; '
            'sleep 63 & echo "\$! \$\$" > "${file.path}"; wait',
      ],
      temporary.path,
      {'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin'},
      null,
      lock,
    );
    final started = await pids(file);
    final daemonFile = File('${file.path}.d');
    for (var i = 0; i < 300 && !daemonFile.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final daemon = int.parse(daemonFile.readAsStringSync().trim());
    expect(alive(daemon), isTrue);
    // While the tree lives, its supervisor holds the run lock.
    final io = Posix();
    final fd = io.openAt(-100, lock, Posix.noFollow);
    try {
      expect(io.tryFlock(fd, shared: false), isFalse);
    } finally {
      io.close(fd);
    }
    await process.stop(wait: const Duration(seconds: 15));
    for (final pid in [...started, daemon]) {
      expect(alive(pid), isFalse, reason: 'process $pid survived stop');
    }
    final again = io.openAt(-100, lock, Posix.noFollow);
    try {
      expect(io.tryFlock(again, shared: false), isTrue);
    } finally {
      io.close(again);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a failed stop is retried rather than remembered', () async {
    // A stand-in supervisor confirms only the second stop request.
    final process = await SupervisedProjectProcess.start(
      [
        '/bin/sh',
        '-c',
        'read start; echo \'{"locked":true}\'; read launch; '
            'read first; read second; '
            'echo \'{"exit":0}\'; echo \'{"stopped":true}\'',
      ],
      ['/bin/true'],
      temporary.path,
      const {},
      null,
      lock,
    );
    await expectLater(
      process.stop(wait: const Duration(milliseconds: 300)),
      throwsA(errorCode('project_processes_still_running')),
    );
    await process.stop(wait: const Duration(seconds: 5));
    await process.stop();
  });

  test(
    'a supervisor lost without confirmation never reports stopped',
    () async {
      final process = await SupervisedProjectProcess.start(
        [
          '/bin/sh',
          '-c',
          'read start; echo \'{"locked":true}\'; read launch; '
              'echo \'{"leader":0}\'; exit 0',
        ],
        ['/bin/true'],
        temporary.path,
        const {},
        null,
        lock,
      );
      await expectLater(
        process.exitCode,
        throwsA(errorCode('project_processes_still_running')),
      );
      await expectLater(
        process.stop(),
        throwsA(errorCode('project_processes_still_running')),
      );
    },
  );

  test('agents do not inherit Maprisma process variables', () {
    final environment = AiProjectCenterPlugin.agentEnvironment({
      'PATH': '/usr/bin',
      'HOME': '/home/someone',
      'MAPRISMA_FEATURE_PROCESS': 'ai-project-center',
      'MAPRISMA_FEATURE_BUNDLE_ROOT': '/opt/maprisma',
      'MAPRISMA_FEATURE_PARENT_PID': '1',
      'MAPRISMA_FEATURE_PARENT_START': '2',
      'MAPRISMA_CORE_WORKER': '/opt/maprisma/plugin',
      'MAPRISMA_PAGE': 'x',
    });
    expect(environment.keys, unorderedEquals(['PATH', 'HOME']));
  });

  test(
    'a vanished controller (EPIPE) does not end the supervisor before its tree',
    () async {
      final file = File('${temporary.path}/pids');
      final supervisorProcess = await Process.start(
        supervisor!.first,
        supervisor.skip(1).toList(),
      );
      supervisorProcess.stderr.drain<void>().ignore();
      final events = supervisorProcess.stdout.listen((_) {});
      supervisorProcess.stdin.writeln(
        '{"argv":["/bin/sh","-c","(trap \\"echo term\\" TERM; '
        'while true; do echo noise; sleep 0.05; done) & '
        'echo \$! > ${file.path}; wait"],'
        '"cwd":"${temporary.path}","input":null,"lock":"$lock",'
        '"controller":{"pid":$pid,"start":"${processIdentity(pid)!.$3}"}}',
      );
      supervisorProcess.stdin.writeln('{"launch":true}');
      final child = (await pids(File(file.path).absolute, single: true)).single;
      expect(alive(child), isTrue);
      // The controller disappears: both pipes close while output continues.
      await events.cancel();
      await supervisorProcess.stdin.close();
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (alive(child) && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(alive(child), isFalse, reason: 'the TERM-ignoring child survived');
      await supervisorProcess.exitCode.timeout(const Duration(seconds: 10));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('a start queued by a controller that is gone never launches', () async {
    final marker = File('${temporary.path}/launched');
    final process = await Process.start(
      supervisor!.first,
      supervisor.skip(1).toList(),
    );
    process.stderr.drain<void>().ignore();
    final lines = process.stdout
        .transform(const SystemEncoding().decoder)
        .join();
    // The named controller is not this supervisor's parent any more.
    process.stdin.writeln(
      '{"argv":["/bin/sh","-c","touch ${marker.path}"],'
      '"cwd":"${temporary.path}","input":null,"lock":"$lock",'
      '"controller":{"pid":1,"start":"0"}}',
    );
    await process.exitCode.timeout(const Duration(seconds: 20));
    await process.stdin.close().catchError((Object _) {});
    expect(await lines, contains('controller_gone'));
    expect(marker.existsSync(), isFalse);
    final io = Posix();
    final fd = io.openAt(-100, lock, Posix.noFollow);
    try {
      expect(io.tryFlock(fd, shared: false), isTrue);
    } finally {
      io.close(fd);
    }
  });

  test('a confirmed natural end has already released the run lock', () async {
    final process = await SupervisedProjectProcess.start(
      supervisor!,
      ['/bin/sh', '-c', 'echo done'],
      temporary.path,
      {'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin'},
      null,
      lock,
    );
    final output = process.output.join();
    expect(await process.exitCode, 0);
    await output;
    await process.stop();
    final io = Posix();
    final fd = io.openAt(-100, lock, Posix.noFollow);
    try {
      expect(io.tryFlock(fd, shared: false), isTrue);
    } finally {
      io.close(fd);
    }
  });

  test(
    'a controller that no longer owns its store never authorizes launch',
    () async {
      final marker = File('${temporary.path}/launched');
      await expectLater(
        SupervisedProjectProcess.start(
          supervisor!,
          ['/bin/sh', '-c', 'touch ${marker.path}'],
          temporary.path,
          {'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin'},
          null,
          lock,
          authorize: () => false,
        ),
        throwsA(errorCode('project_launch_withdrawn')),
      );
      // The supervisor ends on EOF without launching and releases the lock.
      final io = Posix();
      var free = false;
      for (var i = 0; i < 200 && !free; i++) {
        final fd = io.openAt(-100, lock, Posix.noFollow);
        try {
          free = io.tryFlock(fd, shared: false);
        } finally {
          io.close(fd);
        }
        if (!free) await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(free, isTrue);
      expect(marker.existsSync(), isFalse);
    },
  );

  test('a malformed start line ends with invalid_start and stopped', () async {
    final process = await Process.start(
      supervisor!.first,
      supervisor.skip(1).toList(),
    );
    addTearDown(() => stopSupervisor(process));
    process.stderr.drain<void>().ignore();
    final lines = process.stdout
        .transform(const SystemEncoding().decoder)
        .join();
    process.stdin.writeln('{not json');
    expect(await process.exitCode.timeout(const Duration(seconds: 20)), 2);
    await process.stdin.close().catchError((Object _) {});
    final output = await lines;
    expect(output, contains('invalid_start'));
    expect(output, contains('"stopped":true'));
  });

  test(
    'invalid UTF-8 on the control pipe stops the tree instead of crashing',
    () async {
      final file = File('${temporary.path}/pids');
      final process = await Process.start(
        supervisor!.first,
        supervisor.skip(1).toList(),
      );
      int? child;
      addTearDown(() async {
        // EOF first: the supervisor itself stops its tree, also when the
        // child's pid was never read.
        await stopSupervisor(process);
        if (child != null && alive(child)) {
          Process.killPid(child, ProcessSignal.sigkill);
        }
      });
      process.stderr.drain<void>().ignore();
      final lines = process.stdout
          .transform(const SystemEncoding().decoder)
          .join();
      process.stdin.writeln(
        '{"argv":["/bin/sh","-c","sleep 300 & echo \$! > ${file.path}; wait"],'
        '"cwd":"${temporary.path}","input":null,"lock":"$lock",'
        '"controller":{"pid":$pid,"start":"${processIdentity(pid)!.$3}"}}',
      );
      process.stdin.writeln('{"launch":true}');
      child = (await pids(File(file.path).absolute, single: true)).single;
      expect(alive(child), isTrue);
      process.stdin.add([0xff, 0xfe, 10]);
      await process.stdin.flush();
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (alive(child) && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final survived = alive(child);
      expect(survived, isFalse, reason: 'the agent outlived its supervisor');
      await process.stdin.close().catchError((Object _) {});
      await process.exitCode.timeout(const Duration(seconds: 20));
      expect(await lines, contains('"stopped":true'));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('started is reported only once the agent process exists', () async {
    // An executable whose interpreter is missing: execve fails, nothing ran.
    final broken = File('${temporary.path}/broken')
      ..writeAsStringSync('#!/nonexistent/interpreter\n');
    Process.runSync('chmod', ['755', broken.path]);
    final failed = await SupervisedProjectProcess.start(
      supervisor!,
      [broken.path, 'prompt'],
      temporary.path,
      {'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin'},
      null,
      lock,
    );
    final failedOutput = failed.output.drain<void>().then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    expect(await failed.started, isFalse);
    expect(await failedOutput, errorCode('project_agent_unavailable'));
    await failed.exitCode.catchError((Object _) => -1);
    final good = await SupervisedProjectProcess.start(
      supervisor,
      ['/bin/sh', '-c', 'echo done'],
      temporary.path,
      {'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin'},
      null,
      lock,
    );
    final output = good.output.join();
    expect(await good.started, isTrue);
    expect(await good.exitCode, 0);
    expect(await output, contains('done'));
  }, timeout: const Timeout(Duration(seconds: 60)));
}
