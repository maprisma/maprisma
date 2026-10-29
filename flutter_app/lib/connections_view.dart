import 'task_card.dart';
import 'connection_authoring.dart';
import 'mcp_catalog_view.dart';
import 'mcp_tools_view.dart';
import 'skills_web_view.dart';
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
    this.onCatalogTask,
    this.onCatalogPreview,
    this.onCall,
    this.onSkillPreview,
    this.showFound = false,
  });

  /// Open with what was found on this PC (Open problems' "New on this PC").
  final bool showFound;
  final Future<void> Function(Map<String, dynamic>)? onSkillPreview;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
  onCall;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
  onCatalogTask;
  final Future<void> Function(Map<String, dynamic>)? onCatalogPreview;
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
  bool _catalog = false;
  bool _skillsWeb = false;
  final _searchController = TextEditingController();
  Map<String, dynamic> _initial = const {};

  /// found.list for mcp and skills; null while closed.
  Map<String, Map<String, dynamic>>? _found;

  @override
  void initState() {
    super.initState();
    if (widget.showFound) _openFound();
  }

  @override
  void didUpdateWidget(ConnectionsView old) {
    super.didUpdateWidget(old);
    if (widget.showFound && !old.showFound) _openFound();
  }

  Future<void> _openFound() async {
    final call = widget.onCall;
    if (call == null) return;
    try {
      final found = {
        for (final kind in ['mcp', 'skills'])
          kind: await call('found.list', {'kind': kind}),
      };
      if (!mounted) return;
      setState(() => _found = found);
      // Shown: what is new now is no longer new (mark_seen).
      for (final kind in ['mcp', 'skills']) {
        await call('found.seen', {'kind': kind});
      }
    } catch (_) {
      if (mounted) setState(() => _found = {});
    }
  }

  void _addFound(String kind, Map item) => setState(() {
    _found = null;
    _initial = Map<String, dynamic>.from(item);
    _authorKind = kind;
  });

  Widget _foundPanel(BuildContext context) {
    final found = _found!;
    final mcp = found['mcp'] ?? const {}, skills = found['skills'] ?? const {};
    final programs = (mcp['items'] as List? ?? const []).cast<Map>();
    final sets = (skills['items'] as List? ?? const []).cast<Map>();
    String tr(String key) => widget.tr(key);
    Widget row(String kind, Map item, String title, String detail) => ListTile(
      key: ValueKey('found-$kind-$title'),
      dense: true,
      leading: Icon(kind == 'mcp' ? Icons.apps : Icons.auto_awesome),
      title: Text(title),
      subtitle: Text(item['new'] == true ? '★ ${tr('new')} · $detail' : detail),
      trailing: OutlinedButton(
        onPressed: widget.busy || item['ready'] == false
            ? null
            : () => _addFound(kind, item),
        child: Text(tr('Add…')),
      ),
    );
    return Card(
      key: const ValueKey('found-panel'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr('Found on this PC'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: tr('Close'),
                  onPressed: () => setState(() => _found = null),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            if (programs.isEmpty && sets.isEmpty)
              Text(
                tr(
                  (mcp['set_up'] as int? ?? 0) > 0
                      ? 'Every program found here is set up already.'
                      : 'Nothing found.',
                ),
              ),
            for (final c in programs)
              row(
                'mcp',
                c,
                '${c['name']}${'${c['version']}'.isEmpty ? '' : ' ${c['version']}'}',
                '${c['where']}',
              ),
            for (final s in sets)
              row(
                'skills',
                s,
                '${s['origin']}',
                '${s['path']} · ${(s['skills'] as List).take(4).join(', ')}',
              ),
          ],
        ),
      ),
    );
  }

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
                if (widget.onCatalogTask != null &&
                    widget.onCatalogPreview != null)
                  FilledButton.tonalIcon(
                    key: const ValueKey('mcp-catalog-open'),
                    onPressed: widget.busy
                        ? null
                        : () => setState(() => _catalog = true),
                    icon: const Icon(Icons.travel_explore),
                    label: Text(widget.tr('Find MCP servers…')),
                  ),
                if (widget.onCatalogTask != null &&
                    widget.onSkillPreview != null)
                  FilledButton.tonalIcon(
                    key: const ValueKey('skills-web-open'),
                    onPressed: widget.busy
                        ? null
                        : () => setState(() => _skillsWeb = true),
                    icon: const Icon(Icons.travel_explore),
                    label: Text(widget.tr('Find skills on the web…')),
                  ),
                if (widget.onCall != null)
                  OutlinedButton.icon(
                    key: const ValueKey('found-open'),
                    onPressed: widget.busy ? null : _openFound,
                    icon: const Icon(Icons.search),
                    label: Text(widget.tr('Found on this PC')),
                  ),
                for (final kind in ['mcp', 'skills'])
                  OutlinedButton.icon(
                    onPressed: widget.busy
                        ? null
                        : () => setState(() {
                            _initial = const {};
                            _authorKind = kind;
                          }),
                    icon: const Icon(Icons.add),
                    label: Text(
                      widget.tr(
                        kind == 'mcp' ? 'Add MCP server' : 'Add skills',
                      ),
                    ),
                  ),
              ],
            ),
            if (_found != null) _foundPanel(context),
            if (_catalog)
              McpCatalogView(
                agents: (widget.data['agents'] as List? ?? [])
                    .cast<Map<String, dynamic>>(),
                busy: widget.busy,
                tr: widget.tr,
                run: widget.onCatalogTask!,
                onPreview: widget.onCatalogPreview!,
                onClose: () => setState(() => _catalog = false),
              ),
            if (_skillsWeb)
              SkillsWebView(
                busy: widget.busy,
                tr: widget.tr,
                run: widget.onCatalogTask!,
                onPreview: widget.onSkillPreview!,
                onClose: () => setState(() => _skillsWeb = false),
              ),
            if (_authorKind != null)
              ConnectionAuthoring(
                key: ValueKey(
                  '$_authorKind-${_initial['name'] ?? _initial['path'] ?? ''}',
                ),
                kind: _authorKind!,
                initial: _initial,
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
                      if (kind == 'mcp' &&
                          widget.onCall != null &&
                          widget.onCatalogTask != null)
                        McpServerTools(
                          name: item['id'] as String,
                          busy: widget.busy,
                          tr: widget.tr,
                          call: widget.onCall!,
                          run: widget.onCatalogTask!,
                        ),
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
            for (final file in plan['new_files'] as List? ?? [])
              ListTile(
                leading: const Icon(Icons.note_add_outlined),
                title: Text(file as String),
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
