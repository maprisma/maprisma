import 'dart:io';

import 'package:asterism/backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
      final backend = await Backend.start(directory.path);
      addTearDown(backend.dispose);
      await expectLater(backend.call('app.snapshot'), throwsStateError);
      expect(backend.isConnected, isFalse);
    },
  );
}
