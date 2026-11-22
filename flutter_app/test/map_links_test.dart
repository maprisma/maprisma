import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/map_3d.dart' show Map3dBlock;
import 'package:maprisma/map_editor.dart';

/// The map's side of the links between the tabs (task 091): Show on map
/// and "Used in N projects".
Map<String, dynamic> manyAgents(int count) => {
  'nodes': [
    for (var i = 0; i < count; i++)
      {
        'id': 'agent:a$i',
        'kind': 'agent',
        'column': 1,
        'label': 'Agent $i',
        'detail': '',
      },
    {
      'id': 'runtime:r',
      'kind': 'runtime',
      'column': 2,
      'label': 'Runtime',
      'detail': '',
    },
  ],
  'edges': [
    {'source': 'agent:a0', 'target': 'runtime:r', 'kind': 'uses'},
  ],
};

class Calls {
  final revealed = <bool>[];
  final usedIn = <String>[];
  final layouts = <Map<String, dynamic>>[];
  final edits = <Map<String, dynamic>>[];
}

Future<TransformationController> mount(
  WidgetTester tester,
  Calls calls, {
  String? reveal,
  String? focused,
  Map<String, int> usedIn = const {},
  int agents = 30,
  Size size = const Size(1000, 500),
  List<String>? layers,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = TransformationController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MapEditor(
          graph: manyAgents(agents),
          saved: const {},
          onLayout: calls.layouts.add,
          onEdit: (e) async => calls.edits.add(e),
          tr: (s) => s,
          animate: 'off',
          controller: controller,
          reveal: reveal,
          focused: focused,
          onRevealed: calls.revealed.add,
          usedIn: usedIn,
          onUsedIn: calls.usedIn.add,
          layers: layers,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Finder box(String label) => find
    .ancestor(of: find.text(label), matching: find.byType(Map3dBlock))
    .first;

bool marked(WidgetTester tester, String label) => find
    .descendant(
      of: box(label),
      matching: find.byWidgetPredicate(
        (w) =>
            w is Card &&
            w.shape is RoundedRectangleBorder &&
            (w.shape as RoundedRectangleBorder).side.width == 3,
      ),
    )
    .evaluate()
    .isNotEmpty;

void main() {
  testWidgets('Show on map: an off-screen box is panned into view and marked; '
      'nothing is saved', (tester) async {
    final calls = Calls();
    // Without the reveal the last agent is below the window.
    await mount(tester, calls);
    expect(tester.getRect(box('Agent 29')).top, greaterThan(500));
    await mount(tester, calls, reveal: 'agent:a29', focused: 'agent:a29');
    expect(calls.revealed, [true]);
    final rect = tester.getRect(box('Agent 29'));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(500));
    expect(marked(tester, 'Agent 29'), isTrue);
    expect(marked(tester, 'Agent 0'), isFalse);
    // Temporary: no layout, pin or edit written.
    expect(calls.layouts, isEmpty);
    expect(calls.edits, isEmpty);
  });

  testWidgets('a box already in view does not move', (tester) async {
    final calls = Calls();
    final controller = await mount(tester, calls, reveal: 'agent:a0');
    expect(calls.revealed, [true]);
    expect(controller.value.getTranslation().y, 0);
  });

  testWidgets('an agent that is not on the map says so; nothing moves', (
    tester,
  ) async {
    final calls = Calls();
    final before = (await mount(tester, calls)).value.clone();
    final controller = await mount(tester, calls, reveal: 'agent:gone');
    expect(calls.revealed, [false]);
    expect(controller.value, before);
  });

  testWidgets('the mark goes when focused is cleared', (tester) async {
    final calls = Calls();
    await mount(tester, calls, focused: 'agent:a0', agents: 3);
    expect(marked(tester, 'Agent 0'), isTrue);
    await mount(tester, calls, agents: 3);
    expect(marked(tester, 'Agent 0'), isFalse);
  });

  testWidgets('Used in N projects: badge, tooltip, screen-reader text, tap', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final calls = Calls();
    await mount(tester, calls, agents: 3, usedIn: {'a0': 3, 'a1': 1});
    final badges = find.byKey(const ValueKey('used-in-badge'));
    expect(badges, findsNWidgets(2));
    expect(find.byTooltip('Used in 3 projects'), findsOneWidget);
    expect(find.byTooltip('Used in 1 project'), findsOneWidget);
    expect(find.bySemanticsLabel('Used in 3 projects'), findsOneWidget);
    await tester.tap(find.byTooltip('Used in 3 projects'));
    await tester.pump();
    expect(calls.usedIn, ['a0']);
    // No badge for an agent in no project.
    expect(find.descendant(of: box('Agent 2'), matching: badges), findsNothing);
    handle.dispose();
  });

  testWidgets('Used in N projects is in the box\'s Actions menu too', (
    tester,
  ) async {
    final calls = Calls();
    await mount(tester, calls, agents: 3, usedIn: {'a0': 2});
    await tester.tap(
      find.descendant(of: box('Agent 0'), matching: find.byTooltip('Actions')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('used-in-agent:a0')));
    await tester.pumpAndSettle();
    expect(calls.usedIn, ['a0']);
    // Not offered for an agent in no project.
    await tester.tap(
      find.descendant(of: box('Agent 1'), matching: find.byTooltip('Actions')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('used-in-agent:a1')), findsNothing);
  });

  for (final size in [const Size(480, 500), const Size(1000, 500)]) {
    testWidgets('a middle box on a newly shown map at ${size.width.toInt()} '
        'px: in view after the fit', (tester) async {
      final calls = Calls();
      await mount(
        tester,
        calls,
        size: size,
        reveal: 'agent:a15',
        focused: 'agent:a15',
      );
      expect(calls.revealed, [true]);
      final rect = tester.getRect(box('Agent 15'));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(size.height));
    });
  }

  testWidgets('an agent whose layer is hidden is not on the map', (
    tester,
  ) async {
    final calls = Calls();
    await mount(
      tester,
      calls,
      agents: 3,
      reveal: 'agent:a1',
      layers: const ['online', 'local', 'models', 'mcp', 'skills'],
    );
    expect(calls.revealed, [false]);
  });

  testWidgets('the badge is a focusable button for screen readers', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final calls = Calls();
    await mount(tester, calls, agents: 3, usedIn: {'a0': 2});
    expect(
      tester.getSemantics(find.bySemanticsLabel('Used in 2 projects')),
      isSemantics(isButton: true, isFocusable: true, hasTapAction: true),
    );
    handle.dispose();
  });

  testWidgets('no badge on other boxes, even with an empty key', (
    tester,
  ) async {
    final calls = Calls();
    await mount(tester, calls, agents: 1, usedIn: {'': 4});
    expect(find.byKey(const ValueKey('used-in-badge')), findsNothing);
  });
}
