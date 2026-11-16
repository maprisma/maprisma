import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Whether Settings › Map › 3D map layout is active (on by default).
bool map3dEnabled(Map? saved) => saved?['three_d'] != false;

/// Column-tiered 3D extrusion depth: Agents stand proudest in the middle,
/// flanked by Providers and the outer tool/model columns.
Offset map3dColumnDepth(int column) => switch (column) {
  1 => const Offset(5.2, 6.8),
  2 => const Offset(4.2, 5.6),
  _ => const Offset(3.5, 4.7),
};

/// Exact tangent-continuous 3D extrusion walls of an [RRect] swept by [depth]
/// (`dx > 0, dy > 0`), split at the bottom-right corner so the right wall and
/// bottom wall take distinct directional shading.
({Path rightWall, Path bottomWall, Offset creaseStart, Offset creaseEnd})
extrudedMapWalls(Rect rect, double radius, Offset depth) {
  final dx = depth.dx, dy = depth.dy;
  final r = radius.clamp(0.0, math.min(rect.width, rect.height) / 2);
  if (r <= 0.05) {
    final right = Path()
      ..moveTo(rect.right, rect.top)
      ..lineTo(rect.right + dx, rect.top + dy)
      ..lineTo(rect.right + dx, rect.bottom + dy)
      ..lineTo(rect.right, rect.bottom)
      ..close();
    final bottom = Path()
      ..moveTo(rect.right, rect.bottom)
      ..lineTo(rect.right + dx, rect.bottom + dy)
      ..lineTo(rect.left + dx, rect.bottom + dy)
      ..lineTo(rect.left, rect.bottom)
      ..close();
    return (
      rightWall: right,
      bottomWall: bottom,
      creaseStart: Offset(rect.right, rect.bottom),
      creaseEnd: Offset(rect.right + dx, rect.bottom + dy),
    );
  }

  final angle = math.atan2(-dx, dy); // (-pi/2, 0) on top-right arc
  final blAngle = angle + math.pi; // (pi/2, pi) on bottom-left arc
  const split = math.pi / 4; // 45° miter on bottom-right arc

  final frontTR = Rect.fromCircle(
    center: Offset(rect.right - r, rect.top + r),
    radius: r,
  );
  final frontBR = Rect.fromCircle(
    center: Offset(rect.right - r, rect.bottom - r),
    radius: r,
  );
  final frontBL = Rect.fromCircle(
    center: Offset(rect.left + r, rect.bottom - r),
    radius: r,
  );
  final backTR = frontTR.shift(depth);
  final backBR = frontBR.shift(depth);
  final backBL = frontBL.shift(depth);

  final trCos = math.cos(angle), trSin = math.sin(angle);
  final spCos = math.cos(split), spSin = math.sin(split);
  final blCos = math.cos(blAngle), blSin = math.sin(blAngle);

  final creaseStart = Offset(
    rect.right - r + r * spCos,
    rect.bottom - r + r * spSin,
  );
  final creaseEnd = creaseStart + depth;

  final right = Path()
    ..arcTo(frontTR, angle, 0, true)
    ..lineTo(rect.right - r + r * trCos + dx, rect.top + r + r * trSin + dy)
    ..arcTo(backTR, angle, -angle, false)
    ..lineTo(rect.right + dx, rect.bottom - r + dy)
    ..arcTo(backBR, 0, split, false)
    ..lineTo(creaseStart.dx, creaseStart.dy)
    ..arcTo(frontBR, split, -split, false)
    ..lineTo(rect.right, rect.top + r)
    ..arcTo(frontTR, 0, angle, false)
    ..close();

  final bottom = Path()
    ..arcTo(frontBR, split, 0, true)
    ..lineTo(creaseEnd.dx, creaseEnd.dy)
    ..arcTo(backBR, split, math.pi / 2 - split, false)
    ..lineTo(rect.left + r + dx, rect.bottom + dy)
    ..arcTo(backBL, math.pi / 2, blAngle - math.pi / 2, false)
    ..lineTo(rect.left + r + r * blCos, rect.bottom - r + r * blSin)
    ..arcTo(frontBL, blAngle, -(blAngle - math.pi / 2), false)
    ..lineTo(rect.right - r, rect.bottom)
    ..arcTo(frontBR, math.pi / 2, -(math.pi / 2 - split), false)
    ..close();

  return (
    rightWall: right,
    bottomWall: bottom,
    creaseStart: creaseStart,
    creaseEnd: creaseEnd,
  );
}

