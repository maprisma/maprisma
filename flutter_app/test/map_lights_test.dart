import 'package:asterism/map_lights.dart';
import 'package:asterism/map_layout.dart';
import 'package:asterism/map_static_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'map_layout_test.dart' show fixtureGraph;

void main() {
  for (final fps in [20, 30, 60]) {
    testWidgets('$fps fps accepts the nearest 60 Hz vsync and stops cleanly', (
      tester,
    ) async {
      final probe = _CountingTickerProvider(tester);
      final clock = MapLightClock(probe, framesPerSecond: fps)
        ..refreshRate = 60;
      var frames = 0;
      clock.addListener(() => frames++);
      clock.enabled = true;
      await tester.pump();
      // A few microseconds early: the old strict guard skipped these paced vsyncs.
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(microseconds: 16665));
      }
      expect(frames, closeTo(fps * 2 + 1, 2));
      expect(probe.frames, lessThanOrEqualTo(fps * 2 + 1));
      clock.enabled = false;
      final count = frames;
      await tester.pump(const Duration(seconds: 2));
      expect(frames, count);
      expect(tester.binding.transientCallbackCount, 0);
      clock.dispose();
    });
  }
  testWidgets(
    'default is 20; a running clock can change rate without retaining old timers',
    (tester) async {
      final clock = MapLightClock(tester);
      expect(clock.framesPerSecond, 20);
      expect(clock.period, const Duration(milliseconds: 50));
      clock.enabled = true;
      await tester.pump();
      clock.framesPerSecond = 60;
      expect(clock.period, const Duration(microseconds: 16667));
      await tester.pump(const Duration(milliseconds: 17));
      expect(() => clock.framesPerSecond = 25, throwsArgumentError);
      expect(clock.framesPerSecond, 60);
      clock.dispose();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);
    },
  );
  test('tiles damage only old and new occupied cells, including erasure', () {
    final tiles = MapLightTiles(
      MapLayout(fixtureGraph(active: true), {}),
      'all',
    );
    final dirty = <MapLightTile>[];
    for (final tile in tiles.tiles.values) {
      tile.addListener(() => dirty.add(tile));
    }
    tiles.update(.1);
    expect(dirty, isNotEmpty);
    final before = tiles.tiles.values.where((t) => t.marks.isNotEmpty).toSet();
    dirty.clear();
    tiles.update(.4);
    final after = tiles.tiles.values.where((t) => t.marks.isNotEmpty).toSet();
    expect(dirty.toSet(), before.union(after));
    for (final old in before.difference(after)) {
      expect(old.marks, isEmpty);
    }
    expect(tiles.tiles.length, lessThan(MapLightTiles.maxTiles));
    expect(tiles.tileSize, 64);
    tiles.dispose();
  });
  test(
    'tiles remain bounded for distant nodes and filter agent-only activity',
    () {
      final graph = fixtureGraph(active: true);
      (graph['edges'] as List).first['activity'] = 'runtime';
      final layout = MapLayout(graph, {
        'cards': {
          '1:agent:': [0, 0],
          '2:runtime:': [29900, 29900],
        },
      });
      final all = MapLightTiles(layout, 'all'),
          agents = MapLightTiles(layout, 'agents');
      expect(all.tiles.length, lessThanOrEqualTo(MapLightTiles.maxTiles));
      expect(agents.curves.length, lessThan(all.curves.length));
      expect(all.tileSize, greaterThan(64));
      all.dispose();
      agents.dispose();
    },
  );
  for (final style in MapLightStyle.values) {
    testWidgets(
      '${style.name} lights repaint tiles without repainting static content',
      (tester) async {
        final clock = ValueNotifier<double>(.1);
        final paints = ValueNotifier<int>(0);
        final controller = TransformationController();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  Positioned.fill(
                    child: MapStaticCache(
                      enabled: true,
                      controller: controller,
                      child: CustomPaint(painter: _StaticCounter(paints)),
                    ),
                  ),
                  Positioned.fill(
                    child: MapLightLayer(
                      layout: MapLayout(fixtureGraph(active: true), {}),
                      clock: clock,
                      color: Colors.red,
                      mode: 'all',
                      style: style,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        final count = paints.value;
        final boundary = find
            .ancestor(
              of: find.byType(MapStaticCache),
              matching: find.byType(Stack),
            )
            .first;
        final rendered = tester.renderObject(boundary);
        for (var i = 0; i < 6; i++) {
          clock.value = (i + .5) / 10;
          await tester.pump();
        }
        expect(paints.value, count);
        // Retained render trees remain mounted while only the light tiles repaint.
        final layer = tester.renderObject(find.byType(MapLightLayer));
        expect(layer.attached, true);
        expect(rendered.attached, true);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        clock.dispose();
        paints.dispose();
        controller.dispose();
      },
    );
  }
  testWidgets(
    'high-DPI cache uses the zoomed pixel budget without changing child metrics',
    (tester) async {
      final controller = TransformationController(
        Matrix4.diagonal3Values(.53, .53, 1),
      );
      const childKey = ValueKey('real-metrics');
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(devicePixelRatio: 2),
            child: OverflowBox(
              minWidth: 1250,
              maxWidth: 1250,
              minHeight: 2110,
              maxHeight: 2110,
              child: MapStaticCache(
                enabled: true,
                controller: controller,
                child: const ColoredBox(key: childKey, color: Colors.blue),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      final snapshot = find.byType(SnapshotWidget);
      expect(
        tester.widget<SnapshotWidget>(snapshot).controller.allowSnapshotting,
        true,
      );
      expect(
        MediaQuery.devicePixelRatioOf(tester.element(snapshot)),
        closeTo(1.06, .001),
      );
      expect(
        MediaQuery.devicePixelRatioOf(tester.element(find.byKey(childKey))),
        2,
      );
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('hover motion retains cache; entering another control thaws it', (
    tester,
  ) async {
    final controller = TransformationController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 200,
            child: MapStaticCache(
              enabled: true,
              controller: controller,
              contentKey: 0,
              child: Row(
                children: [
                  TextButton(onPressed: () {}, child: const Text('First')),
                  TextButton(onPressed: () {}, child: const Text('Second')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final first = tester.getCenter(find.text('First'));
    await mouse.addPointer(location: first);
    await mouse.moveTo(first);
    await tester.pump(const Duration(milliseconds: 500));
    SnapshotController cache() =>
        tester.widget<SnapshotWidget>(find.byType(SnapshotWidget)).controller;
    expect(cache().allowSnapshotting, true);
    for (var i = 0; i < 12; i++) {
      await mouse.moveTo(first + Offset(1 + (i % 2).toDouble(), 0));
      await tester.pump(const Duration(milliseconds: 100));
      expect(cache().allowSnapshotting, true);
    }
    await mouse.moveTo(tester.getCenter(find.text('Second')));
    expect(cache().allowSnapshotting, false);
    await tester.pump(const Duration(milliseconds: 500));
    expect(cache().allowSnapshotting, true);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    expect(tester.takeException(), isNull);
  });
  testWidgets('static texture cache thaws for input, updates and zoom', (
    tester,
  ) async {
    final controller = TransformationController();
    var taps = 0;
    Future<void> mount(String label) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 200,
              child: MapStaticCache(
                enabled: true,
                controller: controller,
                child: TextButton(onPressed: () => taps++, child: Text(label)),
              ),
            ),
          ),
        ),
      );
    }

    await mount('Old');
    await tester.pump(const Duration(milliseconds: 500));
    SnapshotController cache() =>
        tester.widget<SnapshotWidget>(find.byType(SnapshotWidget)).controller;
    expect(cache().allowSnapshotting, true);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Old')),
    );
    expect(cache().allowSnapshotting, false);
    await tester.pump(const Duration(seconds: 1));
    expect(cache().allowSnapshotting, false);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(taps, 1);
    expect(cache().allowSnapshotting, true);
    await mount('New');
    expect(cache().allowSnapshotting, false);
    await tester.pump(const Duration(milliseconds: 500));
    expect(cache().allowSnapshotting, true);
    controller.value = Matrix4.diagonal3Values(2, 2, 1);
    await tester.pump(const Duration(milliseconds: 500));
    expect(cache().allowSnapshotting, false);
    expect(find.text('New'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}

class _StaticCounter extends CustomPainter {
  _StaticCounter(this.count);
  final ValueNotifier<int> count;
  @override
  void paint(Canvas canvas, Size size) {
    count.value++;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.blue);
  }

  @override
  bool shouldRepaint(covariant _StaticCounter old) => false;
}

class _CountingTickerProvider implements TickerProvider {
  _CountingTickerProvider(this.provider);
  final TickerProvider provider;
  int frames = 0;
  @override
  Ticker createTicker(TickerCallback onTick) =>
      provider.createTicker((elapsed) {
        frames++;
        onTick(elapsed);
      });
}
