import 'package:flutter/material.dart';
import 'task_card.dart';

/// One word of plain characters, as the service accepts it (signin.KEY_RE).
final _keyShape = RegExp(r'^[A-Za-z0-9._~+/=:-]{8,512}$');

/// An API key for an agent (agents.key_preview): where it goes is said before
/// it is typed; the field hides it, and the app does not keep it.
class ApiKeyReview extends StatefulWidget {
  const ApiKeyReview({
    super.key,
    required this.preview,
    required this.controller,
    required this.tr,
    required this.onConfirm,
    required this.onCancel,
  });
  final Map<String, dynamic> preview;
  final TextEditingController controller;
  final String Function(String) tr;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  State<ApiKeyReview> createState() => _ApiKeyReviewState();
}

class _ApiKeyReviewState extends State<ApiKeyReview> {
  bool get _valid => _keyShape.hasMatch(widget.controller.text.trim());

  @override
  Widget build(BuildContext context) {
    final p = widget.preview, tr = widget.tr;
    final where = p['stores'] == 'itself'
        ? tr('{0} stores it itself ({1}).')
              .replaceAll('{0}', '${p['name']}')
              .replaceAll('{1}', '${p['command']}')
        : tr('Written to {0} as {1}, readable only by you.')
              .replaceAll('{0}', '${p['file']}')
              .replaceAll('{1}', '${p['variable']}');
    return TaskReview(
      title: Text(
        tr('API key for {0}').replaceAll('{0}', '${p['name']}'),
        style: Theme.of(context).textTheme.titleLarge,
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('$where ${tr('The app does not keep it.')}'),
          const SizedBox(height: 16),
          TextField(
            controller: widget.controller,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(labelText: '${p['variable']}'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (_valid) widget.onConfirm();
            },
          ),
          if ('${p['url'] ?? ''}'.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(tr('Get a key')),
            SelectableText('${p['url']}'),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: widget.onCancel, child: Text(tr('Cancel'))),
        FilledButton(
          onPressed: _valid ? widget.onConfirm : null,
          child: Text(tr('Save')),
        ),
      ],
    );
  }
}
