import 'support/python_transport.dart';
import 'dart:io';
import 'package:asterism/backend.dart';
import 'package:asterism/provider_task_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'expired task handle shows a closable failure instead of retrying forever',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'asterism-task-error-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      File('${directory.path}/flutter_backend.py').writeAsStringSync(r'''
import json,sys
for line in sys.stdin:
    request = json.loads(line)
    print(json.dumps({'id':request['id'],'error':{'code':'invalid_request'}}),flush=True)
''');
      final backend = await tester.runAsync(
        () => PythonTransport.start(directory.path).then(Backend.fromTransport),
      );
      addTearDown(backend!.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskProgress(
              backend: backend,
              onComplete: (_) {},
              operation: 'connections.apply',
              params: const {},
              existingTask: 'expired',
              title: 'Apply',
              tr: (key) => key,
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      expect(find.text('The action could not be completed.'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Close'))
            .onPressed,
        isNotNull,
      );
    },
  );
}
