import 'dart:async' show FutureOr;
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show GestureBinding, PointerScrollEvent;
import 'package:flutter/material.dart';
import 'core_client.g.dart';
import 'map_groups.dart';
import 'app_theme.dart' show corners;
import 'map_editor.dart';
import 'map_smart_card.dart';
import 'map_zoom.dart';

export 'map_groups.dart' show AgentBadge, UsageBoxLabel;

class AgentMap extends StatelessWidget {
  const AgentMap({
    this.layers,
    this.onLayers,
    super.key,
    required this.graph,
    required this.onAgent,
    required this.tr,
    this.readOnly = false,
    this.onEdit,
    this.selection,
    this.controls,
    this.staticState,
    this.savedLayout = const {},
    this.onLayout,
    this.animate = 'all',
    this.lightFps = 20,
    this.anchors = const {},
    this.onSubagents,
    this.onNode,
    this.controller,
    this.onViewChanged,
    this.focusedNode,
    this.groups,
    this.onExpandGroup,
    this.onNodeMenu,
    this.smartCards = false,
    this.smartAskColumns,
    this.onSmartProvider,
    this.onSmartTask,
    this.smartHelpers = const [],
    this.client,
    this.onSmartApplied,
    this.smartStatus,
    this.smartStatusTarget,
    this.columns = const [
      'MCP servers and skills',
      'Agents',
      'Providers',
      'Models',
    ],
  });

  final Object? staticState;
  final bool smartCards;
  final Set<String>? smartAskColumns;
  final void Function(String step, String key, String name)? onSmartProvider;
  final ValueChanged<Map<String, dynamic>>? onSmartTask;
  final List<Map<String, dynamic>> smartHelpers;
  final CoreClient? client;
  final ValueChanged<Map<String, dynamic>>? onSmartApplied;
  final SmartStatusData? smartStatus;
  final (int, String)? smartStatusTarget;
  final Set<String>? selection;
  final Widget Function(Map<String, dynamic>)? controls;
  final Future<void> Function(Map<String, dynamic>)? onEdit;
  final Map<String, dynamic> savedLayout;
  final ValueChanged<Map<String, dynamic>>? onLayout;
  final String animate;
  final int lightFps;
  final bool readOnly;
  final Set<String> anchors;
  final Map<String, dynamic> graph;
  final ValueChanged<String> onAgent;
  final String Function(String) tr;
  final ValueChanged<String>? onSubagents;
  final ValueChanged<Map<String, dynamic>>? onNode;
  final List<String> columns;
  final TransformationController? controller;
  final VoidCallback? onViewChanged;
  final String? focusedNode;
  final List<MapGroup>? groups;
  final ValueChanged<int>? onExpandGroup;
  final void Function(BuildContext, Map<String, dynamic>)? onNodeMenu;
  final List<String>? layers;
  final FutureOr<void> Function(List<String>)? onLayers;

