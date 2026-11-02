import 'package:flutter/material.dart';

import 'app_look.dart' show AppSpace, StatusColors;

/// The terminal tabs above the map (ai_popup.build_terminal_tabs): while an
/// agent has a terminal here, a legend over one tab per terminal with a dot
/// for working, running or ended; a click shows it, the one in view is
/// marked.
class TerminalTabs extends StatelessWidget {
  const TerminalTabs({
    super.key,
    required this.tabs,
    required this.current,
    required this.tr,
    required this.onSelect,
  });

  /// (label, state: working | running | ended), in the terminals' order.
  final List<(String, String)> tabs;
  final int? current;
  final String Function(String) tr;
  final ValueChanged<int> onSelect;

  static Color colour(BuildContext context, String state) => switch (state) {
    'working' => StatusColors.ok,
    'running' => Theme.of(context).colorScheme.primary,
    _ => Theme.of(context).colorScheme.outline,
  };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.sm,
        AppSpace.xs,
        AppSpace.sm,
        AppSpace.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  tr('Terminals').toUpperCase(),
                  style: text.labelSmall,
                ),
              ),
              for (final state in ['working', 'running', 'ended'])
                Padding(
                  padding: const EdgeInsets.only(left: AppSpace.md),
                  child: Text(
                    '● ${tr(state)}',
                    style: text.labelSmall?.copyWith(
                      color: colour(context, state),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (var i = 0; i < tabs.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpace.sm),
                    child: ChoiceChip(
                      key: ValueKey('terminal-tab-$i'),
                      selected: current == i,
                      showCheckmark: false,
                      avatar: Text(
                        '●',
                        style: TextStyle(color: colour(context, tabs[i].$2)),
                      ),
                      label: Text(tabs[i].$1),
                      tooltip: tr(tabs[i].$2),
                      onSelected: (_) => onSelect(i),
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
