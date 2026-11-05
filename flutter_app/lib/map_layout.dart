import 'dart:math' as math;

import 'package:flutter/material.dart' show ColorScheme;
import 'package:flutter/painting.dart';

import 'map_snapshot.dart';

/// The saved layout's names for the four columns, in order.
const mapColumnKeys = ['mcp', 'agents', 'providers', 'models'];
const mapColumnMinWidth = 200.0, mapColumnMaxWidth = 900.0;

/// The theme's colours a user can choose, as saved: `theme:<name>`.
const mapThemeColors = ['primary', 'secondary', 'tertiary', 'outline'];

/// A saved `#rrggbb` or `theme:<name>`; null for none or a broken one.
Color? mapColor(String? value, ColorScheme colors) {
  if (value != null && value.startsWith('theme:')) {
    return switch (value.substring(6)) {
      'primary' => colors.primary,
      'secondary' => colors.secondary,
      'tertiary' => colors.tertiary,
      'outline' => colors.outline,
      _ => null,
    };
  }
  final number = int.tryParse(value?.replaceFirst('#', '') ?? '', radix: 16);
  return number == null ? null : Color(0xFF000000 | number);
}

/// Keep collaboration paths distinct from the theme's normal active paths.
/// The hue stays well away from the error colour, which is reserved for broken
/// connections: with a blue primary a fixed offset would land on red.
Color mapCollaborationColor(ColorScheme colors) {
  final primary = HSLColor.fromColor(colors.primary);
  final error = HSLColor.fromColor(colors.error).hue;
  double apart(double a, double b) {
    final d = (a - b).abs() % 360;
    return math.min(d, 360 - d);
  }

  var hue = (primary.hue + 145) % 360;
  for (final offset in const [145.0, 180.0, -145.0, 110.0, -110.0]) {
    final candidate = (primary.hue + offset) % 360;
    if (apart(candidate, error) >= 45) {
      hue = candidate;
      break;
    }
  }
  return primary
      .withHue(hue)
      .withSaturation(math.max(primary.saturation, .65))
      .toColor();
}

/// Which line a colour of Settings › Map is for.
String? mapLineKind(String kind) => switch (kind) {
  'uses' || 'available' => 'provider',
  'default' || 'live' => 'model',
  'serves' => 'serves',
  'mcp' => 'mcp',
  'skills' => 'skills',
  _ => null,
};

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
  final called = <String>{};
  void visit(String command, Set<String> path) {
    if (!path.add(command)) return;
    for (final used
        in ((activity[command] as Map?)?['uses'] as List? ?? const [])) {
      if (nodes.contains('agent:$used')) {
        called.add('$used');
        visit('$used', path);
      }
    }
    path.remove(command);
  }

  for (final command in activity.keys) {
    visit('$command', <String>{});
  }
  final links = <Map<String, dynamic>>[
    for (final e in activity.entries)
      for (final used in ((e.value as Map?)?['uses'] as List? ?? const []))
        if (nodes.contains('agent:${e.key}') && nodes.contains('agent:$used'))
          {
            'source': 'agent:${e.key}',
            'target': 'agent:$used',
            'kind': agentLink,
            'collab': true,
            'activity': 'agent',
            'active':
                (e.value as Map)['working'] == true ||
                (activity[used] as Map?)?['working'] == true,
          },
  ];
  if (links.isEmpty) return graph;
  final calledModels = {
    for (final e in graph['edges'] as List? ?? const [])
      if (e is Map &&
          e['kind'] == 'default' &&
          e['active'] == true &&
          '${e['source']}'.startsWith('agent:') &&
          called.contains('${e['source']}'.substring(6)))
        e['target'],
  };
  return {
    ...graph,
    'edges': [
      for (final e in graph['edges'] as List? ?? const [])
        if (e is Map &&
            e['active'] == true &&
            ('${e['source']}'.startsWith('agent:') &&
                    called.contains('${e['source']}'.substring(6)) ||
                // The called agent's model is drawn from its provider: that
                // step of the chain takes the collaboration colour too.
                e['kind'] == 'serves' && calledModels.contains(e['target'])))
          // Typed: the layout casts every edge to Map<String, dynamic>; an
          // untyped literal here blanked the whole map (0.13.0).
          <String, dynamic>{...e, 'collab': true}
        else
          e,
      ...links,
    ],
  };
}

