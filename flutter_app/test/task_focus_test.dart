import 'package:maprisma/task_focus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final graph = <String, dynamic>{
    'nodes': [
      {'id': 'a', 'column': 1, 'label': 'Agent'},
      {'id': 'r', 'column': 2, 'label': 'Runtime'},
      {'id': 'm', 'column': 3, 'label': 'Model'},
      {'id': 's', 'column': 0, 'label': 'Server'},
    ],
    'edges': [
      {'source': 'a', 'target': 'r', 'kind': 'uses'},
      {'source': 'r', 'target': 'm', 'kind': 'serves'},
      {'source': 's', 'target': 'a', 'kind': 'mcp'},
    ],
  };
  const columns = ['Servers', 'Agents', 'Providers', 'Models'];
  test(
    'one hop only, in either direction, keeps facts and compacts columns',
    () {
      final focused = focusGraph(graph, ['r', 'unknown'], columns);
      expect((focused.graph['nodes'] as List).map((n) => n['id']), [
        'a',
        'r',
        'm',
      ]);
      expect((focused.graph['nodes'] as List).map((n) => n['column']), [
        0,
        1,
        2,
      ]);
      expect(focused.columns, ['Agents', 'Providers', 'Models']);
      expect(focused.graph['edges'], (graph['edges'] as List).take(2).toList());
      expect((graph['nodes'] as List).first['column'], 1);
    },
  );
  test('unknown and empty ids return an empty graph', () {
    for (final ids in [
      <String>[],
      ['missing'],
    ]) {
      final result = focusGraph(graph, ids, columns);
      expect(result.graph['nodes'], isEmpty);
      expect(result.graph['edges'], isEmpty);
      expect(result.columns, isEmpty);
    }
  });
  test('selection does not follow edges of newly included neighbours', () {
    final result = focusGraph(graph, ['s'], columns);
    expect((result.graph['nodes'] as List).map((n) => n['id']), ['a', 's']);
    expect(result.columns, ['Servers', 'Agents']);
  });
}
