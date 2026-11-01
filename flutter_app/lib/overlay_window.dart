import 'package:flutter/material.dart';

/// A centred window over the dimmed app: the terminal and Ask AI. What is
/// below takes no clicks until the window's own Close or Back.
class OverlayWindow extends StatelessWidget {
  const OverlayWindow({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      const ModalBarrier(color: Colors.black54, dismissible: false),
      Center(
        child: FractionallySizedBox(
          widthFactor: 0.8,
          heightFactor: 0.85,
          child: Card(clipBehavior: Clip.antiAlias, elevation: 8, child: child),
        ),
      ),
    ],
  );
}
