import 'package:flutter/material.dart';
import 'task_card.dart';

/// An MCP server's or a skill set's details (details.mcp / details.skills,
/// the GTK MCP page): which agents have it and how each starts, calls or
/// reads it (values of keys and tokens hidden), who has not got it yet, and
/// the server's tools as last asked or each skill's description.
class ItemDetailsView extends StatelessWidget {
  const ItemDetailsView({
    super.key,
    required this.details,
    required this.tr,
    required this.onClose,
  });
  final Map<String, dynamic> details;
  final String Function(String) tr;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final tools = (details['tools'] as List? ?? const []).cast<List>();
    return TaskReview(
      title: Text('${details['title']}', style: text.titleLarge),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${details['intro']}', style: text.titleMedium),
          Text('${details['text']}'),
          for (final section in (details['sections'] as List).cast<Map>()) ...[
            const SizedBox(height: 16),
            Text('${section['heading']}', style: text.titleSmall),
            for (final row in (section['rows'] as List).cast<List>())
              Tooltip(
                message: '${row[2]}',
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 160, child: Text('${row[0]}')),
                      Expanded(child: SelectableText('${row[1]}')),
                    ],
                  ),
                ),
              ),
          ],
          if ('${details['missing']}'.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('${details['missing_title']}', style: text.titleSmall),
            Text('${details['missing']}'),
          ],
          if (tools.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(tr('Tools'), style: text.titleSmall),
            for (final t in tools)
              ListTile(
                dense: true,
                title: Text('${t[0]}'),
                subtitle: '${t[1]}'.isEmpty ? null : Text('${t[1]}'),
              ),
          ],
        ],
      ),
      actions: const [], // Back in the window's header leads out
    );
  }
}
