import 'package:flutter/material.dart';
import 'addon_details.dart';
import 'app_look.dart';
import 'map_groups.dart';

/// Why an agent's own add-on cannot be switched off, updated or removed
/// now: the agents running in the app's terminals, by name (task 028).
String addonsLockedText(String Function(String) tr, List<String> agents) =>
    agents.length == 1
    ? tr(
        '{0} is running in a terminal. Its add-on can be switched off, updated or removed when it has finished.',
      ).replaceAll('{0}', agents.single)
    : tr(
        '{0} are running in terminals. Their add-ons can be switched off, updated or removed when they have finished.',
      ).replaceAll('{0}', agents.join(', '));

/// Focused management uses service metadata; it never adds nodes to graph facts.
class MapAddonsFocus extends StatefulWidget {
  const MapAddonsFocus({
    super.key,
    this.hosted = false,
    required this.category,
    required this.items,
    required this.detected,
    required this.nodes,
    required this.entries,
    required this.busy,
    required this.online,
    required this.tr,
    required this.onBack,
    required this.onToggle,
    required this.onCatalog,
    required this.onOnline,
    required this.onInstall,
    required this.onMenu,
    required this.onNode,
    required this.onModels,
    required this.onConnections,
    required this.onFolders,
    this.onFile,
    this.welcome = false,
    this.detecting = false,
    this.detectionFailed = false,
    this.onDetect,
    this.onApply,
    this.onLater,
    this.onLogin,
    this.onNodeMenu,
    this.locked = const {},
    this.onShowTerminal,
    this.onAdd,
    this.runtimes = const [],
  });
  final bool hosted;
  final int category;
  final List<Map<String, dynamic>> items, nodes;
  final List<Map<String, dynamic>>? entries;
  final Set<String> detected;
  final bool busy, online, welcome, detecting, detectionFailed;
  final String Function(String) tr;
  final VoidCallback onBack, onCatalog, onModels, onConnections, onFolders;

  /// The add cards of the MCP and Models pages (no add-ons exist for them):
  /// what to add ('mcp', 'skills', 'model') and a local LLM's key.
  final void Function(String kind, String target)? onAdd;

  /// The local LLMs on the map ({'key', 'name'}): an Add model card each.
  final List<Map<String, String>> runtimes;
  final VoidCallback? onDetect, onLater, onFile;
  final ValueChanged<bool> onOnline;
  final ValueChanged<String>? onLogin;
  final void Function(BuildContext, Map<String, dynamic>)? onNodeMenu;
  final Future<void> Function(String, bool) onToggle;
  final ValueChanged<Map<String, dynamic>> onInstall, onNode;
  final void Function(BuildContext, Map<String, dynamic>) onMenu;
  final Future<void> Function(List<String>)? onApply;

  /// The add-ons a running agent depends on, each with the names of its
  /// agents running in the app's terminals. Only these cannot be switched
  /// off, updated or removed; everything else stays open.
  final Map<String, List<String>> locked;

  /// Brings the first running agent's terminal to the front.
  final VoidCallback? onShowTerminal;
  @override
  State<MapAddonsFocus> createState() => _MapAddonsFocusState();
}

