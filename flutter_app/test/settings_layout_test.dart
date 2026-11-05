import 'package:maprisma/settings_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Settings (task 057): sections on the left, the chosen one's groups on the
/// right, and Find in Settings over all of them.
void main() {
  Widget view({String? section}) => MaterialApp(
    home: Scaffold(
      body: SettingsView(
        section: section,
        settings: const {
          'language': 'auto',
          'look': 'adwaita',
          'map_layers': ['agents'],
          'flutter_map_layout': <String, dynamic>{},
        },
        busy: false,
        tr: (key) => key,
        onBack: () {},
        onUpdate: (values) async {},
      ),
    ),
  );

  testWidgets('a section shows only its own groups', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(view(section: 'general'));
    for (final key in [
      'general',
      'appearance',
      'map',
      'agents',
      'llms',
      'dictation',
    ]) {
      expect(
        find.byKey(ValueKey('settings-section-$key')),
        findsOneWidget,
        reason: key,
      );
    }
    // General: the language; not the theme of Appearance.
    expect(find.text('Language'), findsWidgets);
    expect(find.byKey(const ValueKey('theme-dark')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('settings-section-appearance')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('theme-dark')), findsOneWidget);
    expect(find.text('Appearance'), findsWidgets);
    final selected = tester.widget<ListTile>(
      find.byKey(const ValueKey('settings-section-appearance')),
    );
    expect(selected.selected, isTrue);
  });

  testWidgets('Find in Settings shows matching groups of every section', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(view(section: 'general'));
    await tester.enterText(
      find.byKey(const ValueKey('settings-find')),
      'notify',
    );
    await tester.pumpAndSettle();
    // Notify when red is in Agents › Costs, not in General.
    expect(find.text('Notify when red'), findsOneWidget);
    expect(find.text('Agents › Costs'), findsOneWidget);
    expect(find.byKey(const ValueKey('theme-dark')), findsNothing);
    // No section is marked while searching.
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey('settings-section-general')),
          )
          .selected,
      isFalse,
    );

    await tester.enterText(
      find.byKey(const ValueKey('settings-find')),
      'zzz-nothing',
    );
    await tester.pumpAndSettle();
    expect(find.text('No setting matches “zzz-nothing”'), findsOneWidget);

    // Clear: back to the section.
    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Language'), findsWidgets);
    expect(find.text('Notify when red'), findsNothing);
  });
}
