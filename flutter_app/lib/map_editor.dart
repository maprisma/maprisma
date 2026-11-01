import 'dart:async' show FutureOr, unawaited;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart' show GestureBinding, PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core_client.g.dart';
import 'map_groups.dart';
import 'map_layout.dart';
import 'map_zoom.dart';
import 'map_lights.dart';
import 'map_smart_card.dart';
import 'map_static_cache.dart';
import 'app_theme.dart' show corners;
import 'map_snapshot.dart';

/// The map's columns: the map_layers each stands for, and its filter label.
const mapColumnLayers = [
  ['mcp', 'skills'],
  ['agents'],
  ['online', 'local'],
  ['models'],
];
const mapColumnNames = ['MCP servers', 'Agents', 'Providers', 'Models'];

/// The editable canvas keeps its topology separate from gesture and ticker state.
class MapEditor extends StatefulWidget {
  const MapEditor({
    this.layers,
    this.onLayers,
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
    this.selection,
    this.onSubagents,
    this.controls,
    this.staticState,
    this.lightStyle = defaultMapLightStyle,
    this.smartCards = false,
    this.smartAskColumns,
    this.onSmartProvider,
    this.onSmartTask,
    this.smartHelpers = const [],
    this.client,
    this.onSmartApplied,
    this.smartStatus,
    this.smartStatusTarget,
  });
  final Object? staticState;
  final MapLightStyle lightStyle;
  final bool smartCards;

  /// The columns whose helper takes requests; null: all.
  final Set<String>? smartAskColumns;

  /// A provider step the helper proposed and the user chose.
  final void Function(String step, String key, String name)? onSmartProvider;
  final ValueChanged<Map<String, dynamic>>? onSmartTask;
  final List<Map<String, dynamic>> smartHelpers;
  final CoreClient? client;
  final ValueChanged<Map<String, dynamic>>? onSmartApplied;
  final SmartStatusData? smartStatus;
  final (int, String)? smartStatusTarget;
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

  /// The map_layers setting and its change: the filter above the map, and
  /// the three map views. Null: no filter.
  final List<String>? layers;
  final FutureOr<void> Function(List<String>)? onLayers;
  @override
  State<MapEditor> createState() => _MapEditorState();
}

class _FitState {
  /// Columns the user turned on although the window's view leaves them out.
  final forced = <int>{};
  double? scale;
  Size? fittedTo;
  (Size, Size)? clampedTo;
  int handledStatusToken = 0;
}

final _fitStates = Expando<_FitState>('mapFitState');

