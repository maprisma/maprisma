import 'package:maprisma/map_layout.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> fixtureGraph({bool active = false}) => {
  'nodes': [
    for (final (id, kind, col) in [
      ('agent:a', 'agent', 1),
      ('agent:b', 'agent', 1),
      ('runtime:r', 'runtime', 2),
      ('runtime:s', 'runtime', 2),
      ('model:r:m', 'model', 3),
      ('model:r:n', 'model', 3),
      ('mcp:c', 'mcp', 0),
    ])
      {'id': id, 'kind': kind, 'column': col, 'label': id, 'detail': ''},
  ],
  'edges': [
    {
      'source': 'agent:a',
      'target': 'runtime:r',
      'kind': 'uses',
      'active': active,
      'activity': 'agent',
    },
    {
      'source': 'runtime:r',
      'target': 'model:r:m',
      'kind': 'serves',
      'active': active,
      'activity': 'agent',
    },
    {'source': 'runtime:r', 'target': 'model:r:n', 'kind': 'serves'},
    {'source': 'agent:a', 'target': 'model:r:m', 'kind': 'default'},
  ],
};
void main() {
  test('bezier distance, node and hook hit testing use scene coordinates', () {
    final l = MapLayout(fixtureGraph(), {});
    final curve = l.curves.first;
    expect(curve.distance(curve.point(.45)), lessThan(1));
    expect(l.lineAt(curve.point(.45)), curve);
    expect(l.lineAt(const Offset(20, 30)), isNull);
    expect(l.hookAt(curve.hook, {'agent:a'}), curve);
    expect(l.hookAt(curve.hook, {}), isNull);
    expect(l.nodeAt(l.boxes['agent:a']!.center), 'agent:a');
  });
  test('folding does not change connection semantics', () {
    final l = MapLayout(fixtureGraph(), {
      'collapsed': ['2:runtime:'],
    });
    expect(l.boxes.containsKey('runtime:r'), false);
    expect(l.providerFor('model:r:m'), 'runtime:r');
    expect(l.targetOk('agent:a', 'model:r:n'), true);
    expect(l.targetOk('agent:b', 'model:r:n'), false);
  });
  test(
    'drag targets reject self, unsupported kinds and other provider models',
    () {
      final l = MapLayout(fixtureGraph(), {});
      expect(l.targetOk('agent:a', 'mcp:c'), true);
      expect(l.targetOk('mcp:c', 'agent:a'), true);
      expect(l.targetOk('agent:a', 'agent:a'), false);
      expect(l.targetOk('runtime:s', 'model:r:m'), false);
      expect(
        l.targetOk('agent:a', 'runtime:s', moving: l.curves.first.edge),
        true,
      );
      expect(
        l.targetOk('agent:a', 'mcp:c', moving: l.curves.first.edge),
        false,
      );
    },
  );
  test(
    'saved layout retains folds, order and moves independently of graph',
    () {
      final graph = fixtureGraph(), l = MapLayout(fixtureGraph(), {});
      final saved = reorderMapBox({}, l, 'agent:b', 0);
      expect(MapLayout(graph, saved).cards['1:agent:']!.nodes.first, 'agent:b');
      final moved = moveMapCard(saved, l, '1:agent:', const Offset(40, 300));
      expect(
        MapLayout(graph, moved).cards['1:agent:']!.rect.topLeft,
        const Offset(40, 300),
      );
      expect((graph['nodes'] as List).length, 7);
    },
  );
}
