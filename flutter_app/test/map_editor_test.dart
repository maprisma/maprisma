import 'package:asterism/map_editor.dart';
import 'package:asterism/map_lights.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'map_layout_test.dart' show fixtureGraph;

Future<void> mount(
  WidgetTester tester, {
  required List<Map<String, dynamic>> edits,
  Map<String, dynamic>? saved,
  ValueChanged<Map<String, dynamic>>? onLayout,
  bool active = false,
  bool reduced = false,
  String mode = 'all',
  Set<String>? selection,
}) async {
  tester.view.physicalSize = const Size(1500, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(1500, 1000),
          disableAnimations: reduced,
        ),
        child: Scaffold(
          body: MapEditor(
            graph: fixtureGraph(active: active),
            saved: saved ?? {},
            onLayout: onLayout,
            onEdit: (e) async {
              edits.add(e);
            },
            tr: (s) => s,
            animate: mode,
            selection: selection,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'drawing from a box emits one reviewed edit, invalid drop does nothing',
    (tester) async {
      final edits = <Map<String, dynamic>>[];
      await mount(tester, edits: edits);
      await tester.dragFrom(
        tester.getCenter(find.text('agent:a')),
        const Offset(302, 0),
      );
      await tester.pump();
      expect(edits.single['source'], 'agent:a');
      expect(edits.single['target'], 'runtime:r');
      edits.clear();
      await tester.dragFrom(
        tester.getCenter(find.text('agent:a')),
        const Offset(0, 146),
      );
      await tester.pump();
      expect(edits, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'selected line hook removes on empty and Escape cancels keyboard move',
    (tester) async {
      final edits = <Map<String, dynamic>>[];
      await mount(tester, edits: edits);
      await tester.tap(find.text('agent:a'));
      await tester.pumpAndSettle();
      final hooks = find.byTooltip(
        'Move this connection to another compatible box, or to empty space to disconnect.',
      );
      expect(hooks, findsNWidgets(2));
      await tester.drag(hooks.first, const Offset(0, 300));
      await tester.pump();
      expect(edits.single['target'], isNull);
      expect(edits.single['edge']['kind'], 'uses');
      edits.clear();
      await tester.tap(hooks.first);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('Disconnect'), findsNothing);
      expect(edits, isEmpty);
    },
  );
  testWidgets(
    'fold and keyboard reorder save only layout; pin survives remount',
    (tester) async {
      final edits = <Map<String, dynamic>>[], saved = <Map<String, dynamic>>[];
      await mount(tester, edits: edits, onLayout: saved.add);
      await tester.tap(find.byTooltip('Actions').at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin'));
      await tester.pumpAndSettle();
      expect(saved.last['pins'], ['agent:a']);
      expect(edits, isEmpty);
      await tester.tap(find.byTooltip('Collapse').first);
      await tester.pumpAndSettle();
      expect(saved.last['collapsed'], isNotEmpty);
      expect(edits, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'lights stop with reduced motion, off setting and widget removal',
    (tester) async {
      final edits = <Map<String, dynamic>>[];
      await mount(tester, edits: edits, active: true);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(MapLightLayer), findsOneWidget);
      expect(
        (tester.widget<MapLightLayer>(find.byType(MapLightLayer)).clock
                as MapLightClock)
            .enabled,
        true,
      );
      await mount(tester, edits: edits, active: true, reduced: true);
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      await mount(tester, edits: edits, active: true, mode: 'off');
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'one agent selected with Shift; selecting model requests model edit',
    (tester) async {
      final edits = <Map<String, dynamic>>[], selection = <String>{};
      await mount(tester, edits: edits, selection: selection);
      await tester.tap(find.text('agent:a'));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.text('agent:b'));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(selection, {'agent:b'});
      await tester.tap(find.text('agent:a'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('model:r:n'));
      await tester.pump();
      expect(edits.single, {'source': 'agent:a', 'target': 'model:r:n'});
    },
  );
  testWidgets(
    'keyboard Connect uses the same reviewed edit and card movement saves layout',
    (tester) async {
      final edits = <Map<String, dynamic>>[], saved = <Map<String, dynamic>>[];
      await mount(tester, edits: edits, onLayout: saved.add);
      await tester.tap(find.byTooltip('Actions').at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.text('runtime:s'));
      await tester.pumpAndSettle();
      expect(edits.single, {'source': 'agent:a', 'target': 'runtime:s'});
      edits.clear();
      await tester.drag(find.text('Agents'), const Offset(40, 60));
      await tester.pumpAndSettle();
      expect((saved.last['cards'] as Map)['1:agent:'], isNotNull);
      expect(edits, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('reorder grip and provider hook preserve scene coordinates', (
    tester,
  ) async {
    final edits = <Map<String, dynamic>>[], saved = <Map<String, dynamic>>[];
    await mount(tester, edits: edits, onLayout: saved.add);
    await tester.drag(
      find.byKey(const ValueKey('reorder-agent:a')),
      const Offset(0, 160),
    );
    await tester.pumpAndSettle();
    expect((saved.last['order'] as Map)['1:agent:'], ['agent:b', 'agent:a']);
    await tester.tap(find.text('agent:a'));
    await tester.pumpAndSettle();
    final hook = find
        .byTooltip(
          'Move this connection to another compatible box, or to empty space to disconnect.',
        )
        .first;
    final from = tester.getCenter(hook),
        to = tester.getCenter(find.text('runtime:s'));
    await tester.dragFrom(from, to - from);
    await tester.pumpAndSettle();
    expect(edits.single['target'], 'runtime:s');
    expect(edits.single['edge']['kind'], 'uses');
    expect(tester.takeException(), isNull);
  });
}
