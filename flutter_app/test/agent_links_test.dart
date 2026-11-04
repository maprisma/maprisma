import 'package:maprisma/map_layout.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _graph({bool working = false}) => {
  'nodes': [
    {'id': 'agent:claude', 'column': 1, 'kind': 'agent', 'label': 'Claude'},
    {'id': 'agent:pi', 'column': 1, 'kind': 'agent', 'label': 'Pi'},
  ],
  'edges': <dynamic>[],
  'activity': {
    'claude': {
      'working': working,
      'uses': ['pi', 'gone'],
    },
    'pi': {'working': false, 'uses': <String>[]},
  },
};

void main() {
  test('activity.uses becomes an arrow between agents on the map', () {
    final graph = withAgentLinks(_graph());
    expect(graph['edges'], [
      {
        'source': 'agent:claude',
        'target': 'agent:pi',
        'kind': agentLink,
        'collab': true,
        'activity': 'agent',
        'active': false,
      },
    ]);
    expect(
      (withAgentLinks(_graph(working: true))['edges'] as List).single['active'],
      isTrue,
    );
    final plain = {..._graph(), 'activity': <String, dynamic>{}};
    expect(identical(withAgentLinks(plain), plain), isTrue);
  });

  test('called agents at every depth tint only their active paths', () {
    final graph = {
      'nodes': [
        for (final id in ['claude', 'pi', 'codex'])
          {'id': 'agent:$id', 'column': 1, 'kind': 'agent', 'label': id},
        {'id': 'runtime:r', 'column': 2, 'kind': 'runtime', 'label': 'r'},
      ],
      'edges': [
        for (final id in ['claude', 'pi', 'codex'])
          {
            'source': 'agent:$id',
            'target': 'runtime:r',
            'kind': 'uses',
            'active': true,
          },
      ],
      'activity': {
        'claude': {
          'working': true,
          'uses': ['pi'],
        },
        'pi': {
          'working': true,
          'uses': ['codex'],
        },
        'codex': {'working': true, 'uses': <String>[]},
      },
    };
    final edges = (withAgentLinks(graph)['edges'] as List).cast<Map>();
    expect(edges.where((e) => e['kind'] == agentLink).length, 2);
    expect(
      edges
          .where((e) => e['source'] == 'agent:claude' && e['kind'] == 'uses')
          .single['collab'],
      isNull,
    );
    for (final id in ['pi', 'codex']) {
      expect(
        edges
            .where((e) => e['source'] == 'agent:$id' && e['kind'] == 'uses')
            .single['collab'],
        true,
      );
    }
  });

  test('the arrow bends to the right and cannot be picked or moved', () {
    final layout = MapLayout(withAgentLinks(_graph()), const {});
    final curve = layout.curves.single;
    final a = layout.boxes['agent:claude']!, b = layout.boxes['agent:pi']!;
    expect(curve.start, Offset(a.right, a.center.dy));
    expect(curve.end, Offset(b.right, b.center.dy));
    expect(curve.middle, greaterThan(a.right));
    expect(layout.lineAt(curve.point(.5), tolerance: 50), isNull);
    expect(layout.movable(curve.edge), isFalse);
  });
}
