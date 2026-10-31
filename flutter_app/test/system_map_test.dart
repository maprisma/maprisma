import 'package:maprisma/backend.dart';
import 'package:maprisma/map_zoom.dart';
import 'package:maprisma/system_map_view.dart';
import 'package:maprisma/map_welcome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class MapBackend implements Backend {
  final calls = <String>[];
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add(method);
    if (method == 'system.view') return {'ok': true};
    return {
      'preview': 'token',
      'name': 'Fixture helper',
      'prompt': 'Exact reviewed System Map: /mnt/Data/models',
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void desktop(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Map<String, dynamic> data() => {
  'nodes': [
    {
      'id': 'folder:test',
      'label': 'Models folder',
      'detail': '/mnt/Data/models',
      'column': 0,
      'kind': 'folder',
      'status': 'available',
      'path': '/mnt/Data/models',
      'info': '',
    },
  ],
  'edges': [],
  'notes': [],
  'health': [],
  'helpers': [
    {'command': 'fixture', 'name': 'Fixture helper', 'check': true},
  ],
  'limited': false,
  'search_done': false,
};

void main() {
  testWidgets('welcome explains read-only discovery and keeps entry actions', (
    tester,
  ) async {
    desktop(tester);
    int searches = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapWelcome(
            tr: (k) => k,
            busy: false,
            skipSearch: false,
            searched: false,
            onLook: () => searches++,
            onSkip: () {},
            onSystem: () {},
            onAgents: () {},
          ),
        ),
      ),
    );
    expect(find.textContaining(separateMountHint), findsOneWidget);
    await tester.tap(find.text('Look at this PC'));
    expect(searches, 1);
    expect(find.text('Skip').hitTestable(), findsOneWidget);
    expect(find.text('System Map').hitTestable(), findsOneWidget);
  });

  testWidgets('System Map retains selection and zoom while switching pages', (
    tester,
  ) async {
    desktop(tester);
    final backend = MapBackend();
    final controller = TransformationController();
    addTearDown(controller.dispose);
    int page = 0;
    late StateSetter update;
    final system = SystemMapView(
      data: data(),
      backend: backend,
      tr: (k) => k,
      busy: false,
      onRefresh: (_) async {},
      onOperation: (_, _, _) async => null,
      onSaved: (_) async {},
      onSession: (_) {},
      onShowAI: (_) {},
      controller: controller,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return IndexedStack(
                index: page,
                children: [system, const Text('AI side')],
              );
            },
          ),
        ),
      ),
    );
    expect(backend.calls, isEmpty);
    await tester.tap(find.text('Models folder'));
    await tester.pumpAndSettle();
    controller.value = Matrix4.translationValues(-50, 0, 0);
    update(() => page = 1);
    await tester.pumpAndSettle();
    update(() => page = 0);
    await tester.pumpAndSettle();
    expect(controller.value.storage[12], -50);
    expect(
      find.byWidgetPredicate(
        (w) => w is SelectableText && w.data == '/mnt/Data/models',
      ),
      findsOneWidget,
    );
    expect(backend.calls, contains('system.view'));
  });

  testWidgets(
    'Smart Check consent names the online service and cancellation never launches AI',
    (tester) async {
      desktop(tester);
      final backend = MapBackend();
      final controller = TransformationController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SystemMapView(
              data: data(),
              backend: backend,
              tr: (k) => k,
              busy: false,
              onRefresh: (_) async {},
              onOperation: (_, _, _) async =>
                  throw StateError('No AI run before consent'),
              onSaved: (_) async {},
              onSession: (_) => throw StateError('No helper launch'),
              onShowAI: (_) {},
              controller: controller,
            ),
          ),
        ),
      );
      await tester.tap(
        find.byType(DropdownButtonFormField<String>).hitTestable(),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fixture helper').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Check this system with AI'));
      await tester.tap(find.text('Check this system with AI'));
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(backend.calls, ['system.help_preview']);
      expect(
        find.textContaining(
          'and, for an online model, its service receive this System Map',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(backend.calls, ['system.help_preview']);
    },
  );

  testWidgets(
    'System Map puts zoom control in header, folds side panel in small view, and has full screen button',
    (tester) async {
      final backend = MapBackend();
      final controller = TransformationController();
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SystemMapView(
              data: data(),
              backend: backend,
              tr: (k) => k,
              busy: false,
              onRefresh: (_) async {},
              onOperation: (_, _, _) async => null,
              onSaved: (_) async {},
              onSession: (_) {},
              onShowAI: (_) {},
              controller: controller,
            ),
          ),
        ),
      );
      await tester.pump();

      // Zoom control is in the header row above the map, not overlapping column headers.
      expect(find.byType(MapZoomControl), findsOneWidget);
      expect(
        tester.getBottomRight(find.byType(MapZoomControl)).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.byType(InteractiveViewer)).dy),
      );

      // In small view (< 1150 px), the 340 px side panel is folded away and the map uses the full width.
      expect(find.text('What we found'), findsNothing);
      expect(
        find.byKey(const ValueKey('system-sidebar-toggle')),
        findsOneWidget,
      );
      expect(tester.getSize(find.byType(InteractiveViewer)).width, 1000);

      // Tapping the Sidebar button unfolds the 340 px side panel.
      await tester.tap(find.byKey(const ValueKey('system-sidebar-toggle')));
      await tester.pump();
      expect(find.text('What we found'), findsOneWidget);
      expect(tester.getSize(find.byType(InteractiveViewer)).width, 1000 - 340);
    },
  );
}
