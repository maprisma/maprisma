import 'package:flutter/material.dart';
import 'task_card.dart';

const _buildNames = {
  'rocm': 'ROCm',
  'vulkan': 'Vulkan',
  'cuda': 'CUDA',
  'cpu': 'CPU',
};

String _gb(dynamic n) => '${((n as num) / (1 << 30)).toStringAsFixed(1)} GB';

/// short_number: 32768 → 32k.
String shortNumber(dynamic n) =>
    n is int && n != 0 && n % 1024 == 0 ? '${n ~/ 1024}k' : '$n';

/// The choices of a tuning key whose allowed values are a plain list
/// ("on|off|auto"); null when they are a pattern (numbers).
List<String>? _choices(String regex) {
  final parts = regex.split('|');
  return parts.every((x) => RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(x))
      ? parts
      : null;
}

/// A local LLM's performance (models.tuning, the GTK Performance card): its
/// build, the GPU stacks, the video memory, each model's context against what
/// the card holds, and its settings for every model. A change goes through
/// the connection preview: onChange(section, setting, value).
class PerformanceView extends StatelessWidget {
  const PerformanceView({
    super.key,
    required this.facts,
    required this.tr,
    required this.onChange,
    required this.onClose,
  });
  final Map<String, dynamic> facts;
  final String Function(String) tr;
  final void Function(String section, String setting, String value) onChange;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final build = '${facts['build'] ?? ''}';
    final tuning = (facts['tuning'] as Map? ?? const {}).cast<String, List>();
    final shared =
        ((facts['settings'] as Map? ?? const {})['*'] as Map? ?? const {})
            .cast<String, dynamic>();
    // Only llama.cpp keeps a model's context in a file the app changes.
    final contextSettable = facts['key'] == 'llamacpp';
    Widget tile(String title, String value, String detail) => Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: text.labelMedium),
              Text(value, style: text.titleMedium),
              if (detail.isNotEmpty)
                Text(detail, maxLines: 3, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
    return TaskReview(
      title: Text(
        '${tr('Performance')} · ${facts['runtime']}',
        style: text.titleLarge,
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              tile(
                tr('Build'),
                build.isEmpty ? tr('not known') : _buildNames[build] ?? build,
                '${facts['devices'] ?? ''}',
              ),
              tile(
                tr('GPU stacks'),
                (facts['stacks'] as List).isEmpty
                    ? tr('none found')
                    : (facts['stacks'] as List).join(', '),
                '',
              ),
              tile(tr('Video memory'), _gb(facts['vram']), '${facts['gpu']}'),
            ],
          ),
          const SizedBox(height: 12),
          Text(tr('Context per model'), style: text.titleMedium),
          for (final model in (facts['models'] as List).cast<Map>())
            () {
              final best = model['best'] as int, now = model['context'] as int;
              final over = best != 0 && now > best;
              final room = best != 0 && now != 0 && best > now;
              final line = [
                if (model['size'] != 0) _gb(model['size']),
                now != 0
                    ? tr('now {0}').replaceAll('{0}', shortNumber(now))
                    : tr('its default'),
                if (best != 0)
                  tr('fits {0}').replaceAll('{0}', shortNumber(best)),
                if (model['trained'] != 0)
                  tr(
                    'trained for {0}',
                  ).replaceAll('{0}', shortNumber(model['trained'])),
              ].join(' · ');
              return ListTile(
                key: ValueKey('context-${model['name']}'),
                leading: over || room
                    ? Tooltip(
                        message: tr(
                          over
                              ? 'More than the card holds: it would not load, or spill into RAM'
                              : 'The card holds more',
                        ),
                        child: Icon(
                          over ? Icons.warning_amber : Icons.arrow_upward,
                          color: over
                              ? Theme.of(context).colorScheme.error
                              : null,
                        ),
                      )
                    : null,
                title: Text('${model['name']}'),
                subtitle: Tooltip(
                  message: model['per_token'] == 0
                      ? ''
                      : tr(
                          '{0} KB of video memory per token of context',
                        ).replaceAll(
                          '{0}',
                          '${(model['per_token'] as int) ~/ 1024}',
                        ),
                  child: Text(line),
                ),
                trailing: (over || room) && contextSettable
                    ? TextButton(
                        onPressed: () =>
                            onChange('${model['name']}', 'ctx-size', '$best'),
                        child: Text(
                          tr('Set to {0}').replaceAll('{0}', shortNumber(best)),
                        ),
                      )
                    : null,
              );
            }(),
          if (tuning.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(tr('Settings for every model'), style: text.titleMedium),
            for (final e in tuning.entries)
              () {
                final choices = _choices(e.value[0] as String);
                final current = shared[e.key] as String?;
                return ListTile(
                  key: ValueKey('tuning-${e.key}'),
                  title: Text(e.key),
                  subtitle: Text('${e.value[1]}'),
                  trailing: choices == null
                      ? Text(current ?? '—')
                      : DropdownButton<String>(
                          value: choices.contains(current) ? current : null,
                          hint: const Text('—'),
                          items: [
                            for (final c in choices)
                              DropdownMenuItem(value: c, child: Text(c)),
                          ],
                          onChanged: (v) {
                            if (v != null && v != current) {
                              onChange('*', e.key, v);
                            }
                          },
                        ),
                );
              }(),
          ],
        ],
      ),
      actions: [TextButton(onPressed: onClose, child: Text(tr('Close')))],
    );
  }
}
