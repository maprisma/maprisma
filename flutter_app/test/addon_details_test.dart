import 'review_test_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> entry({
  String kind = 'agent',
  String action = 'install',
}) => {
  'id': 'test-adapter',
  'name': 'Test adapter',
  'version': '2.0.0',
  'summary': 'Summary',
  'description': 'Description',
  'kind': kind,
  'reads': ['local metadata'],
  'sends': ['nothing'],
  'capabilities': ['agent'],
  'privacy': 1,
  'action': action,
  'supported': kind == 'agent',
  'preview': kind == 'agent' ? 'owned-preview' : null,
};

void main() {
  testWidgets(
    'install review exposes disclosures and cancel performs no action',
    (tester) async {
      bool? confirmed;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('review'),
                onPressed: () async {
                  confirmed = await confirmAddonInstall(
                    context,
                    entry(),
                    (key) => key,
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('review'));
      await tester.pumpAndSettle();
      expect(find.text('Reads: local metadata'), findsOneWidget);
      expect(find.text('Privacy level: Numbers only'), findsOneWidget);
      expect(
        find.text('Adds an agent to the map and the cards'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(confirmed, isFalse);
    },
  );

  testWidgets('update review shows the reviewed version before consent', (
    tester,
  ) async {
    bool? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('review'),
              onPressed: () async {
                confirmed = await confirmAddonInstall(
                  context,
                  entry(action: 'update'),
                  (key) => key,
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('review'));
    await tester.pumpAndSettle();
    expect(find.text('Update Test adapter · 2.0.0?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });
  testWidgets(
    'shared-folder removal and retention are disclosed before confirmation',
    (tester) async {
      bool? confirmed;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  confirmed = await confirmAddonRemoval(context, {
                    'name': 'Fixture',
                    'notes': [
                      'After a removal, backups older than 30 days may be deleted. Active Undo backups are kept.',
                    ],
                  }, (k) => k);
                },
                child: const Text('review removal'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('review removal'));
      await tester.pumpAndSettle();
      expect(confirmed, isNull);
      expect(find.textContaining('30 days'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(confirmed, isFalse);
    },
  );
}
