import 'package:flutter/material.dart';
import 'addon_details.dart';
import 'map_groups.dart';

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
    required this.running,
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
    this.welcome = false,
    this.detecting = false,
    this.detectionFailed = false,
    this.onDetect,
    this.onApply,
    this.onLater,
    this.onLogin,
    this.onNodeMenu,
  });
  final bool hosted;
  final int category;
  final List<Map<String, dynamic>> items, nodes;
  final List<Map<String, dynamic>>? entries;
  final Set<String> detected;
  final bool busy, running, online, welcome, detecting, detectionFailed;
  final String Function(String) tr;
  final VoidCallback onBack, onCatalog, onModels, onConnections, onFolders;
  final VoidCallback? onDetect, onLater;
  final ValueChanged<bool> onOnline;
  final ValueChanged<String>? onLogin;
  final void Function(BuildContext, Map<String, dynamic>)? onNodeMenu;
  final Future<void> Function(String, bool) onToggle;
  final ValueChanged<Map<String, dynamic>> onInstall, onNode;
  final void Function(BuildContext, Map<String, dynamic>) onMenu;
  final Future<void> Function(List<String>)? onApply;
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
  Widget addon(Map<String, dynamic> item) {
    final blocked = widget.busy || widget.running;
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
                item['supported'] != true
                    ? widget.tr('Not available in this version')
                    : item['verified'] != true || item['state'] == 'failed'
                    ? widget.tr('This add-on could not be verified or loaded.')
                    : item['summary'] as String? ?? '',
              ),
              onTap: () => widget.onMenu(context, item),
              trailing: widget.welcome && item['kind'] == 'agent'
                  ? Checkbox(
                      value: selected.contains(item['id']),
                      onChanged: blocked || !eligible(item)
                          ? null
                          : (on) => setState(() {
                              touched.add(item['id'] as String);
                              on == true
                                  ? selected.add(item['id'] as String)
                                  : selected.remove(item['id']);
                            }),
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
                              item['supported'] == true &&
                              (eligible(item) || item['enabled'] == true),
                          child: Text(
                            widget.tr(
                              item['enabled'] == true
                                  ? 'Switch off'
                                  : 'Switch on',
                            ),
                          ),
                        ),
                        if (update != null)
                          PopupMenuItem(
                            value: 'update',
                            enabled:
                                !blocked &&
                                widget.online &&
                                item['supported'] == true,
                            child: Text(
                              widget
                                  .tr('Update add-on to {0}')
                                  .replaceAll(
                                    '{0}',
                                    update['version'] as String,
                                  ),
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
                    onPressed: widget.busy || widget.running || widget.detecting
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
          if (widget.onDetect != null)
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
          Text(
            tr('Only add-ons signed by Uwe Bruckhaus are offered and loaded.'),
          ),
          Text(tr('New add-ons stay switched off until you enable them.')),
          if (widget.running)
            Text(tr('Finish running agents before changing add-ons.')),
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
          TextButton(
            onPressed: widget.busy ? null : widget.onCatalog,
            child: Text(
              tr(widget.online ? 'Look for add-ons online' : 'Available'),
            ),
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
                            widget.running ||
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
