// Task 073 (O2): in a short window the welcome text scrolls in a capped box, so the add-ons card
// below keeps room for its list (a fresh COSMIC placed the window at about 855×465).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/map_welcome.dart';

void main() {
  Future<double> introHeight(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MapWelcome(
                tr: (s) => s,
                busy: false,
                skipSearch: false,
                searched: false,
                onLook: () {},
                onSkip: () {},
                onAgents: () {},
              ),
              const Expanded(child: SizedBox(key: ValueKey('below'))),
            ],
          ),
        ),
      ),
    );
    return tester.getSize(find.byKey(const ValueKey('welcome-intro'))).height;
  }

  testWidgets(
    'a short window shows only the welcome line; the area below keeps its room',
    (tester) async {
      final h = await introHeight(tester, const Size(855, 465));
      expect(h, lessThan(30)); // one line
      // the whole text one click away
      await tester.tap(find.byKey(const ValueKey('welcome-details')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Only this PC is inspected'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('below'))).height,
        greaterThan(330),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a tall window keeps at most 110 px of welcome text', (
    tester,
  ) async {
    expect(
      await introHeight(tester, const Size(1600, 1200)),
      lessThanOrEqualTo(110),
    );
    // a medium window: at most a fifth of it
    expect(
      await introHeight(tester, const Size(800, 600)),
      lessThanOrEqualTo(120.5),
    );
    expect(tester.takeException(), isNull);
  });
}