(Color right, Color bottom, Color contour) _wallShades(
  Color face,
  ColorScheme colors, {
  Color? tint,
}) {
  final dark = colors.brightness == Brightness.dark;
  var base = tint == null ? face : Color.lerp(face, tint, dark ? 0.34 : 0.24)!;
  // Keep extruded walls visible even on near-black desktop themes.
  if (dark && base.computeLuminance() < 0.045) {
    base = Color.lerp(base, colors.outlineVariant, 0.32)!;
  }
  final right = Color.lerp(
    base,
    dark ? Colors.black : colors.onSurface,
    dark ? 0.34 : 0.14,
  )!;
  final bottom = Color.lerp(
    base,
    dark ? Colors.black : colors.onSurface,
    dark ? 0.52 : 0.23,
  )!;
  final contour = Color.lerp(
    colors.outlineVariant,
    Colors.black,
    dark ? 0.35 : 0.15,
  )!.withValues(alpha: dark ? 0.65 : 0.45);
  return (right, bottom, contour);
}

/// Subtle receding perspective floor grid and overhead studio lighting behind
/// the map. Uses only [Canvas.drawRect] and [Canvas.drawLine] so path counts
/// on the map painter reflect cards and connections only.
void paintMap3dStage(Canvas canvas, Size size, ColorScheme colors) {
  if (size.width <= 0 || size.height <= 0) return;
  final dark = colors.brightness == Brightness.dark;
  final stageRect = Offset.zero & size;
  canvas.drawRect(
    stageRect,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.lerp(
            colors.surface,
            colors.primary,
            dark ? 0.035 : 0.02,
          )!.withValues(alpha: dark ? 0.55 : 0.4),
          colors.surface.withValues(alpha: 0),
          Colors.black.withValues(alpha: dark ? 0.14 : 0.035),
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(stageRect),
  );

  final gridColor = colors.outlineVariant.withValues(alpha: dark ? 0.16 : 0.22);
  final linePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;

  // Perspective-spaced horizontal depth lines (closer together near the top,
  // opening up toward the foreground).
  const rows = 14;
  for (var i = 1; i <= rows; i++) {
    final t = i / rows;
    final y = size.height * math.pow(t, 1.38);
    if (y > size.height) break;
    linePaint.color = gridColor.withValues(
      alpha: gridColor.a * (0.28 + 0.72 * t),
    );
    canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
  }

  // Gentle perspective floor rays converging above the canvas horizon.
  final vanish = Offset(size.width * 0.5, -size.height * 0.85);
  final step = math.max(110.0, size.width / 12);
  linePaint.color = gridColor.withValues(alpha: gridColor.a * 0.65);
  for (var x = -size.width * 0.2; x <= size.width * 1.2; x += step) {
    final target = Offset(x, size.height);
    final dir = target - vanish;
    if (dir.dy <= 0) continue;
    final topT = (0 - vanish.dy) / dir.dy;
    final start = vanish + dir * topT;
    canvas.drawLine(start, target, linePaint);
  }
}

/// Paints a category card as a 3D raised plinth with ground shadow, extruded
/// right/bottom walls, directional surface sheen, top-left specular bevel and
/// a recessed inner tray well when unfolded.
void paintMap3dCard(
  Canvas canvas,
  Rect rect, {
  required double radius,
  required ColorScheme colors,
  required bool folded,
  Paint? borderPaint,
}) {
  final dark = colors.brightness == Brightness.dark;
  final depth = folded ? const Offset(3.0, 4.2) : const Offset(5.0, 6.8);
  final shape = RRect.fromRectAndRadius(rect, Radius.circular(radius));

  // Soft directional cast shadow onto the stage floor.
  canvas.drawRRect(
    shape.shift(Offset(depth.dx + 2.5, depth.dy + 4.5)),
    Paint()
      ..color = Colors.black.withValues(alpha: dark ? 0.36 : 0.12)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, folded ? 5 : 9),
  );

  // Solid 3D extruded plinth walls.
  final walls = extrudedMapWalls(rect, radius, depth);
  final (rightColor, bottomColor, contour) = _wallShades(
    colors.surfaceContainerLow,
    colors,
    tint: borderPaint?.color,
  );
  canvas.drawPath(walls.rightWall, Paint()..color = rightColor);
  canvas.drawPath(walls.bottomWall, Paint()..color = bottomColor);
  final edgePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.9
    ..color = contour;
  canvas.drawLine(walls.creaseStart, walls.creaseEnd, edgePaint);

  // Top face lit from top-left.
  final topHighlight = Color.lerp(
    colors.surfaceContainerLow,
    dark ? Colors.white : colors.surfaceBright,
    dark ? 0.045 : 0.45,
  )!;
  canvas.drawRRect(
    shape,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [topHighlight, colors.surfaceContainerLow],
      ).createShader(rect),
  );

  // Recessed inner well where the 3D boxes sit when unfolded.
  if (!folded && rect.height > 54) {
    final wellRect = Rect.fromLTRB(
      rect.left + 6,
      rect.top + 35,
      rect.right - 6,
      rect.bottom - 7,
    );
    final wellRadius = math.max(0.0, radius - 3);
    final well = RRect.fromRectAndRadius(wellRect, Radius.circular(wellRadius));
    canvas.drawRRect(
      well,
      Paint()..color = Colors.black.withValues(alpha: dark ? 0.16 : 0.035),
    );
    canvas.drawRRect(
      well,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.black.withValues(alpha: dark ? 0.32 : 0.09),
            Colors.white.withValues(alpha: dark ? 0.07 : 0.45),
          ],
        ).createShader(wellRect),
    );
  }

  // Specular top-left catchlight rim (or explicit user card border).
  if (borderPaint != null) {
    canvas.drawRRect(shape, borderPaint);
  } else {
    canvas.drawRRect(
      shape.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: dark ? 0.16 : 0.65),
            colors.outlineVariant.withValues(alpha: dark ? 0.35 : 0.45),
          ],
        ).createShader(rect),
    );
  }
}

