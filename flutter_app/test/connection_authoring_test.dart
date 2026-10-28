import 'package:asterism/connection_authoring.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const agent = {
  'command': 'fixture',
  'name': 'Fixture agent',
  'mcp': true,
  'skills': true,
};
void main() {
  Future<void> mount(
    WidgetTester tester,
    String kind,
    Future<void> Function(Map<String, dynamic>) preview, {
    Future<String?> Function()? choose,
  }) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ConnectionAuthoring(
              kind: kind,
              agents: const [agent],
              busy: false,
              tr: (s) => s,
              onPreview: preview,
              onClose: () {},
              chooseFolder: choose,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'stdio form keeps arguments separate and requires explicit recipients',
    (tester) async {
      Map<String, dynamic>? request;
      await mount(tester, 'mcp', (params) async => request = params);
      await tester.enterText(
        find.byKey(const ValueKey('mcp-name')),
        'my-server',
      );
      await tester.enterText(
        find.byKey(const ValueKey('mcp-command')),
        '/selected/program',
      );
      await tester.enterText(
        find.byKey(const ValueKey('mcp-args')),
        '--flag\nvalue with spaces',
      );
      await tester.tap(find.text('Preview'));
      await tester.pump();
      expect(request, isNull);
      expect(find.text('Choose at least one agent.'), findsOneWidget);
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Fixture agent'));
      await tester.tap(find.text('Preview'));
      await tester.pump();
      expect(request!['agents'], ['fixture']);
      expect(request!['entry'], {
        'transport': 'stdio',
        'command': '/selected/program',
        'args': ['--flag', 'value with spaces'],
        'url': '',
        'env': {},
        'headers': {},
      });
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('HTTP secrets are obscured and sent only as entered headers', (
    tester,
  ) async {
    Map<String, dynamic>? request;
    await mount(tester, 'mcp', (params) async => request = params);
    await tester.enterText(find.byKey(const ValueKey('mcp-name')), 'remote');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('http').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('mcp-url')),
      'https://example.invalid/mcp',
    );
    await tester.tap(find.text('Add'));
    await tester.pump();
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    final secret = fields.singleWhere((w) => w.obscureText);
    expect(secret.decoration!.labelText, 'Value');
    final names = find.widgetWithText(TextField, 'Name');
    await tester.enterText(names.last, 'Authorization');
    await tester.enterText(find.byWidget(secret), 'private-test-value');
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Fixture agent'));
    await tester.tap(find.text('Preview'));
    await tester.pump();
    expect(request!['entry']['headers'], {
      'Authorization': 'private-test-value',
    });
    expect(request!['entry']['command'], '');
    expect(request!['entry']['args'], isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'folder selection is explicit and forwards only a path and chosen agents',
    (tester) async {
      Map<String, dynamic>? request;
      var picks = 0;
      await mount(
        tester,
        'skills',
        (params) async => request = params,
        choose: () async {
          picks++;
          return '/chosen/skills';
        },
      );
      expect(picks, 0);
      await tester.tap(find.text('Choose folder…'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Fixture agent'));
      await tester.tap(find.text('Preview'));
      await tester.pump();
      expect(request, {
        'kind': 'skills',
        'agents': ['fixture'],
        'folder': '/chosen/skills',
      });
      expect(picks, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
