import 'package:asterism/backend.dart';
import 'package:asterism/system_map_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class ActionBackend implements Backend {
  final requests = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    requests.add({'method': method, ...params});
    return method == 'system.view'
        ? {'ok': true}
        : {
            'plan': 'opaque-plan',
            'empty': false,
            'files': [
              {'path': '/home/test/settings.json', 'text': ''},
            ],
          };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    String kind,
    ActionBackend backend,
    List<String> operations, {
    bool missing = false,
  }) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TransformationController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SystemMapView(
            data: {
              'nodes': [
                {
                  'id': 'found:fixture',
                  'found': 'found-token',
                  'label': 'Fixture',
                  'detail': '/mnt/Data/models',
                  'column': 0,
                  'kind': kind,
                  'status': missing ? 'missing' : 'found',
                  'path': '/mnt/Data/models',
                  'info': '',
                  'provider': 'fixture',
                },
              ],
              'edges': [],
              'notes': [],
              'helpers': [],
              'search_done': false,
              'scan_limits': [
                {
                  'path': '/mnt/Data',
                  'limits': ['depth'],
                  'depth': 5,
                },
              ],
            },
            backend: backend,
            tr: (k) => k,
            busy: false,
            onRefresh: (_) async {
              operations.add('search');
            },
            onOperation: (op, params, title) async {
              operations.add(op);
              return {'ok': true, 'undo': 'undo-token'};
            },
            onSaved: (_) async {},
            onSession: (_) {},
            onShowAI: (_) {},
            controller: controller,
          ),
        ),
      ),
    );
  }

  testWidgets('disk search is explicit and reuse needs a preview', (
    tester,
  ) async {
    final backend = ActionBackend();
    final operations = <String>[];
    await mount(tester, 'models', backend, operations);
    expect(operations, isEmpty);
    await tester.tap(find.text('Look at this PC'));
    await tester.pumpAndSettle();
    expect(operations, ['search']);
    await tester.tap(find.text('Fixture'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reuse model folder'));
    await tester.pumpAndSettle();
    expect(operations, ['search']);
    expect(find.text('Preview'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(operations, ['search', 'existing.apply']);
  });
  testWidgets(
    'forgetting a missing disk requires confirmation and only sends its node id',
    (tester) async {
      final backend = ActionBackend();
      final operations = <String>[];
      await mount(tester, 'disk', backend, operations, missing: true);
      await tester.tap(find.text('Fixture'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Forget this disk'));
      await tester.tap(find.text('Forget this disk'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Files and settings are kept.'),
        findsOneWidget,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(
        backend.requests.where((r) => r['method'] == 'system.forget_disk'),
        isEmpty,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget this disk'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Forget this disk'));
      await tester.pumpAndSettle();
      expect(
        backend.requests
            .where((r) => r['method'] == 'system.forget_disk')
            .single,
        {'method': 'system.forget_disk', 'node': 'found:fixture'},
      );
      expect(operations, isEmpty);
    },
  );
  testWidgets('program version check requires its own confirmation', (
    tester,
  ) async {
    final backend = ActionBackend();
    final operations = <String>[];
    await mount(tester, 'runtime', backend, operations);
    await tester.tap(find.text('Fixture'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check program'));
    await tester.pumpAndSettle();
    expect(operations, isEmpty);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(operations, ['existing.check']);
    expect(find.text('Program check passed'), findsOneWidget);
  });
}
