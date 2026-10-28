import 'task_card.dart';
import 'package:flutter/material.dart';
import 'providers_view.dart' show modelSize;

class ModelRemovalReview extends StatelessWidget {
  const ModelRemovalReview({
    super.key,
    required this.preview,
    required this.tr,
    required this.onConfirm,
    required this.onCancel,
  });
  final Map<String, dynamic> preview;
  final String Function(String) tr;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  @override
  Widget build(BuildContext context) => TaskReview(
    title: Text('${tr('Remove model')} · ${preview['model']}'),
    content: SizedBox(
      width: 580,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (preview['provider'] != null)
              Text(preview['provider'] as String),
            if ((preview['address'] as String? ?? '').isNotEmpty)
              Text(preview['address'] as String),
            Text(
              tr(
                preview['mode'] == 'api'
                    ? 'This provider deletes models permanently.'
                    : preview['links_only'] == true
                    ? 'Only links move to Trash; original model files remain.'
                    : 'Move these model files to Trash?',
              ),
            ),
            const SizedBox(height: 12),
            Text(tr('This can interrupt agents using this provider.')),
            if (preview['mode'] == 'file')
              Text(modelSize(preview['size'] as num)),
            if ((preview['shared'] as List).isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '${tr('Also used by')}: ${(preview['shared'] as List).join(', ')}',
                ),
              ),
            for (final file in preview['files'] as List)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(file as String),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: onCancel, child: Text(tr('Cancel'))),
      FilledButton(
        onPressed: onConfirm,
        child: Text(
          tr(preview['mode'] == 'api' ? 'Remove permanently' : 'Move to Trash'),
        ),
      ),
    ],
  );
}
