import 'package:flutter/material.dart';

import 'core_client.g.dart';

/// Projects, last 30 days (agents.projects, the GTK details' projects card):
/// per project folder the working time, sessions, tokens, lines changed and
/// API value, the subagent runs per type and the busiest hour.
class ProjectsCard extends StatefulWidget {
  const ProjectsCard({super.key, required this.command, required this.call});
  final String command;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
  call;

  @override
  State<ProjectsCard> createState() => _ProjectsCardState();
}

class _ProjectsCardState extends State<ProjectsCard> {
  Map<String, dynamic>? _card;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ProjectsCard old) {
    super.didUpdateWidget(old);
    if (old.command != widget.command) _load();
  }

  Future<void> _load() async {
    try {
      final found = await CoreClient.fromCall(
        widget.call,
      ).agentsProjects(command: widget.command);
      if (mounted) {
        setState(() => _card = found['card'] as Map<String, dynamic>?);
      }
    } catch (_) {
      // No card: the rest of the page is shown.
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = _card;
    if (card == null || card['projects'] is! List) {
      return const SizedBox.shrink();
    }
    final text = Theme.of(context).textTheme;
    return Card(
      key: ValueKey('projects-${widget.command}'),
      child: ExpansionTile(
        leading: const Icon(Icons.folder_outlined),
        title: Text('${card['title']}'),
        subtitle: Text('${card['summary']}'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final p in (card['projects'] as List).cast<Map>())
            ListTile(
              dense: true,
              leading: const Icon(Icons.folder_outlined, size: 18),
              title: SelectableText('${p['folder']}'),
              subtitle: Text('${p['text']}'),
            ),
          if (card['subagents_title'] != null) ...[
            const SizedBox(height: 8),
            Text('${card['subagents_title']}', style: text.titleSmall),
            for (final s in (card['subagents'] as List).cast<Map>())
              ListTile(
                dense: true,
                leading: const Icon(Icons.account_tree_outlined, size: 18),
                title: Text('${s['kind']}'),
                subtitle: Text('${s['text']}'),
              ),
          ],
          for (final note in card['notes'] as List)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('$note', style: text.bodySmall),
            ),
        ],
      ),
    );
  }
}
