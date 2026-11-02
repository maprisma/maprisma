import 'package:flutter/material.dart';

import 'app_look.dart' show StatusColors;

class AgentUsage extends StatelessWidget {
  const AgentUsage({super.key, required this.info, required this.tr});
  final Map<String, dynamic> info;
  final String Function(String) tr;

  /// Costs beyond the plan: what the agent says, or at least where to look.
  Widget _extraUsage() {
    final extra = info['extra_usage'] as Map? ?? const {};
    final on = extra['on'] as bool?;
    final url = '${extra['url'] ?? ''}';
    return ListTile(
      key: const ValueKey('agent-extra-usage'),
      leading: on == true
          ? Icon(Icons.warning_amber, color: StatusColors.warn)
          : null,
      title: Text(tr('Additional usage')),
      subtitle: SelectableText(
        [
          tr(switch (on) {
            true => 'On: beyond the plan\'s limits it can cost extra money.',
            false => 'Off: it stops at the plan\'s limits.',
            null =>
              'Not known on this PC. Check with the provider whether it can bill beyond the plan.',
          }),
          if (url.isNotEmpty) url,
        ].join('\n'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if ((info['model'] as String).isNotEmpty)
        ListTile(
          title: Text(tr('Model')),
          subtitle: SelectableText(info['model'] as String),
        ),
      if ((info['plan'] as String).isNotEmpty)
        ListTile(
          title: Text(tr('Plan')),
          subtitle: Text(info['plan'] as String),
        ),
      if ((info['plan'] as String).isNotEmpty) _extraUsage(),
      if ((info['providers'] as List).isNotEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tr('Providers'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                for (final provider in info['providers'] as List)
                  ListTile(
                    title: Text(provider['name'] as String),
                    leading: Icon(
                      provider['local'] == true
                          ? Icons.computer
                          : Icons.cloud_outlined,
                    ),
                    trailing: provider['active'] == true
                        ? const Icon(Icons.check)
                        : null,
                  ),
              ],
            ),
          ),
        ),
      if ((info['limits'] as List).isNotEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tr('Limits'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                for (final limit in info['limits'] as List)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '${limit['label']} · ${((limit['percent'] as num) * 100).round()}%',
                        ),
                        const SizedBox(height: 6),
                        LinearProgressIndicator(
                          value: (limit['percent'] as num).toDouble().clamp(
                            0,
                            1,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      if (info['today_prompts'] != null ||
          info['today_sessions'] != null ||
          info['today_tokens'] != null)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tr('Today'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (info['today_prompts'] != null)
                  ListTile(
                    title: Text(tr('Prompts')),
                    trailing: Text('${info['today_prompts']}'),
                  ),
                if (info['today_sessions'] != null)
                  ListTile(
                    title: Text(tr('Sessions')),
                    trailing: Text('${info['today_sessions']}'),
                  ),
                if (info['today_tokens'] != null)
                  ListTile(
                    title: Text(tr('Tokens')),
                    trailing: Text('${info['today_tokens']}'),
                  ),
              ],
            ),
          ),
        ),
    ],
  );
}
