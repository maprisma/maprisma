import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'map_groups.dart';
import 'map_layout.dart';
import 'map_lights.dart';
import 'map_smart_card.dart';
import 'map_static_cache.dart';
import 'app_theme.dart' show corners;
import 'map_snapshot.dart';

/// The editable canvas keeps its topology separate from gesture and ticker state.
class MapEditor extends StatefulWidget {
  const MapEditor({
    super.key,
    required this.graph,
    required this.saved,
    required this.onEdit,
    required this.tr,
    this.onLayout,
    this.controller,
    this.groups,
    this.onExpandGroup,
    this.onOpen,
    this.onMenu,
    this.animate = 'all',
    this.lightFps = 20,
    this.onAnimationChanged,
    this.selection,
    this.onSubagents,
    this.controls,
    this.staticState,
    this.lightStyle = defaultMapLightStyle,
    this.smartCards = false,
  });
  final Object? staticState;
  final MapLightStyle lightStyle;
  final bool smartCards;
  final Set<String>? selection;
  final ValueChanged<String>? onSubagents;
  final Widget Function(Map<String, dynamic>)? controls;
  final Map<String, dynamic> graph, saved;
  final Future<void> Function(Map<String, dynamic>) onEdit;
  final ValueChanged<Map<String, dynamic>>? onLayout;
  final String Function(String) tr;
  final TransformationController? controller;
  final List<MapGroup>? groups;
  final ValueChanged<int>? onExpandGroup;
  final ValueChanged<Map<String, dynamic>>? onOpen;
  final void Function(BuildContext, Map<String, dynamic>)? onMenu;
  final String animate;
  final int lightFps;
  final ValueChanged<String>? onAnimationChanged;
  @override
  State<MapEditor> createState() => _MapEditorState();
}

