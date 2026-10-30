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
    'saved layout retains folds and column order, and ignores old free card positions',
    () {
      final graph = {
        ...fixtureGraph(),
        'nodes': [
          ...(fixtureGraph()['nodes'] as List),
          {
            'id': 'skills:s',
            'kind': 'skills',
            'column': 0,
            'label': 'skills:s',
            'detail': '',
          },
        ],
      };
      final l = MapLayout(graph, {
        'cards': {
          '0:mcp:': [500, 300],
          '1:agent:': [40, 300],
        },
      });
      // Old free card coordinates in `cards` are ignored; cards stay in their column.
      expect(l.cards['0:mcp:']!.rect.topLeft, const Offset(16, 144));
      expect(l.cards['1:agent:']!.rect.topLeft, const Offset(318, 144));
      final saved = reorderMapBox(
        l.cards.isEmpty ? {} : {'cards': {}},
        l,
        'agent:b',
        0,
      );
      expect(MapLayout(graph, saved).cards['1:agent:']!.nodes.first, 'agent:b');
      final reordered = reorderMapCard(saved, l, '0:mcp:', 1);
      expect(reordered.containsKey('cards'), false);
      final after = MapLayout(graph, reordered);
      final col0 = [
        for (final c in after.cards.values)
          if (c.column == 0) c.id,
      ];
      expect(col0, ['0:skills:', '0:mcp:']);
      expect(after.cards['0:skills:']!.rect.left, 16);
      expect(after.cards['0:mcp:']!.rect.left, 16);
      expect(
        MapLayout(graph, {}, smartCards: true).cards['1:agent:']!.rect.top,
        156,
      );
      expect((fixtureGraph()['nodes'] as List).length, 7);
    },
  );
}
