import 'package:maprisma/providers_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Model load sends its provider key and known model, not a command',
    (tester) async {
      String? operation;
      Map<String, dynamic>? params;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProvidersView(
              data: {
                'local': [
                  {
                    'key': 'fixture',
                    'name': 'Fixture provider',
                    'installed': true,
                    'running': true,
                    'server_off': false,
                    'address': '',
                    'models_dir': '',
                    'models': ['example-model'],
                    'can_control': false,
                    'can_load': true,
                    'download': '',
                    'can_import': false,
                  },
                ],
                'online': [],
              },
              busy: false,
              tr: (key) => key,
              onBack: () {},
              onOperation: (op, values, title) async {
                operation = op;
                params = values;
                return {'ok': true};
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Models (1)'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Load'));
      await tester.tap(find.byTooltip('Load'));
      expect(operation, 'model.load');
      expect(params, {'key': 'fixture', 'model': 'example-model'});
    },
  );

  testWidgets(
    'Model downloads preserve the selected file size for revalidation',
    (tester) async {
      Map<String, dynamic>? downloaded;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelBrowser(
              onClose: () {},
              runtime: {
                'key': 'fixture',
                'name': 'Fixture',
                'download': 'file',
              },
              tr: (key) => key,
              onOperation: (op, params, title) async {
                if (op == 'models.search') {
                  return {
                    'repos': [
                      {'id': 'owner/repo'},
                    ],
                  };
                }
                if (op == 'models.files') {
                  return {
                    'files': [
                      {'name': 'model.gguf', 'quant': 'Q4', 'size': 123},
                    ],
                  };
                }
                downloaded = params;
                return {};
              },
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'example');
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('owner/repo'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Download'));
      expect(downloaded, {
        'key': 'fixture',
        'repo': 'owner/repo',
        'file': 'model.gguf',
        'size': 123,
      });
    },
  );
}
