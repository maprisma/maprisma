import 'dart:math' as math;
import 'package:flutter/painting.dart';
import 'map_snapshot.dart';

const mapBoxWidth = 242.0, mapBoxHeight = 128.0, mapRowStep = 146.0;
String edgeKey(Map<String, dynamic> e) =>
    '${e['source']}|${e['target']}|${e['kind']}';

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
  MapCurve(this.edge, this.start, this.end);
  Map<String, dynamic> edge;
  final Offset start, end;
  double get middle => (start.dx + end.dx) / 2;
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
    double top = 144,
  }) {
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
      final xy = (saved['cards'] as Map?)?[id] as List?;
      final origin = xy == null
          ? Offset(16 + column * 302, heights[column] ?? top)
          : Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
      final height = folded ? 38.0 : 48 + ids.length * mapRowStep;
      final rect = origin & Size(266, height);
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
      heights[column] = math.max(heights[column] ?? top, rect.bottom + 18);
      if (!folded) {
        for (var i = 0; i < ids.length; i++) {
          boxes[ids[i]] = Rect.fromLTWH(
            origin.dx + 12,
            origin.dy + 38 + i * mapRowStep,
            mapBoxWidth,
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
  Size get size => Size(
    math.max(
      1250,
      cards.values.fold<double>(0, (v, c) => math.max(v, c.rect.right)) + 48,
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

Map<String, dynamic> moveMapCard(
  Map<String, dynamic> saved,
  MapLayout layout,
  String id,
  Offset position,
) {
  final positions = <String, dynamic>{...?saved['cards'] as Map?};
  final card = layout.cards[id]!;
  var rect = Rect.fromLTWH(
    position.dx.clamp(0, 29000),
    position.dy.clamp(120, 29000),
    card.rect.width,
    card.rect.height,
  );
  positions[id] = [rect.left, rect.top];
  final placed = <Rect>[rect];
  final others = layout.cards.values.where((c) => c.id != id).toList()
    ..sort((a, b) => a.rect.top.compareTo(b.rect.top));
  for (final other in others) {
    var candidate = other.rect;
    while (placed.any((r) => r.inflate(8).overlaps(candidate))) {
      final bottom =
          placed
              .where((r) => r.inflate(8).overlaps(candidate))
              .map((r) => r.bottom)
              .reduce(math.max) +
          18;
      if (bottom > 30000) return saved;
      candidate = Rect.fromLTWH(
        candidate.left,
        bottom,
        candidate.width,
        candidate.height,
      );
    }
    placed.add(candidate);
    if (candidate != other.rect) {
      positions[other.id] = [candidate.left, candidate.top];
    }
  }
  return {...saved, 'cards': positions};
}
