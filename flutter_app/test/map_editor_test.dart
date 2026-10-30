import 'package:maprisma/backend.dart';
import 'package:maprisma/connections_view.dart' show ConnectionReview;
import 'package:maprisma/map_editor.dart';
import 'package:maprisma/map_groups.dart';
import 'package:maprisma/map_lights.dart';
import 'package:maprisma/map_smart_card.dart';
import 'package:maprisma/task_card.dart' show TaskReview;
import 'package:maprisma/window_popup.dart' show popupSize;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'map_layout_test.dart' show fixtureGraph;

class _FakeSmartTransport implements ServiceTransport {
  _FakeSmartTransport(this.onCall);
  final Future<Map<String, dynamic>> Function(
    String method,
    Map<String, dynamic> params,
  )
  onCall;

  @override
  bool get isConnected => true;

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) => onCall(method, params);

  @override
  void dispose() {}

  @override
  Future<void> shutdown() async {}
}

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
  List<Map<String, dynamic>> smartHelpers = const [],
  CoreClient? client,
  ValueChanged<Map<String, dynamic>>? onSmartApplied,
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
            smartHelpers: smartHelpers,
            client: client,
            onSmartApplied: onSmartApplied,
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

      // At scale 0.8 in the 1100 × 760 Omarchy popup, the Models column (board left 922)
      // is already fully in view: opening it keeps board left at 922 and does not touch
      // the transform or any node position.
      controller.value = Matrix4.diagonal3Values(0.8, 0.8, 1);
      await tester.pump();
      final scaledNodes = nodeRects();
      final scaledMatrix = controller.value.clone();
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
      expect(
        tester
            .widget<Positioned>(
              find
                  .ancestor(
                    of: find.byKey(const ValueKey('smart-card-models')),
                    matching: find.byType(Positioned),
                  )
                  .first,
            )
            .left,
        922,
      );
      expect(nodeRects(), scaledNodes);
      expect(controller.value, scaledMatrix);
      final scaledModelsRect = tester.getRect(
        find.byKey(const ValueKey('smart-card-models')),
      );
      expect(scaledModelsRect.left, greaterThanOrEqualTo(0));
      expect(scaledModelsRect.right, lessThanOrEqualTo(popup.width));
      expect(scaledModelsRect.bottom, lessThanOrEqualTo(popup.height));

      // When cut off at scale 1.0 in 1100 × 760, opening Models keeps board left at 922
      // and brings it into view through the transform.
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      controller.value = Matrix4.identity();
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('smart-card-models')),
          matching: find.text('Ask AI…'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Positioned>(
              find
                  .ancestor(
                    of: find.byKey(const ValueKey('smart-card-models')),
                    matching: find.byType(Positioned),
                  )
                  .first,
            )
            .left,
        922,
      );
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
  testWidgets(
    'open smart card sits above line handles so tapping over a handle does not reach it',
    (tester) async {
      final edits = <Map<String, dynamic>>[];
      await mount(tester, edits: edits, smartCards: true);
      await tester.tap(find.text('agent:a'));
      await tester.pumpAndSettle();
      final hook = find
          .byTooltip(
            'Move this connection to another compatible box, or to empty space to disconnect.',
          )
          .first;
      final hookCenter = tester.getCenter(hook);

      await tester.tap(find.byKey(const ValueKey('smart-card-providers')));
      await tester.pumpAndSettle();
      final cardRect = tester.getRect(
        find.byKey(const ValueKey('smart-card-providers')),
      );
      expect(cardRect.contains(hookCenter), isTrue);

      await tester.tapAt(hookCenter);
      await tester.pump();
      expect(find.text('Disconnect'), findsNothing);
      await tester.dragFrom(hookCenter, const Offset(0, 240));
      await tester.pump();
      expect(edits, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'opening smart card focuses the text field; Esc and Close return focus to the collapsed bar',
    (tester) async {
      final edits = <Map<String, dynamic>>[];
      await mount(tester, edits: edits, smartCards: true);
      final agentsCard = find.byKey(const ValueKey('smart-card-agents'));

      bool focusInside(Finder finder) {
        final focused = FocusManager.instance.primaryFocus?.context;
        if (focused == null) return false;
        final target = finder.evaluate().single;
        var inside = focused == target;
        focused.visitAncestorElements((e) {
          if (e == target) inside = true;
          return !inside;
        });
        return inside;
      }

      // Opening focuses the TextField inside the open smart card.
      await tester.tap(agentsCard);
      await tester.pumpAndSettle();
      expect(
        focusInside(
          find.descendant(of: agentsCard, matching: find.byType(TextField)),
        ),
        isTrue,
      );

      // Pressing Escape closes the card and returns focus to its collapsed bar.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.widget<MapSmartCard>(agentsCard).open, isFalse);
      expect(
        focusInside(
          find.descendant(of: agentsCard, matching: find.byType(InkWell)),
        ),
        isTrue,
      );

      // Re-open with Enter on the focused collapsed bar, then click Close:
      // focus returns to the collapsed bar again.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tester.widget<MapSmartCard>(agentsCard).open, isTrue);
      expect(
        focusInside(
          find.descendant(of: agentsCard, matching: find.byType(TextField)),
        ),
        isTrue,
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(tester.widget<MapSmartCard>(agentsCard).open, isFalse);
      expect(
        focusInside(
          find.descendant(of: agentsCard, matching: find.byType(InkWell)),
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'smart card states 1 to 6: 16 px status slot, helper cost before Ask, working cancel, clarify, redirect move, and error try again',
    (tester) async {
      final edits = <Map<String, dynamic>>[];
      final calls = <(String, Map<String, dynamic>)>[];
      var nextTaskState = 'running';
      Map<String, dynamic> nextResult = const {};
      final client = CoreClient(
        _FakeSmartTransport((method, params) async {
          calls.add((method, Map<String, dynamic>.from(params)));
          switch (method) {
            case 'map.smart_ask':
              return {'task': 'task-1'};
            case 'tasks.status':
              return {
                'state': nextTaskState,
                if (nextTaskState == 'done') 'result': nextResult,
              };
            case 'tasks.cancel':
              return {'cancelled': true};
            default:
              throw StateError('Unexpected method $method');
          }
        }),
      );
      const helpers = [
        {'command': 'local-helper', 'name': 'Local helper', 'local': true},
        {'command': 'claude', 'name': 'Claude Code', 'local': false},
      ];
      await mount(
        tester,
        edits: edits,
        smartCards: true,
        smartHelpers: helpers,
        client: client,
      );

      // State 2: collapsed bar reserves a 16 px slot at its left and shows the default helper.
      final slots = find.byKey(const ValueKey('smart-status-slot'));
      expect(slots, findsNWidgets(4));
      expect(tester.getSize(slots.first), const Size(16, 16));
      expect(find.text(' · Local helper'), findsNWidgets(4));

      // Open Agents smart card (State 3: Idle).
      final agentsCard = find.byKey(const ValueKey('smart-card-agents'));
      await tester.tap(agentsCard);
      await tester.pumpAndSettle();
      expect(find.text('Local, no tokens'), findsOneWidget);
      expect(find.text('Set up or connect an agent…'), findsOneWidget);

      // Switching helper shows Uses plan/tokens before Ask; no request sent yet.
      await tester.tap(find.byKey(const ValueKey('smart-helper-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Claude Code').last);
      await tester.pumpAndSettle();
      expect(find.text('Uses plan/tokens'), findsOneWidget);
      expect(calls, isEmpty);

      // Clicking Ask with blank prompt sends nothing.
      await tester.tap(find.text('Ask'));
      await tester.pump();
      expect(calls, isEmpty);

      // Typing text does not send; only clicking Ask sends map.smart_ask (State 4: Working).
      await tester.enterText(
        find.descendant(of: agentsCard, matching: find.byType(TextField)),
        'install qwencoder',
      );
      await tester.pump();
      expect(calls, isEmpty);
      await tester.tap(find.text('Ask'));
      await tester.pump();
      expect(calls.first.$1, 'map.smart_ask');
      expect(calls.first.$2, {
        'column': 'agents',
        'command': 'claude',
        'request': 'install qwencoder',
      });
      expect(find.text('Claude Code is checking Agents…'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      // Cancel in Working cancels the task and returns to Idle with the text kept.
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls.any((c) => c.$1 == 'tasks.cancel'), isTrue);
      expect(find.text('install qwencoder'), findsOneWidget);

      // State 6: Redirect on a column that is not Models, with Move to Models.
      calls.clear();
      nextTaskState = 'done';
      nextResult = {
        'helper': 'Claude Code',
        'local': false,
        'status': 'redirect',
        'instead': {
          'hint': 'Models are managed in the Models column.',
          'column': 'models',
          'request': 'install qwencoder',
        },
      };
      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();
      expect(
        find.text('Models are managed in the Models column.'),
        findsOneWidget,
      );
      expect(find.text('Move to Models'), findsOneWidget);

      // Clicking Move to Models opens Models card and pre-fills prompt without auto-sending.
      calls.clear();
      await tester.tap(find.text('Move to Models'));
      await tester.pumpAndSettle();
      final modelsCard = find.byKey(const ValueKey('smart-card-models'));
      expect(tester.widget<MapSmartCard>(agentsCard).open, isFalse);
      expect(tester.widget<MapSmartCard>(modelsCard).open, isTrue);
      expect(calls, isEmpty);
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: modelsCard, matching: find.byType(TextField)),
            )
            .controller
            ?.text,
        'install qwencoder',
      );

      // State 5: Clarify shows question and choice chips; clicking a chip sends answer.
      nextResult = {
        'helper': 'Local helper',
        'local': true,
        'status': 'clarify',
        'question': 'Which local LLM should run this model?',
        'choices': ['Ollama', 'llama.cpp'],
      };
      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();
      expect(
        find.text('Which local LLM should run this model?'),
        findsOneWidget,
      );
      expect(find.text('Ollama'), findsOneWidget);
      expect(find.text('llama.cpp'), findsOneWidget);

      // Clicking a choice chip sends map.smart_ask with answer; if it returns error,
      // Try again returns to prompt with text kept (no auto-retry).
      calls.clear();
      nextResult = {
        'helper': 'Local helper',
        'local': true,
        'status': 'error',
        'summary': 'Could not reach the search service.',
      };
      await tester.tap(find.text('Ollama'));
      await tester.pumpAndSettle();
      expect(calls.first.$1, 'map.smart_ask');
      expect(calls.first.$2, {
        'column': 'models',
        'command': 'local-helper',
        'request': 'install qwencoder',
        'answer': 'Ollama',
      });
      expect(find.text('Could not reach the search service.'), findsOneWidget);
      calls.clear();
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: modelsCard, matching: find.byType(TextField)),
            )
            .controller
            ?.text,
        'install qwencoder',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'smart card states 7 to 10: proposal words fit, omits Review on too_large, reviews and runs download, then connects via ConnectionReview',
    (tester) async {
      final edits = <Map<String, dynamic>>[];
      final calls = <(String, Map<String, dynamic>)>[];
      final applied = <Map<String, dynamic>>[];
      const gib = 1024 * 1024 * 1024;
      final client = CoreClient(
        _FakeSmartTransport((method, params) async {
          calls.add((method, Map<String, dynamic>.from(params)));
          switch (method) {
            case 'map.smart_ask':
              return {'task': 'ask-task'};
            case 'tasks.status':
              final task = params['task'] as String;
              if (task == 'ask-task') {
                return {
                  'state': 'done',
                  'result': {
                    'helper': 'Local helper',
                    'local': true,
                    'status': 'proposal',
                    'proposal': 'prop-1',
                    'summary': 'Found 3 models for Ollama.',
                    'limits': {
                      'gpu_name': 'AMD Radeon',
                      'vram': 12 * gib,
                      'ram': 32 * gib,
                      'free_disk': 80 * gib,
                    },
                    'candidates': [
                      {
                        'id': 'c1',
                        'title': 'Qwen2.5-Coder-7B-Q4_K_M.gguf',
                        'subtitle': 'bartowski/Qwen2.5-Coder-7B-GGUF · Ollama',
                        'reason': 'Fast coding model.',
                        'fit': 'ok',
                        'size': 5 * gib,
                      },
                      {
                        'id': 'c2',
                        'title': 'Qwen2.5-Coder-14B-Q4_K_M.gguf',
                        'subtitle': 'bartowski/Qwen2.5-Coder-14B-GGUF · Ollama',
                        'reason': 'Larger coding model.',
                        'fit': 'tight',
                        'size': 9 * gib,
                      },
                      {
                        'id': 'c3',
                        'title': 'Qwen2.5-Coder-72B-Q8_0.gguf',
                        'subtitle': 'bartowski/Qwen2.5-Coder-72B-GGUF · Ollama',
                        'reason': 'Exceeds memory.',
                        'fit': 'too_large',
                        'size': 75 * gib,
                      },
                    ],
                  },
                };
              }
              return {
                'state': 'done',
                'result': {'ok': true},
              };
            case 'map.smart_review':
              return {
                'title': 'Qwen2.5-Coder-7B-Q4_K_M.gguf',
                'subtitle': 'bartowski/Qwen2.5-Coder-7B-GGUF · Ollama',
                'size': 5 * gib,
                'fit': 'ok',
                'runtime': 'Ollama',
              };
            case 'map.smart_run':
              return {
                'task': 'run-task',
                'focus': ['runtime:ollama'],
              };
            case 'map.smart_connect':
              return {
                'plan': 'plan-1',
                'empty': false,
                'command': 'claude',
                'item': 'ollama',
                'remove': false,
                'files': [
                  {'path': '~/.claude.json', 'added': 2, 'removed': 0},
                ],
                'links_add': [],
                'links_remove': [],
              };
            case 'connections.apply':
              return {'ok': true, 'undo': 'undo-1'};
            default:
              throw StateError('Unexpected method $method');
          }
        }),
      );
      const helpers = [
        {'command': 'local-helper', 'name': 'Local helper', 'local': true},
        {'command': 'claude', 'name': 'Claude Code', 'local': false},
      ];
      await mount(
        tester,
        edits: edits,
        smartCards: true,
        smartHelpers: helpers,
        client: client,
        onSmartApplied: applied.add,
      );

      final modelsCard = find.byKey(const ValueKey('smart-card-models'));
      await tester.tap(modelsCard);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(of: modelsCard, matching: find.byType(TextField)),
        'coding model for ollama',
      );
      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();

      // State 7: Proposal shows PC limits, worded fit, and Review only on ok/tight.
      expect(find.text('Found 3 models for Ollama.'), findsOneWidget);
      expect(
        find.text('PC: 12.0 GiB VRAM · 32.0 GiB RAM · 80.0 GiB free'),
        findsOneWidget,
      );
      expect(find.text('Fits in VRAM'), findsOneWidget);
      expect(find.text('Uses RAM offload'), findsOneWidget);
      expect(find.text('Too large for this PC'), findsOneWidget);
      expect(find.byKey(const ValueKey('smart-review-c1')), findsOneWidget);
      expect(find.byKey(const ValueKey('smart-review-c2')), findsOneWidget);
      expect(find.byKey(const ValueKey('smart-review-c3')), findsNothing);

      // State 8: Clicking Review calls map.smart_review and shows SmartModelDownloadReview (TaskReview).
      await tester.tap(find.byKey(const ValueKey('smart-review-c1')));
      await tester.pumpAndSettle();
      expect(calls.last.$1, 'map.smart_review');
      expect(calls.last.$2, {'proposal': 'prop-1', 'candidate': 'c1'});
      expect(find.byType(SmartModelDownloadReview), findsOneWidget);
      expect(find.byType(TaskReview), findsOneWidget);
      expect(
        find.text('Download Qwen2.5-Coder-7B-Q4_K_M.gguf?'),
        findsOneWidget,
      );

      // Cancelling review keeps the proposal in State 7.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(SmartModelDownloadReview), findsNothing);
      expect(find.byKey(const ValueKey('smart-review-c1')), findsOneWidget);

      // Re-open review and confirm: runs map.smart_run (State 9) and arrives at State 10 (Done).
      await tester.tap(find.byKey(const ValueKey('smart-review-c1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(calls.any((c) => c.$1 == 'map.smart_run'), isTrue);
      expect(
        find.text('Qwen2.5-Coder-7B-Q4_K_M.gguf is ready.'),
        findsOneWidget,
      );
      expect(
        find.text('Connect it to an agent now? (Optional)'),
        findsOneWidget,
      );
      // Only real agents (Claude Code), not local-helper, are offered as connect chips.
      expect(find.widgetWithText(ActionChip, 'Claude Code'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Local helper'), findsNothing);

      // Clicking Claude Code calls map.smart_connect and shows ConnectionReview.
      await tester.tap(find.widgetWithText(ActionChip, 'Claude Code'));
      await tester.pumpAndSettle();
      expect(calls.last.$1, 'map.smart_connect');
      expect(calls.last.$2, {
        'proposal': 'prop-1',
        'candidate': 'c1',
        'agent': 'claude',
      });
      expect(find.byType(ConnectionReview), findsOneWidget);

      // Clicking Apply in ConnectionReview calls connections.apply, records Undo, and closes the card.
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(calls.last.$1, 'connections.apply');
      expect(calls.last.$2, {'plan': 'plan-1'});
      expect(applied.last['undo'], 'undo-1');
      expect(tester.widget<MapSmartCard>(modelsCard).open, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
