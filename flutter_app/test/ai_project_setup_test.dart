import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ai_project_center_test.dart' show mount, project;

const profiles = [
  {
    'id': 'test-agent',
    'name': 'Test agent',
    'model_option': '--model',
    'setup_argv': ['test', '{prompt}'],
    'plan_argv': ['test', '--read-only'],
    'run_argv': ['test', '--edit'],
  },
  {
    'id': 'pi',
    'name': 'Pi fixture',
    'model_option': '--model',
    'provider_option': '--provider',
    'access_modes': ['read-only'],
    'plan_argv': ['pi', '--read-only'],
    'run_argv': ['pi', '--read-only'],
  },
];

void main() {
  testWidgets('fresh execution requires a ready project after review', (
    tester,
  ) async {
    for (final status in ['completed', 'failed']) {
      final saved = {...project(status: status), 'approved_version': 1};
      await mount(tester, (operation, params) async {
        if (operation == 'profiles') return {'profiles': profiles};
        if (operation == 'list') {
          return {
            'projects': [saved],
          };
        }
        return {'project': saved};
      });
      await tester.tap(find.text('Saved project'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Run project'),
            )
            .onPressed,
        isNull,
      );
      if (status == 'failed') {
        expect(find.text('Continue project'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('planning fallback cannot edit execution instructions or model', (
    tester,
  ) async {
    final saved = project();
    await mount(tester, (operation, params) async {
      if (operation == 'profiles') return {'profiles': profiles};
      if (operation == 'list') {
        return {
          'projects': [saved],
        };
      }
      return {'project': saved};
    });
    await tester.tap(find.text('Saved project'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Team'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Planning'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, 'Role instructions'),
          )
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, 'Model (optional)'),
          )
          .enabled,
      isFalse,
    );
    expect(
      find.text('Planning follows the execution team until customized.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'setup proposes a phase-specific team and applies only after review',
    (tester) async {
      var saved = project();
      final calls = <String>[];
      Map<String, dynamic>? request;
      await mount(tester, (operation, params) async {
        calls.add(operation);
        if (operation == 'profiles') return {'profiles': profiles};
        if (operation == 'list') {
          return {
            'projects': [saved],
          };
        }
        if (operation == 'save') saved = {...saved, ...params, 'revision': 2};
        if (operation == 'setup') {
          request = {...params};
          saved = {
            ...saved,
            'revision': 3,
            'setup_proposal': {
              'target': params['target'],
              'team': [
                {'agent': 'pi', 'role': 'lead', 'access': 'read-only'},
              ],
              'rationale': 'Use the local bound agent.',
              'warnings': ['Check local model availability.'],
              'excluded_agents': ['test-agent'],
              'excluded_runtimes': ['missing-runtime'],
            },
          };
        }
        if (operation == 'setup_apply') {
          saved = {
            ...saved,
            'revision': 4,
            'plan_team': (saved['setup_proposal'] as Map)['team'],
          };
        }
        return {'project': saved};
      });
      await tester.tap(find.text('Saved project'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Setup'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Planning'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'AI setup request'),
        'Use Pi with the local runtime',
      );
      final propose = find.widgetWithText(FilledButton, 'Propose AI setup');
      await tester.ensureVisible(propose);
      await tester.tap(propose);
      await tester.pumpAndSettle();
      expect(request!['target'], 'plan');
      expect(request!['request'], 'Use Pi with the local runtime');
      expect(calls.contains('setup_apply'), isFalse);
      expect(calls.contains('run'), isFalse);
      expect(find.text('Use the local bound agent.'), findsOneWidget);
      expect(find.textContaining('Excluded agents'), findsOneWidget);
      await tester.ensureVisible(find.text('Execution'));
      await tester.tap(find.text('Execution'));
      await tester.pumpAndSettle();
      final apply = find.widgetWithText(FilledButton, 'Use proposed team');
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(calls.where((c) => c == 'setup_apply').length, 1);
      expect(saved['plan_team'], isNotNull);
      expect((saved['team'] as List).first['agent'], 'test-agent');
      expect(
        tester
            .widget<SegmentedButton<String>>(
              find.byType(SegmentedButton<String>),
            )
            .selected,
        {'plan'},
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('editing planning configuration preserves execution team', (
    tester,
  ) async {
    var saved = {
      ...project(),
      'plan_team': [
        {
          'agent': 'pi',
          'role': 'lead',
          'access': 'read-only',
          'instructions': 'Plan only',
        },
      ],
    };
    Map<String, dynamic>? write;
    await mount(tester, (operation, params) async {
      if (operation == 'profiles') return {'profiles': profiles};
      if (operation == 'list') {
        return {
          'projects': [saved],
        };
      }
      if (operation == 'save') {
        write = {...params};
        saved = {...saved, ...params, 'revision': 2};
      }
      return {'project': saved};
    });
    await tester.tap(find.text('Saved project'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Team'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Planning'));
    await tester.pumpAndSettle();
    final instructions = find.widgetWithText(
      TextFormField,
      'Role instructions',
    );
    await tester.ensureVisible(instructions);
    await tester.enterText(instructions, 'Investigate before planning');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save project'));
    await tester.pumpAndSettle();
    expect(
      (write!['plan_team'] as List).first['instructions'],
      'Investigate before planning',
    );
    expect((write!['team'] as List).first['agent'], 'test-agent');
    expect((write!['plan_team'] as List).first['agent'], 'pi');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'local binding selects exact provider and model with Pi read-only access',
    (tester) async {
      var saved = {
        ...project(),
        'team': [
          {
            'agent': 'pi',
            'role': 'lead',
            'access': 'read-only',
            'instructions': '',
          },
        ],
      };
      Map<String, dynamic>? write;
      await mount(tester, (operation, params) async {
        if (operation == 'profiles') {
          return {
            'profiles': profiles,
            'runtimes': [
              {
                'key': 'llama',
                'name': 'Local llama',
                'installed': true,
                'running': true,
                'models': ['qwen-local'],
                'bindings': {
                  'pi': {
                    'provider': 'llama-local',
                    'models': ['qwen-local'],
                  },
                },
              },
            ],
          };
        }
        if (operation == 'list') {
          return {
            'projects': [saved],
          };
        }
        if (operation == 'save') {
          write = {...params};
          saved = {...saved, ...params, 'revision': 2};
        }
        return {'project': saved};
      });
      await tester.tap(find.text('Saved project'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Team'));
      await tester.pumpAndSettle();
      final access = tester.widget<DropdownButton<String>>(
        find.descendant(
          of: find.widgetWithText(
            DropdownButtonFormField<String>,
            'Execution access',
          ),
          matching: find.byType(DropdownButton<String>),
        ),
      );
      expect(access.items!.map((item) => item.value), ['read-only']);
      final runtime = find.widgetWithText(
        DropdownButtonFormField<String>,
        'Local runtime',
      );
      await tester.ensureVisible(runtime);
      await tester.tap(runtime);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Local llama').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save project'));
      await tester.pumpAndSettle();
      final member = (write!['team'] as List).first;
      expect(member['runtime'], 'llama');
      expect(member['provider'], 'llama-local');
      expect(member['model'], 'qwen-local');
      expect(member['access'], 'read-only');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