class _MapAddonsFocusState extends State<MapAddonsFocus> {
  final selected = <String>{}, touched = <String>{};
  bool eligible(Map<String, dynamic> i) =>
      i['supported'] == true &&
      i['verified'] == true &&
      ['verified', 'loaded'].contains(i['state']);
  void recommend() {
    final allowed = widget.items
        .where((i) => i['kind'] == 'agent' && eligible(i))
        .map((i) => i['id'] as String)
        .toSet();
    selected.removeWhere((id) => !allowed.contains(id));
    for (final item in widget.items.where(
      (i) => i['kind'] == 'agent' && eligible(i),
    )) {
      if (!touched.contains(item['id']) &&
          (widget.detected.contains(item['id']) || item['enabled'] == true)) {
        selected.add(item['id'] as String);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    recommend();
  }

  @override
  void didUpdateWidget(MapAddonsFocus oldWidget) {
    super.didUpdateWidget(oldWidget);
    recommend();
  }

  bool matches(Map<String, dynamic> item) => widget.category == 1
      ? item['kind'] == 'agent'
      : widget.category == 2 && item['kind'] != 'agent';

  /// The running agents that hold [item], or null when it is free.
  List<String>? lockOf(Map<String, dynamic> item) => widget.locked[item['id']];

  /// A control a running agent locks says why, not only by being grey.
  Widget explained(Widget child, List<String>? lock) => lock != null
      ? Tooltip(message: addonsLockedText(widget.tr, lock), child: child)
      : child;

  /// A menu entry a running agent locks, with the reason under its label.
  Widget menuLabel(String label, [List<String>? lock]) => lock != null
      ? Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            Text(
              addonsLockedText(widget.tr, lock),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        )
      : Text(label);

  Widget lockedBanner(String lockedText) => SectionCard(
    key: const ValueKey('addons-locked'),
    child: Row(
      children: [
        const Icon(Icons.lock_clock, color: StatusColors.warn),
        const SizedBox(width: AppSpace.md),
        Expanded(child: Text(lockedText)),
        if (widget.onShowTerminal != null) ...[
          const SizedBox(width: AppSpace.sm),
          TextButton(
            key: const ValueKey('addons-locked-show'),
            onPressed: widget.onShowTerminal,
            child: Text(widget.tr('Show terminal')),
          ),
        ],
      ],
    ),
  );

  Widget addon(Map<String, dynamic> item) {
    final blocked = widget.busy;
    final lock = lockOf(item);
    // Switching on is always allowed; switching off waits for the agent.
    final offLock = item['enabled'] == true ? lock : null;
    final update = (widget.entries ?? [])
        .where(
          (e) =>
              e['id'] == item['id'] &&
              e['action'] == 'update' &&
              e['preview'] != null,
        )
        .firstOrNull;
    return GestureDetector(
      onSecondaryTap: () => widget.onMenu(context, item),
      child: Card(
        child: Column(
          children: [
            ListTile(
              title: Text('${item['name']} · ${item['version']}'),
              subtitle: Text(
                item['legacy'] == true
                    ? widget.tr(
                        "Made for Asterism, this app's old name, and never loaded. Remove it: Maprisma brings its own copy.",
                      )
                    : item['verified'] != true || item['state'] == 'failed'
                    ? widget.tr('This add-on could not be verified or loaded.')
                    : item['supported'] != true
                    ? widget.tr('Not available in this version')
                    : item['summary'] as String? ?? '',
              ),
              onTap: () => widget.onMenu(context, item),
              trailing: widget.welcome && item['kind'] == 'agent'
                  ? explained(
                      Checkbox(
                        value: selected.contains(item['id']),
                        onChanged:
                            blocked ||
                                !eligible(item) ||
                                lock != null && selected.contains(item['id'])
                            ? null
                            : (on) => setState(() {
                                touched.add(item['id'] as String);
                                on == true
                                    ? selected.add(item['id'] as String)
                                    : selected.remove(item['id']);
                              }),
                      ),
                      lock != null && selected.contains(item['id'])
                          ? lock
                          : null,
                    )
                  : PopupMenuButton<String>(
                      tooltip: widget.tr('Actions'),
                      onSelected: (action) {
                        if (action == 'on') {
                          widget.onToggle(
                            item['id'] as String,
                            item['enabled'] != true,
                          );
                        } else if (action == 'update' && update != null) {
                          widget.onInstall(update);
                        } else if (action.startsWith('login:')) {
                          widget.onLogin?.call(action.substring(6));
                        } else {
                          widget.onMenu(context, item);
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'on',
                          enabled:
                              !blocked &&
                              offLock == null &&
                              item['supported'] == true &&
                              (eligible(item) || item['enabled'] == true),
                          child: menuLabel(
                            widget.tr(
                              item['enabled'] == true
                                  ? 'Switch off'
                                  : 'Switch on',
                            ),
                            offLock,
                          ),
                        ),
                        if (update != null)
                          PopupMenuItem(
                            value: 'update',
                            enabled:
                                !blocked &&
                                lock == null &&
                                widget.online &&
                                item['supported'] == true,
                            child: menuLabel(
                              widget
                                  .tr('Update add-on to {0}')
                                  .replaceAll(
                                    '{0}',
                                    update['version'] as String,
                                  ),
                              lock,
                            ),
                          ),
                        for (final agent in item['sign_ins'] as List? ?? [])
                          if (widget.onLogin != null)
                            PopupMenuItem(
                              value: 'login:${agent['command']}',
                              enabled: !widget.busy,
                              child: Text(
                                widget
                                    .tr('Sign in to {0}…')
                                    .replaceAll('{0}', agent['name'] as String),
                              ),
                            ),
                        PopupMenuItem(
                          value: 'details',
                          child: Text(widget.tr('Add-on…')),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    final items = widget.items.where(matches).toList();
    final catalog = (widget.entries ?? [])
        .where(matches)
        .where((i) => i['action'] == 'install')
        .toList();
    final dummy = widget.nodes.isEmpty;
    final on = items.where((i) => i['enabled'] == true).toList();
    final off = items
        .where(
          (i) => i['enabled'] != true && !widget.detected.contains(i['id']),
        )
        .toList();
    final found = items
        .where((i) => i['enabled'] != true && widget.detected.contains(i['id']))
        .toList();
    // The banner names the agents that hold an add-on of this page.
    final holders = <String>{
      for (final item in items) ...?lockOf(item),
    }.toList();
    // Add-ons exist for agents and providers only; the MCP and Models pages
    // add servers, skills and models instead.
    final addons = widget.category == 1 || widget.category == 2;
    final title = const [
      'MCP servers and skills',
      'Agents',
      'Providers',
      'Models',
    ][widget.category];
    return MapFocus(
      hosted: widget.hosted,
      title: title,
      tr: tr,
      onBack: widget.onBack,
      footer: widget.welcome
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: widget.busy ? null : widget.onLater,
                    child: Text(tr('Later')),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: widget.busy || widget.detecting
                        ? null
                        : () => widget.onApply?.call(selected.toList()..sort()),
                    child: Text(tr('Switch on')),
                  ),
                ],
              ),
            )
          : null,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // First, so the reason is seen before any greyed-out switch.
          if (holders.isNotEmpty) ...[
            lockedBanner(addonsLockedText(tr, holders)),
            const SizedBox(height: AppSpace.md),
          ],
          if (widget.onDetect != null && addons)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: widget.busy || widget.detecting
                    ? null
                    : widget.onDetect,
                icon: const Icon(Icons.refresh),
                label: Text(tr('Refresh')),
              ),
            ),
          if (addons) ...[
            Text(
              tr(
                'Only add-ons signed by Uwe Bruckhaus are offered and loaded.',
              ),
            ),
            Text(tr('New add-ons stay switched off until you enable them.')),
          ],
          if (widget.welcome)
            Text(
              tr(
                'Pick the AI agents you use. The ones found on this PC are already marked.',
              ),
            ),
          if (widget.detecting) const LinearProgressIndicator(),
          if (widget.detectionFailed)
            ListTile(
              title: Text(tr('The action could not be completed.')),
              trailing: TextButton(
                onPressed: widget.busy ? null : widget.onDetect,
                child: Text(tr('Refresh')),
              ),
            ),
          if (!dummy && on.isNotEmpty) ...[
            Text(tr('On'), style: Theme.of(context).textTheme.titleLarge),
            for (final item in on) addon(item),
          ],
          if (!dummy && off.isNotEmpty) ...[
            Text(tr('Off'), style: Theme.of(context).textTheme.titleLarge),
            for (final item in off) addon(item),
          ],
          if (found.isNotEmpty) ...[
            Text(
              tr('Found on this PC'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            for (final item in found) addon(item),
          ],
          for (final node in widget.nodes)
            if (!items.any(
              (i) => (i['provides'] as List? ?? []).contains(
                (node['id'] as String? ?? '').split(':').skip(1).join(':'),
              ),
            ))
              Card(
                child: ListTile(
                  title: Text(node['label'] as String),
                  subtitle: Text(node['detail'] as String? ?? ''),
                  onTap: () => widget.onNode(node),
                  trailing: IconButton(
                    tooltip: tr('Actions'),
                    onPressed: () {
                      final menu = widget.onNodeMenu;
                      if (menu != null) {
                        menu(context, node);
                      } else {
                        widget.onNode(node);
                      }
                    },
                    icon: const Icon(Icons.more_horiz),
                  ),
                ),
              ),
          if (!addons && widget.onAdd != null) ...[
            const SizedBox(height: AppSpace.md),
            for (final (kind, target, label, hint) in [
              if (widget.category == 0) ...[
                (
                  'mcp',
                  '',
                  tr('Add MCP server'),
                  tr('Recommended, registry, this PC'),
                ),
                ('skills', '', tr('Add skills'), tr('This PC or the web')),
              ],
              // No local LLM on the map (its column hidden): the first one
              // installed, or Providers and models if there is none.
              if (widget.category == 3 && widget.runtimes.isEmpty)
                ('model', '', tr('Add model'), tr('Download model')),
              if (widget.category == 3)
                for (final rt in widget.runtimes)
                  (
                    'model',
                    rt['key']!,
                    '${tr('Add model')} · ${rt['name']}',
                    tr('Download for {0}').replaceAll('{0}', rt['name']!),
                  ),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  height: 48,
                  child: MapAddCard(
                    key: ValueKey('focus-add-$kind-$target'),
                    label: label,
                    hint: hint,
                    onTap: widget.busy
                        ? null
                        : () => widget.onAdd!(kind, target),
                  ),
                ),
              ),
          ],
          if (addons) ...[
            const Divider(),
            Text(
              tr('Not installed'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (dummy) ...[
              for (final item in [...on, ...off]) addon(item),
            ],
            SwitchListTile(
              title: Text(tr('Look for add-ons online')),
              value: widget.online,
              onChanged: widget.busy ? null : widget.onOnline,
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: widget.busy ? null : widget.onCatalog,
                  child: Text(
                    tr(widget.online ? 'Look for add-ons online' : 'Available'),
                  ),
                ),
                if (widget.onFile != null)
                  TextButton(
                    key: const ValueKey('addons-install-file'),
                    onPressed: widget.busy ? null : widget.onFile,
                    child: Text(tr('Install from file…')),
                  ),
              ],
            ),
            if (widget.entries == null)
              Text(tr('The catalog loads only when you ask to look online.')),
            for (final item in catalog)
              Card(
                child: ExpansionTile(
                  title: Text('${item['name']} · ${item['version']}'),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: AddonDetails(item: item, tr: tr),
                    ),
                    FilledButton(
                      onPressed:
                          widget.busy ||
                              !widget.online ||
                              item['supported'] != true ||
                              item['preview'] == null
                          ? null
                          : () => widget.onInstall(item),
                      child: Text(tr('Get add-on')),
                    ),
                  ],
                ),
              ),
          ],
          if (widget.category == 3 || widget.category == 2)
            TextButton(
              onPressed: widget.busy ? null : widget.onModels,
              child: Text(tr('Providers and models')),
            ),
          if (widget.category == 3)
            TextButton(
              onPressed: widget.busy ? null : widget.onFolders,
              child: Text(tr('Reuse model folder')),
            ),
          if (widget.category == 0)
            TextButton(
              onPressed: widget.busy ? null : widget.onConnections,
              child: Text(tr('Connections')),
            ),
        ],
      ),
    );
  }
}
