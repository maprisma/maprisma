import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'map_layout.dart';

enum MapLightStyle { circles, sprites }

// Sprites had the lowest measured CPU; the difference from circles was small.
const defaultMapLightStyle = MapLightStyle.sprites;

/// One-shot ticker: a sleeping map never requests a vsync between light frames.
/// Throttling the *value* of a continuously running ticker still composites at
/// display refresh rate. Pace requests instead, with a selectable frame-rate guard.
class MapLightClock extends ChangeNotifier implements ValueListenable<double> {
  MapLightClock(TickerProvider provider, {int framesPerSecond = 20}) {
    _ticker = provider.createTicker(_frame);
    this.framesPerSecond = framesPerSecond;
  }
  int _fps = 20;
  int get framesPerSecond => _fps;
  Duration get period => Duration(microseconds: (1000000 / _fps).ceil());
  set framesPerSecond(int value) {
    if (!const [20, 30, 60].contains(value)) {
      throw ArgumentError.value(value, 'framesPerSecond');
    }
    if (value == _fps) return;
    _fps = value;
    _wake?.cancel();
    _wake = null;
    _ticker.stop();
    _lastFrame = null;
    if (_enabled) _ticker.start();
  }

  late final Ticker _ticker;
  Timer? _wake;
  bool _enabled = false;
  double _value = 0;
  Duration? _lastFrame;
  double refreshRate = 60;

  @override
  double get value => _value;
  bool get enabled => _enabled;

  set enabled(bool enabled) {
    if (enabled == _enabled) return;
    _enabled = enabled;
    if (enabled) {
      _ticker.start();
    } else {
      _wake?.cancel();
      _wake = null;
      _ticker.stop();
    }
  }

  void _frame(Duration _) {
    _ticker.stop();
    if (!_enabled) return;
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    final since = _lastFrame == null ? period : now - _lastFrame!;
    final rate = refreshRate.isFinite && refreshRate > 0 ? refreshRate : 60.0;
    final vsync = 1000000 / rate;
    // Accept the nearest paced vsync instead of skipping it for timestamp jitter.
    final ready = since.inMicroseconds >= period.inMicroseconds - vsync / 2;
    if (ready) {
      _lastFrame = now;
      _value = now.inMicroseconds / 2000000 % 1;
      notifyListeners();
    }
    final interval = vsync * (rate / _fps).ceil();
    // Request the intended vsync just before its deadline, not just after it.
    final wait = ready
        ? interval - math.min(4000, vsync / 4)
        : math.max(1000, (period - since).inMicroseconds);
    _wake = Timer(Duration(microseconds: wait.round()), () {
      _wake = null;
      if (_enabled) _ticker.start();
    });
  }

  @override
  void dispose() {
    _enabled = false;
    _wake?.cancel();
    _ticker.dispose();
    super.dispose();
  }
}

/// Each tile owns its repaint signal; changing lights never repaints the Stack
/// or the map behind it. Empty tiles only repaint once to erase departed marks.
class MapLightTile extends ChangeNotifier {
  MapLightTile(this.rect);
  final Rect rect;
  List<Offset> marks = const [];
  void update(List<Offset> next) {
    if (marks.isEmpty && next.isEmpty) return;
    marks = next;
    notifyListeners();
  }
}

class MapLightTiles {
  MapLightTiles(this.layout, this.mode) {
    // Avoid allocating an unbounded grid for a very large saved layout. Retry
    // with coarser tiles as soon as the budget is reached, before building UI.
    while (!_makeTiles()) {
      for (final tile in tiles.values) {
        tile.dispose();
      }
      tiles.clear();
      tileSize *= 2;
    }
    occluders = layout.boxes.values.map((r) => r.inflate(radius)).toList();
    // Over a bordered card the line is not drawn, nor are its lights; the bend
    // between two agents is drawn whole, and so are its lights.
    cardOccluders = layout.bordered
        ? [for (final c in layout.cards.values) c.rect]
        : const [];
  }
  static const radius = 4.0;
  static const maxTiles = 4096;
  final MapLayout layout;
  String mode;
  List<MapCurve> get curves => layout.curves
      .where(
        (c) =>
            c.edge['active'] == true &&
            (mode == 'all' || c.edge['activity'] == 'agent'),
      )
      .toList();
  late final List<Rect> occluders, cardOccluders;
  double tileSize = 64;
  final tiles = <(int, int), MapLightTile>{};
  Set<(int, int)> _occupied = {};

