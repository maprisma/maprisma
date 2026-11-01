import 'dart:math' as math;
import 'package:flutter/painting.dart';
import 'map_snapshot.dart';

const mapBoxWidth = 242.0, mapBoxHeight = 128.0, mapRowStep = 146.0;
String edgeKey(Map<String, dynamic> e) =>
    '${e['source']}|${e['target']}|${e['kind']}';

/// subagents.agents_using_agents on the map: an agent that started another
/// one and uses it (activity.uses), an arrow from the first to the second,
/// lit while either works. Drawn only, never edited.
const agentLink = 'agent-link';

Map<String, dynamic> withAgentLinks(Map<String, dynamic> graph) {
  final activity = (graph['activity'] as Map?) ?? const {};
  final nodes = {
    for (final n in (graph['nodes'] as List? ?? const []).cast<Map>()) n['id'],
  };
  final links = <Map<String, dynamic>>[
    for (final e in activity.entries)
      for (final used in ((e.value as Map?)?['uses'] as List? ?? const []))
        if (nodes.contains('agent:${e.key}') && nodes.contains('agent:$used'))
          {
            'source': 'agent:${e.key}',
            'target': 'agent:$used',
            'kind': agentLink,
            'activity': 'agent',
            'active':
                (e.value as Map)['working'] == true ||
                (activity[used] as Map?)?['working'] == true,
          },
  ];
  if (links.isEmpty) return graph;
  return {
    ...graph,
    'edges': [...(graph['edges'] as List? ?? const []), ...links],
  };
}

class MapCardLayout {
  MapCardLayout(
    this.id,
    this.column,
    this.label,
    this.rect,
    this.nodes,
    this.folded,
  );
  final String id, label;
  final int column;
  final Rect rect;
  final List<String> nodes;
  final bool folded;
}

class MapCurve {
  MapCurve(this.edge, this.start, this.end, {this.side});
  Map<String, dynamic> edge;
  final Offset start, end;

  /// For two boxes of one column: how far right the bend goes.
  final double? side;
  double get middle => side ?? (start.dx + end.dx) / 2;
  Offset point(double t) {
    final u = 1 - t;
    return Offset(
      u * u * u * start.dx +
          3 * u * u * t * middle +
          3 * u * t * t * middle +
          t * t * t * end.dx,
      u * u * u * start.dy +
          3 * u * u * t * start.dy +
          3 * u * t * t * end.dy +
          t * t * t * end.dy,
    );
  }

  Offset get hook => point(.91);
  late final Path path = Path()
    ..moveTo(start.dx, start.dy)
    ..cubicTo(middle, start.dy, middle, end.dy, end.dx, end.dy);
  double distance(Offset point) {
    var best = double.infinity;
    var a = start;
    for (var i = 1; i <= 32; i++) {
      final b = this.point(i / 32), delta = b - a;
      final length = delta.dx * delta.dx + delta.dy * delta.dy;
      final t = length == 0
          ? 0.0
          : (((point - a).dx * delta.dx + (point - a).dy * delta.dy) / length)
                .clamp(0.0, 1.0);
      best = math.min(best, (point - (a + delta * t)).distance);
      a = b;
    }
    return best;
  }
}

