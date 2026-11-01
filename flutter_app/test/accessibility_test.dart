import 'package:maprisma/agent_map.dart';
import 'package:maprisma/map_smart_card.dart';
import 'package:maprisma/settings_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/a11y.dart';

/// Accessibility: every control a screen reader reaches has a label, tap
/// targets are large enough and text has enough contrast, in light and dark,
/// on the map, Settings and the smart cards.
void main() {
  final views = <String, Widget Function()>{
    'map': () => AgentMap(
      graph: const {
        'nodes': [
          {
            'id': 'agent:pi',
            'column': 1,
            'kind': 'agent',
            'label': 'Pi',
            'detail': 'gemma-4',
            'status': 'running',
          },
          {
            'id': 'runtime:llamacpp',
            'column': 2,
            'kind': 'runtime',
            'label': 'llama.cpp',
            'detail': '1 model',
            'status': 'running',
          },
        ],
        'edges': [
          {'source': 'agent:pi', 'target': 'runtime:llamacpp'},
        ],
      },
      onAgent: (_) {},
      onNodeMenu: (_, _) {},
      tr: (key) => key,
    ),
    'settings': () => SettingsView(
      settings: const {
        'language': 'auto',
        'look': 'adwaita',
        'map_layers': ['agents'],
      },
      busy: false,
      tr: (key) => key,
      checkers: const [
        {'command': 'claude', 'name': 'Claude Code'},
      ],
      mcpChecks: const {
        'servers': 3,
        'agent': 'Claude Code',
        'summary': 'nothing new',
        'updates': [],
      },
      onCheckMcp: () {},
      onBack: () {},
      onUpdate: (_) async {},
    ),
    'smart card status': () => Center(
      child: MapSmartCard(
        column: 'agents',
        title: 'AI Agents',
        open: true,
        statusTrigger: 1,
        onToggle: () {},
        tr: (key) => key,
        status: SmartStatusData(
          report: const {
            'warn': 1,
            'hint': 0,
            'open_text': '1 open problem',
            'areas': [
              {
                'key': 'agents',
                'title': 'Agents',
                'findings': [
                  {
                    'level': 'warn',
                    'column': 'agents',
                    'title': 'Pi: Not signed in',
                    'text': '',
                    'action': ['details', 'pi'],
                  },
                ],
              },
            ],
            'uses': [],
          },
          mcpUpdates: const [
            {
              'name': 'fetch',
              'column': 'mcp',
              'text': 'MCP server fetch 1.5.0 is available (you have 1.4.2)',
              'notes': 'Faster.',
              'on_pc': false,
            },
          ],
          mcpTaskAgent: 'Claude Code',
          onAction: (_) {},
          onMcpUpdate: (_, _) {},
          onCheckAgain: () {},
        ),
      ),
    ),
    'smart card collapsed': () => Center(
      child: MapSmartCard(
        column: 'models',
        title: 'Models',
        open: false,
        onToggle: () {},
        tr: (key) => key,
        helpers: const [
          {'command': 'local-helper', 'name': 'Local helper', 'local': true},
        ],
      ),
    ),
    'smart card open': () => Center(
      child: MapSmartCard(
        column: 'models',
        title: 'Models',
        open: true,
        onToggle: () {},
        tr: (key) => key,
        helpers: const [
          {'command': 'local-helper', 'name': 'Local helper', 'local': true},
          {'command': 'claude', 'name': 'Claude Code', 'local': false},
        ],
      ),
    ),
  };
  for (final MapEntry(key: name, value: view) in views.entries) {
    for (final brightness in Brightness.values) {
      testWidgets('$name (${brightness.name}) meets the guidelines', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(body: view()),
          ),
        );
        await tester.pumpAndSettle();
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        await expectLater(tester, meetsGuideline(desktopTapTargets));
        semantics.dispose();
        await tester.binding.setSurfaceSize(null);
      });
    }
  }
}
