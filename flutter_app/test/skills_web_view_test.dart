import 'package:maprisma/skills_web_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('search, fetch, choose the folder and agents, preview', (
    tester,
  ) async {
    final calls = <(String, Map)>[];
    final previews = <Map<String, dynamic>>[];
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SkillsWebView(
              busy: false,
              tr: (key) => key,
              run: (method, params) async {
                calls.add((method, params));
                if (method == 'skills.web_search') {
                  return {
                    'skills': [
                      {
                        'name': 'pdf',
                        'skill_id': 'pdf',
                        'repo': 'anthropics/skills',
                        'installs': 12,
                      },
                    ],
                  };
                }
                return {
                  'fetched': 'f1',
                  'name': 'pdf',
                  'repo': 'anthropics/skills',
                  'skill_id': 'pdf',
                  'description': 'Reads PDFs.',
                  'files': ['SKILL.md', 'scripts/run.py'],
                  'scripts': ['scripts/run.py'],
                  'targets': ['~/.agents/skills', '~/my-skills'],
                  'agents': [
                    {'command': 'claude', 'name': 'Claude Code'},
                    {'command': 'codex', 'name': 'Codex'},
                  ],
                };
              },
              onPreview: (params) async => previews.add(params),
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('skills-web-search')),
      'pdf',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(calls.single.$2, {'query': 'pdf'});
    await tester.tap(find.byKey(const ValueKey('skill-anthropics/skills/pdf')));
    await tester.pumpAndSettle();
    expect(calls.last.$1, 'skills.web_fetch');
    expect(calls.last.$2, {
      'repo': 'anthropics/skills',
      'skill_id': 'pdf',
      'name': 'pdf',
    });
    expect(find.text('Reads PDFs.'), findsOneWidget);
    expect(find.textContaining('scripts/run.py'), findsOneWidget);
    expect(find.text('Files: 2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('skills-web-into')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('~/my-skills').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Codex'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Preview'));
    await tester.pump();
    expect(previews.single, {
      'fetched': 'f1',
      'folder': '~/my-skills',
      'agents': ['codex'],
    });
  });

  testWidgets('nothing found says so', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SkillsWebView(
            busy: false,
            tr: (key) => key,
            run: (method, params) async => {'skills': []},
            onPreview: (params) async {},
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('skills-web-search')),
      'nothing',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('No skill found.'), findsOneWidget);
  });
}
