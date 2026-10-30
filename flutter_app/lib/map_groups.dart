import 'package:flutter/material.dart';
import 'app_theme.dart' show corners;
import 'package:flutter/services.dart';

/// UI-only metadata. Never inserted into the graph or serialized.
class MapGroup {
  const MapGroup(
    this.category,
    this.label,
    this.count,
    this.found, [
    this.available = 0,
  ]);
  final int category;
  final String label;
  final int count, found, available;
  bool get dummy => count == 0;
  static List<MapGroup> fromGraph(
    Map<String, dynamic> graph,
    List<String> columns, {
    Map<int, int> found = const {},
    Map<int, int> available = const {},
  }) => [
    for (var i = 0; i < columns.length; i++)
      MapGroup(
        i,
        columns[i],
        (graph['nodes'] as List? ?? []).where((n) => n['column'] == i).length,
        found[i] ?? 0,
        available[i] ?? found[i] ?? 0,
      ),
  ];
}

class MapGroupCard extends StatelessWidget {
  const MapGroupCard({
    super.key,
    required this.group,
    required this.tr,
    required this.onExpand,
  });
  final MapGroup group;
  final String Function(String) tr;
  final VoidCallback onExpand;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: tr(
        group.dummy ? 'Nothing set up yet. Expand to add one' : 'Expand',
      ),
      child: CustomPaint(
        foregroundPainter: group.dummy
            ? _DashedBorder(colors.outline, corners(context))
            : null,
        child: Card(
          color: group.dummy
              ? colors.surfaceContainerLowest
              : colors.surfaceContainerHigh,
          child: InkWell(
            onTap: onExpand,
            borderRadius: BorderRadius.circular(corners(context)),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  if (group.dummy) const Icon(Icons.add, size: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          tr(group.label),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          group.dummy
                              ? group.found > 0
                                    ? tr(
                                        '{0} found on this PC · Expand',
                                      ).replaceAll('{0}', '${group.found}')
                                    : tr('None yet · Expand to add one')
                              : tr('{0} on · {1} more available')
                                    .replaceAll('{0}', '${group.count}')
                                    .replaceAll('{1}', '${group.available}'),
                          maxLines: 2,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: tr('Expand'),
                    onPressed: onExpand,
                    icon: const Icon(Icons.open_in_full, size: 18),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  _DashedBorder(this.color, this.radius);
  final Color color;
  final double radius;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke;
    for (final metric in path.computeMetrics()) {
      for (double i = 0; i < metric.length; i += 10) {
        canvas.drawPath(metric.extractPath(i, i + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}

/// Finite transition only; the map's controller and selection live outside it.
class MapFocus extends StatelessWidget {
  const MapFocus({
    super.key,
    required this.title,
    required this.tr,
    required this.onBack,
    required this.child,
    this.footer,
    this.hosted = false,
  });
  final String title;
  final String Function(String) tr;
  final VoidCallback onBack;
  final Widget child;
  final Widget? footer;
  final bool hosted;
  @override
  Widget build(BuildContext context) {
    final content = Column(
      children: [
        if (!hosted)
          ListTile(
            leading: IconButton(
              tooltip: tr('Back'),
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
            ),
            title: Text(
              tr(title),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
        Expanded(child: child),
        if (footer != null) ...[const Divider(height: 1), footer!],
      ],
    );
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            [
              LogicalKeyboardKey.escape,
              LogicalKeyboardKey.backspace,
            ].contains(event.logicalKey)) {
          if (event.logicalKey == LogicalKeyboardKey.backspace &&
              FocusManager.instance.primaryFocus?.context
                      ?.findAncestorWidgetOfExactType<EditableText>() !=
                  null) {
            return KeyEventResult.ignored;
          }
          onBack();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: hosted
          ? content
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onBack,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: GestureDetector(
                    onTap: () {},
                    child: Card(
                      margin: const EdgeInsets.all(16),
                      child: content,
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
