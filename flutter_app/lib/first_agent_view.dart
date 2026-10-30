import 'package:flutter/material.dart';

class FirstAgentView extends StatelessWidget {
  const FirstAgentView({
    super.key,
    this.hosted = false,
    required this.data,
    required this.busy,
    required this.tr,
    required this.onChoose,
    required this.onAction,
    this.onStarter,
    required this.onBack,
    required this.onRefresh,
  });
  final bool hosted;
  final Map<String, dynamic> data;
  final bool busy;
  final String Function(String) tr;
  final ValueChanged<String> onChoose;
  final void Function(String, String) onAction;

  /// A starter model to download into this local LLM (its key, the model).
  final void Function(String, Map<String, dynamic>)? onStarter;
  final VoidCallback onBack;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final routes = (data['routes'] as List? ?? []).cast<Map<String, dynamic>>();
    final selected = routes
        .where((route) => route['id'] == data['selected'])
        .firstOrNull;
    const labels = {
      'addons': 'Add-ons',
      'install': 'Install',
      'login': 'Sign in…',
      'providers': 'Providers and models',
      'existing': 'Find existing AI',
      'connections': 'Connections',
      'verify': 'Send the test question',
      'install-agent': 'Install',
      'install-tool': 'Install mise',
      'install-node': 'Install Node.js',
      'install-runtime': 'Install {0}…',
      'download-starter': 'Download it',
    };
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 850),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Row(
              children: [
                if (!hosted)
                  TextButton.icon(
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back),
                    label: Text(tr('Back')),
                  ),
                const Spacer(),
                TextButton.icon(
                  onPressed: busy ? null : onRefresh,
                  icon: const Icon(Icons.refresh),
                  label: Text(tr('Refresh')),
                ),
              ],
            ),
            if (!hosted)
              Text(
                tr('Your first agent'),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: busy ? null : () => onAction('', 'existing'),
                icon: const Icon(Icons.manage_search),
                label: Text(tr('Find existing AI')),
              ),
            ),
            const SizedBox(height: 16),
            if (selected == null) ...[
              Text(tr('Get one agent working')),
              for (final kind in ['online', 'local']) ...[
                const SizedBox(height: 20),
                Text(
                  tr(
                    kind == 'online' ? 'With an online account' : 'On this PC',
                  ),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                for (final route in routes.where(
                  (route) => route['kind'] == kind,
                ))
                  Card(
                    child: ListTile(
                      title: Text(route['title'] as String),
                      subtitle: Text(route['access'] as String),
                      onTap: busy
                          ? null
                          : () => onChoose(route['id'] as String),
                      trailing: const Icon(Icons.chevron_right),
                    ),
                  ),
              ],
            ] else ...[
              Text(
                selected['title'] as String,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(selected['access'] as String),
              const SizedBox(height: 16),
              if (selected['verified'] == true) Text(tr('Your agent is ready')),
              for (final step
                  in (selected['steps'] as List).cast<Map<String, dynamic>>())
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(
                              step['done'] == true
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                step['title'] as String,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                          ],
                        ),
                        if ((step['detail'] as String).isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(step['detail'] as String),
                          ),
                        if (labels.containsKey(step['action']))
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              // A tool or a local LLM is named by its step's target.
                              onPressed: busy
                                  ? null
                                  : step['action'] == 'download-starter' &&
                                        onStarter != null
                                  ? () => onStarter!(
                                      step['target'] as String,
                                      step['starter'] as Map<String, dynamic>,
                                    )
                                  : () => onAction(
                                      const {
                                            'install-tool',
                                            'install-runtime',
                                          }.contains(step['action'])
                                          ? step['target'] as String
                                          : selected['command'] as String,
                                      step['action'] as String,
                                    ),
                              child: Text(
                                tr(
                                  labels[step['action']]!,
                                ).replaceAll('{0}', step['title'] as String),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              if ((data['answer'] as String? ?? '').isNotEmpty &&
                  selected['verified'] == true)
                SelectableText(data['answer'] as String),
              for (final route in routes.where(
                (route) => route['id'] != selected['id'],
              ))
                TextButton(
                  onPressed: busy
                      ? null
                      : () => onChoose(route['id'] as String),
                  child: Text(route['title'] as String),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
