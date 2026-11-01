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

  Widget app({required bool covered}) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          TextButton(onPressed: () {}, child: const Text('behind')),
          MapSmartCard(
            column: 'agents',
            title: 'Agents',
            open: true,
            covered: covered,
            onToggle: () {},
            tr: (s) => s,
            helpers: helpers,
          ),
        ],
      ),
    ),
  );

  testWidgets('a covered window waits, comes back focused and blocks keys', (
    tester,
  ) async {
    await tester.pumpWidget(app(covered: true));
    await tester.pump();
    expect(find.byType(OverlayWindow), findsNothing);
    expect(smartWindowsShown.value, 0);
    await tester.pumpWidget(app(covered: false));
    await tester.pumpAndSettle();
    expect(find.byType(OverlayWindow), findsOneWidget);
    expect(smartWindowsShown.value, 1);
    expect(
      tester.binding.focusManager.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<OverlayWindow>(),
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(smartWindowsShown.value, 0);
  });

  testWidgets('Tab stays in the window', (tester) async {
    await tester.pumpWidget(app(covered: false));
    await tester.pumpAndSettle();
    for (var i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        tester.binding.focusManager.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<OverlayWindow>(),
        isNotNull,
      );
    }
  });
}
