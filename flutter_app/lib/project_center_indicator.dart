import 'package:flutter/material.dart';

/// Run state comes from the project supervisor, never agent CPU or usage.
class ProjectCenterIndicator extends StatelessWidget {
  const ProjectCenterIndicator({
    super.key,
    required this.summary,
    required this.onOpen,
    required this.tr,
  });

  final Map<String, dynamic> summary;
  final VoidCallback? onOpen;
  final String Function(String) tr;

  @override
  Widget build(BuildContext context) {
    int count(String key) => (summary[key] as num?)?.toInt() ?? 0;
    final connected = summary['connected'] != false;
    final running = count('running');
    final pausing = count('pausing');
    final waiting = count('waiting') + count('attention');
    final description = !connected
        ? tr('AI Project Center · status unavailable')
        : [
            tr('AI Project Center'),
            if (running > 0)
              tr('{0} projects running').replaceAll('{0}', '$running'),
            if (pausing > 0)
              tr('{0} projects pausing').replaceAll('{0}', '$pausing'),
            if (waiting > 0)
              tr('{0} projects need attention').replaceAll('{0}', '$waiting'),
          ].join(' · ');
    final total = running + pausing;
    return IconButton(
      key: const ValueKey('ai-project-center-open'),
      tooltip: description,
      onPressed: onOpen,
      icon: Badge(
        isLabelVisible: connected && (total > 0 || waiting > 0),
        label: Text(total > 0 ? '$total' : '!'),
        backgroundColor: waiting > 0
            ? Theme.of(context).colorScheme.tertiary
            : Theme.of(context).colorScheme.primary,
        child: Icon(
          connected ? Icons.account_tree_outlined : Icons.cloud_off_outlined,
        ),
      ),
    );
  }
}