/// Paints a connection curve as a floating 3D cylindrical cable with a cast
/// shadow on the stage below, 3-pass tube shading and beveled socket ports.
void paintMap3dCable(
  Canvas canvas,
  Path path, {
  required Offset start,
  required Offset end,
  required Color color,
  required double width,
  required ColorScheme colors,
  required bool castShadow,
  bool sockets = true,
}) {
  final dark = colors.brightness == Brightness.dark;
  if (castShadow) {
    canvas.drawPath(
      path.shift(const Offset(3.5, 7.5)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width + 2.0
        ..strokeCap = StrokeCap.round
        ..color = Colors.black.withValues(alpha: dark ? 0.34 : 0.14)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.8),
    );
  }

  // Outer shaded cable casing.
  final jacket = Color.lerp(
    color,
    Colors.black,
    dark ? 0.42 : 0.25,
  )!.withValues(alpha: color.a);
  canvas.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = width + 1.6
      ..color = jacket,
  );

  // Core vivid cable body.
  canvas.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = width + 0.4
      ..color = color,
  );

  // Cylindrical specular sheen along the upper-left side of the tube.
  final sheenAlpha = (color.a * (dark ? 0.46 : 0.58)).clamp(0.0, 1.0);
  if (sheenAlpha > 0.08) {
    canvas.drawPath(
      path.shift(const Offset(-0.35, -0.55)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = math.max(0.75, width * 0.38)
        ..color = Color.lerp(
          color,
          Colors.white,
          0.62,
        )!.withValues(alpha: sheenAlpha),
    );
  }

  if (sockets && color.a > 0.3) {
    for (final port in [start, end]) {
      canvas.drawCircle(
        port + const Offset(1.0, 1.5),
        4.2,
        Paint()..color = Colors.black.withValues(alpha: dark ? 0.35 : 0.16),
      );
      canvas.drawCircle(port, 4.0, Paint()..color = jacket);
      canvas.drawCircle(
        port,
        2.4,
        Paint()..color = Color.lerp(color, Colors.white, 0.28)!,
      );
    }
  }
}

/// Wraps a map box or column group card in solid 3D extruded walls, cast
/// shadow and overhead specular bevel without altering its hit-test rectangle.
class Map3dBlock extends StatelessWidget {
  const Map3dBlock({
    super.key,
    required this.enabled,
    required this.radius,
    required this.faceColor,
    required this.child,
    this.inset = 0.0,
    this.depth = const Offset(4.0, 5.4),
    this.accent,
    this.elevated = false,
    this.dimmed = false,
  });

