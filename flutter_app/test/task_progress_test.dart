import 'support/python_transport.dart';
import 'dart:io';
import 'package:asterism/backend.dart';
import 'package:asterism/provider_task_dialog.dart';
import 'package:asterism/task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'focus arrival and responsive reparenting do not start a task twice',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync(
        'asterism-card-progress-',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/flutter_backend.py').writeAsStringSync(r'''
import json,sys
starts=0
polls=0
for line in sys.stdin:
    q=json.loads(line)
    method=q['method']
    if method=='providers.run':
        starts+=1
        result={'task':'owned','focus':['runtime:test']}
    elif method=='tasks.status':
        polls+=1
        result=({'state':'running','fraction':0.5,'text':'Working'} if polls<4
                else {'state':'done','result':{'ok':True,'starts':starts}})
    else:
        result={}
    print(json.dumps({'id':q['id'],'result':result}),flush=True)
''');
      final backend = await tester.runAsync(
        () => PythonTransport.start(dir.path).then(Backend.fromTransport),
      );
      addTearDown(backend!.dispose);
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Set<String> focus = {};
      Map<String, dynamic>? result;
      late TaskProgress progress;
      final taskKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                progress = TaskProgress(
                  key: taskKey,
                  backend: backend,
                  operation: 'model.load',
                  params: const {'key': 'test'},
                  title: 'Load',
                  tr: (s) => s,
                  onFocus: (ids) => setState(() => focus = ids),
                  onComplete: (value) => setState(() => result = value),
                );
                return TaskHost(
                  spec: TaskCardSpec(
                    title: 'Load',
                    focus: focus,
                    closable: result != null,
                    child: result == null
                        ? progress
                        : Text('starts: ${result!['starts']}'),
                  ),
                  graph: const {
                    'nodes': [
                      {
                        'id': 'runtime:test',
                        'column': 2,
                        'kind': 'runtime',
                        'label': 'Test runtime',
                        'detail': '',
                      },
                    ],
                    'edges': [],
                  },
                  tr: (s) => s,
                  onClose: () {},
                );
              },
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('half-task')), findsOneWidget);
      tester.view.physicalSize = const Size(800, 800);
      await tester.pump();
      expect(find.byKey(const ValueKey('full-task')), findsOneWidget);
      // Polling delays run in fake time; subprocess IO runs in real time.
      for (var i = 0; i < 8 && result == null; i++) {
        await tester.pump(const Duration(milliseconds: 220));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(result, {'ok': true, 'starts': 1});
      expect(find.text('starts: 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
