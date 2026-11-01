import 'package:maprisma/item_details_view.dart';
import 'package:maprisma/projects_card.dart';
import 'package:maprisma/runtime_details_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('projects of the last 30 days', (tester) async {
    await tester.pumpWidget(
      _app(
        ProjectsCard(
          command: 'claude',
          call: (method, params) async => {
            'card': {
              'title': 'Projects, last 30 days',
              'summary': '2 projects · 1.2M tokens · 3 h 1 min working',
              'projects': [
                {'folder': '~/work/a', 'text': '2 h working · 3 sessions'},
              ],
              'subagents_title': 'Subagents, last 30 days',
              'subagents': [
                {
                  'kind': 'Explore',
                  'text': '2 runs · 4k tokens · 5 min working',
                },
              ],
              'notes': ['Most active: Wednesday, around 13:00'],
            },
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Projects, last 30 days'));
    await tester.pumpAndSettle();
    expect(find.text('~/work/a'), findsOneWidget);
    expect(find.text('Explore'), findsOneWidget);
    expect(find.text('Most active: Wednesday, around 13:00'), findsOneWidget);
  });

  testWidgets('a local LLM\'s details', (tester) async {
    await tester.pumpWidget(
      _app(
        RuntimeDetailsCard(
          runtime: 'ollama',
          tr: (t) => t,
          call: (method, params) async => {
            'now': 'Running · 13.0 GB of GPU memory · loaded: gemma3',
            'tiles': [
              ['Models', '5', '~/models'],
              ['Agents', '2', 'Hermes, OpenCode'],
            ],
            'usage': {
              'title': 'Usage and tokens',
              'summary': 'through Ollama · 1k tokens in 7 days · 2 sessions',
              'tiles': [
                ['Today', '10 tokens', '1 session'],
              ],
              'models_title': 'Tokens by agent and model',
              'models': [
                ['Hermes · gemma3', '1k in · 2 out · 0 cache'],
              ],
              'note': 'What your agents sent through it',
            },
            'risks': [
              {
                'level': 'high',
                'title': 'Reachable from your network',
                'text': 'It listens on 0.0.0.0:11434',
                'step': 'Let it listen on 127.0.0.1 only',
              },
            ],
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Running · 13.0 GB of GPU memory · loaded: gemma3'),
      findsOneWidget,
    );
    await tester.tap(find.text('Usage and tokens'));
    await tester.pumpAndSettle();
    expect(find.text('Hermes · gemma3'), findsOneWidget);
    await tester.tap(find.text('Risk management'));
    await tester.pumpAndSettle();
    expect(find.text('Reachable from your network'), findsOneWidget);
  });

  testWidgets('an MCP server\'s details', (tester) async {
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ItemDetailsView(
            tr: (t) => t,
            details: const {
              'title': 'MCP server notes',
              'intro': 'An MCP server gives agents tools.',
              'text': 'The agents below have this server.',
              'sections': [
                {
                  'heading': 'Claude Code',
                  'rows': [
                    [
                      'Environment',
                      'NOTES_TOKEN = •••',
                      'Values are not shown',
                    ],
                  ],
                },
              ],
              'missing': 'Codex · draw a line',
              'missing_title': 'Not set up',
              'tools': [
                ['lookup', 'Looks up'],
              ],
            },
            onClose: () => closed = true,
          ),
        ),
      ),
    );
    expect(find.text('NOTES_TOKEN = •••'), findsOneWidget);
    expect(find.text('lookup'), findsOneWidget);
    expect(find.text('Codex · draw a line'), findsOneWidget);
    await tester.tap(find.text('Close'));
    expect(closed, isTrue);
  });
}
