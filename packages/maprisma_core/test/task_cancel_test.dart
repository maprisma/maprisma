import 'dart:io';
import 'package:maprisma_core/src/core_tasks.dart';
import 'package:test/test.dart';

/// tasks.cancel stops the worker, as flutter_tasks does; a commit is never
/// cancelled. It once only answered with the state, the worker went on.
void main() {
  test('cancel ends a running worker and says stopped', () async {
    final home = Directory.systemTemp.createTempSync('task-cancel');
    addTearDown(() => home.deleteSync(recursive: true));
    final pidFile = File('${home.path}/pid');
    final script = File('${home.path}/worker.sh')
      ..writeAsStringSync(
        '#!/bin/sh\necho \$\$ > ${pidFile.path}\nexec sleep 30\n',
      );
    Process.runSync('chmod', ['+x', script.path]);
    final tasks = CoreTasks([script.path]);
    final ident = tasks.startPrivate('mcp.tools', [1])['task'] as String;
    for (var i = 0; i < 200 && !pidFile.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final pid = pidFile.readAsStringSync().trim();
    expect(tasks.status(ident)['state'], 'running');
    expect(tasks.cancel(ident)['state'], 'stopped');
    for (var i = 0; i < 300 && Directory('/proc/$pid').existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(Directory('/proc/$pid').existsSync(), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(tasks.status(ident)['state'], 'stopped');
  });
}
