import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
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

  /// The provider watcher's user service, as the user sees it in systemctl.
  final String unitName;

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
                              final chosen = await getDirectoryPath();
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
          ],
        ),
      ),
    );
  }
}
