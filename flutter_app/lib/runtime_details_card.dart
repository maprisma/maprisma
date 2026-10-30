import 'package:flutter/material.dart';

import 'core_client.g.dart';

/// A local LLM's details (providers.details, the GTK local LLM page): whether
/// it runs and what it holds on the GPU, its models, agents and address,
/// what agents sent through it, and who can reach it.
class RuntimeDetailsCard extends StatefulWidget {
  const RuntimeDetailsCard({
    super.key,
    required this.runtime,
    required this.call,
    required this.tr,
  });
  final String runtime;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
  call;
  final String Function(String) tr;

  @override
  State<RuntimeDetailsCard> createState() => _RuntimeDetailsCardState();
}

class _RuntimeDetailsCardState extends State<RuntimeDetailsCard> {
  Map<String, dynamic>? _details;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(RuntimeDetailsCard old) {
    super.didUpdateWidget(old);
    if (old.runtime != widget.runtime) _load();
  }

  Future<void> _load() async {
    try {
      final found = await CoreClient.fromCall(
        widget.call,
      ).providersDetails(key: widget.runtime);
      if (mounted) setState(() => _details = found);
    } catch (_) {
      // No card: the rest of the page is shown.
    }
  }

  Widget _tiles(BuildContext context, List tiles) {
    final text = Theme.of(context).textTheme;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final tile in tiles.cast<List>())
          SizedBox(
            width: 200,
            child: Card.outlined(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${tile[0]}', style: text.labelMedium),
                    Text('${tile[1]}', style: text.titleLarge),
                    if ('${tile[2]}'.isNotEmpty)
                      Text(
                        '${tile[2]}',
                        style: text.bodySmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final details = _details;
    // Nothing (or an answer without the page's fields): no card.
    if (details == null || details['tiles'] is! List) {
      return const SizedBox.shrink();
    }
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final usage = details['usage'] as Map?;
    final risks = (details['risks'] as List? ?? const []).cast<Map>();
    return Column(
      key: ValueKey('runtime-details-${widget.runtime}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: SelectableText('${details['now']}', style: text.bodyMedium),
        ),
        _tiles(context, details['tiles'] as List),
        if (usage != null)
          Card(
            child: ExpansionTile(
              leading: const Icon(Icons.bar_chart),
              title: Text('${usage['title']}'),
              subtitle: Text('${usage['summary']}'),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _tiles(context, usage['tiles'] as List),
                const SizedBox(height: 12),
                Text('${usage['models_title']}', style: text.titleSmall),
                for (final row in (usage['models'] as List).cast<List>())
                  Row(
                    children: [
                      Expanded(flex: 3, child: SelectableText('${row[0]}')),
                      Expanded(flex: 2, child: Text('${row[1]}')),
                    ],
                  ),
                const SizedBox(height: 8),
                Text('${usage['note']}', style: text.bodySmall),
              ],
            ),
          ),
        if (risks.isNotEmpty)
          Card(
            child: ExpansionTile(
              leading: const Icon(Icons.shield_outlined),
              title: Text(widget.tr('Risk management')),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                for (final r in risks)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      r['level'] == 'ok'
                          ? Icons.check_circle_outline
                          : r['level'] == 'high'
                          ? Icons.error_outline
                          : Icons.info_outline,
                      color: r['level'] == 'ok'
                          ? Colors.green
                          : r['level'] == 'high'
                          ? scheme.error
                          : scheme.outline,
                    ),
                    title: Text('${r['title']}'),
                    subtitle: Text(
                      [
                        '${r['text']}',
                        if ('${r['step']}'.isNotEmpty) '${r['step']}',
                      ].join('\n'),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
