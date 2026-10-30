import 'review_test_host.dart';
import 'package:maprisma/provider_connections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('An existing connection can switch to the selected model', (
    tester,
  ) async {
    Map<String, dynamic>? requested;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProviderConnections(
            provider: {
              'id': 'fixture',
              'name': 'Fixture',
              'address': 'localhost',
              'models': ['first', 'second'],
              'agents': ['test-agent'],
            },
            agents: [
              {'command': 'test-agent', 'name': 'Test agent', 'provider': true},
            ],
            busy: false,
            tr: (key) => key,
            onPreview: (params) async {
              requested = params;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Fixture'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('second').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Use now'));
    expect(requested, {
      'kind': 'provider',
      'command': 'test-agent',
      'item': 'fixture',
      'remove': false,
      'model': 'second',
      'use_now': true,
    });
  });

  for (final mode in ['file', 'api']) {
    testWidgets(
      'Removal confirmation clearly describes $mode and Cancel keeps it',
      (tester) async {
        bool? accepted;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    accepted = await confirmModelRemoval(context, {
                      'model': 'example',
                      'mode': mode,
                      'size': 123,
                      'files': ['~/models/example.gguf'],
                      'shared': ['Another provider'],
                      'links_only': false,
                    }, (key) => key);
                  },
                  child: const Text('Review removal'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Review removal'));
        await tester.pumpAndSettle();
        expect(accepted, isNull);
        expect(
          find.text(mode == 'file' ? 'Move to Trash' : 'Remove permanently'),
          findsOneWidget,
        );
        expect(find.text('Also used by: Another provider'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(accepted, isFalse);
      },
    );
  }
}
