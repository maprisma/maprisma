/// Equality for the bounded JSON snapshots returned by the local service.
/// Map key order is immaterial; list order (including map row order) is not.
bool sameMapJson(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every(
          (key) => b.containsKey(key) && sameMapJson(a[key], b[key]),
        );
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!sameMapJson(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Shared by live scans and the benchmark's synthetic snapshot delivery.
Map<String, dynamic> retainMapSnapshot(
  Map<String, dynamic>? old,
  Map<String, dynamic> next,
) => old != null && sameMapJson(old, next) ? old : next;

Object mapGeometry(Map<String, dynamic> graph) => [
  for (final node in graph['nodes'] as List? ?? [])
    [node['id'], node['column'], node['kind'], node['group']],
  [
    for (final edge in graph['edges'] as List? ?? [])
      [edge['source'], edge['target'], edge['kind']],
  ],
  // A provider's chosen model is drawn: a new choice is a new layout.
  graph['provider_models'] ?? const {},
];

/// Only activity fields visible on a box are part of the static bitmap.
/// Working/activity flags drive the separate light layer.
Object mapAppearance(Map<String, dynamic> graph) => [
  graph['nodes'],
  graph['provider_models'],
  graph['agent_badges'],
  graph['usage_boxes'],
  graph['usage_box_size'],
  {
    for (final entry in (graph['traffic'] as Map? ?? {}).entries)
      if (((entry.value as Map?)?['connections'] as num? ?? 0) > 0)
        entry.key: [
          (entry.value as Map)['connections'],
          (entry.value as Map)['rate_in'],
          (entry.value as Map)['rate_out'],
        ],
  },
  [
    for (final edge in graph['edges'] as List? ?? [])
      {
        for (final key in (edge as Map).keys)
          if (key != 'active' && key != 'activity') key: edge[key],
      },
  ],
  {
    for (final entry in (graph['activity'] as Map? ?? {}).entries)
      if (entry.value['subagents_supported'] == true &&
          (entry.value['children'] as List? ?? []).isNotEmpty)
        entry.key: [
          entry.value['active_subagents'],
          (entry.value['children'] as List).length,
        ],
  },
];
