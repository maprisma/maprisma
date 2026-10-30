import 'package:maprisma/app_theme.dart';
import 'package:maprisma/settings_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'explicit themes override desktop brightness; System follows its palette',
    () {
      const desktop = {
        'accent': '#44aa88',
        'background': '#111111',
        'foreground': '#eeeeee',
      };
      expect(appThemeMode('system', desktop), ThemeMode.dark);
      expect(appThemeMode('system', {}), ThemeMode.system);
      expect(appThemeMode('light', desktop), ThemeMode.light);
      final light = appTheme(
        Brightness.light,
        mode: 'light',
        desktop: desktop,
      ).colorScheme;
      final dark = appTheme(
        Brightness.dark,
        mode: 'dark',
        desktop: desktop,
      ).colorScheme;
      expect(light.surface.computeLuminance(), greaterThan(.5));
      expect(dark.surface.computeLuminance(), lessThan(.5));
      expect(
        appTheme(Brightness.dark, desktop: desktop).colorScheme.surface,
        const Color(0xff111111),
      );
    },
  );
  testWidgets(
    'settings show three previews and send only the selected values',
    (tester) async {
      final updates = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsView(
              settings: const {
                'map_layers': ['agents'],
                'language': 'auto',
              },
              busy: false,
              tr: (s) => s,
              onUpdate: (v) async {
                updates.add(v);
              },
              onBack: () {},
            ),
          ),
        ),
      );
      expect(find.byType(ThemeChoices), findsOneWidget);
      expect(
        find
            .byType(CustomPaint)
            .evaluate()
            .where(
              (e) =>
                  (e.widget as CustomPaint).painter.runtimeType.toString() ==
                  '_ThemePreview',
            )
            .length,
        3,
      );
      await tester.tap(find.byKey(const ValueKey('theme-light')));
      expect(updates.single, {'flutter_theme_mode': 'light'});
      final rate = find.byKey(const ValueKey('map-light-fps-20'));
      await tester.scrollUntilVisible(rate, 200);
      await tester.ensureVisible(rate);
      await tester.pumpAndSettle();
      await tester.tap(rate);
      await tester.pumpAndSettle();
      expect(find.text('20 fps (default)'), findsWidgets);
      expect(find.text('30 fps'), findsOneWidget);
      expect(find.text('60 fps'), findsOneWidget);
      await tester.tap(find.text('30 fps'));
      await tester.pumpAndSettle();
      expect(updates.last, {'map_light_fps': 30});
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'theme previews respond to platform brightness and are disabled while saving',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(platformBrightness: Brightness.dark),
            child: Scaffold(
              body: ThemeChoices(
                value: 'system',
                enabled: false,
                tr: (s) => s,
                onChanged: (_) => fail('disabled choice'),
              ),
            ),
          ),
        ),
      );
      for (final name in ['system', 'light', 'dark']) {
        expect(
          tester.widget<InkWell>(find.byKey(ValueKey('theme-$name'))).onTap,
          isNull,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );
}
