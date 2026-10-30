import 'package:maprisma/settings_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget view(
    Map<String, dynamic> settings,
    List<Map> checkers,
    void Function(Map<String, dynamic>) onUpdate,
  ) => MaterialApp(
    home: Scaffold(
      body: SettingsView(
        settings: {
          'language': 'auto',
          'look': 'adwaita',
          'map_layers': ['agents'],
          ...settings,
        },
        busy: false,
        tr: (key) => key,
        checkers: checkers,
        unitName: 'fixture-providers.service',
        onBack: () {},
        onUpdate: (values) async => onUpdate(values),
      ),
    ),
  );

  testWidgets('local LLMs with their agents and the agent for AI checks', (
    tester,
  ) async {
    Map<String, dynamic>? updated;
    await tester.pumpWidget(
      view(
        {'providers_with_agents': true, 'ai_checks_agent': 'codex'},
        [
          {'command': 'claude', 'name': 'Claude Code'},
          {'command': 'codex', 'name': 'Codex'},
        ],
        (values) => updated = values,
      ),
    );
    await tester.scrollUntilVisible(
      find.text('Start local LLMs with their agents'),
      250,
    );
    expect(
      find.textContaining('(user service fixture-providers.service)'),
      findsOneWidget,
    );
    final watch = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Start local LLMs with their agents'),
    );
    expect(watch.value, isTrue);
    watch.onChanged!(false);
    expect(updated, {'providers_with_agents': false});
    await tester.scrollUntilVisible(find.text('Agent for AI checks'), 250);
    await tester.scrollUntilVisible(find.text('Codex'), 100);
    await tester.pumpAndSettle();
    expect(find.text('Codex'), findsOneWidget); // the saved one is shown
    await tester.tap(find.text('Codex'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claude Code').last);
    await tester.pumpAndSettle();
    expect(updated, {'ai_checks_agent': 'claude'});
  });

  testWidgets('no agent that can check: none installed', (tester) async {
    await tester.pumpWidget(view({}, const [], (_) {}));
    await tester.scrollUntilVisible(find.text('Agent for AI checks'), 250);
    expect(find.text('None installed'), findsOneWidget);
  });

  testWidgets('notify when an agent turns red, on by default', (tester) async {
    Map<String, dynamic>? updated;
    await tester.pumpWidget(view({}, const [], (values) => updated = values));
    await tester.scrollUntilVisible(find.text('Notify when red'), 250);
    final notify = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('warn-notify')),
    );
    expect(notify.value, isTrue);
    notify.onChanged!(false);
    expect(updated, {'warn_notify': false});
  });

  testWidgets('the local helper: the suggestion marked, a choice saved', (
    tester,
  ) async {
    Map<String, dynamic>? updated;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsView(
            settings: const {
              'language': 'auto',
              'look': 'adwaita',
              'map_layers': ['agents'],
            },
            busy: false,
            tr: (key) => key,
            checkers: const [],
            helpers: const {
              'candidates': [
                {
                  'key': {
                    'agent': 'pi',
                    'provider': 'llama-local',
                    'model': 'big',
                  },
                  'label': 'Pi · llama.cpp · big',
                },
                {
                  'key': {
                    'agent': 'pi',
                    'provider': 'llama-local',
                    'model': 'small',
                  },
                  'label': 'Pi · llama.cpp · small',
                },
              ],
              'suggested': {
                'key': {
                  'agent': 'pi',
                  'provider': 'llama-local',
                  'model': 'big',
                },
                'label': 'Pi · llama.cpp · big',
              },
              'chosen': null,
            },
            unitName: 'fixture.service',
            onBack: () {},
            onUpdate: (values) async => updated = values,
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(find.text('Local helper'), 250);
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(find.text('Pi · llama.cpp · big (suggested)').last, findsOneWidget);
    await tester.tap(find.text('Pi · llama.cpp · small').last);
    await tester.pumpAndSettle();
    expect(updated, {
      'ai_local_helper': {
        'agent': 'pi',
        'provider': 'llama-local',
        'model': 'small',
      },
    });
  });

  testWidgets('daily AI checks: off by default, switched on, checked now', (
    tester,
  ) async {
    Map<String, dynamic>? updated;
    var checked = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsView(
            settings: const {
              'language': 'auto',
              'look': 'adwaita',
              'map_layers': ['agents'],
            },
            busy: false,
            tr: (key) => key,
            checkers: const [],
            mcpChecks: const {
              'servers': 3,
              'agent': 'Claude Code',
              'summary': 'daily checks off',
              'updates': [],
            },
            onCheckMcp: () => checked++,
            onBack: () {},
            onUpdate: (values) async => updated = values,
          ),
        ),
      ),
    );
    final daily = find.byKey(const ValueKey('ai-checks'));
    await tester.scrollUntilVisible(daily, 250);
    expect(tester.widget<SwitchListTile>(daily).value, isFalse);
    final now = find.byKey(const ValueKey('ai-checks-now'));
    await tester.scrollUntilVisible(now, 100);
    expect(find.text('MCP server updates: daily checks off'), findsOneWidget);
    await tester.ensureVisible(daily);
    await tester.pumpAndSettle();
    await tester.tap(daily);
    await tester.pumpAndSettle();
    expect(updated, {'ai_checks': true});
    await tester.ensureVisible(now);
    await tester.pumpAndSettle();
    await tester.tap(now);
    expect(checked, 1);
  });
}
