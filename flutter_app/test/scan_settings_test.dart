import 'package:maprisma/settings_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('column widths: shown, kept with the layout, not lost on Back', (
    tester,
  ) async {
    final layouts = <Map<String, dynamic>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsView(
            settings: const {
              'language': 'auto',
              'look': 'adwaita',
              'map_layers': ['agents'],
              'flutter_map_layout': {
                'pins': ['agent:a'],
                'column_widths': {'agents': 410},
              },
            },
            busy: false,
            tr: (key) => key,
            onBack: () {},
            onUpdate: (values) async {},
            onMapLayout: layouts.add,
          ),
        ),
      ),
    );
    final current = find.byKey(const ValueKey('column_widths-agents'));
    final fallback = find.byKey(const ValueKey('column_defaults-models'));
    await tester.scrollUntilVisible(
      fallback,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.descendant(of: current, matching: find.text('410')),
      findsOneWidget,
    );

    await tester.enterText(fallback, '5000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(layouts.last['pins'], ['agent:a']);
    expect(layouts.last['column_defaults'], {'models': 900});

    await tester.enterText(current, '360');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    // This test's Settings never gets the saved layout back, so the other
    // field repeats its value too; the typed width must have gone out.
    expect(
      layouts.any((l) => (l['column_widths'] as Map)['agents'] == 360),
      isTrue,
    );
  });

  testWidgets('manual mode and independent scan targets are editable', (
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
              'map_scan_interval': 0,
              'map_scan_pause_unfocused': true,
              'map_scan_targets': ['activity'],
            },
            busy: false,
            tr: (key) => key,
            onBack: () {},
            onUpdate: (values) async {
              updated = values;
            },
          ),
        ),
      ),
    );
    // Down to the last target this test uses: the list builds only what it shows.
    await tester.scrollUntilVisible(find.text('Agent details'), 250);
    final activity = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, 'Activity and subagents'),
    );
    final agents = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, 'Agent details'),
    );
    expect(activity.value, isTrue);
    expect(agents.value, isFalse);
    agents.onChanged!(true);
    expect(updated, {
      'map_scan_targets': ['activity', 'agents'],
    });
    await tester.scrollUntilVisible(
      find.text('Pause scans while unfocused'),
      -200,
    );
    final pause = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Pause scans while unfocused'),
    );
    expect(pause.value, isTrue);
    pause.onChanged!(false);
    expect(updated, {'map_scan_pause_unfocused': false});
  });
}
