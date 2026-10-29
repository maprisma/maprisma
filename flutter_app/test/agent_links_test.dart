import 'package:asterism/map_layout.dart';
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
