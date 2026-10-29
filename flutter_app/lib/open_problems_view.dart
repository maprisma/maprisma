import 'package:flutter/material.dart';
import 'task_card.dart';

const _actionLabels = {
  'details': 'Details',
  'runtime': 'Details',
  'models': 'Models…',
  'install': 'Install…',
  'link': 'Map',
  'firstagent': 'Get started',
  'addmcp': 'Add MCP server',
  'addskills': 'Add skills',
  'reorganize': 'Tidy up…',
};
const _useLevels = {'ready': 'Ready', 'almost': 'Almost', 'missing': 'Not yet'};

/// Open problems (health.report, the GTK page behind the header's "!"): what
/// needs fixing, each with the way to where it is fixed, then what this
/// setup is good for (the use cases), each with its next step.
class OpenProblemsView extends StatelessWidget {
  const OpenProblemsView({
    super.key,
    required this.report,
    required this.tr,
    required this.onAction,
    required this.onCheckAgain,
    required this.onClose,
  });
  final Map<String, dynamic> report;
  final String Function(String) tr;
  final void Function(List<String> action) onAction;
  final VoidCallback onCheckAgain;
  final VoidCallback onClose;

  Widget _finding(BuildContext context, Map f) {
    final scheme = Theme.of(context).colorScheme;
    final level = '${f['level']}';
    final action = [for (final x in f['action'] as List? ?? const []) '$x'];
    final label = action.isEmpty ? null : _actionLabels[action.first];
    return ListTile(
      dense: true,
      leading: Text(
        const {'ok': '✓', 'hint': '→', 'warn': '!'}[level] ?? '·',
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: level == 'warn'
              ? scheme.error
              : level == 'ok'
              ? Colors.green
              : scheme.tertiary,
        ),
      ),
      title: Text('${f['title']}'),
      subtitle: '${f['text']}'.isEmpty ? null : Text('${f['text']}'),
      trailing: label == null
          ? null
          : OutlinedButton(
              onPressed: () => onAction(action),
              child: Text(tr(label)),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final problems = [
      for (final a in (report['areas'] as List? ?? const []).cast<Map>())
        for (final f in (a['findings'] as List).cast<Map>())
          if (f['level'] == 'warn') f,
    ];
    final uses = (report['uses'] as List? ?? const []).cast<Map>();
    return TaskReview(
      title: Row(
        children: [
          Expanded(child: Text(tr('Open problems'), style: text.titleLarge)),
          TextButton(
            key: const ValueKey('health-again'),
            onPressed: onCheckAgain,
            child: Text(tr('Check again')),
          ),
        ],
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (problems.isEmpty) ...[
            Text(tr('Nothing to fix.'), style: text.titleMedium),
            Text('${report['summary'] ?? tr('Everything set up and working')}'),
          ] else ...[
            Text('${report['open_text']}', style: text.titleMedium),
            Text(tr('Each one opens where it is fixed.')),
            for (final f in problems) _finding(context, f),
          ],
          if (uses.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(tr('What you can do with it'), style: text.titleMedium),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final u in uses)
                  SizedBox(
                    width: 280,
                    child: Card(
                      key: ValueKey('use-${u['key']}'),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${u['title']}',
                                    style: text.titleSmall,
                                  ),
                                ),
                                Chip(
                                  label: Text(
                                    tr(
                                      _useLevels[u['level']] ?? '${u['level']}',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            Text('${u['blurb']}'),
                            if ((u['have'] as List).isNotEmpty)
                              Text(
                                '✓ ${(u['have'] as List).take(5).join(', ')}',
                              ),
                            for (final s
                                in (u['steps'] as List).cast<Map>().take(2))
                              _finding(context, s),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
      actions: [TextButton(onPressed: onClose, child: Text(tr('Close')))],
    );
  }
}