class MapLayout {
  MapLayout(
    Map<String, dynamic> graph,
    Map<String, dynamic> saved, {
    double? top,
    bool smartCards = false,
    List<int>? columns,
    double viewportWidth = 0,
    double? centerWidth,
  }) {
    _columns = columns;
    // The shown columns sit in the middle of a wider window and grow to fill
    // the free space (column width 266..360, gap about 12% of the width, as far
    // as the columns' minimum leaves room).
    final count = columns?.length ?? 4;
    final minNatural = 32.0 + count * 266.0 + math.max(0, count - 1) * 36.0;
    if (count == 0 || viewportWidth <= minNatural) {
      columnGap = 36.0;
      columnWidth = 266.0;
    } else {
      final room = count > 1
          ? (viewportWidth - 32.0 - count * 266.0) / (count - 1)
          : 240.0;
      var gap = math
          .min(viewportWidth * 0.12, room)
          .floorToDouble()
          .clamp(36.0, 240.0);
      columnWidth = ((viewportWidth - 32.0 - (count - 1) * gap) / count)
          .floorToDouble()
          .clamp(266.0, 360.0);
      // Fewer columns: what the cards leave goes into the gaps, so that the
      // lines between them stay readable.
      if (count > 1) {
        final free =
            viewportWidth - 32.0 - count * columnWidth - (count - 1) * gap;
        if (free > 0) {
          gap = math
              .min(gap + free / (count - 1), math.max(gap, viewportWidth * 0.3))
              .floorToDouble();
        }
      }
      columnGap = gap;
    }
    boxWidth = columnWidth - 24.0;
    final natural =
        32.0 + count * columnWidth + math.max(0, count - 1) * columnGap;
    final span = centerWidth ?? viewportWidth;
    _inset = count == 0 || span <= natural
        ? 0
        : ((span - natural) / 2).floorToDouble();
    _sized = count > 0 && (viewportWidth >= minNatural || _inset > 0);
    final startTop = top ?? (smartCards ? 156.0 : 106.0);
    _geometry = mapGeometry(graph);
    for (final node
        in (graph['nodes'] as List? ?? []).cast<Map<String, dynamic>>()) {
      nodes[node['id'] as String] = node;
    }
    final grouped = <String, List<String>>{};
    for (final node in nodes.values) {
      final id = '${node['column']}:${node['kind']}:${node['group'] ?? ''}';
      grouped.putIfAbsent(id, () => []).add(node['id'] as String);
      cardOf[node['id'] as String] = id;
    }
    final cardOrder = (saved['card_order'] as List? ?? []).cast<String>();
    final keys = grouped.keys.toList()
      ..sort((a, b) {
        final col = (nodes[grouped[a]!.first]!['column'] as int).compareTo(
          nodes[grouped[b]!.first]!['column'] as int,
        );
        if (col != 0) return col;
        final ai = cardOrder.indexOf(a), bi = cardOrder.indexOf(b);
        return (ai < 0 ? 10000 : ai).compareTo(bi < 0 ? 10000 : bi);
      });
    final heights = <int, double>{};
    for (final id in keys) {
      final ids = grouped[id]!;
      final order = ((saved['order'] as Map?)?[id] as List? ?? [])
          .cast<String>();
      final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
      ids.sort((a, b) => (rank[a] ?? 10000).compareTo(rank[b] ?? 10000));
      final column = nodes[ids.first]!['column'] as int;
      final folded = (saved['collapsed'] as List? ?? []).contains(id);
      final origin = Offset(columnX(column), heights[column] ?? startTop);
      final height = folded ? 38.0 : 32 + ids.length * mapRowStep;
      final rect = origin & Size(columnWidth, height);
      final first = nodes[ids.first]!;
      const labels = {
        'agent': 'Agents',
        'runtime': 'Providers',
        'cloud': 'Online',
        'model': 'Models',
        'mcp': 'MCP servers',
        'skills': 'Skills',
      };
      cards[id] = MapCardLayout(
        id,
        column,
        (first['group'] as String? ?? '').isNotEmpty
            ? first['group'] as String
            : labels[first['kind']] ?? first['kind'] as String,
        rect,
        ids,
        folded,
      );
      heights[column] = math.max(heights[column] ?? startTop, rect.bottom + 18);
      if (!folded) {
        for (var i = 0; i < ids.length; i++) {
          boxes[ids[i]] = Rect.fromLTWH(
            origin.dx + 12,
            origin.dy + 38 + i * mapRowStep,
            boxWidth,
            mapBoxHeight,
          );
        }
      }
    }
    allEdges.addAll(
      (graph['edges'] as List? ?? []).cast<Map<String, dynamic>>(),
    );
    for (final e in allEdges) {
      final a = boxes[e['source']], b = boxes[e['target']];
      if (a == null || b == null) continue;
      if (e['kind'] == agentLink) {
        // Both agents in one column: a bend on the right of their boxes.
        curves.add(
          MapCurve(
            e,
            Offset(a.right, a.center.dy),
            Offset(b.right, b.center.dy),
            side: math.max(a.right, b.right) + 22,
          ),
        );
        continue;
      }
      final forward = a.center.dx <= b.center.dx;
      curves.add(
        MapCurve(
          e,
          Offset(forward ? a.right : a.left, a.center.dy),
          Offset(forward ? b.left : b.right, b.center.dy),
        ),
      );
    }
  }
  late final Object _geometry;

