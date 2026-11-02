import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_look.dart' show StatusColors;

const _badges = {
  'ok': 'Healthy',
  'warn': 'Needs a look',
  'missing': 'Not set up',
};

/// Health (agents.health / providers.health, the GTK details' Health card):
/// whether an agent or a local LLM is ready, each check with what to do next
/// and, where there is one, the command for it to copy.
class HealthCard extends StatefulWidget {
  const HealthCard({
    super.key,
    required this.method,
    required this.params,
    required this.call,
    required this.tr,
  });
  final String method;
  final Map<String, dynamic> params;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
  call;
  final String Function(String) tr;

  @override
  State<HealthCard> createState() => _HealthCardState();
}

class _HealthCardState extends State<HealthCard> {
  Map<String, dynamic>? _report;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(HealthCard old) {
    super.didUpdateWidget(old);
    if (old.method != widget.method || '${old.params}' != '${widget.params}') {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final report = await widget.call(widget.method, widget.params);
      if (mounted) setState(() => _report = report);
    } catch (_) {
      // No card: the rest of the page is shown.
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    if (report == null || report['checks'] is! List) {
      return const SizedBox.shrink();
    }
    final tr = widget.tr;
    final scheme = Theme.of(context).colorScheme;
    final state = '${report['state']}';
    Color colorOf(String s) => switch (s) {
      'missing' => scheme.error,
      'warn' => StatusColors.warn,
      'ok' => StatusColors.ok,
      _ => scheme.outline,
    };
    IconData iconOf(String s) => switch (s) {
      'missing' => Icons.error_outline,
      'warn' => Icons.warning_amber,
      'ok' => Icons.check_circle_outline,
      _ => Icons.info_outline,
    };
    return Card(
      // Inside a provider's card: one step stronger.
      color: Theme.of(context).colorScheme.surfaceContainer,
      key: ValueKey('health-${widget.method}'),
      child: ExpansionTile(
        initiallyExpanded: state != 'ok',
        leading: Icon(iconOf(state), color: colorOf(state)),
        title: Row(
          children: [
            Text(tr('Health')),
            const SizedBox(width: 8),
            if (_badges.containsKey(state))
              Chip(
                label: Text(tr(_badges[state]!)),
                side: BorderSide(color: colorOf(state)),
              ),
          ],
        ),
        subtitle: Text('${report['summary']}'),
        children: [
          for (final c in (report['checks'] as List).cast<Map>())
            ListTile(
              dense: true,
              leading: Icon(
                iconOf('${c['state']}'),
                color: colorOf('${c['state']}'),
              ),
              title: Text('${c['title']}'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if ('${c['detail']}'.isNotEmpty) Text('${c['detail']}'),
                  if ('${c['step']}'.isNotEmpty)
                    Text(
                      '${c['step']}',
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                  if ('${c['command']}'.isNotEmpty)
                    Row(
                      children: [
                        Expanded(
                          child: SelectableText(
                            '${c['command']}',
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ),
                        IconButton(
                          tooltip: tr('Copy'),
                          icon: const Icon(Icons.copy, size: 16),
                          onPressed: () => Clipboard.setData(
                            ClipboardData(text: '${c['command']}'),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
