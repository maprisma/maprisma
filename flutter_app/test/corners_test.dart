import 'package:maprisma/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Settings › Corners: like windows (Hyprland's rounding, Material's own
/// when unknown), rounded 12, square 0; cards and dialogs follow, the map's
/// boxes read it from the theme.
void main() {
  test('the radius for each choice', () {
    expect(cornerRadius('windows', 0), 0);
    expect(cornerRadius('windows', 8), 8);
    expect(cornerRadius(null, 8), 8);
    expect(cornerRadius('windows', null), isNull);
    expect(cornerRadius('slight', 0), 6);
    expect(cornerRadius('rounded', 0), 12);
    expect(cornerRadius('square', 8), 0);
  });

  testWidgets('cards take the radius; 12 when nothing set it', (tester) async {
    double? seen;
    Future<void> pump(ThemeData theme) => tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) {
            seen = corners(context);
            return const Card(child: SizedBox(width: 10, height: 10));
          },
        ),
      ),
    );
    await pump(appTheme(Brightness.light, radius: 0));
    await tester.pumpAndSettle();
    expect(seen, 0);
    final shape =
        Theme.of(tester.element(find.byType(Card))).cardTheme.shape
            as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(0));
    await pump(appTheme(Brightness.light));
    await tester.pumpAndSettle(); // the theme's change is animated
    expect(seen, 12);
  });

  test('every control in three sizes; Square keeps a small knob', () {
    BorderRadius? of(OutlinedBorder? shape) =>
        (shape as RoundedRectangleBorder?)?.borderRadius as BorderRadius?;
    for (final (radius, control, small) in [
      (12.0, 8.0, 4.0),
      (6.0, 6.0, 4.0),
      (0.0, 0.0, 0.0),
    ]) {
      final theme = appTheme(Brightness.dark, radius: radius);
      final sizes = theme.extension<Corners>()!;
      expect((sizes.control, sizes.small), (control, small));
      final c = BorderRadius.circular(control),
          s = BorderRadius.circular(small);
      expect(
        of(theme.dialogTheme.shape as OutlinedBorder),
        BorderRadius.circular(radius),
      );
      expect(
        of(theme.popupMenuTheme.shape as OutlinedBorder?),
        BorderRadius.circular(radius),
      );
      expect(of(theme.filledButtonTheme.style!.shape!.resolve({})), c);
      expect(of(theme.outlinedButtonTheme.style!.shape!.resolve({})), c);
      expect(of(theme.textButtonTheme.style!.shape!.resolve({})), c);
      expect(of(theme.iconButtonTheme.style!.shape!.resolve({})), c);
      expect(of(theme.chipTheme.shape), c);
      expect((theme.tooltipTheme.decoration as BoxDecoration).borderRadius, c);
      expect(of(theme.checkboxTheme.shape), s);
      expect(theme.progressIndicatorTheme.borderRadius, s);
      final knob = theme.sliderTheme.thumbShape as KnobShape;
      expect(knob.square, radius == 0);
      expect(knob.getPreferredSize(true, false), const Size.square(14));
    }
  });

  test('the bar with Undo stays dark in the dark theme', () {
    final theme = appTheme(Brightness.dark);
    final background = theme.snackBarTheme.backgroundColor!;
    expect(background, theme.colorScheme.surfaceContainerHigh);
    expect(background.computeLuminance(), lessThan(.2));
    expect(
      theme.snackBarTheme.contentTextStyle!.color,
      theme.colorScheme.onSurface,
    );
  });

  test(
    'the desktop accent is the primary colour itself, as in the Launcher',
    () {
      final theme = appTheme(
        Brightness.dark,
        desktop: const {'accent': '#7ebae4', 'background': '#0b0c16'},
      );
      expect(theme.colorScheme.primary, const Color(0xff7ebae4));
      expect(theme.colorScheme.onPrimary, Colors.black);
    },
  );
}
