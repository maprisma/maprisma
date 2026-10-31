import 'dart:convert';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'window_popup.dart';
import 'app_theme.dart';

class SettingsView extends StatelessWidget {
  const SettingsView({
    super.key,
    required this.settings,
    required this.busy,
    required this.tr,
    required this.onUpdate,
    required this.onBack,
    this.desktopTheme = const {},
    this.checkers = const [],
    this.helpers,
    this.mcpChecks,
    this.mcpChecking = false,
    this.onCheckMcp,
    this.changes,
    this.windowRounding,
    this.onUndoChange,
    this.unitName = '',
  });

  final Map<String, dynamic> settings;
  final Map desktopTheme;
  final bool busy;
  final String Function(String) tr;
  final Future<void> Function(Map<String, dynamic>) onUpdate;
  final VoidCallback onBack;

  /// The installed agents that can do the System Map's checks (command, name).
  final List<Map> checkers;

  /// helper.snapshot: the local helper's candidates, suggestion and choice.
  final Map<String, dynamic>? helpers;

  /// Settings › Daily AI checks: the last check's summary (checks.mcp_*),
  /// whether one runs, and Check now.
  final Map<String, dynamic>? mcpChecks;
  final bool mcpChecking;
  final VoidCallback? onCheckMcp;

  /// Recent changes (changes.history): the connection changes kept on disk,
  /// each with Undo, also after a restart; null while loading.
  final List<Map<String, dynamic>>? changes;

  /// Hyprland's window rounding, for Corners "Like windows" (null: unknown).
  final int? windowRounding;
  final ValueChanged<String>? onUndoChange;

  /// The provider watcher's user service, as the user sees it in systemctl.
  final String unitName;

  static const _boxItems = [
    (
      'rate',
      'Tokens per second',
      'How fast its latest reply came: output tokens over the time from its input to the end.',
    ),
    ('context', 'Context size', 'How many tokens its model can keep in mind.'),
    (
      'used',
      'Context used',
      'The part of the context in use: green, yellow from 75 %, red over 90 %, as the batteries.',
    ),
  ];
  static const _boxSizes = [7, 8, 9, 10, 12];

