import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_look.dart';
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
          WindowHeader(
            title: spec.title,
            tr: tr,
            backKey: const ValueKey('task-back'),
            onBack: spec.closable ? onClose : null,
          ),
          Expanded(
            child: _HostTitle(title: spec.title, child: spec.child),
          ),
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

/// The title of the window a review sits in.
class _HostTitle extends InheritedWidget {
  const _HostTitle({required this.title, required super.child});
  final String title;

  static bool repeats(BuildContext context, Widget title) {
    final host = context
        .dependOnInheritedWidgetOfExactType<_HostTitle>()
        ?.title;
    return host != null && title is Text && title.data == host;
  }

  @override
  bool updateShouldNotify(_HostTitle old) => title != old.title;
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
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The window's header already says it: no second heading.
              if (title != null && !_HostTitle.repeats(context, title!)) ...[
                title!,
                const SizedBox(height: AppSpace.lg),
              ],
              content,
            ],
          ),
        ),
      ),
      WindowFooter(children: actions),
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
