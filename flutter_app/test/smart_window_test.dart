import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/backend.dart';
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

  group('the central Ask AI window (no bar)', () {
    Widget central(CoreClient? client, List<String> changes) => MaterialApp(
      home: Scaffold(
        body: MapSmartCard(
          showBar: false,
          column: 'agents',
          title: 'Agents',
          open: true,
          onToggle: () {},
          onColumnChanged: changes.add,
          tr: (s) => s,
          helpers: helpers,
          client: client,
        ),
      ),
    );

    testWidgets('a category chip keeps the same window and is in Tab order', (
      tester,
    ) async {
      final changes = <String>[];
      await tester.pumpWidget(central(null, changes));
      await tester.pumpAndSettle();
      final window = tester.state(find.byType(OverlayWindow));
      await tester.tap(find.byKey(const ValueKey('smart-category-models')));
      await tester.pumpAndSettle();
      expect(find.text('Ask AI · Models'), findsOneWidget);
      expect(tester.state(find.byType(OverlayWindow)), same(window));
      expect(find.byKey(const ValueKey('smart-card')), findsOneWidget);
      expect(changes, ['models']);

      var reached = false;
      for (var i = 0; i < 20 && !reached; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        reached =
            tester.binding.focusManager.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<ChoiceChip>() !=
            null;
      }
      expect(reached, isTrue);
    });

    testWidgets(
      'Move to switches the category in place and keeps the question',
      (tester) async {
        final calls = <String>[];
        final client = CoreClient(
          _FakeTransport((method, params) async {
            calls.add(method);
            if (method == 'map.smart_ask') return {'task': 'ask'};
            return {
              'state': 'done',
              'result': {
                'helper': 'Agent B',
                'local': false,
                'status': 'redirect',
                'instead': {
                  'hint': 'Models are managed in the Models column.',
                  'column': 'models',
                  'request': '',
                },
              },
            };
          }),
        );
        final changes = <String>[];
        await tester.pumpWidget(central(client, changes));
        await tester.pumpAndSettle();
        final window = tester.state(find.byType(OverlayWindow));
        await tester.enterText(find.byType(TextField), 'install qwencoder');
        await tester.tap(find.widgetWithText(FilledButton, 'Ask'));
        await tester.pumpAndSettle();
        expect(find.text('Move to Models'), findsOneWidget);
        calls.clear();
        await tester.tap(find.text('Move to Models'));
        await tester.pumpAndSettle();
        expect(find.text('Ask AI · Models'), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller?.text,
          'install qwencoder',
        );
        expect(changes.last, 'models');
        expect(calls, isEmpty); // nothing is asked again by itself
        expect(tester.state(find.byType(OverlayWindow)), same(window));
      },
    );
  });
}

class _FakeTransport implements ServiceTransport {
  _FakeTransport(this.onCall);
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
