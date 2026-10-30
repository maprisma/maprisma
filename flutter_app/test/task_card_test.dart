import 'package:maprisma/agent_map.dart';
import 'package:maprisma/task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final graph = <String, dynamic>{
  'nodes': [
    {
      'id': 'agent:test',
      'column': 1,
      'kind': 'agent',
      'label': 'Test',
      'detail': '',
    },
  ],
  'edges': [],
};

void main() {
  Future<void> mount(
    WidgetTester tester, {
    double width = 1200,
    bool closable = true,
    TaskCardWidth mode = TaskCardWidth.half,
    Set<String> focus = const {'agent:test'},
    VoidCallback? close,
    Widget child = const Text('Review contents'),
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
              focus: focus,
              width: mode,
              closable: closable,
            ),
            graph: graph,
            tr: (s) => s,
            onClose: close ?? () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('wide half card includes a read-only focused map', (
    tester,
  ) async {
    await mount(tester);
    expect(find.byKey(const ValueKey('half-task')), findsOneWidget);
    expect(tester.widget<AgentMap>(find.byType(AgentMap)).readOnly, isTrue);
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(find.text('Review contents'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('narrow, full and unknown focus omit the map', (tester) async {
    await mount(tester, width: 899);
    expect(find.byType(AgentMap), findsNothing);
    await mount(tester, mode: TaskCardWidth.full);
    expect(find.byType(AgentMap), findsNothing);
    await mount(tester, focus: const {'missing'});
    expect(find.byKey(const ValueKey('full-task')), findsOneWidget);
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
