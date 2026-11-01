import 'package:flutter/material.dart';
import 'map_smart_card.dart' show smartActionLabels;
import 'system_map_view.dart' show separateMountHint, simplifyHint;

const _useLevels = {'ready': 'Ready', 'almost': 'Almost', 'missing': 'Not yet'};

class MapWelcome extends StatelessWidget {
  const MapWelcome({
    super.key,
    required this.tr,
    required this.busy,
    required this.skipSearch,
    required this.searched,
    required this.onLook,
    required this.onSkip,
    required this.onSystem,
    required this.onAgents,
    this.uses = const [],
    this.onAction,
  });
  final String Function(String) tr;
  final bool busy, skipSearch, searched;
  final VoidCallback onLook, onSkip, onSystem, onAgents;
  final List<Map<String, dynamic>> uses;
  final void Function(List<String> action)? onAction;

  Widget _stepTile(BuildContext context, Map f) {
    final scheme = Theme.of(context).colorScheme;
    final level = '${f['level']}';
    final action = [for (final x in f['action'] as List? ?? const []) '$x'];
    final label = action.isEmpty ? null : smartActionLabels[action.first];
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Text(
        const {'ok': '✓', 'hint': '→', 'warn': '!'}[level] ?? '·',
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: level == 'warn'
              ? scheme.error
              : level == 'ok'
              ? Colors.green
              : scheme.tertiary,
        ),
      ),
      title: Text('${f['title']}'),
      subtitle: '${f['text'] ?? ''}'.isEmpty ? null : Text('${f['text']}'),
      trailing: label == null || onAction == null
          ? null
          : OutlinedButton(
              onPressed: () => onAction!(action),
              child: Text(tr(label)),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final intro = Text(
      '${tr('Welcome to {0}').replaceAll('{0}', 'Maprisma')}\n${tr(separateMountHint)}\n${tr(simplifyHint)}\n${tr('Only this PC is inspected. Nothing is sent and no detected program is run. You can skip the disk search.')}',
    );
    return MaterialBanner(
      content: uses.isEmpty
          ? intro
          : ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 110),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    intro,
                    const SizedBox(height: 12),
                    Text(
                      tr('What you can do with it'),
                      style: text.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final u in uses)
                          SizedBox(
                            width: 280,
                            child: Card(
                              key: ValueKey('use-${u['key']}'),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            '${u['title']}',
                                            style: text.titleSmall,
                                          ),
                                        ),
                                        Chip(
                                          label: Text(
                                            tr(
                                              _useLevels[u['level']] ??
                                                  '${u['level']}',
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    Text('${u['blurb']}'),
                                    if ((u['have'] as List? ?? const [])
                                        .isNotEmpty)
                                      Text(
                                        '✓ ${(u['have'] as List).take(5).join(', ')}',
                                      ),
                                    for (final s
                                        in (u['steps'] as List? ?? const [])
                                            .cast<Map>()
                                            .take(2))
                                      _stepTile(context, s),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
      actions: [
        if (!skipSearch && !searched) ...[
          TextButton(
            onPressed: busy ? null : onLook,
            child: Text(tr('Look at this PC')),
          ),
          TextButton(onPressed: busy ? null : onSkip, child: Text(tr('Skip'))),
        ],
        TextButton(
          onPressed: busy ? null : onSystem,
          child: Text(tr('System Map')),
        ),
        TextButton(
          onPressed: busy ? null : onAgents,
          child: Text(tr('Agents')),
        ),
      ],
    );
  }
}
