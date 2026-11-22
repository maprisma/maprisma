import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/task_card.dart' show RetainedTaskView;

/// A view kept mounted behind another closes its tooltips when it is hidden
/// (task 093): with its tickers off a tooltip's fade-out never ends, and it
/// stayed over the view in front. Its subtree, focus and state stay as they
/// are.
void main() {
  Future<void> show(WidgetTester tester, bool visible) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: RetainedTaskView(
          visible: visible,
          child: Center(
            child: IconButton(
              key: const ValueKey('badge'),
              tooltip: 'Used in 2 projects',
              onPressed: () {},
              icon: const Icon(Icons.folder_copy_outlined),
            ),
          ),
        ),
      ),
    ),
  );

  Finder tip() => find.text('Used in 2 projects', skipOffstage: false);

  testWidgets('hidden while its tooltip shows: the tooltip goes; shown again: '
      'tooltips work', (tester) async {
    await show(tester, true);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    final badge = tester.getCenter(find.byKey(const ValueKey('badge')));
    await mouse.moveTo(badge);
    // Fully faded in, so hiding has to fade it out.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tip(), findsOneWidget);
    // Behind another view now; the pointer has not moved.
    await show(tester, false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tip(), findsNothing);
    // Shown again: tooltips work.
    await show(tester, true);
    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(seconds: 1));
    await mouse.moveTo(badge);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tip(), findsOneWidget);
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
  });

  testWidgets('hidden and shown again: a focused button keeps its focus node', (
    tester,
  ) async {
    await show(tester, true);
    final button = find.byKey(const ValueKey('badge'));
    Focus.of(
      tester.element(find.descendant(of: button, matching: find.byType(Icon))),
    ).requestFocus();
    await tester.pump();
    final node = FocusManager.instance.primaryFocus!;
    await show(tester, false);
    await tester.pumpAndSettle();
    await show(tester, true);
    await tester.pumpAndSettle();
    // The same node, still attached: the shell can give the focus back.
    expect(node.context?.mounted, isTrue);
    node.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, node);
  });
}
