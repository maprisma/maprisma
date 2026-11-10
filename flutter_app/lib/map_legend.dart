import 'package:flutter/material.dart';

import 'app_theme.dart' show cornerSizes;
import 'map_groups.dart' show AgentBadge;
import 'map_layout.dart' show mapCollaborationColor;

/// agent_details.warn_levels: Settings › Costs' (yellow, red) as % used,
/// red always above yellow; else the defaults (75, 90).
(int, int) warnPercents(Map settings) {
  final yellow = settings['warn_yellow'], red = settings['warn_red'];
  return yellow is int && red is int && red > yellow ? (yellow, red) : (75, 90);
}

/// What the marks on the map mean (the ⓘ in the header).
class MapLegendButton extends StatelessWidget {
  const MapLegendButton({
    super.key,
    required this.tr,
    this.enabled = true,
    this.levels = (75, 90),
  });
  final String Function(String) tr;
  final bool enabled;

  /// Settings › Costs' yellow and red levels, as % used (warnPercents).
  final (int, int) levels;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('map-legend'),
    tooltip: tr('What the marks mean'),
    icon: const Icon(Icons.info_outline),
    onPressed: enabled
        ? () => showDialog<void>(
            context: context,
            builder: (_) => MapLegend(tr: tr, levels: levels),
          )
        : null,
  );
}

class MapLegend extends StatelessWidget {
  const MapLegend({super.key, required this.tr, this.levels = (75, 90)});
  final String Function(String) tr;
  final (int, int) levels;

  Widget _row(Widget mark, String text, [String? value]) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        SizedBox(width: 44, child: Center(child: mark)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value == null ? tr(text) : tr(text).replaceAll('{0}', value),
          ),
        ),
      ],
    ),
  );

  Widget _battery(String colour, double left, {bool stale = false}) =>
      AgentBadge(
        badge: {
          'kind': 'battery',
          'colour': colour,
          'left': left,
          'tip': '',
          if (stale) 'stale': true,
        },
      );

  Widget _line(Color colour, double width) =>
      Container(width: 36, height: width, color: colour);

  Widget _heading(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 2),
    child: Text(tr(text), style: Theme.of(context).textTheme.titleSmall),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(tr('What the marks mean')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _heading(context, 'Boxes'),
              _row(
                Container(
                  width: 36,
                  height: 18,
                  decoration: BoxDecoration(
                    color: colors.secondaryContainer,
                    borderRadius: BorderRadius.circular(
                      cornerSizes(context).small,
                    ),
                  ),
                ),
                'A tinted box is running.',
              ),
              _row(
                Container(
                  width: 36,
                  height: 18,
                  decoration: BoxDecoration(
                    border: Border.all(color: colors.primary, width: 2),
                    borderRadius: BorderRadius.circular(
                      cornerSizes(context).small,
                    ),
                  ),
                ),
                'A bright border: selected, or connected to the box you point at.',
              ),
              _heading(context, 'Battery'),
              _row(
                _battery('green', .9),
                "Green: what is left of an agent's plan limits or of a day's limit (paid per token), or free GPU memory on a running local LLM.",
              ),
              // The cards' levels (agent_badges.charge: this much left or
              // less), not fixed ones.
              _row(
                _battery('yellow', (100 - levels.$1) / 100),
                'Yellow: {0} % or less is left.',
                '${100 - levels.$1}',
              ),
              _row(
                _battery('red', (100 - levels.$2) / 200),
                'Red: {0} % or less is left.',
                '${100 - levels.$2}',
              ),
              _row(
                _battery('green', .6, stale: true),
                'Faded: its numbers may be out of date (its tooltip says when they were measured).',
              ),
              _heading(context, 'Lines'),
              _row(
                _line(colors.primary, 2),
                'A connection. Moving lights show it is in use.',
              ),
              _row(
                _line(mapCollaborationColor(colors), 3),
                "Agents working together: the arrow points from the agent that hands out work to the agent it uses (e.g. Claude Code asking Codex). While they work, the used agent's lines take this colour and light flows; afterwards the arrow stays dim.",
              ),
              _row(
                _line(colors.outlineVariant, 1),
                'Dim: it belongs to other boxes than the selected one.',
              ),
              _row(
                _line(colors.error, 2),
                'Red: this connection has a problem.',
              ),
              _row(
                const Icon(Icons.circle, color: Colors.orange, size: 13),
                'Round hook on a selected box\'s line: drag it to another box, or click it, then Disconnect.',
              ),
              _heading(context, 'Symbols on a box'),
              _row(
                const Icon(Icons.account_tree_outlined, size: 18),
                'Subagents, with their number.',
              ),
              _row(
                const Icon(Icons.swap_vert, size: 18),
                'Network traffic: it has connections now.',
              ),
              _row(const Icon(Icons.info_outline, size: 18), 'Details.'),
              _row(const Icon(Icons.bar_chart_outlined, size: 18), 'Usage.'),
              _row(const Icon(Icons.play_arrow, size: 18), 'Start.'),
              _row(
                const Icon(Icons.terminal, size: 18),
                'Its terminal in this app.',
              ),
              _row(
                Icon(Icons.stop, size: 18, color: colors.error),
                'Red stop: stops it, shown only while it runs.',
              ),
              _row(
                const Icon(Icons.drag_handle, size: 18),
                'Drag to change the order in its card.',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('Close')),
        ),
      ],
    );
  }
}