class _MapEditorState extends State<MapEditor>
    with SingleTickerProviderStateMixin {
  final _board = GlobalKey(), _viewport = GlobalKey();
  final _ownTransform = TransformationController();
  TransformationController get _transform => widget.controller ?? _ownTransform;
  late final MapLightClock _phase;
  final _localSelection = <String>{};
  Set<String> get _selected => widget.selection ?? _localSelection;
  late Map<String, dynamic> _saved;
  MapLayout? _layout;
  String? _source, _hover, _draggingCard;
  bool _pointerDrawing = false;
  Map<String, dynamic>? _moving;
  Offset? _cursor;
  double? _draggingCardY;
  int? _openSmartColumn;
  double _reorderDistance = 0;
  int _staticRevision = 0;
  @override
  void initState() {
    super.initState();
    _saved = widget.saved;
    _phase = MapLightClock(this);
  }

  @override
  void didUpdateWidget(covariant MapEditor old) {
    super.didUpdateWidget(old);
    final savedChanged = !sameMapJson(old.saved, widget.saved);
    final graphChanged = !sameMapJson(old.graph, widget.graph);
    final smartChanged = old.smartCards != widget.smartCards;
    if (savedChanged || smartChanged) {
      _saved = widget.saved;
      _layout = null;
      if (!widget.smartCards) _openSmartColumn = null;
    }
    if (graphChanged &&
        _layout != null &&
        !_layout!.updateGraph(widget.graph)) {
      _layout = null;
    }
    if (savedChanged ||
        smartChanged ||
        old.staticState != widget.staticState ||
        !sameMapJson(mapAppearance(old.graph), mapAppearance(widget.graph)) ||
        old.controls != widget.controls ||
        old.tr != widget.tr ||
        (old.onOpen == null) != (widget.onOpen == null) ||
        (old.onSubagents == null) != (widget.onSubagents == null) ||
        !sameMapJson(_groups(old.groups), _groups(widget.groups))) {
      _staticRevision++;
    }
  }

  Object? _groups(List<MapGroup>? groups) => groups
      ?.map((g) => [g.category, g.label, g.count, g.found, g.available])
      .toList();

  @override
  void dispose() {
    _phase.dispose();
    _ownTransform.dispose();
    super.dispose();
  }

  void _renderChange(VoidCallback update) {
    setState(() {
      update();
      _staticRevision++;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _staticRevision++;
  }

  void _save(Map<String, dynamic> data) {
    _renderChange(() {
      _saved = data;
      _layout = null;
    });
    widget.onLayout?.call(data);
  }

  void _cancel() {
    _renderChange(() {
      _pointerDrawing = false;
      _source = null;
      _moving = null;
      _cursor = null;
    });
  }

  Offset _local(Offset global) =>
      (_board.currentContext!.findRenderObject() as RenderBox).globalToLocal(
        global,
      );
  void _begin(
    String source, {
    Map<String, dynamic>? edge,
    Offset? global,
    bool pointer = false,
  }) {
    _renderChange(() {
      _pointerDrawing = pointer;
      _source = source;
      _moving = edge;
      _cursor = global == null ? null : _local(global);
    });
  }

  void _drop(String? target) {
    final source = _source, moving = _moving;
    if (source == null) return;
    if (target != null && !_layout!.targetOk(source, target, moving: moving)) {
      _cancel();
      return;
    }
    _cancel();
    if (target != null || moving != null) {
      widget.onEdit({'source': source, 'target': target, 'edge': ?moving});
    }
  }

  void _choose(String id) {
    if (_source != null) {
      _drop(id);
      return;
    }
    final agent = _selected
        .where((v) => _layout!.nodes[v]?['kind'] == 'agent')
        .firstOrNull;
    if (_layout!.nodes[id]?['kind'] == 'model' &&
        agent != null &&
        _layout!.targetOk(agent, id)) {
      widget.onEdit({'source': agent, 'target': id});
      return;
    }
    final shift = HardwareKeyboard.instance.isShiftPressed;
    _renderChange(() {
      if (!shift) _selected.clear();
      if (widget.graph['nodes'] != null &&
          _layout!.nodes[id]?['kind'] == 'agent') {
        _selected.removeWhere((v) => _layout!.nodes[v]?['kind'] == 'agent');
      }
      if (!_selected.add(id)) _selected.remove(id);
    });
  }

  void _pin(String id) {
    final pins = {...(_saved['pins'] as List? ?? []).cast<String>()};
    if (!pins.add(id)) pins.remove(id);
    _save({..._saved, 'pins': pins.toList()});
  }

  void _fold(String id) {
    final folded = {...(_saved['collapsed'] as List? ?? []).cast<String>()};
    if (!folded.add(id)) folded.remove(id);
    _save({..._saved, 'collapsed': folded.toList()});
  }

  void _toggleSmartCard(int col) {
    setState(() {
      if (_openSmartColumn == col) {
        _openSmartColumn = null;
        return;
      }
      _openSmartColumn = col;
      final box = _viewport.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final visible = Rect.fromPoints(
        _transform.toScene(Offset.zero),
        _transform.toScene(Offset(box.size.width, box.size.height)),
      );
      final card = Rect.fromLTWH(16.0 + col * 302, 106, 266, 320);
      final dx = card.right > visible.right
          ? visible.right - 16 - card.right
          : card.left < visible.left
          ? visible.left + 16 - card.left
          : 0.0;
      final dy = card.bottom > visible.bottom
          ? visible.bottom - 16 - card.bottom
          : card.top < visible.top
          ? visible.top + 16 - card.top
          : 0.0;
      if (dx != 0 || dy != 0) {
        _transform.value = _transform.value.clone()
          ..translateByDouble(dx, dy, 0, 1);
      }
    });
  }

  Widget _node(String id, MapLayout layout, Set<String> lit) {
    final node = layout.nodes[id]!, rect = layout.boxes[id]!;
    final valid =
        _source != null && layout.targetOk(_source!, id, moving: _moving);
    final colors = Theme.of(context).colorScheme;
    final pins = (_saved['pins'] as List? ?? []);
    final command = id.startsWith('agent:') ? id.substring(6) : '';
    final activity = (widget.graph['activity'] as Map?)?[command] as Map?;
    final children = activity?['children'] as List? ?? [];

    return Positioned.fromRect(
      rect: rect,
      child: MouseRegion(
        onEnter: (_) => _renderChange(() => _hover = id),
        onExit: (_) => _renderChange(() => _hover = null),
        child: GestureDetector(
          onPanStart: (d) =>
              _begin(id, global: d.globalPosition, pointer: true),
          onPanUpdate: (d) =>
              _renderChange(() => _cursor = _local(d.globalPosition)),
          onPanEnd: (_) =>
              _drop(_cursor == null ? null : layout.nodeAt(_cursor!)),
          onPanCancel: () {
            if (_pointerDrawing) _cancel();
          },
          child: Tooltip(
            message: widget.tr(
              valid
                  ? 'Connect'
                  : 'Hold and drag to connect or move. A preview appears before changes.',
            ),
            child: Card(
              color: node['status'] == 'running'
                  ? colors.secondaryContainer
                  : colors.surfaceContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(corners(context)),
                side: BorderSide(
                  color: valid || lit.contains(id)
                      ? colors.primary
                      : colors.outlineVariant,
                  width: valid ? 3 : 1,
                ),
              ),
              child: InkWell(
                onTap: () => _choose(id),
                onSecondaryTap: () => widget.onMenu?.call(context, node),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          GestureDetector(
                            key: ValueKey('reorder-$id'),
                            onVerticalDragStart: (_) => _reorderDistance = 0,
                            onVerticalDragUpdate: (d) =>
                                _reorderDistance += d.delta.dy,
                            onVerticalDragEnd: (d) {
                              _save(
                                reorderMapBox(
                                  _saved,
                                  layout,
                                  id,
                                  layout.cards[layout.cardOf[id]]!.nodes
                                          .indexOf(id) +
                                      (_reorderDistance / mapRowStep).round(),
                                ),
                              );
                            },
                            child: Tooltip(
                              message: widget.tr('Reorder'),
                              child: const Icon(Icons.drag_handle, size: 16),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              widget.tr(node['label'] as String),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          PopupMenuButton<String>(
                            tooltip: widget.tr('Actions'),
                            onSelected: (action) {
                              switch (action) {
                                case 'connect':
                                  _begin(id);
                                case 'pin':
                                  _pin(id);
                                case 'up':
                                  _save(
                                    reorderMapBox(
                                      _saved,
                                      layout,
                                      id,
                                      layout.cards[layout.cardOf[id]]!.nodes
                                              .indexOf(id) -
                                          1,
                                    ),
                                  );
                                case 'down':
                                  _save(
                                    reorderMapBox(
                                      _saved,
                                      layout,
                                      id,
                                      layout.cards[layout.cardOf[id]]!.nodes
                                              .indexOf(id) +
                                          1,
                                    ),
                                  );
                                case 'open':
                                  widget.onOpen?.call(node);
                                case 'actions':
                                  widget.onMenu?.call(context, node);
                                default:
                                  final edge = layout.allEdges.firstWhere(
                                    (e) => edgeKey(e) == action,
                                  );
                                  _begin(edge['source'] as String, edge: edge);
                              }
                            },
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'connect',
                                child: Text(widget.tr('Connect')),
                              ),
                              PopupMenuItem(
                                value: 'pin',
                                child: Text(
                                  widget.tr(
                                    pins.contains(id) ? 'Unpin' : 'Pin',
                                  ),
                                ),
                              ),
                              for (final action in ['up', 'down'])
                                PopupMenuItem(
                                  value: action,
                                  child: Text(
                                    widget.tr(
                                      action == 'up' ? 'Move up' : 'Move down',
                                    ),
                                  ),
                                ),
                              PopupMenuItem(
                                value: 'open',
                                child: Text(widget.tr('Open')),
                              ),
                              if (widget.onMenu != null)
                                PopupMenuItem(
                                  value: 'actions',
                                  child: Text(widget.tr('Actions')),
                                ),
                              for (final edge in layout.allEdges.where(
                                (e) =>
                                    layout.movable(e) &&
                                    (e['source'] == id || e['target'] == id),
                              ))
                                PopupMenuItem(
                                  value: edgeKey(edge),
                                  child: Text(
                                    '${widget.tr('Move connection')}: ${layout.nodes[edge['target']]?['label']}',
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                      Text(
                        node['detail'] as String? ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      if (widget.onSubagents != null &&
                          activity?['subagents_supported'] == true &&
                          children.isNotEmpty)
                        SizedBox(
                          height: 22,
                          child: TextButton(
                            onPressed: () => widget.onSubagents!(command),
                            child: Text(
                              '${widget.tr('Subagents')}: ${activity?['active_subagents']} / ${children.length}',
                            ),
                          ),
                        ),
                      if (widget.controls != null) widget.controls!(node),
                      if (widget.onOpen != null && widget.controls == null)
                        SizedBox(
                          height: 24,
                          child: TextButton(
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                            ),
                            onPressed: () => widget.onOpen!(node),
                            child: Text(widget.tr('Open')),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final layout = _layout ??= MapLayout(
      widget.graph,
      _saved,
      smartCards: widget.smartCards,
    );
    final colors = Theme.of(context).colorScheme;
    final active =
        widget.animate != 'off' &&
        layout.curves.any(
          (c) =>
              c.edge['active'] == true &&
              (widget.animate == 'all' || c.edge['activity'] == 'agent'),
        );
    final flowing =
        active &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    _phase.framesPerSecond = widget.lightFps;
    _phase.refreshRate = View.of(context).display.refreshRate;
    _phase.enabled = flowing;
    final seed = {
      ..._selected,
      ...(_saved['pins'] as List? ?? []).cast<String>(),
      ?_hover,
    };
    final lit = {...seed};
    for (final e in layout.allEdges) {
      if (seed.contains(e['source']) || seed.contains(e['target'])) {
        lit.addAll([e['source'] as String, e['target'] as String]);
      }
    }
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            _source != null) {
          _cancel();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(
        children: [
          SizedBox(
            height: 42,
            child: Row(
              children: [
                if (_source != null) ...[
                  TextButton(
                    onPressed: _cancel,
                    child: Text(widget.tr('Cancel')),
                  ),
                  if (_moving != null)
                    TextButton(
                      onPressed: () => _drop(null),
                      child: Text(widget.tr('Disconnect')),
                    ),
                ],
                const Spacer(),
                DropdownButton<String>(
                  value: widget.animate,
                  onChanged: (v) => widget.onAnimationChanged?.call(v!),
                  items: [
                    for (final mode in ['all', 'agents', 'off'])
                      DropdownMenuItem(
                        value: mode,
                        child: Text(
                          widget.tr(
                            {
                              'all': 'All lights',
                              'agents': 'Agent lights',
                              'off': 'Lights off',
                            }[mode]!,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: InteractiveViewer(
              key: _viewport,
              transformationController: _transform,
              constrained: false,
              minScale: .3,
              maxScale: 2,
              boundaryMargin: const EdgeInsets.all(120),
              child: SizedBox(
                key: _board,
                width: layout.size.width,
                height: layout.size.height,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: MapStaticCache(
                        enabled: flowing,
                        contentKey: _staticRevision,
                        controller: _transform,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapUp: (d) {
                                  if (_source != null) {
                                    _drop(null);
                                    return;
                                  }
                                  final line = layout.lineAt(d.localPosition);
                                  if (line != null &&
                                      line.edge['hints'] is List &&
                                      (line.edge['hints'] as List).isNotEmpty) {
                                    widget.onEdit({'failure': line.edge});
                                  } else {
                                    _renderChange(() => _selected.clear());
                                  }
                                },
                                child: RepaintBoundary(
                                  child: CustomPaint(
                                    painter: _MapPaint(
                                      layout,
                                      colors,
                                      lit,
                                      _source,
                                      _cursor,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (widget.groups != null)
                              for (var i = 0; i < widget.groups!.length; i++)
                                Positioned(
                                  left: 16 + i * 302,
                                  top: 0,
                                  width: 266,
                                  height: 98,
                                  child: MapGroupCard(
                                    group: widget.groups![i],
                                    tr: widget.tr,
                                    onExpand: () =>
                                        widget.onExpandGroup?.call(i),
                                  ),
                                ),
                            for (final card in layout.cards.values)
                              Positioned(
                                left: card.rect.left,
                                top: card.rect.top,
                                width: card.rect.width,
                                height: 36,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onVerticalDragStart: (d) => _renderChange(() {
                                    _draggingCard = card.id;
                                    _draggingCardY = _local(
                                      d.globalPosition,
                                    ).dy;
                                  }),
                                  onVerticalDragUpdate: (d) => _renderChange(
                                    () => _draggingCardY = _local(
                                      d.globalPosition,
                                    ).dy,
                                  ),
                                  onVerticalDragEnd: (_) {
                                    final y = _draggingCardY;
                                    _draggingCard = null;
                                    _draggingCardY = null;
                                    if (y == null) return;
                                    _save(
                                      reorderMapCard(
                                        _saved,
                                        layout,
                                        card.id,
                                        layout.cardDrop(card.id, y).$1,
                                      ),
                                    );
                                  },
                                  onVerticalDragCancel: () => _renderChange(() {
                                    _draggingCard = null;
                                    _draggingCardY = null;
                                  }),
                                  child: Row(
                                    children: [
                                      IconButton(
                                        tooltip: widget.tr(
                                          card.folded ? 'Expand' : 'Collapse',
                                        ),
                                        onPressed: () => _fold(card.id),
                                        icon: Icon(
                                          card.folded
                                              ? Icons.chevron_right
                                              : Icons.expand_more,
                                          size: 18,
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          widget.tr(card.label),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      PopupMenuButton<String>(
                                        tooltip: widget.tr('Move card'),
                                        onSelected: (direction) {
                                          final colCards = [
                                            for (final c in layout.cards.values)
                                              if (c.column == card.column) c.id,
                                          ];
                                          final index = colCards.indexOf(
                                            card.id,
                                          );
                                          _save(
                                            reorderMapCard(
                                              _saved,
                                              layout,
                                              card.id,
                                              index +
                                                  (direction == 'before'
                                                      ? -1
                                                      : 1),
                                            ),
                                          );
                                        },
                                        itemBuilder: (_) => [
                                          for (final d in ['before', 'after'])
                                            PopupMenuItem(
                                              value: d,
                                              child: Text(
                                                widget.tr(
                                                  d == 'before'
                                                      ? 'Earlier card'
                                                      : 'Later card',
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            if (_draggingCard != null &&
                                _draggingCardY != null &&
                                layout.cards.containsKey(_draggingCard))
                              Positioned.fromRect(
                                rect: layout
                                    .cardDrop(_draggingCard!, _draggingCardY!)
                                    .$2,
                                child: IgnorePointer(
                                  child: ColoredBox(
                                    key: const ValueKey('card-drop-line'),
                                    color: colors.primary,
                                  ),
                                ),
                              ),
                            for (final id in layout.boxes.keys)
                              _node(id, layout, lit),
                          ],
                        ),
                      ),
                    ),
                    if (flowing)
                      Positioned.fill(
                        child: MapLightLayer(
                          layout: layout,
                          clock: _phase,
                          color: colors.primary,
                          mode: widget.animate,
                          style: widget.lightStyle,
                        ),
                      ),
                    for (final curve in layout.curves.where(
                      (c) =>
                          layout.movable(c.edge) &&
                          (_selected.contains(c.edge['source']) ||
                              _selected.contains(c.edge['target'])),
                    ))
                      Positioned(
                        left: curve.hook.dx - 12,
                        top: curve.hook.dy - 12,
                        width: 24,
                        height: 24,
                        child: GestureDetector(
                          onPanStart: (d) => _begin(
                            curve.edge['source'] as String,
                            edge: curve.edge,
                            global: d.globalPosition,
                            pointer: true,
                          ),
                          onPanUpdate: (d) => _renderChange(
                            () => _cursor = _local(d.globalPosition),
                          ),
                          onPanEnd: (_) => _drop(
                            _cursor == null ? null : layout.nodeAt(_cursor!),
                          ),
                          onPanCancel: () {
                            if (_pointerDrawing) _cancel();
                          },
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            tooltip: widget.tr(
                              'Move this connection to another compatible box, or to empty space to disconnect.',
                            ),
                            onPressed: () => _begin(
                              curve.edge['source'] as String,
                              edge: curve.edge,
                            ),
                            icon: const Icon(
                              Icons.circle,
                              color: Colors.orange,
                              size: 13,
                            ),
                          ),
                        ),
                      ),
                    if (widget.smartCards)
                      for (final col in [
                        for (var i = 0; i < mapSmartColumns.length; i++)
                          if (i != _openSmartColumn) i,
                        ?_openSmartColumn,
                      ])
                        Positioned(
                          key: ValueKey(
                            'smart-card-slot-${mapSmartColumns[col].$1}',
                          ),
                          left: 16.0 + col * 302,
                          top: 106,
                          width: 266,
                          child: MapSmartCard(
                            key: ValueKey(
                              'smart-card-${mapSmartColumns[col].$1}',
                            ),
                            column: mapSmartColumns[col].$1,
                            title: mapSmartColumns[col].$2,
                            open: _openSmartColumn == col,
                            onToggle: () => _toggleSmartCard(col),
                            tr: widget.tr,
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MapPaint extends CustomPainter {
  _MapPaint(this.layout, this.colors, this.lit, this.source, this.cursor);
  final MapLayout layout;
  final ColorScheme colors;
  final Set<String> lit;
  final String? source;
  final Offset? cursor;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final card in layout.cards.values) {
      paint
        ..style = PaintingStyle.fill
        ..color = colors.surfaceContainerLow;
      canvas.drawRRect(
        RRect.fromRectAndRadius(card.rect, const Radius.circular(14)),
        paint,
      );
    }
    for (final curve in layout.curves) {
      final edge = curve.edge,
          related =
              lit.isEmpty ||
              lit.contains(edge['source']) && lit.contains(edge['target']);
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = related ? 2 : 1
        ..color =
            edge['kind'] == 'failed' ||
                (edge['hints'] as List? ?? []).isNotEmpty
            ? colors.error
            : related
            ? colors.primary
            : colors.outlineVariant;
      canvas.drawPath(curve.path, paint);
    }
    if (source != null && cursor != null && layout.boxes[source] != null) {
      final rect = layout.boxes[source]!;
      final curve = MapCurve(const {}, rect.center, cursor!);
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = colors.primary;
      canvas.drawPath(curve.path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MapPaint old) => true;
}
