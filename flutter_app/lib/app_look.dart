import 'package:flutter/material.dart';

import 'app_theme.dart' show corners;

/// The app's spacing steps: every gap and padding is one of these.
abstract final class AppSpace {
  static const xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 24.0;
}

/// The top of every window and side page: title, an optional line under it,
/// actions, and Back at the right. Esc does what Back does where it is used.
class WindowHeader extends StatelessWidget {
  const WindowHeader({
    super.key,
    required this.title,
    required this.tr,
    this.subtitle,
    this.actions = const [],
    this.onBack,
    this.backKey,
  });
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final String Function(String) tr;

  /// Null greys Back out: something runs that cannot be left.
  final VoidCallback? onBack;
  final Key? backKey;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.md,
            AppSpace.md,
            AppSpace.md,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: text.titleLarge),
                    if (subtitle != null) ...[
                      const SizedBox(height: AppSpace.xs),
                      Text(
                        subtitle!,
                        style: text.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              for (final action in actions) ...[
                const SizedBox(width: AppSpace.sm),
                action,
              ],
              const SizedBox(width: AppSpace.sm),
              TextButton.icon(
                key: backKey,
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
                label: Text(tr('Back')),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}

/// The bottom of a window: its buttons at the right, the main one last.
class WindowFooter extends StatelessWidget {
  const WindowFooter({super.key, required this.children, this.leading});
  final List<Widget> children;
  final Widget? leading;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Divider(height: 1),
      Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        // The buttons wrap when the window is narrow, the main one last.
        child: Row(
          children: [
            if (leading != null) ...[
              Expanded(child: leading!),
              const SizedBox(width: AppSpace.md),
            ],
            Expanded(
              child: Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.sm,
                alignment: WrapAlignment.end,
                children: children,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

/// A group of things that belong together, drawn like the map's category
/// cards: a title band, then its body.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.title,
    required this.child,
    this.trailing,
    this.padding = const EdgeInsets.all(AppSpace.md),
  });

  /// Null: no title band, only the body.
  final String? title;
  final Widget child;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(corners(context)),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.md,
                AppSpace.sm,
                AppSpace.sm,
                AppSpace.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title!,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
            Divider(height: 1, color: colors.outlineVariant),
          ],
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

/// A row with its words at the left and its control at the right.
class SettingRow extends StatelessWidget {
  const SettingRow({
    super.key,
    required this.title,
    required this.control,
    this.subtitle,
  });
  final String title;
  final String? subtitle;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.bodyMedium),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: text.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.md),
          control,
        ],
      ),
    );
  }
}
