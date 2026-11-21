import 'package:flutter/material.dart';

import 'app_look.dart';

/// The two main tabs of the window.
enum MainTab {
  projects('projects'),
  map('map');

  const MainTab(this.code);

  /// As saved in the `main_tab` setting.
  final String code;

  static MainTab? fromCode(Object? code) => switch (code) {
    'projects' => MainTab.projects,
    'map' => MainTab.map,
    _ => null,
  };
}

/// The start tab, decided once after the startup data loaded (task 086):
/// the AI Map while setup is needed, else the last used tab, else Projects
/// when a project exists. [summary] is null when it could not be read in
/// time: the AI Map.
MainTab startTab({
  required bool setupNeeded,
  required Object? saved,
  required Map<String, dynamic>? summary,
}) {
  if (setupNeeded) return MainTab.map;
  final chosen = MainTab.fromCode(saved);
  if (chosen != null) return chosen;
  if (summary == null || summary['connected'] == false) return MainTab.map;
  return ((summary['total'] as num?) ?? 0) > 0 ? MainTab.projects : MainTab.map;
}

/// What the Projects tab shows of `features.summary`.
final class ProjectTabCounts {
  const ProjectTabCounts({
    required this.connected,
    required this.running,
    required this.needsYou,
    required this.attention,
    required this.error,
  });

  /// Reads a summary of API 2 and of an older backend alike: an old one has
  /// no `needs_you` (its `waiting` stands for it) and counts a store fault
  /// inside `attention`.
  factory ProjectTabCounts.from(Map<String, dynamic> summary) {
    int count(String key) => (summary[key] as num?)?.toInt() ?? 0;
    final error = summary['error'];
    return ProjectTabCounts(
      connected: summary['connected'] != false,
      running: count('running') + count('pausing'),
      needsYou: summary.containsKey('needs_you')
          ? count('needs_you')
          : count('waiting'),
      attention: summary.containsKey('attention_projects')
          ? count('attention_projects')
          : count('attention'),
      error: error is String && error.isNotEmpty ? error : null,
    );
  }

  final bool connected;
  final int running, needsYou, attention;

  /// The project store's fault: a warning mark, never a count.
  final String? error;

  bool get anything => running > 0 || needsYou > 0 || attention > 0;

  /// The tab's accessible description and tooltip.
  String describe(String Function(String) tr) {
    if (!connected) return tr('Projects · status unavailable');
    return [
      tr('Projects'),
      if (running > 0) tr('{0} running').replaceAll('{0}', '$running'),
      if (needsYou > 0) tr('{0} need you').replaceAll('{0}', '$needsYou'),
      if (attention > 0)
        tr('{0} need attention').replaceAll('{0}', '$attention'),
      if (error != null) tr('The project list has a problem'),
    ].join(' · ');
  }
}

/// `[ Projects ]  [ AI Map ]` at the left of the header. The Projects tab
/// carries the project counts (one dot when [compact]) and the store
/// fault's warning mark; the tabs never wrap.
class MainTabs extends StatelessWidget {
  const MainTabs({
    super.key,
    required this.selected,
    required this.summary,
    required this.tr,
    required this.onSelect,
    this.compact = false,
  });

  final MainTab selected;
  final Map<String, dynamic> summary;
  final String Function(String) tr;

  /// Null greys both tabs out (a task or a card owns the window).
  final ValueChanged<MainTab>? onSelect;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final counts = ProjectTabCounts.from(summary);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _MainTabButton(
          key: const ValueKey('tab-projects'),
          label: tr('Projects'),
          selected: selected == MainTab.projects,
          tooltip: counts.describe(tr),
          onPressed: onSelect == null
              ? null
              : () => onSelect!(MainTab.projects),
          trailing: _ProjectCounts(counts: counts, compact: compact, tr: tr),
        ),
        const SizedBox(width: AppSpace.xs),
        _MainTabButton(
          // The key the AI Map button always had.
          key: const ValueKey('ai-map-open'),
          label: tr('AI Map'),
          selected: selected == MainTab.map,
          tooltip: tr('AI Map'),
          onPressed: onSelect == null ? null : () => onSelect!(MainTab.map),
        ),
      ],
    );
  }
}

class _MainTabButton extends StatelessWidget {
  const _MainTabButton({
    super.key,
    required this.label,
    required this.selected,
    required this.tooltip,
    required this.onPressed,
    this.trailing,
  });

  final String label, tooltip;
  final bool selected;
  final VoidCallback? onPressed;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // The button keeps its own semantics (tap, enabled); its node reads the
    // full description and whether the tab is selected.
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: selected ? colors.primary : colors.onSurface,
          shape: const RoundedRectangleBorder(),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
        ),
        child: Semantics(
          label: tooltip,
          selected: selected,
          child: ExcludeSemantics(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    width: 2,
                    color: selected ? colors.primary : Colors.transparent,
                  ),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Running, needs you and attention beside the Projects tab, each with its
/// own symbol (never colour alone); "status unavailable" as a crossed cloud.
class _ProjectCounts extends StatelessWidget {
  const _ProjectCounts({
    required this.counts,
    required this.compact,
    required this.tr,
  });

  final ProjectTabCounts counts;
  final bool compact;
  final String Function(String) tr;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final items = <Widget>[];
    if (!counts.connected) {
      items.add(
        Icon(
          key: const ValueKey('tab-projects-unavailable'),
          Icons.cloud_off_outlined,
          size: 16,
          color: colors.onSurfaceVariant,
        ),
      );
    } else if (compact) {
      if (counts.anything) {
        items.add(
          Container(
            key: const ValueKey('tab-projects-dot'),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: counts.attention > 0
                  ? colors.error
                  : counts.needsYou > 0
                  ? StatusColors.warn
                  : colors.primary,
            ),
          ),
        );
      }
    } else {
      Widget count(String key, IconData icon, int value, Color color) => Row(
        key: ValueKey(key),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          Text('$value', style: TextStyle(fontSize: 12, color: color)),
        ],
      );
      if (counts.running > 0) {
        items.add(
          count(
            'tab-projects-running',
            Icons.play_arrow,
            counts.running,
            colors.primary,
          ),
        );
      }
      if (counts.needsYou > 0) {
        items.add(
          count(
            'tab-projects-needs-you',
            Icons.front_hand_outlined,
            counts.needsYou,
            StatusColors.warn,
          ),
        );
      }
      if (counts.attention > 0) {
        items.add(
          count(
            'tab-projects-attention',
            Icons.error_outline,
            counts.attention,
            colors.error,
          ),
        );
      }
    }
    if (counts.connected && counts.error != null) {
      items.add(
        Icon(
          key: const ValueKey('tab-projects-fault'),
          Icons.warning_amber,
          size: 16,
          color: colors.error,
        ),
      );
    }
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: AppSpace.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: AppSpace.xs,
        children: items,
      ),
    );
  }
}