class MapCardLayout {
  MapCardLayout(
    this.id,
    this.column,
    this.label,
    this.rect,
    this.nodes,
    this.folded, {
    List<String>? all,
  }) : all = all ?? nodes;
  final String id, label;

  /// Every box of the card, also those a used-only card leaves out.
  final List<String> all;
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
    _providerModelsRaw = graph['provider_models'] as Map?;
    bordered = (saved['card_border'] as Map?)?['on'] == true;

    // The shown columns sit in the middle of a wider window and grow to fill
    // the free space (column width 266..360). What the columns leave is shared
    // out evenly: the same gap left of the first column, between the columns
    // and right of the last one.
    final count = columns?.length ?? 4;
    final shownColumns = columns ?? const [0, 1, 2, 3];
    final minNatural = 32.0 + count * 266.0 + math.max(0, count - 1) * 36.0;
    final wide = count > 0 && viewportWidth > minNatural;
    // The gap between two columns never drops below this, so that the lines
    // and their hooks keep room; what is left beyond it goes to the edges.
    var least = 36.0;
    if (!wide) {
      columnWidth = 266.0;
    } else {
      final room = count > 1
          ? (viewportWidth - 32.0 - count * 266.0) / (count - 1)
          : 240.0;
      final gap = math
          .min(viewportWidth * 0.12, room)
          .floorToDouble()
          .clamp(36.0, 240.0);
      columnWidth = ((viewportWidth - 32.0 - (count - 1) * gap) / count)
          .floorToDouble()
          .clamp(266.0, 360.0);
      least = math.min(gap, 140.0);
    }
    boxWidth = columnWidth - 24.0;
    // A width set by the user, else its default, else the automatic one.
    final current = saved['column_widths'] as Map? ?? const {};
    final defaults = saved['column_defaults'] as Map? ?? const {};
    for (var i = 0; i < mapColumnKeys.length; i++) {
      final width =
          (current[mapColumnKeys[i]] ?? defaults[mapColumnKeys[i]]) as num?;
      if (width != null) {
        _widths[i] = width.toDouble().clamp(
          mapColumnMinWidth,
          mapColumnMaxWidth,
        );
      }
    }
    final widths = shownColumns.fold<double>(
      0,
      (sum, c) => sum + columnWidthOf(c),
    );
    columnGap = wide
        ? math.max(
            least,
            ((viewportWidth - widths) / (count + 1)).floorToDouble(),
          )
        : 36.0;
    final natural = 32.0 + widths + math.max(0, count - 1) * columnGap;
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
    // A card set to "only what is used" leaves out boxes with no line.
    final usedOnly = {
      ...(saved['used_only'] as List? ?? const []).cast<String>(),
    };
    final linked = <String>{
      // Only real connections: a model merely present in a provider's folder
      // or catalog ("serves") does not count, nor does an offer; a
      // provider's chosen model does.
      for (final e in (graph['edges'] as List? ?? []).cast<Map>())
        if (e['kind'] != 'offer' &&
            (e['kind'] != 'serves' ||
                (graph['provider_models'] as Map?)?[e['source']] ==
                    e['target'])) ...[
          '${e['source']}',
          '${e['target']}',
        ],
      ...(saved['pins'] as List? ?? const []).cast<String>(),
    };
    for (final id in keys) {
      final order = ((saved['order'] as Map?)?[id] as List? ?? [])
          .cast<String>();
      final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
      final full = [...grouped[id]!]
        ..sort((a, b) => (rank[a] ?? 10000).compareTo(rank[b] ?? 10000));
      final ids = usedOnly.contains(id)
          ? full.where(linked.contains).toList()
          : full;
      final column = nodes[grouped[id]!.first]!['column'] as int;
      final folded = (saved['collapsed'] as List? ?? []).contains(id);
      final origin = Offset(columnX(column), heights[column] ?? startTop);
      // An empty card is as tall as a folded one: its header still fits.
      final height = folded || ids.isEmpty
          ? 38.0
          : 32 + ids.length * mapRowStep;
      final rect = origin & Size(columnWidthOf(column), height);
      final first = nodes[grouped[id]!.first]!;
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
        all: full,
      );
      heights[column] = math.max(heights[column] ?? startTop, rect.bottom + 18);
      if (!folded) {
        for (var i = 0; i < ids.length; i++) {
          boxes[ids[i]] = Rect.fromLTWH(
            origin.dx + 12,
            origin.dy + 38 + i * mapRowStep,
            columnWidthOf(column) - 24.0,
            mapBoxHeight,
          );
        }
      }
    }
    allEdges.addAll(
      (graph['edges'] as List? ?? []).cast<Map<String, dynamic>>(),
    );
    for (final e in allEdges) {
      // One line per step: agent → provider → model. A model an agent uses
      // through its provider hangs off that provider; a model nobody uses
      // has no line (being in a folder or catalog is not a connection).
      if (e['kind'] == 'serves' && !modelsInUse.contains(e['target'])) continue;
      // A model the agent's picker could choose from an online provider is
      // no connection either: skills/MCP → agent → provider → model only.
      if (e['kind'] == 'offer') continue;
      if (viaProvider(e)) continue;
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
  final _widths = <int, double>{};

  double columnWidthOf(int column) => _widths[column] ?? columnWidth;

  double columnX(int column) {
    final shown = _columns ?? const [0, 1, 2, 3];
    final slot = shown.indexOf(column);
    if (slot < 0) return _inset + 16 + column * (columnWidth + columnGap);
    var x = _inset + 16;
    for (var i = 0; i < slot; i++) {
      x += columnWidthOf(shown[i]) + columnGap;
    }
    return x;
  }

  Size get size => Size(
    math.max(
      switch (_columns) {
        [] => 0,
        null || [_, _, _, _] when !_sized => 1250,
        final shown =>
          columnX(shown == null ? 3 : shown.last) +
              columnWidthOf(shown == null ? 3 : shown.last) +
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

  /// Borders around the cards are on: lines show only between cards.
  bool bordered = false;

  bool insideCard(Offset point) =>
      bordered && cards.values.any((c) => c.rect.contains(point));

  /// Where a line's hook sits: near its end, but where the line shows.
  Offset hookOf(MapCurve curve) {
    if (!bordered || curve.edge['kind'] == agentLink) return curve.hook;
    for (var t = .91; t > .09; t -= .02) {
      final point = curve.point(t);
      if (!insideCard(point)) return point;
    }
    return curve.hook;
  }

  MapCurve? lineAt(Offset point, {double tolerance = 9}) {
    if (insideCard(point)) return null; // the line is not drawn there
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
            (hookOf(c) - point).distance <= 12,
      )
      .firstOrNull;
  bool movable(Map<String, dynamic> edge) =>
      '${edge['fixed'] ?? ''}'.isEmpty &&
      // Drawn as provider → model instead: that line is the one to move.
      !viaProvider(edge) &&
      (nodes[edge['source']]?['kind'] == 'agent' &&
              [
                'uses',
                'available',
                'mcp',
                'skills',
                'failed',
                'default',
              ].contains(edge['kind']) ||
          // A provider's line to a model in use: move it to another model of
          // that provider (every agent that uses it switches).
          edge['kind'] == 'serves' && modelsInUse.contains(edge['target']));

  /// An agent's model line that runs through the agent's own line to the
  /// model's provider: drawn as provider → model instead.
  bool viaProvider(Map e) {
    if (e['kind'] != 'default') return false;
    final provider = providerFor('${e['target']}');
    return provider != null &&
        allEdges.any(
          (p) =>
              p['source'] == e['source'] &&
              p['target'] == provider &&
              const {'uses', 'available', 'failed'}.contains(p['kind']),
        );
  }

  /// Models some agent uses through their provider, and each provider's own
  /// choice (Settings › provider_models) when that provider serves it.
  late final Set<String> modelsInUse = {
    for (final e in allEdges)
      if (viaProvider(e)) '${e['target']}',
    ...chosenModels,
  };

  /// A provider's chosen model that it really serves.
  late final Set<String> chosenModels = {
    for (final e in allEdges)
      if (e['kind'] == 'serves' && providerModels[e['source']] == e['target'])
        '${e['target']}',
  };
  Map? _providerModelsRaw;
  late final Map<String, String> providerModels = {
    for (final e in (_providerModelsRaw ?? const {}).entries)
      '${e.key}': '${e.value}',
  };
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
  final shown = layout.cards[card]!.nodes;
  final ids = [...shown]..remove(id);
  ids.insert(index.clamp(0, ids.length), id);
  // Boxes a used-only card leaves out keep their places between the others.
  final all = [...layout.cards[card]!.all];
  var next = 0;
  for (var i = 0; i < all.length; i++) {
    if (shown.contains(all[i])) all[i] = ids[next++];
  }
  return {
    ...saved,
    'order': {...?saved['order'] as Map?, card: all},
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
