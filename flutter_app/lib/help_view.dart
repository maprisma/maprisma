import 'package:flutter/material.dart';
import 'task_card.dart';

/// Help (F1; settings_pages.open_help): the user manual of this version in
/// the interface language, opened in the desktop's PDF viewer, and where to
/// start.
class HelpView extends StatefulWidget {
  const HelpView({
    super.key,
    required this.manual,
    required this.tr,
    required this.onOpenManual,
    required this.starts,
    required this.onClose,
  });
  final bool manual;
  final String Function(String) tr;

  /// help.open_manual: whether a viewer was started.
  final Future<bool> Function() onOpenManual;

  /// Where to start: (label, icon, what it opens).
  final List<(String, IconData, VoidCallback)> starts;
  final VoidCallback onClose;

  @override
  State<HelpView> createState() => _HelpViewState();
}

class _HelpViewState extends State<HelpView> {
  String? _error;

  String tr(String key) => widget.tr(key);

  Future<void> _open() async {
    bool opened;
    try {
      opened = await widget.onOpenManual();
    } catch (_) {
      opened = false;
    }
    if (!mounted) return;
    setState(
      () => _error = opened
          ? null
          : tr('Could not open the manual: {0}').replaceAll('{0}', 'xdg-open'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return TaskReview(
      title: Text(tr('Help'), style: text.titleLarge),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.manual) ...[
            Row(
              children: [
                Expanded(
                  child: Text(tr('User manual'), style: text.titleMedium),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('help-manual'),
                  onPressed: _open,
                  icon: const Icon(Icons.description_outlined),
                  label: Text(tr('Open user manual')),
                ),
              ],
            ),
            Text(
              tr(
                'Everything this app does, step by step, as a PDF for this version in your language.',
              ),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 16),
          ],
          Text(tr('Where to start'), style: text.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, icon, open) in widget.starts)
                OutlinedButton.icon(
                  onPressed: open,
                  icon: Icon(icon),
                  label: Text(tr(label)),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: widget.onClose, child: Text(tr('Close'))),
      ],
    );
  }
}
