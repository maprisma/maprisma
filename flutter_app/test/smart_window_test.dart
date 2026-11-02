import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/map_smart_card.dart';
import 'package:maprisma/overlay_window.dart';

void main() {
  const helpers = [
    {'command': 'a', 'name': 'Agent A', 'local': true},
    {'command': 'b', 'name': 'Agent B', 'local': false},
  ];

  var toggled = 0;
  Widget app({bool visible = true, bool takesRequests = true}) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          TextButton(onPressed: () {}, child: const Text('behind')),
          Visibility(
            visible: visible,
            maintainState: true,
            child: MapSmartCard(
              column: 'agents',
              title: 'Agents',
              open: true,
              onToggle: () => toggled++,
              tr: (s) => s,
              helpers: helpers,
              takesRequests: takesRequests,
            ),
          ),
        ],
      ),
    ),
  );

  bool focusInWindow(WidgetTester tester) =>
      tester.binding.focusManager.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<OverlayWindow>() !=
      null;

  testWidgets('a hidden column hides the window, it returns with focus', (
    tester,
  ) async {
    await tester.pumpWidget(app(visible: false));
    await tester.pump();
    expect(find.byType(OverlayWindow), findsNothing);
    expect(smartWindowsShown.value, 0);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byType(OverlayWindow), findsOneWidget);
    expect(smartWindowsShown.value, 1);
    expect(focusInWindow(tester), isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(smartWindowsShown.value, 0);
  });

  testWidgets('Tab stays in the window', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    for (var i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focusInWindow(tester), isTrue);
    }
  });

  testWidgets('Esc still leaves when the focused button goes away', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final ask = find.widgetWithText(FilledButton, 'Ask');
    Focus.of(
      tester.element(find.descendant(of: ask, matching: find.text('Ask'))),
    ).requestFocus();
    await tester.pump();
    // The footer's Ask goes away with the step; the keyboard had it.
    await tester.pumpWidget(app(takesRequests: false));
    await tester.pumpAndSettle();
    expect(ask, findsNothing);
    toggled = 0;
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(toggled, 1);
  });
}
