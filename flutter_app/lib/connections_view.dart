import 'task_card.dart';
import 'connection_authoring.dart';
import 'package:flutter/material.dart';
import 'provider_connections.dart';

class ConnectionsView extends StatefulWidget {
  const ConnectionsView({
    super.key,
    this.hosted = false,
    required this.data,
    required this.busy,
    required this.tr,
    required this.onPreview,
    required this.onBack,
    this.onUndo,
    this.onAuthorPreview,
  });
  final Future<void> Function(Map<String, dynamic>)? onAuthorPreview;
  final bool hosted;
  final Map<String, dynamic> data;
  final bool busy;
  final String Function(String) tr;
  final Future<void> Function(Map<String, dynamic>) onPreview;
  final VoidCallback onBack;
  final VoidCallback? onUndo;
  @override
  State<ConnectionsView> createState() => _ConnectionsViewState();
}

class _ConnectionsViewState extends State<ConnectionsView> {
  String _search = '';
  String? _authorKind;
  final _searchController = TextEditingController();
  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 950),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (!widget.hosted || widget.onUndo != null)
            Row(
              children: [
                if (!widget.hosted)
                  TextButton.icon(
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back),
                    label: Text(widget.tr('Back')),
                  ),
                const Spacer(),
                if (widget.onUndo != null)
                  TextButton.icon(
                    onPressed: widget.busy ? null : widget.onUndo,
                    icon: const Icon(Icons.undo),
                    label: Text(widget.tr('Undo')),
                  ),
              ],
            ),
          if (!widget.hosted)
            Text(
              widget.tr('Connections'),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          if (widget.onAuthorPreview != null) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final kind in ['mcp', 'skills'])
                  OutlinedButton.icon(
                    onPressed: widget.busy
                        ? null
                        : () => setState(() => _authorKind = kind),
                    icon: const Icon(Icons.add),
                    label: Text(
                      widget.tr(
                        kind == 'mcp' ? 'Add MCP server' : 'Add skills',
                      ),
                    ),
                  ),
              ],
            ),
            if (_authorKind != null)
              ConnectionAuthoring(
                key: ValueKey(_authorKind),
                kind: _authorKind!,
                agents: (widget.data['agents'] as List? ?? [])
                    .cast<Map<String, dynamic>>(),
                busy: widget.busy,
                tr: widget.tr,
                onPreview: widget.onAuthorPreview!,
                onClose: () => setState(() => _authorKind = null),
              ),
          ],
          const SizedBox(height: 20),
          TextField(
            key: const ValueKey('connection-search'),
            controller: _searchController,
            decoration: InputDecoration(
              labelText: widget.tr('Search'),
              prefixIcon: const Icon(Icons.search),
            ),
            onChanged: (value) => setState(() => _search = value.toLowerCase()),
          ),
          const SizedBox(height: 20),
          for (final provider in widget.data['providers'] as List? ?? [])
            if ((provider['name'] as String).toLowerCase().contains(_search))
              ProviderConnections(
                key: ValueKey(provider['id']),
                provider: provider as Map<String, dynamic>,
                agents: widget.data['agents'] as List,
                busy: widget.busy,
                tr: widget.tr,
                onPreview: widget.onPreview,
              ),
          for (final kind in ['mcp', 'skills']) ...[
            Text(
              widget.tr(kind == 'mcp' ? 'MCP servers' : 'Skills'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            for (final item in widget.data[kind] as List? ?? [])
              if ('${item['name']} ${item['skills'] ?? ''}'
                  .toLowerCase()
                  .contains(_search))
                Card(
                  key: ValueKey('connection-$kind:${item['id']}'),
                  child: ExpansionTile(
                    title: Text(item['name'] as String),
                    subtitle: kind == 'mcp'
                        ? Text(item['target'] as String)
                        : null,
                    children: [
                      if (kind == 'skills')
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text((item['skills'] as List).join(', ')),
                        ),
                      for (final agent in widget.data['agents'] as List? ?? [])
                        if (agent[kind] == true)
                          SwitchListTile(
                            title: Text(agent['name'] as String),
                            value: (item['agents'] as List).contains(
                              agent['command'],
                            ),
                            onChanged: widget.busy
                                ? null
                                : (on) => widget.onPreview({
                                    'kind': kind,
                                    'command': agent['command'],
                                    'item': item['id'],
                                    'remove': !on,
                                  }),
                          ),
                    ],
                  ),
                ),
            const SizedBox(height: 20),
          ],
        ],
      ),
    ),
  );
}

class ConnectionReview extends StatelessWidget {
  const ConnectionReview({
    super.key,
    required this.plan,
    required this.tr,
    required this.onConfirm,
    required this.onCancel,
  });
  final Map<String, dynamic> plan;
  final String Function(String) tr;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  @override
  Widget build(BuildContext context) => TaskReview(
    title: Text(tr('Preview')),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('Configuration values stay private.')),
            for (final note in plan['notes'] as List? ?? [])
              Text(tr(note as String)),
            for (final context in plan['contexts'] as List? ?? [])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '${context['provider']} · ${context['model']} · ${context['tokens']} ${tr('Tokens')}',
                ),
              ),
            if ((plan['contexts'] as List? ?? []).isNotEmpty)
              Text(
                tr(
                  'Undo restores configuration files; API context changes are not undone.',
                ),
              ),
            for (final action in plan['model_actions'] as List? ?? [])
              Text(
                '${tr(action['operation'] == 'model.load' ? 'Load' : 'Unload')}: ${action['model']}',
              ),
            if (plan['agents'] != null)
              Text('${tr('Agents')}: ${(plan['agents'] as List).join(', ')}'),
            if (plan['item'] != null && plan['command'] != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '${tr(plan['remove'] == true ? 'Disconnect' : 'Connect')} ${plan['item']} → ${plan['command']}',
                ),
              ),
            if (plan['empty'] == true)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(tr('No changes to apply')),
              ),
            for (final file in plan['files'] as List)
              ListTile(
                title: Text(file['path'] as String),
                subtitle: Text('+${file['added']} / −${file['removed']}'),
              ),
            for (final link in plan['links_add'] as List)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text('+ ${link[0]} → ${link[1]}'),
              ),
            for (final link in plan['links_remove'] as List)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text('− ${link[0]} → ${link[1]}'),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: onCancel, child: Text(tr('Cancel'))),
      FilledButton(
        onPressed: plan['empty'] == true ? null : onConfirm,
        child: Text(tr('Apply')),
      ),
    ],
  );
}