  Widget _title(Map<String, dynamic> node) {
    final command = (node['id'] as String).replaceFirst('agent:', '');
    final activity = (graph['activity'] as Map?)?[command] as Map?;
    final children = activity?['children'] as List? ?? [];
    return Row(
      children: [
        Expanded(
          child: Text(
            tr(node['label'] as String),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        if ((graph['agent_badges'] as Map?)?[node['id']] case final Map badge)
          AgentBadge(badge: badge),
        if ((graph['usage_boxes'] as Map?)?[node['id']] case final Map box)
          Flexible(
            child: UsageBoxLabel(
              box: box,
              size: (graph['usage_box_size'] as int? ?? 7).toDouble(),
            ),
          ),
        if (node['kind'] == 'agent' &&
            activity?['subagents_supported'] == true &&
            children.isNotEmpty)
          Tooltip(
            message:
                '${tr('Subagents')}: ${activity?['active_subagents']} / ${children.length}',
            child: TextButton(
              onPressed: readOnly || onSubagents == null
                  ? null
                  : () => onSubagents!(command),
              style: TextButton.styleFrom(
                minimumSize: const Size(34, 22),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.account_tree_outlined, size: 14),
                  Text(
                    '${children.length}',
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!readOnly && onEdit != null) {
      return MapEditor(
        layers: layers,
        onLayers: onLayers,
        graph: graph,
        saved: savedLayout,
        onLayout: onLayout,
        onEdit: onEdit!,
        selection: selection,
        controls: controls,
        staticState: staticState,
        onSubagents: onSubagents,
        tr: tr,
        controller: controller,
        groups: this.groups,
        onExpandGroup: onExpandGroup,
        onOpen: onNode,
        onMenu: onNodeMenu,
        animate: animate,
        lightFps: lightFps,
        smartCards: smartCards,
        smartAskColumns: smartAskColumns,
        onSmartProvider: onSmartProvider,
        onSmartTask: onSmartTask,
        smartHelpers: smartHelpers,
        client: client,
        onSmartApplied: onSmartApplied,
        smartStatus: smartStatus,
        smartStatusTarget: smartStatusTarget,
      );
    }
    final groups = readOnly ? null : this.groups;
    final allNodes = (graph['nodes'] as List).cast<Map<String, dynamic>>();
    final allEdges = (graph['edges'] as List).cast<Map<String, dynamic>>();
    final shownCols = [for (var i = 0; i < columns.length; i++) i];
    final nodes = [
      for (final n in allNodes)
        if (shownCols.contains(n['column'] as int)) n,
    ];
    final shownNodeIds = {for (final n in nodes) n['id']};
    final edges = [
      for (final e in allEdges)
        if (shownNodeIds.contains(e['source']) &&
            shownNodeIds.contains(e['target']))
          e,
    ];
    final counts = <int, int>{};
    for (final node in nodes) {
      final col = node['column'] as int;
      counts[col] = (counts[col] ?? 0) + 1;
    }
    final startTop = groups == null ? 64.0 : (smartCards ? 156.0 : 106.0);
    final height = math
        .max(
          readOnly ? 0 : 650,
          (counts.values.fold<int>(0, math.max) * 106) +
              (groups == null ? 170 : (smartCards ? 220 : 210)),
        )
        .toDouble();
    final colors = Theme.of(context).colorScheme;

    Widget buildCanvas({
      required double colWidth,
      required double colGap,
      required double boxWidth,
      required double inset,
      required Size canvasSize,
    }) {
      final step = colWidth + colGap;
      double colLeft(int col) {
        final slot = shownCols.indexOf(col);
        return inset + 24 + (slot < 0 ? col : slot) * step;
      }

      final positions = <String, Offset>{};
      final rowCounts = <int, int>{};
      for (final node in nodes) {
        final col = node['column'] as int;
        final row = rowCounts[col] ?? 0;
        positions[node['id'] as String] = Offset(
          colLeft(col),
          startTop + row * 106,
        );
        rowCounts[col] = row + 1;
      }
      return SizedBox(
        width: canvasSize.width,
        height: canvasSize.height,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _Connections(
                  positions,
                  edges,
                  colors.outlineVariant,
                  anchors,
                  colors.primary,
                  boxWidth: boxWidth,
                ),
              ),
            ),
            for (final col in shownCols)
              Positioned(
                left: colLeft(col),
                top: groups == null ? 16 : 8,
                width: colWidth,
                height: groups == null ? 40 : 86,
                child: groups == null
                    ? Text(
                        tr(columns[col]),
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    : MapGroupCard(
                        group: groups[col],
                        tr: tr,
                        onExpand: () => onExpandGroup?.call(col),
                      ),
              ),
            for (final node in nodes)
              Positioned(
                left: positions[node['id']]!.dx,
                top: positions[node['id']]!.dy,
                width: boxWidth,
                height: 88,
                child: Semantics(
                  button:
                      !readOnly && (onNode != null || node['kind'] == 'agent'),
                  label: node['label'] as String,
                  child: Card(
                    shape: focusedNode == node['id']
                        ? RoundedRectangleBorder(
                            side: BorderSide(color: colors.primary, width: 2),
                            borderRadius: BorderRadius.circular(
                              corners(context),
                            ),
                          )
                        : null,
                    color: node['status'] == 'running'
                        ? colors.secondaryContainer
                        : node['status'] == 'missing'
                        ? colors.surfaceContainerLowest
                        : colors.surfaceContainer,
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onSecondaryTap: readOnly || onNodeMenu == null
                          ? null
                          : () => onNodeMenu!(context, node),
                      onTap: readOnly
                          ? null
                          : onNode != null
                          ? () => onNode!(node)
                          : node['kind'] == 'agent'
                          ? () => onAgent(
                              (node['id'] as String).substring('agent:'.length),
                            )
                          : null,
                      // The Actions button keeps its place in the title row
                      // but takes a 44 × 44 corner of the box (tap targets).
                      child: Stack(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Row(
                                  children: [
                                    Expanded(child: _title(node)),
                                    if (!readOnly && onNodeMenu != null)
                                      const SizedBox(width: 28, height: 28),
                                  ],
                                ),
                                if ('${node['detail'] ?? ''}'.isNotEmpty)
                                  Text(
                                    node['detail'] as String,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (!readOnly && onNodeMenu != null)
                            Positioned(
                              top: 11,
                              right: 4,
                              width: 44,
                              height: 44,
                              child: IconButton(
                                padding: EdgeInsets.zero,
                                tooltip: tr('Actions'),
                                onPressed: () => onNodeMenu!(context, node),
                                icon: const Icon(Icons.more_vert, size: 18),
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
      );
    }

    if (readOnly) {
      final canvasSize = Size((shownCols.length * 290 + 20).toDouble(), height);
      return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerRight,
        child: buildCanvas(
          colWidth: 250,
          colGap: 40,
          boxWidth: 242,
          inset: 0,
          canvasSize: canvasSize,
        ),
      );
    }

    return _InteractiveBoard(
      shownCols: shownCols,
      height: height,
      controller: controller,
      onViewChanged: onViewChanged,
      buildCanvas: buildCanvas,
    );
  }
}

class _InteractiveBoard extends StatefulWidget {
  const _InteractiveBoard({
    required this.shownCols,
    required this.height,
    required this.controller,
    required this.onViewChanged,
    required this.buildCanvas,
  });
  final List<int> shownCols;
  final double height;
  final TransformationController? controller;
  final VoidCallback? onViewChanged;
  final Widget Function({
    required double colWidth,
    required double colGap,
    required double boxWidth,
    required double inset,
    required Size canvasSize,
  })
  buildCanvas;

  @override
  State<_InteractiveBoard> createState() => _InteractiveBoardState();
}

class _InteractiveBoardState extends State<_InteractiveBoard> {
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final colCount = widget.shownCols.length;
      final width = box.maxWidth.isFinite ? box.maxWidth : 0.0;
      final minNatural =
          48.0 + colCount * 250.0 + math.max(0, colCount - 1) * 40.0;
      final double colWidth, colGap, boxWidth, inset;
      if (colCount == 0 || width <= minNatural) {
        colWidth = 250;
        colGap = 40;
        boxWidth = 242;
        inset = 0;
      } else {
        colGap = (width * 0.035).floorToDouble().clamp(36.0, 96.0);
        colWidth = ((width - 48.0 - (colCount - 1) * colGap) / colCount)
            .floorToDouble()
            .clamp(250.0, 420.0);
        boxWidth = colWidth - 8;
        final natural = 48.0 + colCount * colWidth + (colCount - 1) * colGap;
        inset = width > natural ? ((width - natural) / 2).floorToDouble() : 0;
      }
      final naturalWidth = colCount == 0
          ? 20.0
          : inset * 2 + 48.0 + colCount * colWidth + (colCount - 1) * colGap;
      final canvasSize = Size(naturalWidth, widget.height);
      final canvas = widget.buildCanvas(
        colWidth: colWidth,
        colGap: colGap,
        boxWidth: boxWidth,
        inset: inset,
        canvasSize: canvasSize,
      );
      final controller = widget.controller;
      final onViewChanged = widget.onViewChanged;
      final viewer = InteractiveViewer(
        transformationController: controller,
        onInteractionEnd: (_) => onViewChanged?.call(),
        constrained: false,
        scaleEnabled: false, // the wheel scrolls; zoom has its control
        minScale: 0.3,
        maxScale: 2,
        boundaryMargin: const EdgeInsets.fromLTRB(0, 0, 120, 120),
        child: canvas,
      );
      final zoom = controller;
      if (zoom == null) {
        return viewer;
      }
      void clampAndSave() {
        if (!context.mounted) return; // the map was closed
        scrollMap(
          zoom,
          Offset.zero,
          viewport: box.biggest,
          content: canvasSize,
        );
        onViewChanged?.call();
      }

      void fitToWindow() {
        if (!context.mounted) return;
        final w = box.biggest.width;
        final scale = w > 0 && canvasSize.width > 0
            ? (w / canvasSize.width).clamp(0.3, 1.0)
            : 1.0;
        zoom.value = Matrix4.diagonal3Values(scale, scale, 1);
        clampAndSave();
      }

      mapClamp[zoom] = clampAndSave;
      mapFit[zoom] = fitToWindow;
      return Stack(
        children: [
          Positioned.fill(
            child: Listener(
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) {
                  GestureBinding.instance.pointerSignalResolver.register(
                    event,
                    (e) {
                      scrollMap(
                        zoom,
                        (e as PointerScrollEvent).scrollDelta,
                        viewport: box.biggest,
                        content: canvasSize,
                      );
                      onViewChanged?.call();
                    },
                  );
                }
              },
              child: viewer,
            ),
          ),
        ],
      );
    },
  );
}

class _Connections extends CustomPainter {
  _Connections(
    this.positions,
    this.edges,
    this.color,
    this.anchors,
    this.anchorColor, {
    this.boxWidth = 242,
  });
  final Set<String> anchors;
  final Color anchorColor;
  final Map<String, Offset> positions;
  final List<Map<String, dynamic>> edges;
  final Color color;
  final double boxWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final anchorPaint = Paint()
      ..color = anchorColor
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (final id in anchors) {
      final position = positions[id];
      if (position == null) continue;
      final start = position + Offset(boxWidth, 41);
      final middle = (start.dx + size.width) / 2;
      canvas.drawPath(
        Path()
          ..moveTo(start.dx, start.dy)
          ..cubicTo(
            middle,
            start.dy,
            middle,
            size.height / 2,
            size.width,
            size.height / 2,
          ),
        anchorPaint,
      );
    }
    for (final edge in edges) {
      final source = positions[edge['source']];
      final target = positions[edge['target']];
      if (source == null || target == null) continue;
      final forward = source.dx <= target.dx;
      final start = source + Offset(forward ? boxWidth : 0, 41);
      final end = target + Offset(forward ? 0 : boxWidth, 41);
      final middle = (start.dx + end.dx) / 2;
      canvas.drawPath(
        Path()
          ..moveTo(start.dx, start.dy)
          ..cubicTo(middle, start.dy, middle, end.dy, end.dx, end.dy),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _Connections oldDelegate) =>
      positions != oldDelegate.positions ||
      edges != oldDelegate.edges ||
      color != oldDelegate.color ||
      anchors != oldDelegate.anchors ||
      anchorColor != oldDelegate.anchorColor ||
      boxWidth != oldDelegate.boxWidth;
}
