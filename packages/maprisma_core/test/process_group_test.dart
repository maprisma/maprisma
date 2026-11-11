import 'dart:io';

import 'package:maprisma_core/src/model_hub.dart' show boundedOutput;
import 'package:maprisma_core/src/process_group.dart';
import 'package:test/test.dart';

/// A parent that writes its child's pid and ends (or waits); the child
/// ignores SIGTERM and has output of its own, so the parent's EOF says
/// nothing about it (the HANCORE review fixture).
const _stubborn = r'''
(trap '' TERM; exec sleep 60) >/dev/null 2>&1 </dev/null &
echo $! > "$1"
sleep 0.3
if [ "$2" = exit ]; then echo done; exit 0; fi
sleep 60
''';

bool _running(int pid) {
  try {
    final text = File('/proc/$pid/stat').readAsStringSync();
    return text.substring(text.lastIndexOf(')') + 2).split(' ').first != 'Z';
  } on FileSystemException {
    return false;
  }
}

Future<void> _gone(int pid) async {
  for (var i = 0; i < 60; i++) {
    if (!_running(pid)) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  Process.killPid(pid, ProcessSignal.sigkill);
  fail('a child of the group is still running');
}

void main() {
  late Directory dir;
  late String script, pidfile;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('maprisma-group-');
    script = '${dir.path}/stubborn.sh';
    pidfile = '${dir.path}/child.pid';
    File(script).writeAsStringSync(_stubborn);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<int> childPid() async {
    for (var i = 0; i < 100; i++) {
      final f = File(pidfile);
      if (f.existsSync() && f.readAsStringSync().trim().isNotEmpty) {
        return int.parse(f.readAsStringSync().trim());
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('no child pid');
  }

  test('bounded output: success ends what the program left behind', () async {
    final (out, ok) = await boundedOutput(
      ['sh', script, pidfile, 'exit'],
      timeout: const Duration(seconds: 10),
    );
    expect(ok, isTrue);
    expect(String.fromCharCodes(out).trim(), 'done');
    await _gone(await childPid());
  });

  test('bounded output: the deadline ends the whole group', () async {
    final (_, ok) = await boundedOutput(
      ['sh', script, pidfile, 'wait'],
      timeout: const Duration(seconds: 1),
    );
    expect(ok, isFalse);
    await _gone(await childPid());
  });

  test('endGroup: leader running, child ignoring SIGTERM', () async {
    final process = await Process.start('setsid', ['--', 'sh', script, pidfile, 'wait']);
    final child = await childPid();
    await endGroup(process, grace: const Duration(milliseconds: 300));
    await _gone(child);
  });

  test('endGroup: the leader ended first', () async {
    final process = await Process.start('setsid', ['--', 'sh', script, pidfile, 'exit']);
    final group = ProcessGroup(process.pid); // taken while it runs, as the callers do
    final child = await childPid();
    await process.exitCode;
    group.signal(15);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(_running(child), isTrue); // it ignores SIGTERM
    group.signal(9);
    group.close();
    await _gone(child);
  });
}
