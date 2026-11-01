import 'package:maprisma/task_card.dart';
import 'package:flutter/material.dart';
import 'package:maprisma/overlay_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    double width = 1200,
    bool closable = true,
    VoidCallback? close,
    Widget child = const Text('Review contents'),
    bool overlay = false,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskHost(
            spec: TaskCardSpec(
              title: 'Task',
              child: child,
              closable: closable,
            ),
            tr: (s) => s,
            onClose: close ?? () {},
            overlay: overlay,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an action is the centred window, a page fills the area', (
    tester,
  ) async {
    await mount(tester, overlay: true);
    expect(find.byKey(const ValueKey('overlay-task')), findsOneWidget);
    expect(find.byType(OverlayWindow), findsOneWidget);
    expect(find.text('Review contents'), findsOneWidget);
    await mount(tester);
    expect(find.byKey(const ValueKey('full-task')), findsOneWidget);
    expect(find.byType(OverlayWindow), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the window drags its size; a double click restores it', (
    tester,
  ) async {
    await mount(tester, overlay: true);
    final card = find.byKey(const ValueKey('task-card'));
    final start = tester.getSize(card);
    Future<void> drag(String edge, Offset by) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey(edge))),
      );
      await gesture.moveBy(by.scale(.5, .5));
      await tester.pump();
      await gesture.moveBy(by.scale(.5, .5));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    await drag('overlay-edge-1-0', const Offset(100, 0));
    expect(tester.getSize(card).width, greaterThan(start.width + 60));
    expect(tester.getSize(card).height, start.height);
    await drag('overlay-edge-1-1', const Offset(-5000, -5000));
    expect(tester.getSize(card).width, lessThan(430));
    expect(tester.getSize(card).height, lessThan(310));
    // A smaller app than the smallest window: no error, nothing stuck.
    tester.view.physicalSize = const Size(300, 200);
    await tester.pumpAndSettle();
    await drag('overlay-edge-1-0', const Offset(30, 0));
    await drag('overlay-edge-0-1', const Offset(0, 30));
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();
    final edge = find.byKey(const ValueKey('overlay-edge-1-0'));
    await tester.tap(edge);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(edge);
    await tester.pumpAndSettle();
    expect(tester.getSize(card), start);

    // One edge sizes one way: the other still follows the app's window.
    await drag('overlay-edge-0-1', const Offset(0, 40));
    tester.view.physicalSize = const Size(1000, 800);
    await tester.pumpAndSettle();
    expect(tester.getSize(card).width, 1000 * .8 - 16);
    final corner = find.byKey(const ValueKey('overlay-edge-1-0'));
    await tester.tap(corner);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(corner);
    await tester.pumpAndSettle();
  });

  testWidgets('running card cannot close via Back or Esc; result can', (
    tester,
  ) async {
    var closes = 0;
    await mount(tester, closable: false, close: () => closes++);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Back'))
          .onPressed,
      isNull,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(closes, 0);
    await mount(tester, close: () => closes++, child: const Text('Succeeded'));
    expect(find.text('Succeeded'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(closes, 1);
  });
}
