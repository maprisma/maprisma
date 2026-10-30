import 'package:flutter/material.dart';

import 'core_client.g.dart';

/// The cost card (agents.costs, the GTK details' API cost / API value card):
/// what an agent's tokens cost at API prices today, in 7 and in 30 days, and
/// per model by kind. In euros the day's rate is fetched first (costs.rate).
class CostCard extends StatefulWidget {
  const CostCard({
    super.key,
    required this.command,
    required this.call,
    required this.tr,
  });
  final String command;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
  call;
  final String Function(String) tr;

  @override
  State<CostCard> createState() => _CostCardState();
}

class _CostCardState extends State<CostCard> {
  Map<String, dynamic>? _card;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CostCard old) {
    super.didUpdateWidget(old);
    if (old.command != widget.command) _load();
  }

  Future<void> _load({bool rateAsked = false}) async {
    final client = CoreClient.fromCall(widget.call);
    try {
      final found = await client.agentsCosts(command: widget.command);
      if (!mounted) return;
      setState(() => _card = found['card'] as Map<String, dynamic>?);
      if (found['rate_due'] == true && !rateAsked) {
        final started = await client.costsRate();
        for (var i = 0; i < 150 && mounted; i++) {
          final status = await client.tasksStatus(
            task: started['task'] as String,
          );
          if (status['state'] != 'running') break;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        if (mounted) await _load(rateAsked: true);
      }
    } catch (_) {
      // No card: the rest of the page is shown.
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = _card;
    if (card == null || card['tiles'] is! List) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    return Card(
      key: ValueKey('cost-${widget.command}'),
      child: ExpansionTile(
        leading: const Icon(Icons.payments_outlined),
        title: Text('${card['title']}'),
        subtitle: Text('${card['summary']}'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final tile in (card['tiles'] as List).cast<List>())
                SizedBox(
                  width: 180,
                  child: Card.outlined(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${tile[0]}', style: text.labelMedium),
                          Text('${tile[1]}', style: text.titleLarge),
                          if ('${tile[2]}'.isNotEmpty)
                            Text('${tile[2]}', style: text.bodySmall),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          for (final model in (card['models'] as List).cast<Map>()) ...[
            const SizedBox(height: 12),
            Text('${model['heading']}', style: text.titleSmall),
            for (final row in (model['rows'] as List).cast<List>())
              Row(
                children: [
                  SizedBox(width: 140, child: Text('${row[0]}')),
                  Expanded(child: SelectableText('${row[1]}')),
                ],
              ),
          ],
          const SizedBox(height: 12),
          for (final note in (card['notes'] as List))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('$note', style: text.bodySmall),
            ),
        ],
      ),
    );
  }
}
