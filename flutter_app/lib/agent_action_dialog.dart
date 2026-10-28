import 'task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

String actionLabel(String action) =>
    const {
      'install': 'Install',
      'update': 'Update',
      'uninstall': 'Remove',
      'login': 'Sign in…',
      'logout': 'Sign out',
      'verify': 'Send the test question',
    }[action] ??
    'Continue';

class AgentActionReview extends StatelessWidget {
  const AgentActionReview({
    super.key,
    required this.plan,
    required this.tr,
    required this.onConfirm,
    required this.onCancel,
  });
  final Map<String, dynamic> plan;
  final String Function(String) tr;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  @override
  Widget build(BuildContext context) => TaskReview(
    title: Text(
      '${tr(actionLabel(plan['action'] as String))} · ${plan['name']}',
    ),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (plan['external'] == true)
              Text(
                tr(
                  'This runs in a separate terminal; passwords are entered there. Refresh when it finishes.',
                ),
              ),
            if ((plan['note'] as String? ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(plan['note'] as String),
              ),
            if ((plan['commands'] as List).isNotEmpty)
              SelectableText(
                (plan['commands'] as List).join('\n'),
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            if ((plan['url'] as String? ?? '').isNotEmpty)
              SelectableText(plan['url'] as String),
            if ((plan['data'] as List).isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                tr(
                  'What stays: {0}',
                ).replaceAll('{0}', (plan['data'] as List).join(', ')),
              ),
            ],
            if (plan['runnable'] != true)
              Text(tr('Not available in this version')),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: onCancel, child: Text(tr('Cancel'))),
      if ((plan['commands'] as List).isNotEmpty)
        TextButton(
          onPressed: () => Clipboard.setData(
            ClipboardData(text: (plan['commands'] as List).join('\n')),
          ),
          child: Text(tr('Copy command')),
        ),
      if (plan['runnable'] == true)
        FilledButton(onPressed: onConfirm, child: Text(tr('Continue'))),
    ],
  );
}
