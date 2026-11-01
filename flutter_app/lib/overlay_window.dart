import 'package:flutter/material.dart';

/// The centred window over the dimmed map: terminal, Ask AI and every action.
/// Its edges and corners drag its size; a double click restores it. The size
/// holds until the app closes.
class OverlayWindow extends StatefulWidget {
  const OverlayWindow({super.key, required this.child});
  final Widget child;

  static Size? _chosen;
  static const _minimum = Size(420, 300);

  @override
  State<OverlayWindow> createState() => _OverlayWindowState();
}

class _OverlayWindowState extends State<OverlayWindow> {
  // The window stays centred, so an edge moves half of what the size changes.
  void _drag(Size area, Size shown, Offset delta, int x, int y) {
    final wide = (shown.width + 2 * delta.dx * x).clamp(
      OverlayWindow._minimum.width,
      area.width,
    );
    final high = (shown.height + 2 * delta.dy * y).clamp(
      OverlayWindow._minimum.height,
      area.height,
    );
    setState(() => OverlayWindow._chosen = Size(wide, high));
  }

  Widget _handle(Size area, Size shown, int x, int y) {
    const grip = 8.0, corner = 18.0;
    final cursor = x == 0
        ? SystemMouseCursors.resizeUpDown
        : y == 0
        ? SystemMouseCursors.resizeLeftRight
        : x == y
        ? SystemMouseCursors.resizeUpLeftDownRight
        : SystemMouseCursors.resizeUpRightDownLeft;
    return Positioned(
      left: x < 0 ? 0 : (x == 0 ? corner : null),
      right: x > 0 ? 0 : (x == 0 ? corner : null),
      top: y < 0 ? 0 : (y == 0 ? corner : null),
      bottom: y > 0 ? 0 : (y == 0 ? corner : null),
      width: x == 0 ? null : (y == 0 ? grip : corner),
      height: y == 0 ? null : (x == 0 ? grip : corner),
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          key: ValueKey('overlay-edge-$x-$y'),
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) => _drag(area, shown, d.delta, x, y),
          onDoubleTap: () => setState(() => OverlayWindow._chosen = null),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      const ModalBarrier(color: Colors.black54, dismissible: false),
      LayoutBuilder(
        builder: (context, area) {
          final room = area.biggest;
          final chosen = OverlayWindow._chosen;
          final shown = Size(
            (chosen?.width ?? room.width * .8).clamp(0, room.width),
            (chosen?.height ?? room.height * .85).clamp(0, room.height),
          );
          return Center(
            child: SizedBox.fromSize(
              size: shown,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Card(
                    margin: const EdgeInsets.all(4),
                    clipBehavior: Clip.antiAlias,
                    elevation: 8,
                    child: FocusScope(child: widget.child),
                  ),
                  for (final (x, y) in const [
                    (-1, 0),
                    (1, 0),
                    (0, -1),
                    (0, 1),
                    (-1, -1),
                    (1, -1),
                    (-1, 1),
                    (1, 1),
                  ])
                    _handle(room, shown, x, y),
                ],
              ),
            ),
          );
        },
      ),
    ],
  );
}