  /// Refresh metadata without losing boxes, curves or their cached paths.
  bool updateGraph(Map<String, dynamic> graph) {
    if (!sameMapJson(_geometry, mapGeometry(graph))) return false;
    nodes
      ..clear()
      ..addEntries(
        (graph['nodes'] as List).cast<Map<String, dynamic>>().map(
          (n) => MapEntry(n['id'] as String, n),
        ),
      );
    allEdges
      ..clear()
      ..addAll((graph['edges'] as List).cast<Map<String, dynamic>>());
    final edges = {for (final e in allEdges) edgeKey(e): e};
    for (final curve in curves) {
      curve.edge = edges[edgeKey(curve.edge)]!;
    }
    return true;
  }

  final nodes = <String, Map<String, dynamic>>{}, cardOf = <String, String>{};
  final boxes = <String, Rect>{}, cards = <String, MapCardLayout>{};
  final curves = <MapCurve>[];
  final allEdges = <Map<String, dynamic>>[];

  /// The columns shown, in order (null: all); hidden ones leave no gap.
  List<int>? _columns;
  late final double columnWidth, columnGap, boxWidth;
  double _inset = 0;
  bool _sized = false;
  double columnX(int column) {
    final slot = _columns?.indexOf(column) ?? -1;
    return _inset + 16 + (slot < 0 ? column : slot) * (columnWidth + columnGap);
  }

  Size get size => Size(
    math.max(
      switch (_columns) {
        [] => 0,
        null || [_, _, _, _] when !_sized => 1250,
        final shown =>
          columnX(shown == null ? 3 : shown.last) +
              columnWidth +
              (_sized ? 16 : 48),
      },
      cards.values.fold<double>(0, (v, c) => math.max(v, c.rect.right)) +
          (_sized ? 16 : 48),
    ),
    math.max(
      650,
      cards.values.fold<double>(0, (v, c) => math.max(v, c.rect.bottom)) + 48,
    ),
  );
  String? nodeAt(Offset point) => boxes.entries
      .where((e) => e.value.contains(point))
      .map((e) => e.key)
      .firstOrNull;
  MapCurve? lineAt(Offset point, {double tolerance = 9}) {
    MapCurve? result;
    var distance = tolerance;
    for (final curve in curves) {
      if (curve.edge['kind'] == agentLink) continue; // shown, never edited
      final d = curve.distance(point);
      if (d < distance) {
        result = curve;
        distance = d;
      }
    }
    return result;
  }