  /// Settings › Usage statistics box: whether a working agent shows it,
  /// what it shows, and how big.
  List<Widget> _usageBoxRows() {
    final on = settings['usage_box'] as bool? ?? true;
    final items = [
      for (final i
          in settings['usage_box_items'] as List? ??
              const ['rate', 'context', 'used'])
        '$i',
    ];
    return [
      SwitchListTile(
        key: const ValueKey('usage-box'),
        title: Text(tr('Show the usage statistics box')),
        subtitle: Text(
          tr(
            "Small numbers over a working agent's line to its provider, while light runs along it, read from the agent's own session files (numbers only).",
          ),
        ),
        value: on,
        onChanged: busy ? null : (value) => onUpdate({'usage_box': value}),
      ),
      for (final (item, title, hint) in _boxItems)
        SwitchListTile(
          key: ValueKey('usage-box-$item'),
          title: Text(tr(title)),
          subtitle: Text(tr(hint)),
          value: items.contains(item),
          onChanged: busy || !on
              ? null
              : (value) => onUpdate({
                  'usage_box_items': [
                    for (final (i, _, _) in _boxItems)
                      if (i == item ? value : items.contains(i)) i,
                  ],
                }),
        ),
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<int>(
          key: ValueKey('usage-box-size-${settings['usage_box_size']}'),
          initialValue: _boxSizes.contains(settings['usage_box_size'])
              ? settings['usage_box_size'] as int
              : 7,
          decoration: InputDecoration(
            labelText: tr('Text size'),
            helperText: tr('How big its numbers are written on the line.'),
          ),
          items: [
            for (final n in _boxSizes)
              DropdownMenuItem(
                value: n,
                child: Text(
                  tr(
                    n == 7 ? '{0} pt (default)' : '{0} pt',
                  ).replaceAll('{0}', '$n'),
                ),
              ),
          ],
          onChanged: busy || !on
              ? null
              : (v) => v == null ? null : onUpdate({'usage_box_size': v}),
        ),
      ),
    ];
  }

  /// Settings › Local helper: Off, or an agent with a model of the local
  /// LLM (the suggestion marked; choosing one confirms it).
  static String _when(BuildContext context, DateTime t) {
    final words = MaterialLocalizations.of(context);
    return '${words.formatShortDate(t)} '
        '${words.formatTimeOfDay(TimeOfDay.fromDateTime(t))}';
  }

  List<Widget> _changeRows(BuildContext context) {
    final changes = this.changes;
    if (changes == null) return const [];
    return [
      Text(tr('Recent changes'), style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      Text(
        tr(
          "Every change this app wrote to an agent's settings, newest first. Undo puts back what was not changed again since, also after the app was closed or crashed.",
        ),
      ),
      if (changes.isEmpty) Text(tr('No changes yet.')),
      for (final c in changes)
        ListTile(
          key: ValueKey('change-${c['id']}'),
          contentPadding: EdgeInsets.zero,
          title: Text(_when(context, DateTime.parse('${c['when']}'))),
          subtitle: Text(
            [
              ...(c['changed'] as List).take(3),
              if ((c['count'] as int? ?? 0) > 3) '…',
            ].join(', '),
          ),
          trailing: (c['undoable'] as List).isEmpty
              ? Tooltip(
                  message: tr('Changed again since: nothing left to undo'),
                  child: const Icon(Icons.history_toggle_off),
                )
              : OutlinedButton(
                  key: ValueKey('undo-${c['id']}'),
                  onPressed: busy || onUndoChange == null
                      ? null
                      : () => onUndoChange!(c['id'] as String),
                  child: Text(tr('Undo')),
                ),
        ),
    ];
  }

  List<Widget> _helperRows() {
    final found = (helpers?['candidates'] as List? ?? const []).cast<Map>();
    final suggested = helpers?['suggested'] as Map?;
    String keyOf(dynamic k) => k is Map ? jsonEncode(k) : '';
    final current = keyOf(helpers?['chosen']);
    return [
      DropdownButtonFormField<String>(
        key: ValueKey('local-helper-$current-${found.length}'),
        initialValue: current,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: tr('Local helper'),
          helperText: tr(
            'An agent with a model of your local LLM answers the AI help that needs no web (Smart Check, which MCP server fits, help with local LLMs) on this PC, without tokens. Suggested: the largest chat model your graphics card holds.',
          ),
          helperMaxLines: 4,
        ),
        items: [
          DropdownMenuItem(
            value: '',
            child: Text(tr(found.isEmpty ? 'None set up' : 'Off')),
          ),
          for (final c in found)
            DropdownMenuItem(
              value: keyOf(c['key']),
              child: Text(
                '${c['label']}${keyOf(c['key']) == keyOf(suggested?['key']) ? ' ${tr('(suggested)')}' : ''}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: busy || found.isEmpty
            ? null
            : (v) => onUpdate({
                'ai_local_helper': v == null || v.isEmpty
                    ? <String, dynamic>{}
                    : jsonDecode(v) as Map<String, dynamic>,
              }),
      ),
    ];
  }

  static const _limits = [10, 25, 50, 100, 200, 500];
  static const _yellows = [50, 60, 70, 75, 80, 85];
  static const _reds = [80, 85, 90, 95, 100];

  /// Settings › Costs: the currency, a day's limit for an agent paid per
  /// token, and the yellow and red levels (red always above yellow: the
  /// other one moves along, as the reference does).
  List<Widget> _costRows() {
    final yellow = settings['warn_yellow'] as int? ?? 75;
    final red = settings['warn_red'] as int? ?? 90;
    String used(int n, int standard) => tr(
      n == standard ? '{0} % used (default)' : '{0} % used',
    ).replaceAll('{0}', '$n');
    Widget choice<T>(
      String key,
      String label,
      String hint,
      T value,
      List<(T, String)> items,
      ValueChanged<T> onChanged,
    ) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<T>(
        key: ValueKey('$key-$value'),
        initialValue: value,
        decoration: InputDecoration(
          labelText: tr(label),
          helperText: tr(hint),
          helperMaxLines: 3,
        ),
        items: [
          for (final (v, text) in items)
            DropdownMenuItem(value: v, child: Text(text)),
        ],
        onChanged: busy ? null : (v) => v == null ? null : onChanged(v),
      ),
    );
    return [
      choice<String>(
        'cost-currency',
        'Currency',
        "What an agent paid per token cost is shown in. Euros use the European Central Bank's daily reference rate, fetched once a day from ecb.europa.eu.",
        settings['cost_currency'] == 'eur' ? 'eur' : 'usd',
        [('usd', tr(r'US dollar ($)')), ('eur', tr('Euro (€)'))],
        (v) => onUpdate({'cost_currency': v}),
      ),
      choice<int>(
        'cost-limit',
        "A day's limit",
        'For an agent paid per token: its cost label turns yellow and red at the levels below. In the currency above.',
        settings['cost_limit'] as int? ?? 100,
        [
          for (final n in _limits)
            (
              n,
              tr(
                n == 100 ? '{0} a day (default)' : '{0} a day',
              ).replaceAll('{0}', '$n'),
            ),
        ],
        (v) => onUpdate({'cost_limit': v}),
      ),
      choice<int>(
        'warn-yellow',
        'Yellow from',
        "An agent paid per token turns yellow from this share of a day's limit; an agent on a subscription from this share of its plan's limit used (its battery).",
        yellow,
        [for (final n in _yellows) (n, used(n, 75))],
        (v) => onUpdate({
          'warn_yellow': v,
          'warn_red': red > v ? red : _reds.firstWhere((n) => n > v),
        }),
      ),
      choice<int>(
        'warn-red',
        'Red from',
        'Red from this share, for both kinds. Always above yellow.',
        red,
        [for (final n in _reds) (n, used(n, 90))],
        (v) => onUpdate({
          'warn_red': v,
          'warn_yellow': yellow < v ? yellow : _yellows.lastWhere((n) => n < v),
        }),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    const languages = {
      'auto': 'System',
      'en': 'English',
      'de': 'Deutsch',
      'es': 'Español',
      'fr': 'Français',
      'it': 'Italiano',
      'nl': 'Nederlands',
      'pl': 'Polski',
      'pt': 'Português',
    };
    const layers = {
      'agents': 'Agents',
      'online': 'Online',
      'local': 'Local',
      'models': 'Models',
      'mcp': 'MCP servers',
      'skills': 'Skills',
    };
    final enabled = (settings['map_layers'] as List).cast<String>();
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
                label: Text(tr('Back')),
              ),
            ),
            Text(
              tr('Settings'),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 24),
            DropdownButtonFormField<String>(
              key: ValueKey('language-${settings['language']}'),
              initialValue: languages.containsKey(settings['language'])
                  ? settings['language'] as String
                  : 'auto',
              decoration: InputDecoration(labelText: tr('Language')),
              items: [
                for (final language in languages.entries)
                  DropdownMenuItem(
                    value: language.key,
                    child: Text(
                      language.key == 'auto'
                          ? tr('System language')
                          : language.value,
                    ),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      if (value != null) onUpdate({'language': value});
                    },
            ),
            const SizedBox(height: 24),
            Text(tr('Theme'), style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            ThemeChoices(
              value: settings['flutter_theme_mode'] as String? ?? 'system',
              enabled: !busy,
              tr: tr,
              desktop: desktopTheme,
              onChanged: (mode) => onUpdate({'flutter_theme_mode': mode}),
            ),
            const SizedBox(height: 12),
            Text(tr('System follows the desktop appearance.')),
            const SizedBox(height: 24),
            DropdownButtonFormField<String>(
              key: ValueKey('window-mode-${settings['window_mode'] ?? 'auto'}'),
              initialValue: settings['window_mode'] as String? ?? 'auto',
              isExpanded: true,
              decoration: InputDecoration(labelText: tr('Window')),
              items: [
                for (final (value, label) in const [
                  ('auto', 'Automatic: a normal window'),
                  ('popup', 'A popup under the bar'),
                  ('window', 'A normal window'),
                ])
                  DropdownMenuItem(
                    value: value,
                    child: Text(tr(label), overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      if (value != null) onUpdate({'window_mode': value});
                    },
            ),
            const SizedBox(height: 8),
            Text(
              tr(
                'The popup sits at the top right under the bar and closes with Esc or a click elsewhere; the bar icon or starting the app again brings it back. A change applies the next time the window opens.',
              ),
            ),
            const SizedBox(height: 24),
            DropdownButtonFormField<String>(
              key: ValueKey('corners-${settings['corners'] ?? 'windows'}'),
              initialValue:
                  const [
                    'windows',
                    'rounded',
                    'square',
                  ].contains(settings['corners'])
                  ? settings['corners'] as String
                  : 'windows',
              isExpanded: true,
              decoration: InputDecoration(labelText: tr('Corners')),
              items: [
                DropdownMenuItem(
                  value: 'windows',
                  child: Text(
                    windowRounding == null
                        ? tr('Like windows')
                        : tr(
                            'Like windows ({0} px)',
                          ).replaceAll('{0}', '$windowRounding'),
                  ),
                ),
                DropdownMenuItem(value: 'rounded', child: Text(tr('Rounded'))),
                DropdownMenuItem(value: 'square', child: Text(tr('Square'))),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      if (value != null) onUpdate({'corners': value});
                    },
            ),
            const SizedBox(height: 8),
            Text(
              tr(
                "Corners of the window, its cards and the map's boxes. “Like windows” follows Hyprland's window rounding.",
              ),
            ),
            const SizedBox(height: 24),
            DropdownButtonFormField<int>(
              key: ValueKey('map-light-fps-${settings['map_light_fps'] ?? 20}'),
              initialValue: settings['map_light_fps'] as int? ?? 20,
              decoration: InputDecoration(
                labelText: tr('Map light frame rate'),
              ),
              items: [
                for (final fps in [20, 30, 60])
                  DropdownMenuItem(
                    value: fps,
                    child: Text(
                      tr(
                        fps == 20 ? '{0} fps (default)' : '{0} fps',
                      ).replaceAll('{0}', '$fps'),
                    ),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (fps) {
                      if (fps != null) onUpdate({'map_light_fps': fps});
                    },
            ),
            const SizedBox(height: 8),
            Text(
              tr(
                'Maximum frame rate for map lights. Reduced motion and Lights off stop animation.',
              ),
            ),
            const SizedBox(height: 24),
            Card(
              child: Column(
                children: [
                  ListTile(
                    title: Text(tr('Agents start in')),
                    subtitle: Text(
                      settings['agent_folder'] as String? ?? tr('Home folder'),
                    ),
                    trailing: IconButton(
                      tooltip: tr('Choose folder…'),
                      icon: const Icon(Icons.folder_open),
                      onPressed: busy
                          ? null
                          : () async {
                              final chosen = await PopupGuard.around(
                                getDirectoryPath,
                              );
                              if (chosen != null) {
                                await onUpdate({'agent_folder': chosen});
                              }
                            },
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: busy
                          ? null
                          : () => onUpdate({'agent_folder': null}),
                      child: Text(tr('Use home folder')),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text(
              tr('Subagents'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              key: ValueKey(
                'subagents-minutes-${settings['subagents_minutes']}',
              ),
              initialValue: settings['subagents_minutes'] as int? ?? 30,
              decoration: InputDecoration(labelText: tr('Finished ones stay')),
              items: [
                for (final minutes in [10, 30, 60, 120])
                  DropdownMenuItem(
                    value: minutes,
                    child: Text(
                      tr(
                        minutes == 30 ? '{0} minutes (default)' : '{0} minutes',
                      ).replaceAll('{0}', '$minutes'),
                    ),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      if (value != null) onUpdate({'subagents_minutes': value});
                    },
            ),
            const SizedBox(height: 8),
            Text(
              tr(
                'How long a subagent that finished stays on the subagents page, dimmed, after it last worked.',
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              key: ValueKey('subagents-kept-${settings['subagents_kept']}'),
              initialValue: settings['subagents_kept'] as int? ?? 10,
              decoration: InputDecoration(labelText: tr('At most')),
              items: [
                for (final count in [5, 10, 20, 40])
                  DropdownMenuItem(
                    value: count,
                    child: Text(
                      tr(
                        count == 10
                            ? '{0} subagents (default)'
                            : '{0} subagents',
                      ).replaceAll('{0}', '$count'),
                    ),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      if (value != null) onUpdate({'subagents_kept': value});
                    },
            ),
            const SizedBox(height: 8),
            Text(
              tr(
                'How many finished subagents it keeps, the newest first; working ones are always shown.',
              ),
            ),
            const SizedBox(height: 24),
            Text(
              tr('Local LLMs'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            SwitchListTile(
              title: Text(tr('Start local LLMs with their agents')),
              subtitle: Text(
                tr(
                  'When an agent connected to a local LLM starts, its LLM starts too; when the last such agent closes, the LLM stops and its GPU memory is free again. Works with this window closed and after a reboot (user service {0}).',
                ).replaceAll('{0}', unitName),
              ),
              value: settings['providers_with_agents'] as bool? ?? true,
              onChanged: busy
                  ? null
                  : (value) => onUpdate({'providers_with_agents': value}),
            ),
            SwitchListTile(
              key: const ValueKey('terminal-tabs'),
              title: Text(tr('Terminal tabs above the map')),
              subtitle: Text(
                tr(
                  'While agents run in terminals here: a tab for each, with a dot for working, running or ended, above the map and the terminals. A click shows the terminal.',
                ),
              ),
              value: settings['terminal_tabs'] as bool? ?? true,
              onChanged: busy
                  ? null
                  : (value) => onUpdate({'terminal_tabs': value}),
            ),
            const SizedBox(height: 24),
            Text(
              tr('Usage statistics box'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            ..._usageBoxRows(),
            const SizedBox(height: 24),
            Text(tr('Costs'), style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            ..._costRows(),
            SwitchListTile(
              key: const ValueKey('warn-notify'),
              title: Text(tr('Notify when red')),
              subtitle: Text(
                tr(
                  "A desktop notification when an agent's plan limit turns red: once for each limit until it resets.",
                ),
              ),
              value: settings['warn_notify'] as bool? ?? true,
              onChanged: busy
                  ? null
                  : (value) => onUpdate({'warn_notify': value}),
            ),
            const SizedBox(height: 24),
            Text(tr('AI help'), style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            if (checkers.isEmpty)
              ListTile(
                title: Text(tr('Agent for AI checks')),
                subtitle: Text(tr('None installed')),
              )
            else
              DropdownButtonFormField<String>(
                key: ValueKey('checks-agent-${settings['ai_checks_agent']}'),
                initialValue:
                    checkers.any(
                      (c) => c['command'] == settings['ai_checks_agent'],
                    )
                    ? settings['ai_checks_agent'] as String
                    : checkers.first['command'] as String,
                decoration: InputDecoration(
                  labelText: tr('Agent for AI checks'),
                ),
                items: [
                  for (final c in checkers)
                    DropdownMenuItem(
                      value: c['command'] as String,
                      child: Text('${c['name']}'),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (value) {
                        if (value != null) onUpdate({'ai_checks_agent': value});
                      },
              ),
            const SizedBox(height: 8),
            Text(
              tr(
                'Offered first for AI help and the Smart Check on the System Map; its tokens are used for them.',
              ),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              key: const ValueKey('ai-checks'),
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Daily AI checks')),
              subtitle: Text(
                tr(
                  'Once a day, an installed agent looks on the web for new versions of your MCP servers and shows them as hints, with “Do it with …” to let it do the update. This uses the agent\'s tokens or plan limits; its detail page shows how many.',
                ),
              ),
              value: settings['ai_checks'] as bool? ?? false,
              onChanged: busy
                  ? null
                  : (value) => onUpdate({'ai_checks': value}),
            ),
            if (mcpChecks != null && (mcpChecks!['servers'] as int? ?? 0) > 0)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      mcpChecking
                          ? tr('Checking…')
                          : '${tr('MCP server updates')}: ${mcpChecks!['summary']}',
                    ),
                  ),
                  OutlinedButton(
                    key: const ValueKey('ai-checks-now'),
                    onPressed:
                        busy ||
                            mcpChecking ||
                            mcpChecks!['agent'] == null ||
                            onCheckMcp == null
                        ? null
                        : onCheckMcp,
                    child: Text(tr('Check now')),
                  ),
                ],
              ),
            const SizedBox(height: 16),
            ..._helperRows(),
            const SizedBox(height: 24),
            Text(
              tr('Automatic map scans'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              key: ValueKey('map-scan-${settings['map_scan_interval']}'),
              initialValue: settings['map_scan_interval'] as int? ?? 6,
              decoration: InputDecoration(labelText: tr('Automatic map scans')),
              items: [
                for (final seconds in [0, 6, 15, 30, 60, 120, 300])
                  DropdownMenuItem(
                    value: seconds,
                    child: Text(
                      seconds == 0
                          ? tr('Manual only')
                          : tr(
                              'Every {0} seconds',
                            ).replaceAll('{0}', '$seconds'),
                    ),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      if (value != null) onUpdate({'map_scan_interval': value});
                    },
            ),
            SwitchListTile(
              title: Text(tr('Pause scans while unfocused')),
              value: settings['map_scan_pause_unfocused'] as bool? ?? true,
              onChanged: busy
                  ? null
                  : (value) => onUpdate({'map_scan_pause_unfocused': value}),
            ),
            Text(
              tr('Automatic scan targets'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final target in const {
              'activity': 'Activity and subagents',
              'agents': 'Agent details',
              'inventory': 'Models, MCP servers and skills',
            }.entries)
              CheckboxListTile(
                title: Text(tr(target.value)),
                value:
                    (settings['map_scan_targets'] as List? ??
                            ['activity', 'agents', 'inventory'])
                        .contains(target.key),
                onChanged: busy
                    ? null
                    : (on) {
                        final next =
                            (settings['map_scan_targets'] as List? ??
                                    ['activity', 'agents', 'inventory'])
                                .cast<String>()
                                .toSet();
                        on == true
                            ? next.add(target.key)
                            : next.remove(target.key);
                        onUpdate({'map_scan_targets': next.toList()});
                      },
              ),
            Text(tr('Startup and Refresh scan all targets.')),
            Text(tr('Updates apply only while the map is visible.')),
            const SizedBox(height: 24),
            Text(tr('Map'), style: Theme.of(context).textTheme.titleLarge),
            for (final layer in layers.entries)
              CheckboxListTile(
                title: Text(tr(layer.value)),
                value: enabled.contains(layer.key),
                onChanged: busy
                    ? null
                    : (on) {
                        final next = enabled.toSet();
                        on == true
                            ? next.add(layer.key)
                            : next.remove(layer.key);
                        onUpdate({'map_layers': next.toList()});
                      },
              ),
            const SizedBox(height: 24),
            ..._changeRows(context),
          ],
        ),
      ),
    );
  }
}
