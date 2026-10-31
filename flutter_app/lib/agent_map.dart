import 'dart:async' show FutureOr;
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show GestureBinding, PointerScrollEvent;
import 'package:flutter/material.dart';
import 'core_client.g.dart';
import 'map_groups.dart';
import 'app_theme.dart' show corners;
import 'map_editor.dart';
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
    this.onAnimationChanged,
    this.anchors = const {},
    this.onSubagents,
    this.onNode,
    this.controller,
    this.onNodeDrop,
    this.onViewChanged,
    this.focusedNode,
    this.groups,
    this.onExpandGroup,
    this.onNodeMenu,
    this.smartCards = false,
    this.smartAskColumns,
    this.onSmartProvider,
    this.smartHelpers = const [],
    this.client,
    this.onSmartApplied,
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
  final void Function(String step, String key)? onSmartProvider;
  final List<Map<String, dynamic>> smartHelpers;
  final CoreClient? client;
  final ValueChanged<Map<String, dynamic>>? onSmartApplied;
  final Set<String>? selection;
  final Widget Function(Map<String, dynamic>)? controls;
  final Future<void> Function(Map<String, dynamic>)? onEdit;
  final Map<String, dynamic> savedLayout;
  final ValueChanged<Map<String, dynamic>>? onLayout;
  final String animate;
  final int lightFps;
  final ValueChanged<String>? onAnimationChanged;
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
  final void Function(Map<String, dynamic>, Map<String, dynamic>)? onNodeDrop;
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
        if ((node['badges'] as int? ?? 0) > 0)
          Tooltip(
            message: tr('Findings'),
            child: Badge(
              backgroundColor: Colors.blueGrey,
              label: Text('${node['badges']}'),
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

  Widget _interactiveNode(
    BuildContext context,
    Map<String, dynamic> node,
    Widget child,
  ) {
    if (readOnly || onNodeDrop == null) return child;
    final target = DragTarget<Map<String, dynamic>>(
      onWillAcceptWithDetails: (details) =>
          details.data['id'] != node['id'] &&
          node['status'] != 'missing' &&
          ((details.data['kind'] == 'runtime' &&
                  node['found'] != null &&
                  node['kind'] != 'runtime') ||
              (['models', 'folder', 'store'].contains(details.data['kind']) &&
                  ['disk', 'runtime'].contains(node['kind']) &&
                  !(details.data['kind'] == 'store' &&
                      node['kind'] == 'disk'))),
      onAcceptWithDetails: (details) => onNodeDrop!(details.data, node),
      builder: (context, candidates, rejected) => DecoratedBox(
        decoration: BoxDecoration(
          border: candidates.isEmpty
              ? null
              : Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 2,
                ),
        ),
        child: child,
      ),
    );
    if (node['status'] == 'missing' ||
        !['runtime', 'models', 'folder', 'store'].contains(node['kind'])) {
      return target;
    }
    return Tooltip(
      message: tr(
        'Hold and drag to connect or move. A preview appears before changes.',
      ),
      child: LongPressDraggable<Map<String, dynamic>>(
        data: node,
        feedback: Material(
          child: SizedBox(
            width: 240,
            child: ListTile(title: Text(node['label'] as String)),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.4, child: target),
        child: target,
      ),
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
        onAnimationChanged: onAnimationChanged,
        smartCards: smartCards,
        smartAskColumns: smartAskColumns,
        onSmartProvider: onSmartProvider,
        smartHelpers: smartHelpers,
        client: client,
        onSmartApplied: onSmartApplied,
      );
    }
    final groups = readOnly ? null : this.groups;
    final nodes = (graph['nodes'] as List).cast<Map<String, dynamic>>();
    final edges = (graph['edges'] as List).cast<Map<String, dynamic>>();
    final counts = <int, int>{};
    for (final node in nodes) {
      final col = node['column'] as int;
      counts[col] = (counts[col] ?? 0) + 1;
    }
    final height = math
        .max(
          readOnly ? 0 : 650,
          (counts.values.fold<int>(0, math.max) * 106) + 170,
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
      final positions = <String, Offset>{};
      final rowCounts = <int, int>{};
      for (final node in nodes) {
        final col = node['column'] as int;
        final row = rowCounts[col] ?? 0;
        positions[node['id'] as String] = Offset(
          inset + 24 + col * step,
          (groups == null ? 64 : 128) + row * 106,
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
            for (var col = 0; col < columns.length; col++)
              Positioned(
                left: inset + 24 + col * step,
                top: 16,
                width: colWidth,
                height: groups == null ? 40 : 98,
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
                height: 82,
                child: _interactiveNode(
                  context,
                  node,
                  Semantics(
                    button:
                        !readOnly &&
                        (onNode != null || node['kind'] == 'agent'),
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
                                (node['id'] as String).substring(
                                  'agent:'.length,
                                ),
                              )
                            : null,
                        // The Actions button keeps its place in the title row
                        // but takes a 44 × 44 corner of the box (tap targets).
                        child: Stack(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(12),
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
              ),
          ],
        ),
      );
    }

    if (readOnly) {
      final canvasSize = Size((columns.length * 290 + 20).toDouble(), height);
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

    return LayoutBuilder(
      builder: (context, box) {
        final colCount = columns.length;
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
        final canvasSize = Size(naturalWidth, height);
        final canvas = buildCanvas(
          colWidth: colWidth,
          colGap: colGap,
          boxWidth: boxWidth,
          inset: inset,
          canvasSize: canvasSize,
        );
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
