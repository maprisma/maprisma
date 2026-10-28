import 'task_card.dart';
import 'package:flutter/material.dart';

class AddonDetails extends StatelessWidget {
  const AddonDetails({super.key, required this.item, required this.tr});
  final Map<String, dynamic> item;
  final String Function(String) tr;

  @override
  Widget build(BuildContext context) {
    const privacy = {
      1: 'Numbers only',
      2: 'Session titles',
      3: 'Titles and a summary by Claude',
    };
    const capabilities = {
      'agent': 'Adds an agent to the map and the cards',
      'provider': 'Adds an LLM provider to the map',
      'installer':
          "Can install a program (from a download checked against its release's SHA-256)",
      'updater': 'Updates',
    };
    final reads = (item['reads'] as List? ?? []).join('; ');
    final sends = (item['sends'] as List? ?? []).join('; ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if ((item['description'] as String? ?? '').isNotEmpty) ...[
          SelectableText(item['description'] as String),
          const SizedBox(height: 12),
        ],
        if (privacy.containsKey(item['privacy']))
          Text(
            tr(
              'Privacy level: {0}',
            ).replaceAll('{0}', tr(privacy[item['privacy']]!)),
          ),
        for (final capability in item['capabilities'] as List? ?? [])
          if (capabilities.containsKey(capability))
            Text(tr(capabilities[capability]!)),
        const SizedBox(height: 12),
        Text(
          '${tr('Reads')}: ${reads.isEmpty ? tr('Nothing beyond what Asterism shows anyway.') : reads}',
        ),
        const SizedBox(height: 8),
        Text(
          '${tr('Sends')}: ${sends.isEmpty ? tr('Nothing: it sends nothing anywhere.') : sends}',
        ),
      ],
    );
  }
}

class AddonInstallReview extends StatelessWidget {
  const AddonInstallReview({
    super.key,
    required this.item,
    required this.tr,
    required this.onConfirm,
    required this.onCancel,
  });
  final Map<String, dynamic> item;
  final String Function(String) tr;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  @override
  Widget build(BuildContext context) => TaskReview(
    title: Text(
      tr(
        item['action'] == 'update' ? 'Update {0}?' : 'Install {0}?',
      ).replaceAll('{0}', '${item['name']} · ${item['version']}'),
    ),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr(
                'Catalog installs and updates also change the add-ons used by Asterism (GTK).',
              ),
            ),
            const SizedBox(height: 12),
            AddonDetails(item: item, tr: tr),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: onCancel, child: Text(tr('Cancel'))),
      FilledButton(
        onPressed: onConfirm,
        child: Text(tr(item['action'] == 'update' ? 'Update' : 'Install')),
      ),
    ],
  );
}

class AddonRemovalReview extends StatelessWidget {
  const AddonRemovalReview({
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
    title: Text(tr('Remove {0}?').replaceAll('{0}', plan['name'] as String)),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr(
              'The add-on is backed up. Its programs and data are kept. Undo is available until this app closes.',
            ),
          ),
          for (final note in plan['notes'] as List? ?? []) ...[
            const SizedBox(height: 12),
            Text(tr(note as String)),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: onCancel, child: Text(tr('Cancel'))),
      FilledButton(onPressed: onConfirm, child: Text(tr('Remove'))),
    ],
  );
}
