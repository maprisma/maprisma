import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/agent_map.dart';
import 'package:maprisma/map_3d.dart';
import 'package:maprisma/map_editor.dart';
import 'package:maprisma/map_groups.dart';
import 'package:maprisma/map_lights.dart';

import 'map_layout_test.dart' show fixtureGraph;

class _RecordingCanvas implements Canvas {
  int paths = 0;
  int lines = 0;
  int circles = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final m = invocation.memberName;
    if (m == #drawPath) paths++;
    if (m == #drawLine) lines++;
    if (m == #drawCircle) circles++;
    return null;
  }
}

void main() {
  test('map3dEnabled defaults to true and respects three_d: false', () {
    expect(map3dEnabled(null), isTrue);
    expect(map3dEnabled(const {}), isTrue);
    expect(map3dEnabled(const {'three_d': true}), isTrue);
    expect(map3dEnabled(const {'three_d': false}), isFalse);
  });

  test(
    'map3dColumnDepth tiers Agents proudest above Providers and outer columns',
    () {
      final mcp = map3dColumnDepth(0);
      final agents = map3dColumnDepth(1);
      final providers = map3dColumnDepth(2);
      final models = map3dColumnDepth(3);
      expect(agents.distance, greaterThan(providers.distance));
      expect(providers.distance, greaterThan(mcp.distance));
      expect(mcp, models);
    },
  );

  test(
    'extrudedMapWalls produces bounded non-empty paths for rounded and square corners',
    () {
      const rect = Rect.fromLTWH(20, 40, 240, 88);
      const depth = Offset(5, 7);

      final rounded = extrudedMapWalls(rect, 12, depth);
      expect(rounded.rightWall.getBounds().isEmpty, isFalse);
      expect(rounded.bottomWall.getBounds().isEmpty, isFalse);
      expect(
        rounded.rightWall.getBounds().right,
        closeTo(rect.right + depth.dx, 0.5),
      );
      expect(
        rounded.bottomWall.getBounds().bottom,
        closeTo(rect.bottom + depth.dy, 0.5),
      );

      final square = extrudedMapWalls(rect, 0, depth);
      expect(
        square.rightWall.getBounds(),
        const Rect.fromLTRB(260, 40, 265, 135),
      );
      expect(
        square.bottomWall.getBounds(),
        const Rect.fromLTRB(20, 128, 265, 135),
      );
      expect(square.creaseStart, const Offset(260, 128));
      expect(square.creaseEnd, const Offset(265, 135));
    },
  );

  testWidgets(
    'MapEditor toggles between 3D layout and flat map while staying interactive',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final graph = fixtureGraph(active: true);
      final groups = MapGroup.fromGraph(graph, const [
        'MCP servers and skills',
        'Agents',
        'Providers',
        'Models',
      ]);
      final edits = <Map<String, dynamic>>[];

      CustomPainter mapPainter() => tester
          .widget<CustomPaint>(
            find.byWidgetPredicate(
              (w) =>
                  w is CustomPaint &&
                  w.painter.runtimeType.toString() == '_MapPaint',
            ),
          )
          .painter!;

      ui.Image? lightSprite() =>
          (tester
                          .widget<CustomPaint>(
                            find
                                .descendant(
                                  of: find.byType(MapLightLayer),
                                  matching: find.byType(CustomPaint),
                                )
                                .first,
                          )
                          .painter
                      as dynamic)
                  .sprite
              as ui.Image?;

      Widget buildEditor(Map<String, dynamic> saved) => MaterialApp(
        home: Scaffold(
          body: MapEditor(
            graph: graph,
            saved: saved,
            groups: groups,
            onEdit: (e) async => edits.add(e),
            tr: (s) => s,
          ),
        ),
      );

      // Default (three_d unset): 3D stage, walls, cables, blocks and 48x48 orb sprite.
      await tester.pumpWidget(buildEditor(const {}));
      await tester.pump();

      final canvas3d = _RecordingCanvas();
      mapPainter().paint(canvas3d, const Size(1600, 900));
      expect(
        canvas3d.lines,
        greaterThan(10),
      ); // 3D stage perspective grid + wall creases
      expect(canvas3d.circles, greaterThan(0)); // 3D cable socket ports
      expect(lightSprite()?.width, 48);
      expect(
        find
            .descendant(
              of: find.byType(Map3dBlock),
              matching: find.byType(CustomPaint),
            )
            .evaluate()
            .where(
              (e) =>
                  (e.widget as CustomPaint).painter.runtimeType.toString() ==
                  '_Map3dBlockBackPainter',
            ),
        isNotEmpty,
      );

      // Box selection and connection gestures stay pixel-accurate in 3D mode.
      await tester.tap(find.text('agent:b'));
      await tester.pump();
      final drag = await tester.startGesture(
        tester.getCenter(find.text('agent:b')),
      );
      await drag.moveTo(tester.getCenter(find.text('runtime:s')));
      await tester.pump();
      await drag.up();
      await tester.pump();
      expect(edits, isNotEmpty);

      // Disabled (three_d: false): flat map without stage grid, sockets or 3D block painters.
      await tester.pumpWidget(buildEditor(const {'three_d': false}));
      await tester.pump();

      final canvasFlat = _RecordingCanvas();
      mapPainter().paint(canvasFlat, const Size(1600, 900));
      expect(canvasFlat.lines, 0);
      expect(canvasFlat.circles, 0);
      expect(canvasFlat.paths, lessThan(canvas3d.paths));
      expect(lightSprite()?.width, 32);
      expect(
        find
            .descendant(
              of: find.byType(Map3dBlock),
              matching: find.byType(CustomPaint),
            )
            .evaluate()
            .where(
              (e) =>
                  (e.widget as CustomPaint).painter.runtimeType.toString() ==
                  '_Map3dBlockBackPainter',
            ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('AgentMap read-only board honors savedLayout three_d setting', (
    tester,
  ) async {
    final graph = fixtureGraph();
    Widget board(Map<String, dynamic> saved) => MaterialApp(
      home: Scaffold(
        body: AgentMap(
          graph: graph,
          savedLayout: saved,
          onAgent: (_) {},
          tr: (s) => s,
        ),
      ),
    );

    await tester.pumpWidget(board(const {}));
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is CustomPaint &&
            w.painter.runtimeType.toString() == '_Map3dBlockBackPainter',
      ),
      findsWidgets,
    );

    await tester.pumpWidget(board(const {'three_d': false}));
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is CustomPaint &&
            w.painter.runtimeType.toString() == '_Map3dBlockBackPainter',
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
