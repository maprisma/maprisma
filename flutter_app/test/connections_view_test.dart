import 'review_test_host.dart';
import 'package:asterism/connections_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Connecting requests a preview for the discovered item and agent',
    (tester) async {
      Map<String, dynamic>? requested;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConnectionsView(
              data: {
                'agents': [
                  {
                    'command': 'test-agent',
                    'name': 'Test agent',
                    'mcp': true,
                    'skills': true,
                  },
                ],
                'mcp': [
                  {
                    'id': 'known-server',
                    'name': 'Known server',
                    'target': 'example.test',
                    'agents': [],
                  },
                ],
                'skills': [],
              },
              busy: false,
              tr: (key) => key,
              onBack: () {},
              onPreview: (params) async {
                requested = params;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Known server'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test agent'));
      expect(requested, {
        'kind': 'mcp',
        'command': 'test-agent',
        'item': 'known-server',
        'remove': false,
      });
    },
  );

  testWidgets('The preview requires Apply; Cancel does not accept the plan', (
    tester,
  ) async {
    bool? accepted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                accepted = await confirmConnection(context, {
                  'plan': 'opaque',
                  'empty': false,
                  'files': [
                    {'path': '~/settings.json', 'added': 1, 'removed': 0},
                  ],
                  'links_add': [],
                  'links_remove': [],
                }, (key) => key);
              },
              child: const Text('Open preview'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open preview'));
    await tester.pumpAndSettle();
    expect(accepted, isNull);
    expect(find.text('~/settings.json'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(accepted, isFalse);
  });
}