  bool _makeTiles() {
    for (final curve in layout.curves) {
      // The whole path: a bend between two agents reaches past both ends.
      final bounds = curve.path.getBounds().inflate(radius);
      for (
        var y = math.max(0, (bounds.top / tileSize).floor());
        y <= (bounds.bottom / tileSize).floor();
        y++
      ) {
        for (
          var x = math.max(0, (bounds.left / tileSize).floor());
          x <= (bounds.right / tileSize).floor();
          x++
        ) {
          final key = (x, y);
          if (tiles.containsKey(key)) continue;
          final rect = Rect.fromLTWH(
            x * tileSize,
            y * tileSize,
            tileSize,
            tileSize,
          );
          if (layout.boxes.values.any(
            (box) =>
                box.contains(rect.topLeft) && box.contains(rect.bottomRight),
          )) {
            continue;
          }
          if (tiles.length >= maxTiles) return false;
          tiles[key] = MapLightTile(rect);
        }
      }
    }
    return true;
  }

  void update(double phase) {
    final marks = <(int, int), List<Offset>>{};
    for (final curve in curves) {
      for (var i = 0; i < 3; i++) {
        final point = curve.point((phase + i / 3) % 1);
        // The static scene is now one cache above which the light tiles sit.
        // Hide marks passing through boxes, as when boxes painted over lights.
        if (occluders.any((r) => r.contains(point))) continue;
        if (curve.edge['kind'] != agentLink &&
            cardOccluders.any((r) => r.contains(point))) {
          continue;
        }
        for (
          var y = ((point.dy - radius) / tileSize).floor();
          y <= ((point.dy + radius) / tileSize).floor();
          y++
        ) {
          for (
            var x = ((point.dx - radius) / tileSize).floor();
            x <= ((point.dx + radius) / tileSize).floor();
            x++
          ) {
            final key = (x, y), tile = tiles[key];
            if (tile != null) {
              marks.putIfAbsent(key, () => []).add(point - tile.rect.topLeft);
            }
          }
        }
      }
    }
    for (final key in {..._occupied, ...marks.keys}) {
      tiles[key]!.update(marks[key] ?? const []);
    }
    _occupied = marks.keys.toSet();
  }

  void dispose() {
    for (final tile in tiles.values) {
      tile.dispose();
    }
  }
}

/// Both drawing paths use identical geometry, tiles and clock for comparison.
class MapLightLayer extends StatefulWidget {
  const MapLightLayer({
    super.key,
    required this.layout,
    required this.clock,
    required this.color,
    required this.mode,
    this.style = defaultMapLightStyle,
  });
  final MapLayout layout;
  final ValueListenable<double> clock;
  final Color color;
  final String mode;
  final MapLightStyle style;
  @override
  State<MapLightLayer> createState() => _MapLightLayerState();
}

class _MapLightLayerState extends State<MapLightLayer> {
  late MapLightTiles _tiles;
  ui.Image? _sprite;
  @override
  void initState() {
    super.initState();
    _create();
    widget.clock.addListener(_frame);
  }

  void _create() {
    _tiles = MapLightTiles(widget.layout, widget.mode)
      ..update(widget.clock.value);
    _makeSprite();
  }

  void _makeSprite() {
    _sprite?.dispose();
    _sprite = null;
    if (widget.style != MapLightStyle.sprites) return;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(4);
    canvas.drawCircle(const Offset(4, 4), 3, Paint()..color = widget.color);
    final picture = recorder.endRecording();
    _sprite = picture.toImageSync(32, 32);
    picture.dispose();
  }

  void _frame() => _tiles.update(widget.clock.value);
  @override
  void didUpdateWidget(covariant MapLightLayer old) {
    super.didUpdateWidget(old);
    if (old.clock != widget.clock) {
      old.clock.removeListener(_frame);
      widget.clock.addListener(_frame);
    }
    if (old.layout != widget.layout) {
      _tiles.dispose();
      _create();
    } else {
      _tiles.mode = widget.mode;
      if (old.color != widget.color || old.style != widget.style) _makeSprite();
      _frame();
    }
  }

  @override
  void dispose() {
    widget.clock.removeListener(_frame);
    _tiles.dispose();
    _sprite?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Stack(
      children: [
        for (final tile in _tiles.tiles.values)
          Positioned.fromRect(
            rect: tile.rect,
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _LightTilePaint(tile, widget.color, _sprite),
              ),
            ),
          ),
      ],
    ),
  );
}

class _LightTilePaint extends CustomPainter {
  _LightTilePaint(this.tile, this.color, this.sprite) : super(repaint: tile);
  final MapLightTile tile;
  final Color color;
  final ui.Image? sprite;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final paint = Paint()..color = color;
    for (final mark in tile.marks) {
      if (sprite == null) {
        canvas.drawCircle(mark, 3, paint);
      } else {
        canvas.drawImageRect(
          sprite!,
          const Rect.fromLTWH(0, 0, 32, 32),
          Rect.fromCenter(center: mark, width: 8, height: 8),
          paint..filterQuality = FilterQuality.low,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LightTilePaint old) =>
      tile != old.tile || color != old.color || sprite != old.sprite;
}
