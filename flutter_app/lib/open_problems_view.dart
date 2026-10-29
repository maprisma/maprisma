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
    this.updates = const [],
    this.onUpdate,
    this.addonHints = const [],
    this.onAddonHint,
    required this.onCheckAgain,
    required this.onClose,
  });
  final Map<String, dynamic> report;
  final String Function(String) tr;
  final void Function(List<String> action) onAction;

  /// agent_updates: newer versions of agents and local LLMs (updates.check).
  final List<Map<String, dynamic>> updates;
  final ValueChanged<Map<String, dynamic>>? onUpdate;

  /// addons.hints: add-ons for what is on this PC, and add-on updates.
  final List<Map<String, dynamic>> addonHints;

  /// A hint's button: all true is "Update all", else the add-ons to get or
  /// switch on.
  final void Function(Map<String, dynamic> line, bool all)? onAddonHint;
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
          if (updates.isNotEmpty || addonHints.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(tr('Updates and suggestions'), style: text.titleMedium),
            for (final h in addonHints)
              ListTile(
                key: ValueKey('addon-hint-${h['kind']}'),
                dense: true,
                leading: Icon(
                  h['kind'] == 'updates' ? Icons.upgrade : Icons.extension,
                ),
                title: Text('${h['text']}'),
                trailing: onAddonHint == null
                    ? null
                    : Wrap(
                        spacing: 8,
                        children: [
                          if (h['kind'] == 'updates')
                            OutlinedButton(
                              onPressed: () => onAddonHint!(h, true),
                              child: Text(tr('Update all')),
                            ),
                          OutlinedButton(
                            onPressed: () => onAddonHint!(h, false),
                            child: Text(
                              tr(
                                h['kind'] == 'new' ? 'Get add-ons' : 'Add-ons',
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            for (final u in updates)
              ListTile(
                key: ValueKey('update-${u['key']}'),
                dense: true,
                leading: const Icon(Icons.upgrade),
                title: Text(
                  tr('{0} {1} is available (you have {2})')
                      .replaceAll('{0}', '${u['name']}')
                      .replaceAll('{1}', '${u['available']}')
                      .replaceAll('{2}', '${u['current']}'),
                ),
                trailing: onUpdate == null
                    ? null
                    : OutlinedButton(
                        onPressed: () => onUpdate!(u),
                        child: Text(tr('Update')),
                      ),
              ),
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
