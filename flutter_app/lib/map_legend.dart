import 'package:flutter/material.dart';

import 'map_groups.dart' show AgentBadge;

/// What the marks on the map mean (the ⓘ in the header).
class MapLegendButton extends StatelessWidget {
  const MapLegendButton({super.key, required this.tr});
  final String Function(String) tr;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('map-legend'),
    tooltip: tr('What the marks mean'),
    icon: const Icon(Icons.info_outline),
    onPressed: () => showDialog<void>(
      context: context,
      builder: (_) => MapLegend(tr: tr),
    ),
  );
}

class MapLegend extends StatelessWidget {
  const MapLegend({super.key, required this.tr});
  final String Function(String) tr;

  Widget _row(Widget mark, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        SizedBox(width: 44, child: Center(child: mark)),
        const SizedBox(width: 12),
        Expanded(child: Text(tr(text))),
      ],
    ),
  );

  Widget _battery(String colour, double left) => AgentBadge(
    badge: {'kind': 'battery', 'colour': colour, 'left': left, 'tip': ''},
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
                    borderRadius: BorderRadius.circular(4),
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
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                'A bright border: selected, or connected to the box you point at.',
              ),
              _heading(context, 'Battery'),
              _row(
                _battery('green', .9),
                'Green: what is left of an agent\'s plan limits, or free GPU memory on a running local LLM.',
              ),
              _row(
                _battery('yellow', .2),
                'Yellow: a quarter or less is left.',
              ),
              _row(_battery('red', .05), 'Red: under a tenth is left.'),
              _heading(context, 'Lines'),
              _row(
                _line(colors.primary, 2),
                'A connection. Moving lights show it is in use.',
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
