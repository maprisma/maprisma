import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/ai_project_center.dart';

void main() {
  testWidgets('system events translate while agent output and names stay original', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final saved = <String, dynamic>{
      'id': 'fixture',
      'title': 'User project',
      'brief': 'User goal',
      'path': '/tmp/project',
      'team': <Object>[],
      'plan': '',
      'status': 'draft',
      'revision': 1,
      'output': 'Original agent output',
      'handoff': 'Original saved handoff',
      'events': [
        {'type': 'saved', 'text': 'Project saved.'},
        {'type': 'assignment', 'text': 'Agent name: lead'},
        {'type': 'assignment_done', 'text': 'lead ended successfully.'},
        {
          'type': 'failed',
          'text':
              'The agent ended with exit code -15. Review partial work before continuing.',
        },
        {'type': 'failed', 'text': 'project_agent_unavailable'},
        // Send now's new session failed before its agent started (096).
        {'type': 'continue_failed', 'text': 'project_prompt_too_large'},
        // A timer that could not be kept (103): systemd's reason stays.
        {
          'type': 'schedule_timer_failed',
          'text':
              'The timer of its schedule could not be removed (systemctl disable --now failed: Access denied). Maprisma tries again at its next start.',
        },
      ],
    };
    const translations = {
      'Activity': 'Aktivität',
      'Lead agent': 'Leitung',
      'Project saved.': 'Projekt gespeichert.',
      '{0}: {1}': '{0} · {1}',
      '{0} ended successfully.': '{0} erfolgreich beendet.',
      'The agent ended with exit code {0}. Review partial work before continuing.':
          'Agent mit Code {0} beendet.',
      'A selected agent is unavailable.': 'Agent nicht verfügbar.',
      'The new session did not start: {0} The project is paused; check the changes, then continue.':
          'Nicht gestartet: {0}',
      'The prompt for the next agent would be too large. Shorten the goal, the plan or the waiting messages.':
          'Prompt zu groß.',
      'The timer of its schedule could not be removed. Maprisma tries again at its next start.':
          'Timer nicht entfernt.',
      'Original agent output': 'Must not replace output',
      'Original saved handoff': 'Must not replace handoff',
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiProjectCenterPage(
            tr: (key) => translations[key] ?? key,
            onBack: () {},
            onCall: (operation, params) async => switch (operation) {
              'list' => {
                'projects': [saved],
              },
              'profiles' => {'profiles': <Object>[]},
              _ => {'project': saved},
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('User project'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aktivität'));
    await tester.pumpAndSettle();
    expect(find.text('Projekt gespeichert.'), findsOneWidget);
    expect(find.text('Agent name · Leitung'), findsOneWidget);
    expect(find.text('Leitung erfolgreich beendet.'), findsOneWidget);
    expect(find.text('Agent mit Code -15 beendet.'), findsOneWidget);
    expect(find.text('Agent nicht verfügbar.'), findsOneWidget);
    expect(find.text('Nicht gestartet: Prompt zu groß.'), findsOneWidget);
    expect(
      find.text(
        'Timer nicht entfernt. (systemctl disable --now failed: Access denied)',
      ),
      findsOneWidget,
    );
    expect(find.text('Original agent output'), findsOneWidget);
    expect(find.text('Original saved handoff'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
