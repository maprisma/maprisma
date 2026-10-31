import 'package:flutter/material.dart';
import 'task_card.dart';

/// Help (F1; settings_pages.open_help): the user manual of this version in
/// the interface language, opened in the desktop's PDF viewer, where to
/// start, and tabs for Your first agent, Agents, Providers and models,
/// Connections, and Usage.
class HelpView extends StatefulWidget {
  const HelpView({
    super.key,
    required this.manual,
    required this.tr,
    required this.onOpenManual,
    required this.starts,
    required this.onClose,
    this.tabs = const [],
    this.onUsage,
  });
  final bool manual;
  final String Function(String) tr;

  /// help.open_manual: whether a viewer was started.
  final Future<bool> Function() onOpenManual;

  /// Where to start: (label, icon, what it opens).
  final List<(String, IconData, VoidCallback)> starts;

  /// Secondary pages placed as tabs on the Help page: (label, icon, open).
  final List<(String, IconData, VoidCallback)> tabs;

  /// Loads the 30-day usage snapshot for the Usage tab.
  final Future<Map<String, dynamic>> Function()? onUsage;
  final VoidCallback onClose;

  @override
  State<HelpView> createState() => _HelpViewState();
}

class _HelpViewState extends State<HelpView> {
  String? _error;
  bool _showUsage = false;
  bool _loadingUsage = false;
  Map<String, dynamic>? _usage;

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

  Future<void> _selectUsage() async {
    setState(() {
      _showUsage = true;
      _error = null;
    });
    if (_usage != null || widget.onUsage == null || _loadingUsage) return;
    setState(() => _loadingUsage = true);
    try {
      final result = await widget.onUsage!();
      if (mounted) setState(() => _usage = result);
    } catch (_) {
      if (mounted) {
        setState(() => _error = tr('The action could not be completed.'));
      }
    } finally {
      if (mounted) setState(() => _loadingUsage = false);
    }
  }

  Widget _buildTabBar(BuildContext context) {
    final hasTabs = widget.tabs.isNotEmpty || widget.onUsage != null;
    if (!hasTabs) return const SizedBox.shrink();
    final activeStyle = OutlinedButton.styleFrom(
      side: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            key: const ValueKey('help-tab-overview'),
            style: _showUsage ? null : activeStyle,
            onPressed: () => setState(() => _showUsage = false),
            icon: const Icon(Icons.help_outline),
            label: Text(tr('Help')),
          ),
          for (final (label, icon, open) in widget.tabs)
            OutlinedButton.icon(
              key: ValueKey('help-tab-$label'),
              onPressed: open,
              icon: Icon(icon),
              label: Text(tr(label)),
            ),
          if (widget.onUsage != null)
            OutlinedButton.icon(
              key: const ValueKey('help-tab-Usage'),
              style: _showUsage ? activeStyle : null,
              onPressed: _selectUsage,
              icon: const Icon(Icons.bar_chart_outlined),
              label: Text(tr('Usage')),
            ),
        ],
      ),
    );
  }

  Widget _buildUsageContent() {
    if (_loadingUsage) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: LinearProgressIndicator(),
      );
    }
    final categories = (_usage?['categories'] as List? ?? const []);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          tr('Last 30 days'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          )
        else if (categories.isEmpty)
          Text(tr('No AI runs recorded in the last 30 days.'))
        else
          for (final c in categories)
            ExpansionTile(
              title: Text('${c['plugin']} · ${tr(c['task'] as String)}'),
              subtitle: Text(
                '${c['runs']} ${tr('Sessions')} · ${c['totals']['tokens']} ${tr('Tokens')} · ${c['totals']['unknown']} ${tr('Unknown')}',
              ),
              children: [
                for (final run in c['entries'] as List)
                  ListTile(
                    title: Text('${run['when']} · ${run['agent']}'),
                    subtitle: Text(
                      '${tr(run['ok'] == true ? 'Succeeded' : 'Failed')} · ${run['tokens'] ?? '—'} ${tr('Tokens')}',
                    ),
                  ),
              ],
            ),
      ],
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
          _buildTabBar(context),
          if (_showUsage)
            _buildUsageContent()
          else ...[
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
        ],
      ),
      actions: [
        TextButton(onPressed: widget.onClose, child: Text(tr('Close'))),
      ],
    );
  }
}
