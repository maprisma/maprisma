import 'package:flutter/material.dart';
import 'app_theme.dart' show monoFont;
import 'task_card.dart';

const _riskNames = {
  'high': 'High risk',
  'medium': 'Medium risk',
  'low': 'Low risk',
};
const _riskSentences = {
  'high':
      'It can do serious things on this PC without asking you. What lowers the risk is listed below.',
  'medium':
      'Some things happen without asking you. What lowers the risk is listed below.',
  'low':
      'It asks before it does anything that matters, or cannot do it at all.',
};

bool _same(dynamic a, dynamic b) {
  if (a is List && b is List) {
    return a.length == b.length &&
        a.toSet().containsAll(b) &&
        b.toSet().containsAll(a);
  }
  return a == b;
}

Color _riskColor(BuildContext context, dynamic risk) {
  final scheme = Theme.of(context).colorScheme;
  return switch ('$risk') {
    'high' || '3' => scheme.error,
    'medium' || '2' => scheme.tertiary,
    _ => scheme.primary,
  };
}

/// An agent's security (agents.security): what it may do without asking,
/// each setting with its choices, and what lowers each risk. A change goes
/// through the connection preview (backup, Undo): onChange(key, value).
class AgentSecurityView extends StatelessWidget {
  const AgentSecurityView({
    super.key,
    required this.report,
    required this.tr,
    required this.onChange,
    required this.onClose,
  });
  final Map<String, dynamic> report;
  final String Function(String) tr;
  final void Function(String key, dynamic value) onChange;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final settings = (report['settings'] as List? ?? const []).cast<Map>();
    final risks = (report['risks'] as List? ?? const []).cast<Map>();
    final level = '${report['level'] ?? ''}';
    final name = '${report['name'] ?? report['agent']}';
    final files = (report['files'] as List? ?? const []).cast<String>();
    final text = Theme.of(context).textTheme;
    String labelOf(Map setting, dynamic value) {
      final choice = (setting['choices'] as List)
          .cast<Map>()
          .where((c) => _same(c['value'], value))
          .firstOrNull;
      return choice == null ? '$value' : '${choice['label']}';
    }

    return TaskReview(
      title: Row(
        children: [
          Expanded(
            child: Text(tr('Security settings'), style: text.titleLarge),
          ),
          if (_riskNames.containsKey(level))
            Chip(
              label: Text(tr(_riskNames[level]!)),
              side: BorderSide(color: _riskColor(context, level)),
            ),
        ],
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr('What it may do on this PC without asking you')),
          const SizedBox(height: 8),
          for (final setting in settings)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('${setting['title']}', style: text.titleMedium),
                    if ('${setting['explain'] ?? ''}'.isNotEmpty)
                      Text('${setting['explain']}'),
                    const SizedBox(height: 8),
                    if (setting['editable'] == true)
                      DropdownButton<int>(
                        isExpanded: true,
                        // The choice in use; null (not set) shows the agent's default.
                        value: () {
                          final choices = (setting['choices'] as List)
                              .cast<Map>();
                          final i = choices.indexWhere(
                            (c) => _same(c['value'], setting['current']),
                          );
                          return i < 0 ? null : i;
                        }(),
                        hint: Text(
                          tr("Not set: the agent's own default applies."),
                        ),
                        items: [
                          for (final (i, c)
                              in (setting['choices'] as List)
                                  .cast<Map>()
                                  .indexed)
                            DropdownMenuItem(
                              value: i,
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.circle,
                                    size: 10,
                                    color: _riskColor(context, c['risk']),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '${c['label']}${_same(c['value'], setting['recommended']) ? ' · ${tr('recommended')}' : ''}',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                        onChanged: (i) {
                          if (i == null) return;
                          final value =
                              (setting['choices'] as List)[i]['value'];
                          if (!_same(value, setting['current'])) {
                            onChange('${setting['key']}', value);
                          }
                        },
                      )
                    else
                      Text(
                        tr('{0}: {1}')
                            .replaceAll('{0}', tr('In use'))
                            .replaceAll(
                              '{1}',
                              labelOf(
                                setting,
                                setting['current'] ?? setting['default'],
                              ),
                            ),
                      ),
                  ],
                ),
              ),
            ),
          if (settings.any((s) => s['editable'] == true))
            Text(
              tr(
                'Open a setting to see every choice. A change is shown first, backed up and can be undone; it applies the next time {0} starts.',
              ).replaceAll('{0}', name),
            ),
          // Allow/deny lists as [title, key, entries], the first 60 shown.
          for (final rule
              in (report['rules'] as List? ?? const []).cast<List>())
            ExpansionTile(
              leading: const Icon(Icons.list),
              title: Text('${rule[0]}'),
              subtitle: Text('${(rule[2] as List).length}'),
              children: [
                for (final entry in (rule[2] as List).take(60))
                  ListTile(
                    dense: true,
                    title: SelectableText(
                      '$entry',
                      style: TextStyle(fontFamily: monoFont(context)),
                    ),
                  ),
              ],
            ),
          if ('${report['note'] ?? ''}'.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('${report['note']}'),
          ],
          if (files.isNotEmpty)
            SelectableText('${tr('Settings file')}: ${files.join(', ')}'),
          if (risks.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(tr('Risk management'), style: text.titleLarge),
            if (_riskSentences.containsKey(level))
              Text(tr(_riskSentences[level]!)),
            for (final risk in risks)
              ListTile(
                leading: Icon(
                  risk['level'] == 'ok'
                      ? Icons.check_circle
                      : Icons.warning_amber,
                  color: _riskColor(context, risk['level']),
                ),
                title: Text('${risk['title']}'),
                subtitle: Text(
                  [
                    '${risk['why'] ?? ''}',
                    if (risk['level'] != 'ok' &&
                        '${risk['lower'] ?? ''}'.isNotEmpty)
                      '→ ${risk['lower']}',
                  ].where((l) => l.isNotEmpty).join('\n'),
                ),
                trailing: () {
                  final setting = settings
                      .where((s) => s['key'] == risk['fix_key'])
                      .firstOrNull;
                  final fixable =
                      setting != null &&
                      setting['editable'] == true &&
                      (setting['choices'] as List).any(
                        (c) => _same(c['value'], risk['fix_value']),
                      ) &&
                      !_same(
                        setting['current'] ?? setting['default'],
                        risk['fix_value'],
                      );
                  if (!fixable) return null;
                  return TextButton(
                    onPressed: () =>
                        onChange('${risk['fix_key']}', risk['fix_value']),
                    child: Text(tr('Lower it…')),
                  );
                }(),
              ),
          ],
        ],
      ),
      actions: const [], // Back in the window's header leads out
    );
  }
}
