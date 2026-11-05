import 'package:maprisma/settings_view.dart';
import 'package:maprisma/terminal_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a tab per terminal with its state; a click shows it', (
    tester,
  ) async {
    int? shown;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabs(
            tabs: const [
              ('Claude Code', 'working'),
              ('Codex', 'running'),
              ('Pi', 'ended'),
            ],
            current: 1,
            tr: (t) => t,
            onSelect: (i) => shown = i,
          ),
        ),
      ),
    );
    expect(find.text('TERMINALS'), findsOneWidget);
    expect(find.text('● working'), findsOneWidget);
    final codex = tester.widget<ChoiceChip>(
      find.byKey(const ValueKey('terminal-tab-1')),
    );
    expect(codex.selected, isTrue);
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('terminal-tab-0')))
          .selected,
      isFalse,
    );
    await tester.tap(find.text('Pi'));
    expect(shown, 2);
    expect(find.byTooltip('ended'), findsOneWidget);
  });

  testWidgets('Settings: the terminal tabs switch, on by default', (
    tester,
  ) async {
    Map<String, dynamic>? updated;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsView(
            section: 'all',
            settings: const {
              'language': 'auto',
              'look': 'adwaita',
              'map_layers': ['agents'],
            },
            busy: false,
            tr: (key) => key,
            checkers: const [],
            unitName: 'fixture.service',
            onBack: () {},
            onUpdate: (values) async => updated = values,
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('terminal-tabs')),
      250,
      scrollable: settingsList,
    );
    final tabs = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('terminal-tabs')),
    );
    expect(tabs.value, isTrue);
    tabs.onChanged!(false);
    expect(updated, {'terminal_tabs': false});
  });

  testWidgets('Settings: the usage statistics box and what it shows', (
    tester,
  ) async {
    final updates = <Map<String, dynamic>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsView(
            section: 'all',
            settings: const {
              'language': 'auto',
              'look': 'adwaita',
              'map_layers': ['agents'],
              'usage_box_items': ['rate', 'used'],
            },
            busy: false,
            tr: (key) => key,
            checkers: const [],
            unitName: 'fixture.service',
            onBack: () {},
            onUpdate: (values) async => updates.add(values),
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('usage-box-context')),
      250,
      scrollable: settingsList,
    );
    final context = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('usage-box-context')),
    );
    expect(context.value, isFalse);
    context.onChanged!(true);
    expect(updates.last, {
      'usage_box_items': ['rate', 'context', 'used'],
    });
    final rate = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('usage-box-rate')),
    );
    rate.onChanged!(false);
    expect(updates.last, {
      'usage_box_items': ['used'],
    });
  });
}

/// The page's own list in Settings (not the Find in Settings field).
Finder get settingsList => find
    .descendant(
      of: find.byKey(const ValueKey('settings-content')),
      matching: find.byType(Scrollable),
    )
    .first;
