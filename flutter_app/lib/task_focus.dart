/// Select one hop from the original seeds, preserving facts and input order.
({Map<String, dynamic> graph, List<String> columns}) focusGraph(
  Map<String, dynamic> graph,
  Iterable<String> ids,
  List<String> columns,
) {
  final nodes = (graph['nodes'] as List? ?? []).cast<Map<String, dynamic>>();
  final edges = (graph['edges'] as List? ?? []).cast<Map<String, dynamic>>();
  final known = nodes.map((n) => n['id']).toSet();
  final seeds = ids.where(known.contains).toSet();
  final selected = <Object?>{...seeds};
  for (final edge in edges) {
    if (seeds.contains(edge['source'])) selected.add(edge['target']);
    if (seeds.contains(edge['target'])) selected.add(edge['source']);
  }
  selected.retainAll(known);
  final kept = nodes.where((n) => selected.contains(n['id'])).toList();
  final used = kept.map((n) => n['column'] as int).toSet().toList()..sort();
  return (
    graph: {
      ...graph,
      'nodes': [
        for (final n in kept)
          {...n, 'column': used.indexOf(n['column'] as int)},
      ],
      'edges': [
        for (final e in edges)
          if (selected.contains(e['source']) && selected.contains(e['target']))
            e,
      ],
    },
    columns: [for (final col in used) columns[col]],
  );
}
