import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_theme.dart' show corners;
import 'overlay_window.dart';

class TaskCardSpec {
  const TaskCardSpec({
    required this.title,
    required this.child,
    this.closable = true,
  });
  final String title;
  final Widget child;
  final bool closable;
}

class TaskHost extends StatelessWidget {
  const TaskHost({
    super.key,
    required this.spec,
    required this.tr,
    required this.onClose,
    this.overlay = false,
  });
  final TaskCardSpec spec;
  final String Function(String) tr;
  final VoidCallback onClose;

  /// An action in the window over the page; otherwise the whole page.
  final bool overlay;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final card = Material(
      key: const ValueKey('task-card'),
      color: colors.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(corners(context)),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    spec.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                TextButton.icon(
                  onPressed: spec.closable ? onClose : null,
                  icon: const Icon(Icons.arrow_back),
                  label: Text(tr('Back')),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: spec.child),
        ],
      ),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (spec.closable) onClose();
        },
      },
      child: Focus(
        autofocus: true,
        child: overlay
            ? OverlayWindow(key: const ValueKey('overlay-task'), child: card)
            : Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox.expand(
                  key: const ValueKey('full-task'),
                  child: card,
                ),
              ),
      ),
    );
  }
}

/// Reuses existing review contents while keeping actions inside the task card.
class TaskReview extends StatelessWidget {
  const TaskReview({
    super.key,
    this.title,
    required this.content,
    required this.actions,
  });
  final Widget? title;
  final Widget content;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [?title, const SizedBox(height: 16), content],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(spacing: 8, runSpacing: 8, children: actions),
      ),
    ],
  );
}

/// Preserve task-view state under a review without keeping a main map alive.
class RetainedTaskView extends StatelessWidget {
  const RetainedTaskView({
    super.key,
    required this.visible,
    required this.child,
    this.focusable = true,
  });
  final bool visible;
  final Widget child;

  /// False under an overlay card: seen, but the keyboard stays with the card.
  final bool focusable;
  @override
  Widget build(BuildContext context) => Offstage(
    offstage: !visible,
    child: ExcludeFocus(
      excluding: !visible || !focusable,
      child: TickerMode(enabled: visible, child: child),
    ),
  );
}
