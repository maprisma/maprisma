import 'package:asterism/settings_view.dart';
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
}
