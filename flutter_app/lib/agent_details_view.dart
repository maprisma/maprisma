import 'health_card.dart';
import 'package:flutter/material.dart';
import 'agent_usage.dart';
import 'cost_card.dart';
import 'projects_card.dart';
import 'project_start_menu.dart';

class AgentDetailsView extends StatelessWidget {
  const AgentDetailsView({
    super.key,
    required this.catalog,
    required this.selected,
    required this.projectsByAgent,
    required this.busy,
    required this.info,
    required this.tr,
    required this.onBack,
    required this.onStart,
    required this.startMenu,
    required this.onProjectAction,
    this.onSubagents,
    this.onAction,
    this.onConnections,
    this.onCall,
  });
  final List<Map<String, dynamic>> catalog;
  final String? selected;
  final Map projectsByAgent;
  final bool busy;
  final Map<String, dynamic>? info;
  final String Function(String) tr;
  final VoidCallback onBack;
  final Future<void> Function(Map<String, dynamic>) onStart;
  final ProjectStartMenuController startMenu;
  final Future<void> Function(String, String, String?) onProjectAction;
  final ValueChanged<String>? onSubagents;
  final void Function(String, String)? onAction;
  final VoidCallback? onConnections;

  /// A plain service call (the Health card's agents.health).
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
  onCall;
  @override
  Widget build(BuildContext context) {
    final matches = catalog.where((agent) => agent['command'] == selected);
    if (matches.isEmpty) return Center(child: Text(tr('Select an agent')));
    final agent = matches.first;
    final command = agent['command'] as String;
    final projects = projectsByAgent[command] as Map;
    final history = projects['history'] as List;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
            label: Text(tr('Back')),
          ),
        ),
        Text(
          agent['name'] as String,
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        SelectableText('${tr('Version')}: ${agent['version']}'),
        if (onCall != null && agent['installed'] == true)
          HealthCard(
            key: ValueKey('health-$command'),
            method: 'agents.health',
            params: {'command': command},
            call: onCall!,
            tr: tr,
          ),
        if (info != null) AgentUsage(info: info!, tr: tr),
        if (onCall != null)
          CostCard(
            key: ValueKey('cost-$command'),
            command: command,
            call: onCall!,
            tr: tr,
          ),
        if (onCall != null)
          ProjectsCard(
            key: ValueKey('projects-$command'),
            command: command,
            call: onCall!,
          ),
        const SizedBox(height: 16),
        if (onAction != null)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final action in const {
                'install': 'Install',
                'update': 'Update',
                'uninstall': 'Remove',
                'login': 'Sign in…',
                'key': 'API key…',
                'verify': 'Send the test question',
              }.entries)
                if ((info?['actions'] as Map?)?[action.key] == true &&
                    (action.key != 'install' || agent['installed'] != true))
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => onAction!(command, action.key),
                    child: Text(tr(action.value)),
                  ),
              if (agent['installed'] == true)
                OutlinedButton(
                  onPressed: busy ? null : () => onAction!(command, 'security'),
                  child: Text(tr('Security settings')),
                ),
              if (onConnections != null && agent['installed'] == true)
                OutlinedButton(
                  onPressed: busy ? null : onConnections,
                  child: Text(tr('Connections')),
                ),
            ],
          ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: ProjectStartMenu(
            key: ValueKey(command),
            command: command,
            projects: projects,
            controller: startMenu,
            enabled: !busy && agent['installed'] == true,
            tr: tr,
            onStart: onStart,
          ),
        ),
        const SizedBox(height: 24),
        if (onSubagents != null && agent['installed'] == true)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: busy ? null : () => onSubagents!(command),
              icon: const Icon(Icons.account_tree_outlined),
              label: Text(tr('Subagents')),
            ),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tr('Default folder'),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                SelectableText(projects['default'] as String),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tr('Recent projects'),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  tr(
                    'Projects started from the map, newest first. Pin a folder to use it by default. The trash button removes only the history entry, not the folder.',
                  ),
                ),
                if (history.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(tr('No recent projects yet')),
                  ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 350),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final entry in history)
                        ListTile(
                          onTap: busy || entry['available'] != true
                              ? null
                              : () => startMenu.openFor(
                                  command,
                                  entry['path'] as String,
                                ),
                          title: Text(entry['path'] as String),
                          subtitle: entry['available'] == true
                              ? null
                              : Text(tr('Folder unavailable')),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: tr(
                                  projects['pinned'] == entry['path']
                                      ? 'Unpin default folder'
                                      : 'Pin as default folder',
                                ),
                                icon: Icon(
                                  projects['pinned'] == entry['path']
                                      ? Icons.push_pin
                                      : Icons.push_pin_outlined,
                                ),
                                onPressed:
                                    busy ||
                                        (entry['available'] != true &&
                                            projects['pinned'] != entry['path'])
                                    ? null
                                    : () => onProjectAction(
                                        'projects.pin',
                                        command,
                                        projects['pinned'] == entry['path']
                                            ? null
                                            : entry['path'] as String,
                                      ),
                              ),
                              IconButton(
                                tooltip: tr(
                                  'Remove from history (keeps the folder)',
                                ),
                                icon: const Icon(Icons.delete_outline),
                                onPressed: busy
                                    ? null
                                    : () => onProjectAction(
                                        'projects.forget',
                                        command,
                                        entry['path'] as String,
                                      ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
