import 'dart:convert';
import 'package:asterism/map_benchmark.dart';
import 'package:asterism/map_editor.dart';
import 'package:asterism/map_layout.dart';
import 'package:asterism/map_lights.dart';
import 'package:asterism/map_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'map_layout_test.dart' show fixtureGraph;

Map<String, dynamic> copy(Map<String, dynamic> graph) =>
    jsonDecode(jsonEncode(graph)) as Map<String, dynamic>;
String label(String s) => s;
Future<void> edit(Map<String, dynamic> _) async {}
void main() {
  test(
    'equal nested snapshots retain identity; pending transitions are not lost',
    () {
      final graph = fixtureGraph(active: true)..['pending'] = true;
      expect(identical(retainMapSnapshot(graph, copy(graph)), graph), true);
      final done = copy(graph)..['pending'] = false;
      expect(identical(retainMapSnapshot(graph, done), graph), false);
      expect(sameMapJson(mapAppearance(graph), mapAppearance(done)), true);
      expect(
        sameMapJson(
          {
            'a': [
              1,
              {'b': false},
            ],
            'z': null,
          },
          {
            'z': null,
            'a': [
              1,
              {'b': false},
            ],
          },
        ),
        true,
      );
      expect(
        sameMapJson(
          {
            'a': [1, 2],
          },
          {
            'a': [2, 1],
          },
        ),
        false,
      );
    },
  );
  test(
    'metadata refresh keeps boxes and paths; topology edits require new geometry',
    () {
      final graph = fixtureGraph(active: true),
          layout = MapLayout(fixtureGraph(active: true), {});
      final curve = layout.curves.first,
          path = curve.path,
          boxes = layout.boxes;
      (graph['nodes'] as List).first['detail'] = 'Updated';
      (graph['edges'] as List).first['active'] = false;
      expect(layout.updateGraph(graph), true);
      expect(identical(layout.boxes, boxes), true);
      expect(identical(layout.curves.first, curve), true);
      expect(identical(curve.path, path), true);
      expect(layout.nodes['agent:a']!['detail'], 'Updated');
      expect(curve.edge['active'], false);
      final changed = copy(graph);
      (changed['nodes'] as List).first['column'] = 0;
      expect(layout.updateGraph(changed), false);
      expect(layout.nodes['agent:a']!['column'], 1);
    },
  );
  test(
    'benchmark options are bounded and reject unknown or duplicate flags',
    () {
      final o = MapBenchmarkOptions.parse([
        '--map-benchmark-on',
        '--map-benchmark-updates=mixed',
        '--map-benchmark-hover',
        '--map-benchmark-zoom=1.5',
      ]);
      expect(o.updates, 'mixed');
      expect(o.hover, true);
      expect(o.zoom, 1.5);
      for (final options in [
        ['--map-benchmark-bad'],
        ['--map-benchmark-on', '--command=sh'],
        ['--map-benchmark-on', '--map-benchmark-zoom=NaN'],
        ['--map-benchmark-on', '--map-benchmark-zoom=3'],
        [
          '--map-benchmark-on',
          '--map-benchmark-hover',
          '--map-benchmark-hover',
        ],
      ]) {
        expect(() => MapBenchmarkOptions.parse(options), throwsArgumentError);
      }
    },
  );
  testWidgets(
    'activity updates retain layout, tiles, sprite and static cache; visible changes thaw',
    (tester) async {
      final graph = ValueNotifier(fixtureGraph(active: true));
      final editor = ValueListenableBuilder<Map<String, dynamic>>(
        valueListenable: graph,
        builder: (_, g, _) =>
            MapEditor(graph: g, saved: const {}, onEdit: edit, tr: label),
      );
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: editor)));
      await tester.pump(const Duration(milliseconds: 500));
      MapLightLayer lights() =>
          tester.widget<MapLightLayer>(find.byType(MapLightLayer));
      dynamic painter() => tester
          .widget<CustomPaint>(
            find
                .descendant(
                  of: find.byType(MapLightLayer),
                  matching: find.byType(CustomPaint),
                )
                .first,
          )
          .painter;
      SnapshotController cache() =>
          tester.widget<SnapshotWidget>(find.byType(SnapshotWidget)).controller;
      final layout = lights().layout,
          tile = painter().tile,
          sprite = painter().sprite;
      expect(cache().allowSnapshotting, true);
      final activity = copy(graph.value);
      (activity['edges'] as List).first['active'] = false;
      activity['activity'] = {
        'a': {'working': false},
      };
      graph.value = activity;
      await tester.pump();
      expect(identical(lights().layout, layout), true);
      expect(identical(painter().tile, tile), true);
      expect(identical(painter().sprite, sprite), true);
      expect(cache().allowSnapshotting, true);
      final node = copy(activity);
      (node['nodes'] as List).first['detail'] = 'New detail';
      graph.value = node;
      await tester.pump();
      expect(identical(lights().layout, layout), true);
      expect(cache().allowSnapshotting, false);
      expect(find.text('New detail'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      expect(cache().allowSnapshotting, true);
      final badge = copy(node);
      badge['activity'] = {
        'a': {
          'subagents_supported': true,
          'children': [
            {'key': 'child'},
          ],
          'active_subagents': 1,
        },
      };
      graph.value = badge;
      await tester.pump();
      expect(cache().allowSnapshotting, false);
      await tester.pump(const Duration(milliseconds: 500));
      final topology = copy(badge);
      (topology['nodes'] as List).first['column'] = 0;
      graph.value = topology;
      await tester.pump();
      expect(identical(lights().layout, layout), false);
      await tester.pumpWidget(const SizedBox());
      graph.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}
