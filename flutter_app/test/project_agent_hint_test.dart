import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/project_agent_hint.dart';

String tr(String s) => s;

void main() {
  test('a read-only profile cannot edit, choose a provider or set up', () {
    final a = AgentAbilities.of(
      {
        'access_modes': ['read-only'],
        'model_option': '--model',
        'permissions': 'Reads only.',
      },
      access: 'read-only',
      tr: tr,
    );
    expect(a.can, ['Choose a model']);
    expect(a.cannot, [
      'Edit project files',
      'Use a local LLM from the map',
      'Use native subagents',
      'Propose a team',
    ]);
    expect(a.here, 'In this team: read-only');
    expect(a.text, contains('✗ Edit project files'));
    expect(a.text, endsWith('Reads only.'));
  });

  test('a full profile can do everything it declares', () {
    final a = AgentAbilities.of(
      {
        'model_option': '--model',
        'provider_option': '--provider',
        'native_subagents': true,
        'subagent_option': '--agents',
        'subagent_definitions': {
          'reviewer': {'description': 'Review'},
        },
        'setup_argv': ['x', '{prompt}'],
      },
      access: 'project-edit',
      tr: tr,
    );
    expect(a.cannot, isEmpty);
    expect(a.can, contains('Edit project files'));
    expect(a.here, 'In this team: edits project files');
  });

  test('a read-only member of an editing profile cannot edit here', () {
    final a = AgentAbilities.of(
      {'model_option': '--model'},
      access: 'read-only',
      tr: tr,
    );
    expect(a.can, isNot(contains('Edit project files')));
    expect(a.cannot, contains('Edit project files (read-only in this team)'));
    expect(a.here, 'In this team: read-only');
  });

  test('a read-only profile never says it edits, even with a stale access', () {
    final a = AgentAbilities.of(
      {
        'access_modes': ['read-only'],
      },
      access: 'project-edit',
      tr: tr,
    );
    expect(a.here, 'In this team: read-only');
    expect(a.cannot, contains('Edit project files'));
  });

  test('an unknown access value is not editing', () {
    final a = AgentAbilities.of({}, access: 'full-access', tr: tr);
    expect(a.here, 'In this team: read-only');
    expect(a.can, isNot(contains('Edit project files')));
  });

  test('claims follow what the core would start', () {
    final a = AgentAbilities.of(
      {
        'provider_option': '--provider',
        'native_subagents': true,
        'subagent_definitions': <String, dynamic>{},
        'setup_argv': <String>[],
        'model_option': '',
      },
      access: 'project-edit',
      tr: tr,
    );
    expect(
      a.cannot,
      containsAll([
        'Choose a model',
        'Use a local LLM from the map',
        'Use native subagents',
        'Propose a team',
      ]),
    );
  });

  test('the profile sentence is translated', () {
    final a = AgentAbilities.of(
      {'permissions': 'Reads.'},
      access: 'read-only',
      tr: (s) => s == 'Reads.' ? 'Liest.' : s,
    );
    expect(a.details, 'Liest.');
  });

  testWidgets('the keyboard opens the hint and screen readers name it', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: AgentAbilityHint(
              profile: {'permissions': 'Planning reads.'},
              access: 'read-only',
              tr: tr,
            ),
          ),
        ),
      ),
    );
    final node = tester.getSemantics(
      find.byKey(const ValueKey('agent-ability-hint')),
    );
    expect(node.label, contains('What this agent can and cannot do'));
    expect(node.hint, contains('Planning reads.'));
    expect(node.flagsCollection.isButton, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.textContaining('Planning reads.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 13));
    semantics.dispose();
  });

  testWidgets('the symbol shows the hint when tapped', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: AgentAbilityHint(
              profile: {'permissions': 'Planning reads.'},
              access: 'read-only',
              tr: tr,
            ),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.shield_outlined), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('agent-ability-hint')));
    await tester.pumpAndSettle();
    expect(find.textContaining('✗ Edit project files'), findsOneWidget);
    expect(find.textContaining('Planning reads.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 13));
  });

  testWidgets('without a chosen agent it says to choose one', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AgentAbilityHint(profile: null, access: 'read-only', tr: tr),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('agent-ability-hint')));
    await tester.pumpAndSettle();
    expect(find.text('Choose an agent to see what it can do.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 13));
  });
}
