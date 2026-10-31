import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The three map views by screen share (or fallback window width).
enum MapViewSize {
  small,
  medium,
  max;

  bool allows(int column) => switch (this) {
    MapViewSize.small => column == 1 || column == 2,
    MapViewSize.medium => column == 1 || column == 2 || column == 3,
    MapViewSize.max => true,
  };
}

MapViewSize mapViewSizeFor({
  required double windowWidth,
  required double displayWidth,
}) {
  if (displayWidth <= 0 || displayWidth < windowWidth) {
    if (windowWidth < 1150) return MapViewSize.small;
    if (windowWidth < 1600) return MapViewSize.medium;
    return MapViewSize.max;
  }
  final share = windowWidth / displayWidth;
  if (share <= 0.55) return MapViewSize.small;
  if (share <= 0.80) return MapViewSize.medium;
  return MapViewSize.max;
}

/// The display's width in the window's logical pixels. The Linux embedder
/// reports Display.size already logical (a 3840 px screen at scale 2 gives
/// 1920 and ratio 2), other platforms physical.
double displayWidthIn(Size size, double ratio, TargetPlatform platform) =>
    platform == TargetPlatform.linux || ratio <= 0
    ? size.width
    : size.width / ratio;

double mapDisplayWidthOf(BuildContext context) {
  final platform = defaultTargetPlatform;
  if (platform != TargetPlatform.linux && platform != TargetPlatform.macOS) {
    return 0; // desktop only; the widths decide
  }
  final display = View.of(context).display;
  return displayWidthIn(display.size, display.devicePixelRatio, platform);
}

/// A map that fits its window registers here how to fit again.
final mapFit = Expando<VoidCallback>('mapFit');

/// Whether the user has zoomed a controller away from its fitted scale.
final mapUserZoomed = Expando<bool>('mapUserZoomed');

/// A map without its own fit state registers here to clamp and save after zoom.
final mapClamp = Expando<VoidCallback>('mapClamp');

/// The mouse wheel: scrolls within the map plus a margin (InteractiveViewer
/// would zoom, or with scaleEnabled false do nothing). Zoom stays with the
/// control.
void scrollMap(
  TransformationController controller,
  Offset delta, {
  required Size viewport,
  required Size content,
  double margin = 120,
}) {
  final scale = controller.value.entry(0, 0);
  final edge = margin * scale;
  double clamped(double value, double view, double size) {
    final lowest = math.min(0.0, view - size * scale - edge);
    return value.clamp(lowest, 0.0); // nothing above or left of the map
  }

  final now = controller.value.getTranslation();
  final next = controller.value.clone();
  next.setTranslationRaw(
    clamped(now.x - delta.dx, viewport.width, content.width),
    clamped(now.y - delta.dy, viewport.height, content.height),
    now.z,
  );
  controller.value = next;
}

/// Zoom on the map itself: the mouse wheel scrolls it, these buttons and
/// Ctrl+Plus / Ctrl+Minus / Ctrl+0 zoom it (within 30–200 %).
void zoomMap(TransformationController controller, double factor) {
  if (factor == 0) {
    mapUserZoomed[controller] = false;
    final fit = mapFit[controller];
    fit == null ? controller.value = Matrix4.identity() : fit();
    mapClamp[controller]?.call();
    return;
  }
  mapUserZoomed[controller] = true;
  final scale = controller.value.entry(0, 0); // x scale (no rotation)
  final next = (scale * factor).clamp(0.3, 2.0);
  controller.value = controller.value.clone()
    ..scaleByDouble(next / scale, next / scale, 1, 1);
  mapClamp[controller]?.call();
}

class MapZoomControl extends StatelessWidget {
  const MapZoomControl({super.key, required this.controller, required this.tr});
  final TransformationController controller;
  final String Function(String) tr;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        key: const ValueKey('map-zoom-out'),
        visualDensity: VisualDensity.compact,
        tooltip: tr('Zoom out'),
        icon: const Icon(Icons.remove),
        onPressed: () => zoomMap(controller, .8),
      ),
      SizedBox(
        width: 56,
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => Text(
            '${(controller.value.entry(0, 0) * 100).round()} %',
            key: const ValueKey('map-zoom-value'),
            textAlign: TextAlign.center,
            softWrap: false,
          ),
        ),
      ),
      IconButton(
        key: const ValueKey('map-zoom-in'),
        visualDensity: VisualDensity.compact,
        tooltip: tr('Zoom in'),
        icon: const Icon(Icons.add),
        onPressed: () => zoomMap(controller, 1.25),
      ),
      IconButton(
        key: const ValueKey('map-zoom-fit'),
        visualDensity: VisualDensity.compact,
        tooltip: tr('Fit to window'),
        icon: const Icon(Icons.fit_screen),
        onPressed: () => zoomMap(controller, 0),
      ),
    ],
  );
}
