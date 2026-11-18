import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/agent_activity_dialog.dart';

void main() {
  testWidgets('refreshes the chosen report and stops on Esc', (tester) async {
    final fetched = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AgentActivityDialog(
                  tr: (text) => text,
                  fetch: (instance) async {
                    fetched.add(instance);
                    return {
                      'report': {
                        'instance': {'id': '7:42', 'label': 'Fixture'},
                        'details': {
                          'request': {'text': 'Refresh ${fetched.length}'},
                          'answers': [],
                          'tool_calls': [],
                          'edited_files': [],
                        },
                        'origin': {'ancestors': []},
                        'timeline': [],
                        'helpers': [],
                      },
                    };
                  },
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Refresh 1'), findsOneWidget);
    expect(fetched, [null]);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.textContaining('Refresh 2'), findsOneWidget);
    expect(fetched, [null, '7:42']);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AgentActivityDialog), findsNothing);
    await tester.pump(const Duration(seconds: 6));
    expect(fetched, [null, '7:42']);
  });
}