  MapCurve? hookAt(Offset point, Set<String> selected) => curves
      .where(
        (c) =>
            movable(c.edge) &&
            (selected.contains(c.edge['source']) ||
                selected.contains(c.edge['target'])) &&
            (c.hook - point).distance <= 12,
      )
      .firstOrNull;
  bool movable(Map<String, dynamic> edge) =>
      nodes[edge['source']]?['kind'] == 'agent' &&
          [
            'uses',
            'available',
            'mcp',
            'skills',
            'failed',
            'default',
          ].contains(edge['kind']) ||
      ['runtime', 'cloud'].contains(nodes[edge['source']]?['kind']) &&
          edge['kind'] == 'serves';
  String? providerFor(String model) => allEdges
      .where((e) => e['kind'] == 'serves' && e['target'] == model)
      .map((e) => e['source'] as String)
      .firstOrNull;
  bool connected(String agent, String provider) => allEdges.any(
    (e) =>
        e['source'] == agent &&
        e['target'] == provider &&
        ['uses', 'available', 'offer'].contains(e['kind']),
  );
  bool targetOk(String source, String target, {Map<String, dynamic>? moving}) {
    final a = nodes[source], b = nodes[target];
    if (a == null ||
        b == null ||
        source == target ||
        b['status'] == 'missing') {
      return false;
    }
    if (moving != null) {
      final old = nodes[moving['target']];
      if (target == moving['target']) return false;
      if (a['kind'] == 'agent' && old?['kind'] == 'runtime') {
        return b['kind'] == 'runtime';
      }
      if (old?['kind'] == 'model') {
        return b['kind'] == 'model' &&
            providerFor(target) == providerFor(moving['target'] as String);
      }
      return false;
    }
    if (a['kind'] == 'agent' &&
        ['mcp', 'skills', 'runtime', 'cloud'].contains(b['kind'])) {
      return true;
    }
    if (b['kind'] == 'agent' &&
        ['mcp', 'skills', 'runtime', 'cloud'].contains(a['kind'])) {
      return a['status'] != 'missing';
    }
    if (['runtime', 'cloud'].contains(a['kind']) && b['kind'] == 'model') {
      return providerFor(target) == source;
    }
    final agent = a['kind'] == 'agent'
        ? source
        : b['kind'] == 'agent'
        ? target
        : null;
    final model = a['kind'] == 'model'
        ? source
        : b['kind'] == 'model'
        ? target
        : null;
    return agent != null &&
        model != null &&
        providerFor(model) != null &&
        connected(agent, providerFor(model)!);
  }

  (int, Rect) cardDrop(String id, double y) {
    final card = cards[id]!;
    final colCards = [
      for (final c in cards.values)
        if (c.column == card.column) c,
    ];
    final current = colCards.indexOf(card);
    final index = [
      for (final other in colCards)
        if (other.id != id &&
            (other.rect.top < card.rect.top
                ? y >= other.rect.bottom
                : y > other.rect.top))
          other,
    ].length;
    final lineY = index > current
        ? colCards[index].rect.bottom + 9
        : colCards[index].rect.top - 9;
    return (
      index,
      Rect.fromLTWH(card.rect.left, lineY - 1, card.rect.width, 2),
    );
  }
}

Map<String, dynamic> reorderMapBox(
  Map<String, dynamic> saved,
  MapLayout layout,
  String id,
  int index,
) {
  final card = layout.cardOf[id]!;
  final ids = [...layout.cards[card]!.nodes]..remove(id);
  ids.insert(index.clamp(0, ids.length), id);
  return {
    ...saved,
    'order': {...?saved['order'] as Map?, card: ids},
  };
}

Map<String, dynamic> reorderMapCard(
  Map<String, dynamic> saved,
  MapLayout layout,
  String id,
  int index,
) {
  final card = layout.cards[id]!;
  final colCards = [
    for (final c in layout.cards.values)
      if (c.column == card.column && c.id != id) c.id,
  ];
  colCards.insert(index.clamp(0, colCards.length), id);
  return {
    for (final e in saved.entries)
      if (e.key != 'cards') e.key: e.value,
    'card_order': [
      // A hidden column's cards are not in the layout: keep their order.
      for (final c in saved['card_order'] as List? ?? const [])
        if (!layout.cards.containsKey(c)) c,
      for (final c in layout.cards.values)
        if (c.column != card.column) c.id,
      ...colCards,
    ],
  };
}
