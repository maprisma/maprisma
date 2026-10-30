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
}
