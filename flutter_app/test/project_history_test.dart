import 'package:maprisma/agent_details_view.dart';
import 'package:maprisma/project_start_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'History opens Start with this agent and folder; trash only requests history removal',
    (tester) async {
      String? startedCommand;
      String? startedPath;
      List<Object?>? action;
      final menu = ProjectStartMenuController();
      addTearDown(menu.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentDetailsView(
              catalog: [
                {
                  'command': 'first-agent',
                  'name': 'First agent',
                  'version': '1',
                  'installed': true,
                },
              ],
              selected: 'first-agent',
              projectsByAgent: {
                'first-agent': {
                  'default': '/home/example',
                  'pinned': null,
                  'history': [
                    {'path': '/project with spaces', 'available': true},
                  ],
                },
              },
              busy: false,
              info: null,
              tr: (key) => key,
              onBack: () {},
              startMenu: menu,
              onStart: (choice) async {
                startedCommand = choice['command'] as String;
                startedPath = choice['path'] as String;
              },
              onProjectAction: (method, command, path) async {
                action = [method, command, path];
              },
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text('/project with spaces'));
      await tester.tap(find.text('/project with spaces'));
      await tester.pumpAndSettle();
      expect(startedCommand, isNull);
      await tester.tap(find.text('Start · Selected project'));
      await tester.pumpAndSettle();
      expect(startedCommand, 'first-agent');
      expect(startedPath, '/project with spaces');
      await tester.tap(find.byTooltip('Pin as default folder'));
      expect(action, ['projects.pin', 'first-agent', '/project with spaces']);
      await tester.tap(
        find.byTooltip('Remove from history (keeps the folder)'),
      );
      expect(action, [
        'projects.forget',
        'first-agent',
        '/project with spaces',
      ]);
    },
  );

  testWidgets(
    'Missing pinned folders can be unpinned without starting a session',
    (tester) async {
      String? unpinned;
      final menu = ProjectStartMenuController();
      addTearDown(menu.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentDetailsView(
              catalog: [
                {
                  'command': 'first-agent',
                  'name': 'First agent',
                  'version': '1',
                  'installed': true,
                },
              ],
              selected: 'first-agent',
              projectsByAgent: {
                'first-agent': {
                  'default': '/home/example',
                  'pinned': '/missing/project',
                  'history': [
                    {'path': '/missing/project', 'available': false},
                  ],
                },
              },
              busy: false,
              info: null,
              tr: (key) => key,
              onBack: () {},
              startMenu: menu,
              onStart: (_) async {
                fail('An unavailable folder must not start');
              },
              onProjectAction: (method, command, path) async {
                expect(method, 'projects.pin');
                expect(path, isNull);
                unpinned = command;
              },
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.byTooltip('Unpin default folder'));
      await tester.tap(find.byTooltip('Unpin default folder'));
      expect(unpinned, 'first-agent');
    },
  );
}