class _MapEditorState extends State<MapEditor>
    with SingleTickerProviderStateMixin {
  final _board = GlobalKey(), _viewport = GlobalKey();
  final _ownTransform = TransformationController();
  TransformationController get _transform => widget.controller ?? _ownTransform;

  /// The map fits the window's width (window resized by hand or by tiling)
  /// until the user zooms; Ctrl+0 fits it to the window again.
  /// Stored on the controller so opening another view and coming back keeps
  /// the user's zoom.
  _FitState get _fitState => _fitStates[_transform] ??= _FitState();
  bool get _userZoomed => mapUserZoomed[_transform] == true;
  set _userZoomed(bool value) => mapUserZoomed[_transform] = value;
  bool _fitting = false;

  List<int> _shownColumns = const [0, 1, 2, 3];
  MapViewSize _view = MapViewSize.max;

  /// The map's width on screen and in scene coordinates: the shown columns
  /// grow to fill the free space and are centred in it. Only with the column
  /// filter (the app's own map).
  double _viewportWidth = 0;
  double _centerIn = 0;

  bool _allowed(MapViewSize view, int col) =>
      view.allows(col) || _fitState.forced.contains(col);

  List<int> _columnsFor(MapViewSize view) {
    final layers = widget.layers;
    if (layers == null) return const [0, 1, 2, 3];
    return [
      for (var col = 0; col < mapColumnLayers.length; col++)
        if (_allowed(view, col) && mapColumnLayers[col].any(layers.contains))
          col,
    ];
  }

  Map<String, dynamic> get _shownGraph {
    final graph = widget.graph;
    if (_shownColumns.length == mapColumnLayers.length) return graph;
    final nodes = [
      for (final n in graph['nodes'] as List? ?? const [])
        if (_shownColumns.contains((n as Map)['column'])) n,
    ];
    final ids = {for (final n in nodes) n['id']};
    return {
      ...graph,
      'nodes': nodes,
      'edges': [
        for (final e in graph['edges'] as List? ?? const [])
          if (ids.contains((e as Map)['source']) && ids.contains(e['target']))
            e,
      ],
    };
  }

  void _toggleColumn(int col, bool on) {
    // The core shows MCP servers and skills only with agents, and models
    // only with a provider: those columns go and come with them.
    const needs = {0: 1, 3: 2}, needed = {1: 0, 2: 3};
    final forced = _fitState.forced;
    final next = {...?(_pendingLayers ?? widget.layers)};
    if (on && !_view.allows(col)) forced.add(col);
    if (!on && forced.remove(col) && !_view.allows(col)) {
      // Back to what the window's view shows; the filter stays as it was.
      setState(() {
        _pendingSmartMove = null;
        if (_openSmartColumn == col) _openSmartColumn = null;
      });
      return;
    }
    if (on) {
      next.addAll(mapColumnLayers[col]);
      if (needs[col] case final other?) next.addAll(mapColumnLayers[other]);
    } else {
      next.removeAll(mapColumnLayers[col]);
      if (needed[col] case final other?) {
        next.removeAll(mapColumnLayers[other]);
        forced.remove(other);
      }
      _pendingSmartMove = null;
      if (_openSmartColumn == col ||
          (needed[col] != null && _openSmartColumn == needed[col])) {
        _openSmartColumn = null;
      }
    }
    final updated = next.toList();
    setState(() => _pendingLayers = updated);
    final res = widget.onLayers?.call(updated);
    if (res is Future) {
      unawaited(
        res.whenComplete(() {
          if (mounted && _pendingLayers == updated) {
            setState(() {
              _pendingLayers = null;
              _pendingSmartMove = null;
            });
          }
        }),
      );
    }
  }

  void _fit(Size content) {
    final box = _viewport.currentContext?.findRenderObject() as RenderBox?;
    if (!mounted || box == null || !box.hasSize || content.width <= 0) return;
    final currentScale = _transform.value.entry(0, 0);
    final vw = box.size.width;
    final centerWidth = _userZoomed && currentScale > 0
        ? vw / currentScale
        : vw;
    if ((vw - _viewportWidth).abs() > .5 ||
        (centerWidth - _centerIn).abs() > .5) {
      setState(() {
        _viewportWidth = vw;
        _centerIn = centerWidth;
        _layout = null;
        _staticRevision++;
      });
      return; // the next frame fits the new layout
    }
    final state = _fitState;
    if (!_userZoomed) {
      final target = Size(box.size.width, content.width);
      if (target != state.fittedTo) {
        state.fittedTo = target;
        final scale = (box.size.width / content.width).clamp(.3, 1.0);
        state.scale = scale;
        _fitting = true;
        final now = _transform.value.getTranslation();
        _transform.value = Matrix4.diagonal3Values(scale, scale, 1)
          ..setTranslationRaw(now.x, now.y, now.z);
        _fitting = false;
      }
    }
    final clampTarget = (box.size, content);
    if (state.clampedTo != clampTarget) {
      state.clampedTo = clampTarget;
      _fitting = true;
      scrollMap(_transform, Offset.zero, viewport: box.size, content: content);
      _fitting = false;
    }
    if (_pendingSmartPan case final col?) {
      _pendingSmartPan = null;
      if (_openSmartColumn == col) _panSmartCardIntoView(col);
    }
  }

  void _fitAgain() {
    final state = _fitState;
    _userZoomed = false;
    state.fittedTo = null;
    state.clampedTo = null;
    _fitting = true;
    _transform.value = Matrix4.identity();
    _fitting = false;
    final box = _viewport.currentContext?.findRenderObject() as RenderBox?;
    if (box != null &&
        box.hasSize &&
        ((box.size.width - _viewportWidth).abs() > .5 ||
            (box.size.width - _centerIn).abs() > .5)) {
      setState(() {
        _viewportWidth = box.size.width;
        _centerIn = box.size.width;
        _layout = null;
        _staticRevision++;
      });
    }
    final layout = _layout ??= MapLayout(
      _shownGraph,
      _saved,
      smartCards: widget.smartCards,
      columns: _shownColumns,
      viewportWidth: _viewportWidth,
      centerWidth: _centerIn,
    );
    _fit(layout.size);
  }

  void _zoomChanged() {
    final state = _fitState;
    final fitted = state.scale;
    if (_fitting || fitted == null) return;
    final scale = _transform.value.entry(0, 0);
    if ((scale - fitted).abs() > .001) {
      _userZoomed = true;
    }
    final box = _viewport.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      final vw = box.size.width;
      final centerWidth = _userZoomed && scale > 0 ? vw / scale : vw;
      if ((vw - _viewportWidth).abs() > .5 ||
          (centerWidth - _centerIn).abs() > .5) {
        setState(() {
          _viewportWidth = vw;
          _centerIn = centerWidth;
          _layout = null;
          _staticRevision++;
        });
      }
      final content = (_layout ??= MapLayout(
        _shownGraph,
        _saved,
        smartCards: widget.smartCards,
        columns: _shownColumns,
        viewportWidth: _viewportWidth,
        centerWidth: _centerIn,
      )).size;
      _fitting = true;
      scrollMap(_transform, Offset.zero, viewport: box.size, content: content);
      _fitting = false;
    }
  }

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
  List<String>? _pendingLayers;
  (int, String, String)? _pendingSmartMove;
  int? _pendingSmartPan;
  final _smartStatusTokens = <String, int>{};
  final _smartPrompts = <String, String>{};
  double _reorderDistance = 0;
  int _staticRevision = 0;
  @override
  void initState() {
    super.initState();
    _saved = widget.saved;
    _phase = MapLightClock(this);
    _fitState
      ..fittedTo = null
      ..clampedTo = null;
    _transform.addListener(_zoomChanged);
    mapFit[_transform] = _fitAgain;
  }

  @override
  void didUpdateWidget(covariant MapEditor old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      final prev = old.controller ?? _ownTransform;
      prev.removeListener(_zoomChanged);
      if (mapFit[prev] == _fitAgain) mapFit[prev] = null;
      _fitState
        ..fittedTo = null
        ..clampedTo = null;
      _transform.addListener(_zoomChanged);
      mapFit[_transform] = _fitAgain;
    }
    if (!listEquals(old.layers, widget.layers)) {
      _pendingLayers = null;
    }
    final savedChanged = !sameMapJson(old.saved, widget.saved);
    final graphChanged = !sameMapJson(old.graph, widget.graph);
    final smartChanged = old.smartCards != widget.smartCards;
    if (savedChanged || smartChanged) {
      _saved = widget.saved;
      _layout = null;
      if (!widget.smartCards) _openSmartColumn = null;
    }
    if (graphChanged && _layout != null && !_layout!.updateGraph(_shownGraph)) {
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
    _transform.removeListener(_zoomChanged);
    if (mapFit[_transform] == _fitAgain) mapFit[_transform] = null;
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
    final layout = _layout;
    if (layout == null ||
        !layout.boxes.containsKey(source) ||
        (moving != null && !layout.boxes.containsKey(moving['target']))) {
      _cancel();
      return;
    }
    if (target != null && !layout.targetOk(source, target, moving: moving)) {
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

  void _panSmartCardIntoView(int col) {
    final layout = _layout ??= MapLayout(
      _shownGraph,
      _saved,
      smartCards: widget.smartCards,
      columns: _shownColumns,
      viewportWidth: _viewportWidth,
      centerWidth: _centerIn,
    );
    final box = _viewport.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final visible = Rect.fromPoints(
      _transform.toScene(Offset.zero),
      _transform.toScene(Offset(box.size.width, box.size.height)),
    );
    final left = layout.columnX(col);
    final card = Rect.fromLTWH(left, 106, layout.columnWidth, 320);
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
  }

  void _toggleSmartCard(int col) {
    setState(() {
      _pendingSmartMove = null;
      if (_openSmartColumn == col) {
        _openSmartColumn = null;
        return;
      }
      if (!_shownColumns.contains(col)) return;
      _openSmartColumn = col;
      _panSmartCardIntoView(col);
    });
  }

  Widget _columnChip(int col) {
    final layers = _pendingLayers ?? widget.layers!;
    final on = mapColumnLayers[col].any(layers.contains);
    return FilterChip(
      key: ValueKey('map-column-$col'),
      visualDensity: VisualDensity.compact,
      label: Text(widget.tr(mapColumnNames[col])),
      selected: on && _allowed(_view, col),
      onSelected: (value) => _toggleColumn(col, value),
    );
  }

  List<Map<String, dynamic>> _movable(String id, MapLayout layout) => [
    for (final e in layout.allEdges)
      if (layout.movable(e) && (e['source'] == id || e['target'] == id)) e,
  ];

  String _moveLabel(Map<String, dynamic> edge, MapLayout layout) =>
      '${widget.tr('Move connection')}: ${layout.nodes[edge['target']]?['label']}';

  Future<void> _chooseMove(String id, MapLayout layout) async {
    final edge = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(widget.tr('Move connection')),
        children: [
          for (final e in _movable(id, layout))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, e),
              child: Text('${layout.nodes[e['target']]?['label']}'),
            ),
        ],
      ),
    );
    if (edge != null && mounted) _begin(edge['source'] as String, edge: edge);
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
    final hasSubagents =
        node['kind'] == 'agent' &&
        widget.onSubagents != null &&
        activity?['subagents_supported'] == true &&
        children.isNotEmpty;
    final traffic = node['kind'] == 'agent'
        ? ((widget.graph['traffic'] as Map?)?[command] as Map?)
        : null;
    final hasTraffic = ((traffic?['connections'] as num?)?.toInt() ?? 0) > 0;

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
              child: Stack(
                children: [
                  Positioned.fill(
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
                                  onVerticalDragStart: (_) =>
                                      _reorderDistance = 0,
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
                                            (_reorderDistance / mapRowStep)
                                                .round(),
                                      ),
                                    );
                                  },
                                  child: Tooltip(
                                    message: widget.tr('Reorder'),
                                    child: const Icon(
                                      Icons.drag_handle,
                                      size: 16,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    widget.tr(node['label'] as String),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if ((widget.graph['agent_badges'] as Map?)?[id]
                                    case final Map badge)
                                  AgentBadge(badge: badge),
                                if ((widget.graph['usage_boxes'] as Map?)?[id]
                                    case final Map box)
                                  Flexible(
                                    child: UsageBoxLabel(
                                      box: box,
                                      size:
                                          (widget.graph['usage_box_size']
                                                      as int? ??
                                                  7)
                                              .toDouble(),
                                    ),
                                  ),
                                PopupMenuButton<String>(
                                  tooltip: widget.tr('Actions'),
                                  onSelected: (action) {
                                    switch (action) {
                                      case 'connect':
                                        _begin(id);
                                      case 'up':
                                        _save(
                                          reorderMapBox(
                                            _saved,
                                            layout,
                                            id,
                                            layout
                                                    .cards[layout.cardOf[id]]!
                                                    .nodes
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
                                            layout
                                                    .cards[layout.cardOf[id]]!
                                                    .nodes
                                                    .indexOf(id) +
                                                1,
                                          ),
                                        );
                                      case 'open':
                                        widget.onOpen?.call(node);
                                      case 'actions':
                                        widget.onMenu?.call(context, node);
                                      case 'move':
                                        _chooseMove(id, layout);
                                      default:
                                        final edge = layout.allEdges.firstWhere(
                                          (e) => edgeKey(e) == action,
                                        );
                                        _begin(
                                          edge['source'] as String,
                                          edge: edge,
                                        );
                                    }
                                  },
                                  itemBuilder: (_) => [
                                    PopupMenuItem(
                                      value: 'connect',
                                      child: Text(widget.tr('Connect')),
                                    ),
                                    for (final action in ['up', 'down'])
                                      PopupMenuItem(
                                        value: action,
                                        child: Text(
                                          widget.tr(
                                            action == 'up'
                                                ? 'Move up'
                                                : 'Move down',
                                          ),
                                        ),
                                      ),
                                    PopupMenuItem(
                                      value: 'open',
                                      child: Text(widget.tr('Details')),
                                    ),
                                    if (widget.onMenu != null)
                                      PopupMenuItem(
                                        value: 'actions',
                                        child: Text(widget.tr('Actions')),
                                      ),
                                    // Many connections get a page of their own, or
                                    // the menu would fill the screen.
                                    if (_movable(id, layout).length > 3)
                                      PopupMenuItem(
                                        value: 'move',
                                        child: Text(
                                          '${widget.tr('Move connection')}…',
                                        ),
                                      )
                                    else
                                      for (final edge in _movable(id, layout))
                                        PopupMenuItem(
                                          value: edgeKey(edge),
                                          child: Text(_moveLabel(edge, layout)),
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
                            if (hasSubagents ||
                                hasTraffic ||
                                widget.controls != null ||
                                widget.onOpen != null)
                              SizedBox(
                                height: 26,
                                child: Row(
                                  children: [
                                    if (hasSubagents)
                                      Tooltip(
                                        message:
                                            '${widget.tr('Subagents')}: ${activity?['active_subagents']} / ${children.length}',
                                        child: InkWell(
                                          key: ValueKey('subagents-$command'),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                          onTap: () =>
                                              widget.onSubagents!(command),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 4,
                                              vertical: 2,
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                  Icons.account_tree_outlined,
                                                  size: 14,
                                                ),
                                                const SizedBox(width: 2),
                                                Text(
                                                  '${children.length}',
                                                  style: const TextStyle(
                                                    fontSize: 11,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    if (hasTraffic)
                                      IconButton(
                                        key: ValueKey('traffic-$command'),
                                        padding: EdgeInsets.zero,
                                        visualDensity: VisualDensity.compact,
                                        constraints: const BoxConstraints(
                                          minWidth: 26,
                                          minHeight: 24,
                                        ),
                                        tooltip: trafficTooltip(
                                          traffic!,
                                          widget.tr,
                                        ),
                                        onPressed: () => showDialog<void>(
                                          context: context,
                                          builder: (_) => AgentTrafficDialog(
                                            label: widget.tr(
                                              node['label'] as String,
                                            ),
                                            traffic: traffic,
                                            tr: widget.tr,
                                          ),
                                        ),
                                        icon: const Icon(
                                          Icons.swap_vert,
                                          size: 16,
                                        ),
                                      ),
                                    if (widget.controls != null)
                                      Expanded(child: widget.controls!(node))
                                    else if (widget.onOpen != null)
                                      IconButton(
                                        key: ValueKey('details-$id'),
                                        padding: EdgeInsets.zero,
                                        visualDensity: VisualDensity.compact,
                                        constraints: const BoxConstraints(
                                          minWidth: 26,
                                          minHeight: 24,
                                        ),
                                        tooltip: widget.tr('Details'),
                                        onPressed: () => widget.onOpen!(node),
                                        icon: const Icon(
                                          Icons.info_outline,
                                          size: 16,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: IconButton(
                      key: ValueKey('pin-$id'),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 26,
                        minHeight: 24,
                      ),
                      tooltip: widget.tr(pins.contains(id) ? 'Unpin' : 'Pin'),
                      onPressed: () => _pin(id),
                      icon: Icon(
                        pins.contains(id)
                            ? Icons.push_pin
                            : Icons.push_pin_outlined,
                        size: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => _buildEditor(context, constraints),
    );
  }

  Widget _buildEditor(BuildContext context, BoxConstraints constraints) {
    final vw = constraints.maxWidth.isFinite && constraints.maxWidth > 0
        ? constraints.maxWidth
        : MediaQuery.sizeOf(context).width;
    final currentScale = _transform.value.entry(0, 0);
    final centerWidth = _userZoomed && currentScale > 0
        ? vw / currentScale
        : vw;
    if ((vw - _viewportWidth).abs() > .5 ||
        (centerWidth - _centerIn).abs() > .5) {
      _viewportWidth = vw;
      _centerIn = centerWidth;
      _layout = null;
      _staticRevision++;
    }
    // A new window size: fit again, and show the columns that fit.
    _view = widget.layers == null
        ? MapViewSize.max
        : mapViewSizeFor(
            windowWidth: MediaQuery.sizeOf(context).width,
            displayWidth: mapDisplayWidthOf(context),
          );
    if (widget.smartStatusTarget case (
      final token,
      final targetCol,
    ) when token != _fitState.handledStatusToken) {
      _fitState.handledStatusToken = token;
      final index = mapSmartColumns.indexWhere((c) => c.$1 == targetCol);
      if (index >= 0) {
        _smartStatusTokens[targetCol] = token;
        if (!_view.allows(index)) {
          _fitState.forced.add(index);
        }
        final shownAfterForce = _columnsFor(_view);
        if (!shownAfterForce.contains(index)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _toggleColumn(index, true);
          });
        }
        _openSmartColumn = index;
        _pendingSmartPan = index;
      }
    }
    final shown = _columnsFor(_view);
    if (!listEquals(shown, _shownColumns)) {
      _shownColumns = shown;
      _layout = null;
      _staticRevision++;
    }
    if (_pendingSmartMove case (
      final col,
      final targetCol,
      final request,
    ) when _shownColumns.contains(col)) {
      _pendingSmartMove = null;
      _smartPrompts[targetCol] = request;
      _openSmartColumn = col;
      _pendingSmartPan = col;
    } else if (_pendingSmartMove case (
      final col,
      _,
      _,
    ) when !_allowed(_view, col)) {
      _pendingSmartMove = null;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fit(_layout?.size ?? Size.zero);
    });
    final layout = _layout ??= MapLayout(
      _shownGraph,
      _saved,
      smartCards: widget.smartCards,
      columns: _shownColumns,
      viewportWidth: _viewportWidth,
      centerWidth: _centerIn,
    );
    if (_source != null &&
        (!layout.boxes.containsKey(_source) ||
            (_moving != null &&
                !layout.boxes.containsKey(_moving!['target'])))) {
      _pointerDrawing = false;
      _source = null;
      _moving = null;
      _cursor = null;
    }
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
    seed.retainWhere(layout.nodes.containsKey); // a hidden column has no lines
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
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
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
                              const SizedBox(width: 6),
                            ],
                            if (widget.onLayers != null)
                              for (
                                var col = 0;
                                col < mapColumnLayers.length;
                                col++
                              ) ...[_columnChip(col), const SizedBox(width: 6)],
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  MapZoomControl(controller: _transform, tr: widget.tr),
                ],
              ),
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Listener(
                    onPointerSignal: (event) {
                      final box = _viewport.currentContext?.findRenderObject();
                      if (event is PointerScrollEvent && box is RenderBox) {
                        GestureBinding.instance.pointerSignalResolver.register(
                          event,
                          (e) => scrollMap(
                            _transform,
                            (e as PointerScrollEvent).scrollDelta,
                            viewport: box.size,
                            content: layout.size,
                          ),
                        );
                      }
                    },
                    child: InteractiveViewer(
                      key: _viewport,
                      transformationController: _transform,
                      constrained: false,
                      scaleEnabled:
                          false, // the wheel scrolls; zoom has its control
                      minScale: .3,
                      maxScale: 2,
                      boundaryMargin: const EdgeInsets.fromLTRB(0, 0, 120, 120),
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
                                          final line = layout.lineAt(
                                            d.localPosition,
                                          );
                                          if (line != null &&
                                              line.edge['hints'] is List &&
                                              (line.edge['hints'] as List)
                                                  .isNotEmpty) {
                                            widget.onEdit({
                                              'failure': line.edge,
                                            });
                                          } else {
                                            _renderChange(
                                              () => _selected.clear(),
                                            );
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
                                      for (
                                        var i = 0;
                                        i < widget.groups!.length;
                                        i++
                                      )
                                        if (_shownColumns.contains(i))
                                          Positioned(
                                            left: layout.columnX(i),
                                            top: 8,
                                            width: layout.columnWidth,
                                            height: 86,
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
                                          onVerticalDragStart: (d) =>
                                              _renderChange(() {
                                                _draggingCard = card.id;
                                                _draggingCardY = _local(
                                                  d.globalPosition,
                                                ).dy;
                                              }),
                                          onVerticalDragUpdate: (d) =>
                                              _renderChange(
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
                                          onVerticalDragCancel: () =>
                                              _renderChange(() {
                                                _draggingCard = null;
                                                _draggingCardY = null;
                                              }),
                                          child: Row(
                                            children: [
                                              IconButton(
                                                tooltip: widget.tr(
                                                  card.folded
                                                      ? 'Expand'
                                                      : 'Collapse',
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
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                              PopupMenuButton<String>(
                                                tooltip: widget.tr('Move card'),
                                                onSelected: (direction) {
                                                  final colCards = [
                                                    for (final c
                                                        in layout.cards.values)
                                                      if (c.column ==
                                                          card.column)
                                                        c.id,
                                                  ];
                                                  final index = colCards
                                                      .indexOf(card.id);
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
                                                  for (final d in [
                                                    'before',
                                                    'after',
                                                  ])
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
                                            .cardDrop(
                                              _draggingCard!,
                                              _draggingCardY!,
                                            )
                                            .$2,
                                        child: IgnorePointer(
                                          child: ColoredBox(
                                            key: const ValueKey(
                                              'card-drop-line',
                                            ),
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
                                    _cursor == null
                                        ? null
                                        : layout.nodeAt(_cursor!),
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
                                  left: layout.columnX(col),
                                  top: 106,
                                  width: layout.columnWidth,
                                  child: Visibility(
                                    visible: _shownColumns.contains(col),
                                    maintainState: true,
                                    child: MapSmartCard(
                                      key: ValueKey(
                                        'smart-card-${mapSmartColumns[col].$1}',
                                      ),
                                      width: layout.columnWidth,
                                      column: mapSmartColumns[col].$1,
                                      onProvider: widget.onSmartProvider,
                                      onTask: widget.onSmartTask,
                                      takesRequests:
                                          widget.smartAskColumns?.contains(
                                            mapSmartColumns[col].$1,
                                          ) ??
                                          true,
                                      title: mapSmartColumns[col].$2,
                                      open: _openSmartColumn == col,
                                      enabled:
                                          widget.layers == null ||
                                          mapColumnLayers[col].any(
                                            widget.layers!.contains,
                                          ),
                                      onToggle: () => _toggleSmartCard(col),
                                      tr: widget.tr,
                                      helpers: widget.smartHelpers,
                                      client: widget.client,
                                      initialPrompt:
                                          _smartPrompts[mapSmartColumns[col]
                                              .$1],
                                      onMoveToColumn: (targetCol, request) {
                                        final index = mapSmartColumns
                                            .indexWhere(
                                              (c) => c.$1 == targetCol,
                                            );
                                        if (index < 0) return;
                                        if (!_view.allows(index)) {
                                          _fitState.forced.add(index);
                                        }
                                        if (!_shownColumns.contains(index)) {
                                          _pendingSmartMove = (
                                            index,
                                            targetCol,
                                            request,
                                          );
                                          _toggleColumn(index, true);
                                          return;
                                        }
                                        _smartPrompts[targetCol] = request;
                                        _toggleSmartCard(index);
                                      },
                                      onApplied: widget.onSmartApplied,
                                      status: widget.smartStatus,
                                      statusTrigger:
                                          _smartStatusTokens[mapSmartColumns[col]
                                              .$1] ??
                                          0,
                                    ),
                                  ),
                                ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String trafficSizeText(num bytes) {
  final b = bytes < 0 ? 0 : bytes;
  if (b < 1024) return '${b.round()} B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String trafficRateText(num bytesPerSecond) =>
    '${trafficSizeText(bytesPerSecond)}/s';

String trafficTooltip(Map traffic, String Function(String) tr) =>
    tr('Network: ↓ {0} ↑ {1}. Click for its network statistics.')
        .replaceAll('{0}', trafficRateText(traffic['rate_in'] as num? ?? 0))
        .replaceAll('{1}', trafficRateText(traffic['rate_out'] as num? ?? 0));

class AgentTrafficDialog extends StatelessWidget {
  const AgentTrafficDialog({
    super.key,
    required this.label,
    required this.traffic,
    required this.tr,
  });

  final String label;
  final Map traffic;
  final String Function(String) tr;

  @override
  Widget build(BuildContext context) {
    final since = '${traffic['since'] ?? ''}'.trim();
    final received = traffic['received'] as num? ?? 0;
    final sent = traffic['sent'] as num? ?? 0;
    final connections = (traffic['connections'] as num? ?? 0).toInt();
    final rateIn = traffic['rate_in'] as num? ?? 0;
    final rateOut = traffic['rate_out'] as num? ?? 0;
    final places = (traffic['places'] as List? ?? const []).cast<Map>();
    final programs = (traffic['programs'] as List? ?? const []).cast<Map>();
    String placeKind(String? kind) => switch (kind) {
      'api' => tr('Online API'),
      'local' || 'local-llm' => tr('This PC'),
      'lan' => tr('Local network'),
      _ => tr('Internet'),
    };
    return AlertDialog(
      title: Text(tr('Network · {0}').replaceAll('{0}', label)),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (since.isNotEmpty) ...[
                Text(
                  '${tr('Counted since')}: $since',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
              ],
              Wrap(
                spacing: 12,
                runSpacing: 6,
                children: [
                  Text(
                    '${tr('In')}: ${trafficSizeText(received)} (${trafficRateText(rateIn)})',
                  ),
                  Text(
                    '${tr('Out')}: ${trafficSizeText(sent)} (${trafficRateText(rateOut)})',
                  ),
                  Text('${tr('Connections')}: $connections'),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                tr('Where it goes'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              if (places.isEmpty)
                Text(tr('No connections yet.'))
              else
                for (final place in places)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '${place['name']} · ${placeKind(place['kind'] as String?)} · ↓ ${trafficSizeText(place['received'] as num? ?? 0)} ↑ ${trafficSizeText(place['sent'] as num? ?? 0)} (${place['connections']})',
                    ),
                  ),
              const SizedBox(height: 12),
              Text(
                tr('Programs'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              if (programs.isEmpty)
                Text(tr('No program has moved data yet.'))
              else
                for (final prog in programs)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '${prog['name']} · ↓ ${trafficSizeText(prog['received'] as num? ?? 0)} ↑ ${trafficSizeText(prog['sent'] as num? ?? 0)}',
                    ),
                  ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('Close')),
        ),
      ],
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
