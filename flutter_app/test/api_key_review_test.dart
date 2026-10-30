import 'package:maprisma/api_key_review.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the key is hidden, says where it goes and saves only a key', (
    tester,
  ) async {
    final field = TextEditingController();
    var saved = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ApiKeyReview(
            preview: {
              'name': 'Codex',
              'variable': 'OPENAI_API_KEY',
              'url': 'https://platform.openai.com/api-keys',
              'stores': 'itself',
              'command': 'codex login --with-api-key',
              'file': '',
            },
            controller: field,
            tr: (key) => key,
            onConfirm: () => saved = true,
            onCancel: () {},
          ),
        ),
      ),
    );
    expect(
      find.text(
        'Codex stores it itself (codex login --with-api-key). The app does not keep it.',
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isTrue,
    );
    final save = find.widgetWithText(FilledButton, 'Save');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'not a key');
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'sk-proj_0123456789');
    await tester.pump();
    await tester.tap(save);
    expect(saved, isTrue);
    field.dispose();
  });
}
