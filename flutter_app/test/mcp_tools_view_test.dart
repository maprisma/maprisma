import 'dart:async';
import 'package:asterism/mcp_tools_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('kept tools show first; Ask the server asks again', (
    tester,
  ) async {
    final calls = <(String, Map)>[];
    final asked = Completer<Map<String, dynamic>>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: McpServerTools(
              name: 'time',
              busy: false,
              tr: (key) => key,
              call: (method, params) async {
                calls.add((method, params));
                return {
                  'cached': {
                    'status': 'failed',
                    'checked': '2026-10-29T10:11:12',
                    'error': 'no answer',
                  },
                };
              },
              run: (method, params) {
                calls.add((method, params));
                return asked.future;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls.single.$1, 'mcp.tools_cached');
    expect(calls.single.$2, {'name': 'time'});
    expect(find.text('Asked on 2026-10-29 10:11: no answer'), findsOneWidget);
    await tester.tap(find.text('Ask again'));
    await tester.pump();
    expect(find.text('Asking the server…'), findsOneWidget);
    expect(calls.last.$1, 'mcp.tools');
    expect(calls.last.$2, {'name': 'time'});
    asked.complete({
      'status': 'ok',
      'checked': '2026-10-29T10:20:00',
      'server': 'time 1.0',
      'tools': [
        {'name': 'get_time', 'description': ''},
      ],
      'prompts': [
        {'name': 'when', 'description': 'Asks when'},
      ],
    });
    await tester.pumpAndSettle();
    expect(
      find.text('Asked on 2026-10-29 10:20: 1 Tools · time 1.0'),
      findsOneWidget,
    );
    expect(find.text('get_time'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(find.text('Prompts'), findsOneWidget);
  });

  testWidgets('never asked says what asking does', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: McpServerTools(
            name: 'new',
            busy: false,
            tr: (key) => key,
            call: (method, params) async => {'cached': null},
            run: (method, params) async => {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Not asked yet.'), findsOneWidget);
    expect(find.text('Ask the server'), findsOneWidget);
  });

  testWidgets('a test answer without a time says it does not answer', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: McpToolsResult(
            answer: {'status': 'failed', 'error': 'the server stopped'},
            tr: (key) => key,
          ),
        ),
      ),
    );
    expect(find.text('Does not answer: the server stopped'), findsOneWidget);
  });
}