  final bool enabled;
  final double radius;
  final Color faceColor;
  final double inset;
  final Offset depth;
  final Color? accent;
  final bool elevated;
  final bool dimmed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    final colors = Theme.of(context).colorScheme;
    final effectiveDepth = dimmed
        ? Offset(depth.dx * 0.55, depth.dy * 0.55)
        : elevated
        ? depth + const Offset(1.5, 2.0)
        : depth;
    return CustomPaint(
      painter: _Map3dBlockBackPainter(
        radius: radius,
        inset: inset,
        faceColor: faceColor,
        depth: effectiveDepth,
        colors: colors,
        accent: accent,
        elevated: elevated,
        dimmed: dimmed,
      ),
      foregroundPainter: _Map3dBlockFrontPainter(
        radius: radius,
        inset: inset,
        colors: colors,
        elevated: elevated,
        dimmed: dimmed,
      ),
      child: child,
    );
  }
}

class _Map3dBlockBackPainter extends CustomPainter {
  const _Map3dBlockBackPainter({
    required this.radius,
    required this.inset,
    required this.faceColor,
    required this.depth,
    required this.colors,
    required this.accent,
    required this.elevated,
    required this.dimmed,
  });

  final double radius;
  final double inset;
  final Color faceColor;
  final Offset depth;
  final ColorScheme colors;
  final Color? accent;
  final bool elevated;
  final bool dimmed;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = (Offset.zero & size).deflate(inset);
    if (rect.width <= 0 || rect.height <= 0) return;
    final dark = colors.brightness == Brightness.dark;
    final shape = RRect.fromRectAndRadius(rect, Radius.circular(radius));

    // Cast shadow onto the category plinth or stage floor.
    final shadowAlpha = dimmed
        ? (dark ? 0.16 : 0.05)
        : elevated
        ? (dark ? 0.44 : 0.18)
        : (dark ? 0.30 : 0.11);
    canvas.drawRRect(
      shape.shift(
        Offset(
          depth.dx + (elevated ? 2.5 : 1.5),
          depth.dy + (elevated ? 4.5 : 2.8),
        ),
      ),
      Paint()
        ..color =
            (elevated && accent != null
                    ? Color.lerp(Colors.black, accent, dark ? 0.28 : 0.15)!
                    : Colors.black)
                .withValues(alpha: shadowAlpha)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, elevated ? 6.5 : 4.0),
    );

    final walls = extrudedMapWalls(rect, radius, depth);
    final (right, bottom, contour) = _wallShades(
      faceColor,
      colors,
      tint: accent,
    );
    final wallAlpha = dimmed ? 0.55 : 1.0;
    canvas.drawPath(
      walls.rightWall,
      Paint()..color = right.withValues(alpha: wallAlpha),
    );
    canvas.drawPath(
      walls.bottomWall,
      Paint()..color = bottom.withValues(alpha: wallAlpha),
    );
    final edgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.85
      ..color = contour.withValues(alpha: contour.a * wallAlpha);
    canvas.drawPath(walls.rightWall, edgePaint);
    canvas.drawPath(walls.bottomWall, edgePaint);
  }

  @override
  bool shouldRepaint(covariant _Map3dBlockBackPainter old) =>
      radius != old.radius ||
      inset != old.inset ||
      faceColor != old.faceColor ||
      depth != old.depth ||
      colors != old.colors ||
      accent != old.accent ||
      elevated != old.elevated ||
      dimmed != old.dimmed;
}

class _Map3dBlockFrontPainter extends CustomPainter {
  const _Map3dBlockFrontPainter({
    required this.radius,
    required this.inset,
    required this.colors,
    required this.elevated,
    required this.dimmed,
  });

  final double radius;
  final double inset;
  final ColorScheme colors;
  final bool elevated;
  final bool dimmed;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || dimmed) return;
    final rect = (Offset.zero & size).deflate(inset);
    if (rect.width <= 0 || rect.height <= 0) return;
    final dark = colors.brightness == Brightness.dark;
    final shape = RRect.fromRectAndRadius(rect, Radius.circular(radius));

    // Gentle overhead studio sheen across the upper face.
    canvas.drawRRect(
      shape,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(
              alpha: elevated ? (dark ? 0.09 : 0.24) : (dark ? 0.05 : 0.15),
            ),
            Colors.white.withValues(alpha: 0),
          ],
          stops: const [0.0, 0.55],
        ).createShader(rect),
    );

    // Crisp top-left specular bevel along the block rim.
    canvas.drawRRect(
      shape.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(
              alpha: elevated ? (dark ? 0.30 : 0.78) : (dark ? 0.18 : 0.58),
            ),
            Colors.white.withValues(alpha: 0),
          ],
          stops: const [0.0, 0.6],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant _Map3dBlockFrontPainter old) =>
      radius != old.radius ||
      inset != old.inset ||
      colors != old.colors ||
      elevated != old.elevated ||
      dimmed != old.dimmed;
}
