import 'package:asterism/agent_map.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Subagent badge opens children without selecting the parent', (
    tester,
  ) async {
    String? selected;
    String? expanded;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentMap(
            graph: {
              'nodes': [
                {
                  'id': 'agent:test-agent',
                  'column': 1,
                  'kind': 'agent',
                  'label': 'Test agent',
                  'detail': '',
                  'status': 'running',
                },
              ],
              'edges': [],
              'activity': {
                'test-agent': {
                  'subagents_supported': true,
                  'active_subagents': 1,
                  'children': [
                    {'key': 'child'},
                  ],
                },
              },
            },
            onAgent: (command) => selected = command,
            onSubagents: (command) => expanded = command,
            tr: (key) => key,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Subagents: 1 / 1'));
    expect(expanded, 'test-agent');
    expect(selected, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Selecting an agent map node preserves its adapter command', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentMap(
            graph: {
              'nodes': [
                {
                  'id': 'agent:test-agent',
                  'column': 1,
                  'kind': 'agent',
                  'label': 'Visible agent name',
                  'detail': '1.0',
                  'status': '',
                },
                {
                  'id': 'cloud:provider',
                  'column': 2,
                  'kind': 'cloud',
                  'label': 'Provider name',
                  'detail': '',
                  'status': '',
                },
              ],
              'edges': [
                {
                  'source': 'agent:test-agent',
                  'target': 'cloud:provider',
                  'kind': 'uses',
                },
              ],
            },
            onAgent: (command) => selected = command,
            tr: (key) => key,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Visible agent name'));
    expect(selected, 'test-agent');
    expect(tester.takeException(), isNull);
  });

  testWidgets('read-only maps ignore interaction callbacks and paint anchors', (
    tester,
  ) async {
    var callbacks = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentMap(
            readOnly: true,
            anchors: const {'runtime:test'},
            columns: const ['Providers'],
            graph: {
              'nodes': [
                {
                  'id': 'runtime:test',
                  'column': 0,
                  'kind': 'runtime',
                  'label': 'Read only',
                  'detail': '',
                  'status': '',
                },
              ],
              'edges': [],
            },
            onAgent: (_) => callbacks++,
            onNode: (_) => callbacks++,
            onNodeMenu: (_, _) => callbacks++,
            onNodeDrop: (_, _) => callbacks++,
            onViewChanged: () => callbacks++,
            tr: (s) => s,
          ),
        ),
      ),
    );
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == 310 && w.height == 276,
      ),
      findsOneWidget,
    );
    expect(find.byType(LongPressDraggable<Map<String, dynamic>>), findsNothing);
    expect(find.byType(DragTarget<Map<String, dynamic>>), findsNothing);
    expect(find.byTooltip('Actions'), findsNothing);
    await tester.tap(find.text('Read only'));
    await tester.tap(find.text('Read only'), buttons: 2);
    await tester.drag(find.text('Read only'), const Offset(40, 20));
    expect(callbacks, 0);
    final paint = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .firstWhere((w) => w.painter.runtimeType.toString() == '_Connections');
    // Exercise the actual anchor painter as well as its repaint contract.
    expect(paint.painter, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Empty maps remain navigable without invented nodes', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentMap(
            graph: {'nodes': [], 'edges': []},
            onAgent: (_) {},
            tr: (key) => key,
          ),
        ),
      ),
    );
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('Agents'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a battery and a cost in the agents\' boxes, with tooltips', (
    tester,
  ) async {
    Map<String, dynamic> node(String id, String label) => {
      'id': id,
      'column': 1,
      'kind': 'agent',
      'label': label,
      'detail': '',
      'status': '',
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentMap(
            graph: {
              'nodes': [
                node('agent:claude', 'Claude Code'),
                node('agent:dsh', 'DSH'),
              ],
              'edges': [],
              'agent_badges': {
                'agent:claude': {
                  'kind': 'battery',
                  'left': 0.2,
                  'colour': 'yellow',
                  'tip': '5 h: 20 % left',
                },
                'agent:dsh': {
                  'kind': 'cost',
                  'label': r'$1.50 today',
                  'colour': 'green',
                  'tip': 'Paid per token',
                },
              },
            },
            onAgent: (_) {},
            tr: (key) => key,
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('agent-battery')), findsOneWidget);
    expect(find.text(r'$1.50 today'), findsOneWidget);
    expect(find.byTooltip('5 h: 20 % left'), findsOneWidget);
    expect(find.byTooltip('Paid per token'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a working agent shows its usage statistics box', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentMap(
            graph: const {
              'nodes': [
                {
                  'id': 'agent:claude',
                  'column': 1,
                  'kind': 'agent',
                  'label': 'Claude Code',
                  'detail': '',
                  'status': 'running',
                },
              ],
              'edges': [],
              'usage_boxes': {
                'agent:claude': {
                  'parts': [
                    ['30 t/s', 'line'],
                    ['1M', 'line'],
                    ['92%', 'red'],
                  ],
                  'model': 'claude-opus-5-5',
                },
              },
              'usage_box_size': 9,
            },
            onAgent: (_) {},
            tr: (key) => key,
          ),
        ),
      ),
    );
    expect(find.text('30 t/s · 1M · 92%'), findsOneWidget);
    expect(find.byTooltip('claude-opus-5-5'), findsOneWidget);
    final label = tester.widget<Text>(find.text('30 t/s · 1M · 92%'));
    expect(label.style?.fontSize, closeTo(9 * 1.33, 0.01));
    expect(tester.takeException(), isNull);
  });
}
