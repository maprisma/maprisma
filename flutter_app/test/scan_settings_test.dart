import 'package:asterism/settings_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
