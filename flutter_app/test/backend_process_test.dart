import 'package:asterism/python_transport.dart';
import 'dart:io';

import 'package:asterism/backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Python reference propagates watcher protection to workers', () async {
    final directory = Directory.systemTemp.createTempSync(
      'asterism-reference-env-',
    );
    try {
      File('${directory.path}/flutter_backend.py').writeAsStringSync(
        r'''import json,os,subprocess,sys
for line in sys.stdin:
 q=json.loads(line)
 child=subprocess.check_output([sys.executable,'-c','import os; print(os.environ.get("ASTERISM_FLUTTER_DEVEL", ""))'],text=True).strip()
 print(json.dumps({'id':q['id'],'result':{'guard':os.environ.get('ASTERISM_FLUTTER_DEVEL'),'worker_guard':child}}),flush=True)
''',
      );
      final backend = await PythonTransport.start(directory.path);
      try {
        expect(await backend.call('test.guard'), {
          'guard': '1',
          'worker_guard': '1',
        });
      } finally {
        await backend.shutdown();
      }
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test(
    'Disconnected service fails waiting requests instead of hanging',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'asterism-disconnect-',
      );
      addTearDown(() => directory.delete(recursive: true));
      await File(
        '${directory.path}/flutter_backend.py',
      ).writeAsString('import sys\nsys.stdin.readline()\n');
      final backend = await PythonTransport.start(
        directory.path,
      ).then(Backend.fromTransport);
      addTearDown(backend.dispose);
      await expectLater(backend.call('app.snapshot'), throwsStateError);
      expect(backend.isConnected, isFalse);
    },
  );
}
