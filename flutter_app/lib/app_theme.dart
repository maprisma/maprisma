import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

Color? desktopThemeColor(Map theme, String key) {
  final value = theme[key];
  if (value is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
    return null;
  }
  return Color(0xff000000 | int.parse(value.substring(1), radix: 16));
}

ThemeMode appThemeMode(String mode, Map desktop) {
  if (mode == 'light') return ThemeMode.light;
  if (mode == 'dark') return ThemeMode.dark;
  final background = desktopThemeColor(desktop, 'background');
  if (background == null) return ThemeMode.system;
  return background.computeLuminance() < .5 ? ThemeMode.dark : ThemeMode.light;
}

/// Settings › Corners: the radius of the window's cards, dialogs and the
/// map's boxes (corners.radius): "windows" follows Hyprland's rounding,
/// "rounded" is 12, "square" 0; null keeps Material's own.
double? cornerRadius(String? setting, int? windowRounding) => switch (setting) {
  'rounded' => 12,
  'square' => 0,
  _ => windowRounding?.toDouble(),
};

/// The corner radius in effect (12 when nothing set it).
class Corners extends ThemeExtension<Corners> {
  const Corners(this.radius);
  final double radius;
  @override
  Corners copyWith({double? radius}) => Corners(radius ?? this.radius);
  @override
  Corners lerp(Corners? other, double t) =>
      other == null ? this : Corners(lerpDouble(radius, other.radius, t)!);
}

double corners(BuildContext context) =>
    Theme.of(context).extension<Corners>()?.radius ?? 12;

ThemeData appTheme(
  Brightness brightness, {
  String mode = 'system',
  Map desktop = const {},
  double? radius,
}) {
  var colors = ColorScheme.fromSeed(
    seedColor: desktopThemeColor(desktop, 'accent') ?? const Color(0xff517f70),
    brightness: brightness,
  );
  final background = desktopThemeColor(desktop, 'background');
  if (mode == 'system' && background != null) {
    colors = colors.copyWith(
      surface: background,
      onSurface: desktopThemeColor(desktop, 'foreground') ?? colors.onSurface,
    );
  }
  final shape = radius == null
      ? null
      : RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
  return ThemeData(
    colorScheme: colors,
    useMaterial3: true,
    extensions: [Corners(radius ?? 12)],
    cardTheme: shape == null ? null : CardThemeData(shape: shape),
    dialogTheme: shape == null ? null : DialogThemeData(shape: shape),
    // Material's default is the inverted surface: a white bar on a dark app.
    snackBarTheme: SnackBarThemeData(
      backgroundColor: colors.surfaceContainerHigh,
      contentTextStyle: TextStyle(color: colors.onSurface),
      actionTextColor: colors.primary,
      closeIconColor: colors.onSurfaceVariant,
    ),
  );
}

/// The preview and the application use the same theme factory.
class ThemeChoices extends StatelessWidget {
  const ThemeChoices({
    super.key,
    required this.value,
    required this.enabled,
    required this.tr,
    required this.onChanged,
    this.desktop = const {},
  });
  final String value;
  final bool enabled;
  final String Function(String) tr;
  final ValueChanged<String> onChanged;
  final Map desktop;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth.clamp(0.0, 210.0);
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final mode in ['system', 'light', 'dark'])
            SizedBox(
              width: width,
              child: Semantics(
                selected: value == mode,
                button: true,
                child: Card(
                  margin: EdgeInsets.zero,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(corners(context)),
                    side: BorderSide(
                      width: value == mode ? 2 : 1,
                      color: value == mode
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                  child: InkWell(
                    key: ValueKey('theme-$mode'),
                    onTap: enabled ? () => onChanged(mode) : null,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ExcludeSemantics(
                            child: SizedBox(
                              height: 68,
                              child: CustomPaint(
                                painter: _ThemePreview(_colors(context, mode)),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Icon(
                                mode == 'system'
                                    ? Icons.brightness_auto
                                    : mode == 'light'
                                    ? Icons.light_mode
                                    : Icons.dark_mode,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  tr(
                                    {
                                      'system': 'System',
                                      'light': 'Light',
                                      'dark': 'Dark',
                                    }[mode]!,
                                  ),
                                ),
                              ),
                              if (value == mode)
                                const Icon(Icons.check, size: 18),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
  ColorScheme _colors(BuildContext context, String mode) {
    final choice = appThemeMode(mode, desktop);
    final brightness = choice == ThemeMode.system
        ? MediaQuery.platformBrightnessOf(context)
        : choice == ThemeMode.dark
        ? Brightness.dark
        : Brightness.light;
    return appTheme(brightness, mode: mode, desktop: desktop).colorScheme;
  }
}

class _ThemePreview extends CustomPainter {
  _ThemePreview(this.colors);
  final ColorScheme colors;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = colors.surface;
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      paint,
    );
    paint.color = colors.primary;
    canvas.drawCircle(const Offset(12, 12), 3, paint);
    paint
      ..color = colors.onSurface
      ..strokeWidth = 2;
    canvas.drawLine(const Offset(22, 12), Offset(size.width - 12, 12), paint);
    for (var i = 0; i < 3; i++) {
      final x = 10 + i * (size.width - 20) / 3;
      paint.color = colors.primaryContainer;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 30, (size.width - 32) / 3, 24),
          const Radius.circular(4),
        ),
        paint,
      );
      paint.color = colors.onPrimaryContainer;
      canvas.drawLine(
        Offset(x + 5, 38),
        Offset(x + (size.width - 32) / 3 - 5, 38),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ThemePreview old) => old.colors != colors;
}
