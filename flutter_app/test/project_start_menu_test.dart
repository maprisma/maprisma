import 'package:asterism/project_start_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final outside in [false, true]) {
    testWidgets('Start works without history or a pin (outside=$outside)', (
      tester,
    ) async {
      final controller = ProjectStartMenuController();
      addTearDown(controller.dispose);
      Map<String, dynamic>? started;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProjectStartMenu(
              command: 'test-agent',
              projects: {
                'default': '/home/example',
                'pinned': null,
                'history': [],
              },
              controller: controller,
              enabled: true,
              tr: (key) => key,
              onStart: (choice) async {
                started = choice;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(outside ? 'Start in terminal' : 'Start · Default folder'),
      );
      await tester.pumpAndSettle();
      expect(started, {
        'command': 'test-agent',
        'path': '/home/example',
        'outside': outside,
      });
    });
  }
}
