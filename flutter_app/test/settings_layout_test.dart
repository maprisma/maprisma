import 'dart:convert';
import 'dart:io';

import 'package:maprisma/settings_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Settings (task 057): sections on the left, the chosen one's groups on the
/// right, and Find in Settings over all of them.
void main() {
  Widget view({
    String? section,
    Map<String, dynamic> translations = const {},
    double scale = 1,
    Brightness brightness = Brightness.light,
    bool busy = false,
    bool dictation = false,
    Future<void> Function(Map<String, dynamic>)? onUpdate,
  }) => MaterialApp(
    theme: ThemeData(brightness: brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: SettingsView(
        section: section,
        settings: {
          'language': 'auto',
          'look': 'adwaita',
          'map_layers': const ['agents'],
          'flutter_map_layout': const <String, dynamic>{},
          if (dictation) 'dictation': true,
        },
        busy: busy,
        tr: (key) => translations[key] as String? ?? key,
        changes: const [],
        onBack: () {},
        onUpdate: onUpdate ?? (values) async {},
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
    // Every group of General has its heading (task 058).
    for (final heading in [
      'Language',
      'Agents',
      'Rules',
      'Terminals and screenshots',
    ]) {
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Text &&
              w.data == heading &&
              w.style?.fontWeight == FontWeight.w600,
        ),
        findsOneWidget,
        reason: heading,
      );
    }
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

  for (final language in ['de', 'pl']) {
    final translations =
        jsonDecode(File('../translations/$language.json').readAsStringSync())
            as Map<String, dynamic>;
    for (final size in [const Size(540, 400), const Size(960, 640)]) {
      for (final scale in [1.0, 1.5, 2.0]) {
        testWidgets('$language $size at $scale keeps every section reachable', (
          tester,
        ) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            view(section: 'general', translations: translations, scale: scale),
          );
          for (final section in [
            'general',
            'appearance',
            'map',
            'agents',
            'llms',
            'dictation',
            'changes',
          ]) {
            final selector = find.byKey(
              const ValueKey('settings-section-selector'),
            );
            if (selector.evaluate().isNotEmpty) {
              await tester.tap(selector);
              await tester.pumpAndSettle();
              final menu = find.byType(Scrollable).last;
              final option = find.descendant(
                of: menu,
                matching: find.byKey(
                  ValueKey('settings-section-option-$section'),
                ),
              );
              await tester.scrollUntilVisible(option, 80, scrollable: menu);
              await tester.pumpAndSettle();
              expect(option.hitTestable(), findsOneWidget);
              await tester.tap(option);
            } else {
              final tile = find.byKey(ValueKey('settings-section-$section'));
              await tester.ensureVisible(tile);
              await tester.tap(tile);
            }
            await tester.pumpAndSettle();
            if (selector.evaluate().isNotEmpty) {
              expect(
                tester.widget<DropdownButton<String>>(selector).value,
                section,
              );
            } else {
              expect(
                tester
                    .widget<ListTile>(
                      find.byKey(ValueKey('settings-section-$section')),
                    )
                    .selected,
                isTrue,
              );
            }
            expect(
              tester.takeException()?.toString(),
              isNull,
              reason: '$section at $size / $scale',
            );
            final page = find.descendant(
              of: find.byKey(const ValueKey('settings-content')),
              matching: find.byType(ListView),
            );
            await tester.drag(page, const Offset(0, -600));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: 'scroll $section');
          }
        });
      }
    }
  }

  testWidgets('resizing preserves global search, focus and selected section', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(view(section: 'appearance'));
    final search = find.byKey(const ValueKey('settings-find'));
    await tester.enterText(search, 'notify');
    final editable = find.descendant(
      of: search,
      matching: find.byType(EditableText),
    );
    final focus = tester.widget<EditableText>(editable).focusNode;
    expect(focus.hasFocus, isTrue);
    for (final size in [const Size(540, 400), const Size(1400, 900)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, 'notify');
      expect(focus.hasFocus, isTrue);
      expect(find.text('Agents › Costs'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('theme-dark')), findsOneWidget);
  });

  testWidgets('keyboard sections stay visible in a short wide window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(view(section: 'general'));
    final last = find.byKey(const ValueKey('settings-section-changes'));
    final node = tester.widget<ListTile>(last).focusNode!;
    node.requestFocus();
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1400, 400);
    await tester.pumpAndSettle();
    expect(node.hasFocus, isTrue);
    expect(tester.getRect(last).bottom, lessThanOrEqualTo(400));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('No changes yet.'), findsOneWidget);
    tester.view.physicalSize = const Size(540, 400);
    await tester.pumpAndSettle();
    final selector = find.byKey(const ValueKey('settings-section-selector'));
    expect(
      tester.widget<DropdownButton<String>>(selector).focusNode!.hasFocus,
      isTrue,
    );
    expect(tester.widget<DropdownButton<String>>(selector).value, 'changes');
    tester.view.physicalSize = const Size(1400, 400);
    await tester.pumpAndSettle();
    expect(node.hasFocus, isTrue);
    expect(tester.getRect(last).bottom, lessThanOrEqualTo(400));
    expect(tester.takeException(), isNull);
  });

  for (final pointer in [false, true]) {
    testWidgets(
      'an open compact menu returns focus on wide resize ($pointer)',
      (tester) async {
        tester.view.physicalSize = const Size(540, 400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          view(section: 'appearance', brightness: Brightness.dark),
        );
        final selector = find.byKey(
          const ValueKey('settings-section-selector'),
        );
        if (pointer) {
          await tester.enterText(
            find.byKey(const ValueKey('settings-find')),
            'dark',
          );
          await tester.tap(selector);
        } else {
          tester
              .widget<DropdownButton<String>>(selector)
              .focusNode!
              .requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
        }
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('settings-section-option-general')),
          findsOneWidget,
        );
        tester.view.physicalSize = const Size(1400, 640);
        await tester.pumpAndSettle();
        final tile = tester.widget<ListTile>(
          find.byKey(const ValueKey('settings-section-appearance')),
        );
        expect(tile.focusNode!.hasFocus, isTrue);
        expect(
          find.byKey(const ValueKey('settings-section-option-general')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        // Cancelling a later menu must not steal focus back from the search.
        tester.view.physicalSize = const Size(540, 400);
        await tester.pumpAndSettle();
        await tester.tap(selector);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        final search = find.byKey(const ValueKey('settings-find'));
        await tester.enterText(search, 'notify');
        final editable = find.descendant(
          of: search,
          matching: find.byType(EditableText),
        );
        final searchFocus = tester.widget<EditableText>(editable).focusNode;
        tester.view.physicalSize = const Size(1400, 640);
        await tester.pumpAndSettle();
        expect(searchFocus.hasFocus, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a compact resize with the section menu open keeps the menu working',
    (tester) async {
      tester.view.physicalSize = const Size(540, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(view(section: 'appearance'));
      final selector = find.byKey(const ValueKey('settings-section-selector'));
      final focus = tester.widget<DropdownButton<String>>(selector).focusNode!;
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      final option = find.byKey(
        const ValueKey('settings-section-option-general'),
      );
      expect(option, findsOneWidget);
      tester.view.physicalSize = const Size(600, 400);
      await tester.pumpAndSettle();
      expect(option, findsOneWidget);
      expect(focus.hasFocus, isFalse); // the menu keeps the focus
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(option, findsNothing); // Esc closed only the menu
      expect(focus.hasFocus, isTrue);
      expect(
        tester.widget<DropdownButton<String>>(selector).value,
        'appearance',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('retention shows persisted value when an update is not saved', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Map<String, dynamic>? attempted;
    await tester.pumpWidget(
      view(
        section: 'map',
        onUpdate: (values) async {
          attempted = values;
        },
      ),
    );
    final field = find.descendant(
      of: find.byKey(const ValueKey('activity-log-days')),
      matching: find.byType(DropdownButton<int>),
    );
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.tap(find.text('30').last);
    await tester.pumpAndSettle();
    expect(attempted, {'ai_activity_log_days': 30});
    expect(tester.widget<DropdownButton<int>>(field).value, 7);
    expect(tester.takeException(), isNull);
  });

  testWidgets('drop-downs stay dense in the wide layout at normal text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    bool languageDense() => tester
        .widget<DropdownButton<String>>(
          find.descendant(
            of: find.byKey(const ValueKey('language-auto')),
            matching: find.byType(DropdownButton<String>),
          ),
        )
        .isDense;
    for (final (size, scale, dense) in [
      (const Size(1400, 900), 1.0, true),
      (const Size(560, 900), 1.0, false),
      (const Size(1800, 900), 1.5, false),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        const SizedBox(),
      ); // a new view opens at its section
      await tester.pumpWidget(view(section: 'general', scale: scale));
      await tester.pumpAndSettle();
      expect(languageDense(), dense, reason: '$size at $scale');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        const SizedBox(),
      ); // a new view opens at its section
      await tester.pumpWidget(
        view(section: 'dictation', scale: scale, dictation: true),
      );
      await tester.pumpAndSettle();
      final engine = find.descendant(
        of: find.byWidgetPredicate(
          (w) => '${w.key}'.contains('dictation-engine-'),
        ),
        matching: find.byType(DropdownButton<String>),
      );
      expect(
        tester.widget<DropdownButton<String>>(engine.first).isDense,
        dense,
        reason: 'dictation engine, $size at $scale',
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('a search marks no section in the compact selector', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(560, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(view(section: 'appearance'));
    DropdownButton<String> selector() => tester.widget<DropdownButton<String>>(
      find.byKey(const ValueKey('settings-section-selector')),
    );
    expect(selector().value, 'appearance');
    await tester.enterText(
      find.byKey(const ValueKey('settings-find')),
      'notify',
    );
    await tester.pumpAndSettle();
    expect(selector().value, isNull);
    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();
    expect(selector().value, 'appearance');
  });

  testWidgets('the retention field shows focus and its busy state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final field = find.byKey(const ValueKey('activity-log-days'));
    InputDecorator decorator() => tester.widget<InputDecorator>(
      find.descendant(of: field, matching: find.byType(InputDecorator)),
    );
    await tester.pumpWidget(view(section: 'map'));
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    expect(decorator().isFocused, isFalse);
    expect(decorator().decoration.enabled, isTrue);
    final dropdown = find.descendant(
      of: field,
      matching: find.byType(DropdownButton<int>),
    );
    // The drop-down's own focus node (keyboard focus, as Tab gives it).
    tester
        .widgetList<Focus>(
          find.descendant(of: dropdown, matching: find.byType(Focus)),
        )
        .map((f) => f.focusNode)
        .firstWhere((node) => node != null && node.canRequestFocus)!
        .requestFocus();
    await tester.pumpAndSettle();
    expect(decorator().isFocused, isTrue);
    await tester.pumpWidget(view(section: 'map', busy: true));
    await tester.pumpAndSettle();
    expect(decorator().decoration.enabled, isFalse);
  });
}
