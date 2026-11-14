import 'package:flutter/material.dart';
import 'app_look.dart' show AppSpace, StatusColors;
import 'map_smart_card.dart' show smartActionLabels;

const _separateMountHint =
    'Already have AI tools on another disk? Mount it first, then use Find existing AI before installing or downloading again.';
const _simplifyHint =
    'Reuse a shared model folder instead of downloading models again. Review duplicate files and unused services before changing anything.';

const _useLevels = {'ready': 'Ready', 'almost': 'Almost', 'missing': 'Not yet'};

/// The use cases: what this setup is good for, with their Ready, Almost and
/// Not yet. On the welcome page and in Help.
class UseCaseCards extends StatelessWidget {
  const UseCaseCards({
    super.key,
    required this.uses,
    required this.tr,
    this.onAction,
  });
  final List<Map<String, dynamic>> uses;
  final String Function(String) tr;
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
              ? StatusColors.ok
              : StatusColors.warn,
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
    return Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      children: [
        for (final u in uses)
          SizedBox(
            width: 280,
            child: Card(
              key: ValueKey('use-${u['key']}'),
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('${u['title']}', style: text.titleSmall),
                        ),
                        Chip(
                          label: Text(
                            tr(_useLevels[u['level']] ?? '${u['level']}'),
                          ),
                        ),
                      ],
                    ),
                    Text('${u['blurb']}'),
                    if ((u['have'] as List? ?? const []).isNotEmpty)
                      Text('✓ ${(u['have'] as List).take(5).join(', ')}'),
                    for (final s
                        in (u['steps'] as List? ?? const []).cast<Map>().take(
                          2,
                        ))
                      _stepTile(context, s),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class MapWelcome extends StatelessWidget {
  const MapWelcome({
    super.key,
    required this.tr,
    required this.busy,
    required this.skipSearch,
    required this.searched,
    required this.onLook,
    required this.onSkip,
    required this.onAgents,
    this.uses = const [],
    this.onAction,
  });
  final String Function(String) tr;
  final bool busy, skipSearch, searched;
  final VoidCallback onLook, onSkip, onAgents;
  final List<Map<String, dynamic>> uses;
  final void Function(List<String> action)? onAction;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final intro = Text(
      '${tr('Welcome to {0}').replaceAll('{0}', 'Maprisma')}\n${tr(_separateMountHint)}\n${tr(_simplifyHint)}\n${tr('Only this PC is inspected. Nothing is sent and no detected program is run. You can skip the disk search.')}',
    );
    final actions = [
      if (!skipSearch && !searched) ...[
        TextButton(
          onPressed: busy ? null : onLook,
          child: Text(tr('Look at this PC')),
        ),
        TextButton(onPressed: busy ? null : onSkip, child: Text(tr('Skip'))),
      ],
      TextButton(onPressed: busy ? null : onAgents, child: Text(tr('Agents'))),
    ];
    // A short window (a fresh COSMIC places one that doesn't fit at about 855×465, task 073):
    // only the welcome line and the buttons, so the Agents card below keeps room for its list.
    // Taller: the text, at most a fifth of the window (and 110 px), scrolling.
    final height = MediaQuery.sizeOf(context).height;
    if (height < 560) {
      return MaterialBanner(
        content: Text(
          tr('Welcome to {0}').replaceAll('{0}', 'Maprisma'),
          key: const ValueKey('welcome-intro'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        // the whole welcome text (where to start, privacy) stays one click away
        actions: [
          TextButton(
            key: const ValueKey('welcome-details'),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                content: SingleChildScrollView(child: intro),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(tr('Close')),
                  ),
                ],
              ),
            ),
            child: Text(tr('Details…')),
          ),
          ...actions,
        ],
      );
    }
    final maxHeight = (height * 0.2).clamp(48.0, 110.0);
    return MaterialBanner(
      content: uses.isEmpty
          ? ConstrainedBox(
              key: const ValueKey('welcome-intro'),
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: SingleChildScrollView(child: intro),
            )
          : ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    intro,
                    const SizedBox(height: AppSpace.md),
                    Text(
                      tr('What you can do with it'),
                      style: text.titleMedium,
                    ),
                    const SizedBox(height: AppSpace.sm),
                    UseCaseCards(uses: uses, tr: tr, onAction: onAction),
                  ],
                ),
              ),
            ),
      actions: actions,
    );
  }
}
