import 'package:maprisma/map_editor.dart';
import 'package:maprisma/map_groups.dart';
import 'package:maprisma/map_lights.dart';
import 'package:maprisma/map_smart_card.dart';
import 'package:maprisma/window_popup.dart' show popupSize;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'map_layout_test.dart' show fixtureGraph;

Future<void> mount(
  WidgetTester tester, {
  required List<Map<String, dynamic>> edits,
  Map<String, dynamic>? graph,
  Map<String, dynamic>? saved,
  ValueChanged<Map<String, dynamic>>? onLayout,
  bool active = false,
  bool reduced = false,
  String mode = 'all',
  Set<String>? selection,
  bool smartCards = false,
  TransformationController? controller,
  Size size = const Size(1500, 1000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final g = graph ?? fixtureGraph(active: active);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size, disableAnimations: reduced),
        child: Scaffold(
          body: MapEditor(
            graph: g,
            saved: saved ?? {},
            onLayout: onLayout,
            onEdit: (e) async {
              edits.add(e);
            },
            tr: (s) => s,
            animate: mode,
            selection: selection,
            smartCards: smartCards,
            controller: controller,
            groups: smartCards
                ? MapGroup.fromGraph(g, const [
                    'MCP servers and skills',
                    'Agents',
                    'Providers',
                    'Models',
                  ])
                : null,
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
      expect((saved.last['card_order'] as List), contains('1:agent:'));
      expect(saved.last.containsKey('cards'), false);
      expect(edits, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'group cards stay in their column with 2 px drop line and Earlier/Later menu only',
    (tester) async {
      final edits = <Map<String, dynamic>>[], saved = <Map<String, dynamic>>[];
      final base = fixtureGraph();
      final graph = {
        ...base,
        'nodes': [
          ...(base['nodes'] as List),
          {
            'id': 'skills:s',
            'kind': 'skills',
            'column': 0,
            'label': 'skills:s',
            'detail': '',
          },
        ],
      };
      await mount(
        tester,
        edits: edits,
        graph: graph,
        saved: {
          'cards': {
            '0:mcp:': [600, 400],
          },
        },
        onLayout: saved.add,
      );
      final mcpHeader = find
          .ancestor(
            of: find.text('MCP servers'),
            matching: find.byType(Positioned),
          )
          .first;
      final skillsHeader = find
          .ancestor(of: find.text('Skills'), matching: find.byType(Positioned))
          .first;
      expect(tester.getTopLeft(mcpHeader).dx, 16);
      expect(tester.getTopLeft(skillsHeader).dx, 16);
      expect(
        tester.getTopLeft(mcpHeader).dy,
        lessThan(tester.getTopLeft(skillsHeader).dy),
      );

      // Header menu only has Earlier card and Later card (the four Move items are gone).
      await tester.tap(
        find.descendant(
          of: mcpHeader,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Earlier card'), findsOneWidget);
      expect(find.text('Later card'), findsOneWidget);
      expect(find.text('Move left'), findsNothing);
      expect(find.text('Move right'), findsNothing);
      expect(find.text('Move up'), findsNothing);
      expect(find.text('Move down'), findsNothing);
      // Trying Earlier card on the top card in column 0 keeps it in column 0 at index 0.
      await tester.tap(find.text('Earlier card'));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(mcpHeader).dx, 16);
      expect(
        tester.getTopLeft(mcpHeader).dy,
        lessThan(tester.getTopLeft(skillsHeader).dy),
      );

      // Vertical drag shows the 2 px drop line inside the column and reorders on release,
      // while horizontal offset cannot move the card out of its column.
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('MCP servers')),
      );
      await gesture.moveBy(const Offset(250, 260));
      await tester.pump();
      final dropLine = find.byKey(const ValueKey('card-drop-line'));
      expect(dropLine, findsOneWidget);
      final lineRect = tester.getRect(dropLine);
      expect(lineRect.left, 16);
      expect(lineRect.width, 266);
      expect(lineRect.height, 2);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(dropLine, findsNothing);
      expect(tester.getTopLeft(mcpHeader).dx, 16);
      expect(tester.getTopLeft(skillsHeader).dx, 16);
      expect(
        tester.getTopLeft(skillsHeader).dy,
        lessThan(tester.getTopLeft(mcpHeader).dy),
      );
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

  testWidgets(
    'connecting works by keyboard: Actions › Connect, Enter on the target',
    (tester) async {
      final edits = <Map<String, dynamic>>[];
      await mount(tester, edits: edits);
      Finder box(String label) => find
          .ancestor(of: find.text(label), matching: find.byType(Card))
          .first;
      // Tab until the focus is inside `target`.
      Future<void> tabTo(Finder target) async {
        final element = target.evaluate().single;
        for (var i = 0; i < 80; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          final focused = FocusManager.instance.primaryFocus?.context;
          if (focused == null) continue;
          var inside = focused == element;
          focused.visitAncestorElements((e) {
            if (e == element) inside = true;
            return !inside;
          });
          if (inside) return;
        }
        fail('not reachable by Tab');
      }

      await tabTo(
        find.descendant(
          of: box('agent:a'),
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter); // Connect
      await tester.pumpAndSettle();
      expect(find.text('Cancel'), findsOneWidget);
      await tabTo(box('runtime:r'));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(edits.single, {'source': 'agent:a', 'target': 'runtime:r'});
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'smart card slot is hidden without helpers, changes no node or transform when opened, keeps one open, and fits Omarchy popup',
    (tester) async {
      final edits = <Map<String, dynamic>>[];
      await mount(tester, edits: edits, smartCards: false);
      expect(find.byType(MapSmartCard), findsNothing);

      final controller = TransformationController()
        ..value = (Matrix4.identity()..translateByDouble(10, 12, 0, 1));
      addTearDown(controller.dispose);
      final popup = Size(
        popupSize.width.toDouble(),
        popupSize.height.toDouble(),
      );
      await mount(
        tester,
        edits: edits,
        smartCards: true,
        controller: controller,
        size: popup,
      );
      expect(find.byType(MapSmartCard), findsNWidgets(4));
      for (final (col, _) in mapSmartColumns) {
        final card = tester.widget<MapSmartCard>(
          find.byKey(ValueKey('smart-card-$col')),
        );
        expect(card.open, isFalse);
        expect(
          tester.getSize(find.byKey(ValueKey('smart-card-$col'))),
          const Size(266, 38),
        );
      }

      Map<String, Rect> nodeRects() => {
        for (final label in [
          'agent:a',
          'agent:b',
          'runtime:r',
          'runtime:s',
          'model:r:m',
          'model:r:n',
          'mcp:c',
        ])
          label: tester.getRect(find.text(label)),
      };
      final beforeNodes = nodeRects();
      final beforeMatrix = controller.value.clone();

      // Open the Agents smart card: node positions and transform do not change.
      await tester.tap(find.byKey(const ValueKey('smart-card-agents')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<MapSmartCard>(
              find.byKey(const ValueKey('smart-card-agents')),
            )
            .open,
        isTrue,
      );
      expect(nodeRects(), beforeNodes);
      expect(controller.value, beforeMatrix);
      final agentsRect = tester.getRect(
        find.byKey(const ValueKey('smart-card-agents')),
      );
      expect(agentsRect.left, greaterThanOrEqualTo(0));
      expect(agentsRect.top, greaterThanOrEqualTo(0));
      expect(agentsRect.right, lessThanOrEqualTo(popup.width));
      expect(agentsRect.bottom, lessThanOrEqualTo(popup.height));

      // Opening another column closes the previously open card, and even the rightmost
      // column (Models) stays inside the 1100 × 760 Omarchy popup size.
      await tester.tap(find.byKey(const ValueKey('smart-card-models')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<MapSmartCard>(
              find.byKey(const ValueKey('smart-card-agents')),
            )
            .open,
        isFalse,
      );
      expect(
        tester
            .widget<MapSmartCard>(
              find.byKey(const ValueKey('smart-card-models')),
            )
            .open,
        isTrue,
      );
      expect(
        find.byWidgetPredicate((w) => w is MapSmartCard && w.open),
        findsOneWidget,
      );
      expect(nodeRects(), beforeNodes);
      expect(controller.value, beforeMatrix);
      final modelsRect = tester.getRect(
        find.byKey(const ValueKey('smart-card-models')),
      );
      expect(modelsRect.left, greaterThanOrEqualTo(0));
      expect(modelsRect.top, greaterThanOrEqualTo(0));
      expect(modelsRect.right, lessThanOrEqualTo(popup.width));
      expect(modelsRect.bottom, lessThanOrEqualTo(popup.height));
      expect(tester.takeException(), isNull);
    },
  );
}
