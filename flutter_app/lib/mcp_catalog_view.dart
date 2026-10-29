import 'package:flutter/material.dart';
import 'mcp_tools_view.dart';

const _runKind = {
  'npm': 'Program · npm',
  'pypi': 'Program · Python',
  'oci': 'Program · Docker',
  'remote': 'Web service',
};
const _runText = {
  'npm':
      'Runs on this PC with Node.js. npx downloads {0} on its first start and keeps it in its cache.',
  'pypi':
      'Runs on this PC with uv. uvx downloads {0} on its first start into an environment of its own.',
  'oci':
      'Runs on this PC in a Docker container ({0}), apart from your files unless you share a folder.',
  'remote':
      'Runs at {0}. Nothing is installed; what the agents send to it leaves your PC.',
};
const _runners = {
  'npx': 'Node.js (npx) is not installed yet: sudo pacman -S nodejs npm',
  'uvx': 'uv (uvx) is not installed yet: sudo pacman -S uv',
  'docker': 'Docker is not installed yet: sudo pacman -S docker',
};
final _nameRe = RegExp(r'^[A-Za-z0-9_.-]{1,64}$');
const _page = 20;

/// MCP servers to add (mcp.catalog, mcp.search): the recommended ones and the
/// MCP registry's, each with who made it, how it runs and what it needs. The
/// chosen way to run it, filled in, goes to the preview (mcp.option_preview);
/// the program it names runs only when an agent starts it.
class McpCatalogView extends StatefulWidget {
  const McpCatalogView({
    super.key,
    required this.agents,
    required this.busy,
    required this.tr,
    required this.run,
    required this.onPreview,
    required this.onClose,
  });
  final List<Map<String, dynamic>> agents;
  final bool busy;
  final String Function(String) tr;

  /// Starts a service task and returns its result.
  final Future<Map<String, dynamic>> Function(
    String method,
    Map<String, dynamic> params,
  )
  run;
  final Future<void> Function(Map<String, dynamic> params) onPreview;
  final VoidCallback onClose;

  @override
  State<McpCatalogView> createState() => _McpCatalogViewState();
}

class _McpCatalogViewState extends State<McpCatalogView> {
  int _tab = 0;
  bool _loading = false;
  String? _error;
  Map<String, dynamic>? _catalog;
  final _query = TextEditingController();
  List<Map<String, dynamic>> _found = [];
  final _cursors = <String>[''];
  String _next = '';
  dynamic _total;
  bool _searched = false;
  Map<String, dynamic>? _server, _pick;
  int _option = 0;
  final _fields = <String, TextEditingController>{};
  final _name = TextEditingController();
  final _chosen = <String>{};
  Map<String, dynamic>? _tested;
  bool _testing = false;

  String tr(String key) => widget.tr(key);

  @override
  void initState() {
    super.initState();
    _loadCatalog();
  }

  @override
  void dispose() {
    _query.dispose();
    _name.dispose();
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.run('mcp.catalog', {});
      if (mounted) setState(() => _catalog = result);
    } catch (_) {
      if (mounted) setState(() => _error = tr('Search failed: {0}'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _search(int page) async {
    final query = _query.text.trim();
    if (query.isEmpty) return;
    if (page == 0) _cursors.removeRange(1, _cursors.length);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.run('mcp.search', {
        'query': query,
        'cursor': _cursors[page],
      });
      if (!mounted) return;
      setState(() {
        _found = (result['servers'] as List).cast<Map<String, dynamic>>();
        _next = result['cursor'] as String? ?? '';
        _total = result['total'];
        _searched = true;
        _cursors.removeRange(page + 1, _cursors.length);
        if (_next.isNotEmpty) _cursors.add(_next);
      });
    } catch (_) {
      if (mounted) setState(() => _error = tr('Search failed: {0}'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _pageIndex => _cursors.length - (_next.isNotEmpty ? 2 : 1);

  List<Map<String, dynamic>> _options(Map<String, dynamic> server) =>
      (server['options'] as List).cast<Map<String, dynamic>>();

  void _open(Map<String, dynamic> server, Map<String, dynamic>? pick) {
    final options = _options(server);
    final best = options.indexWhere((o) => o['runnable'] == true);
    setState(() {
      _server = server;
      _pick = pick;
      _name.text = '${server['short']}';
      _chosen
        ..clear()
        ..addAll([
          for (final a in widget.agents)
            if (a['mcp'] == true) a['command'] as String,
        ]);
      _useOption(best < 0 ? 0 : best);
    });
  }

  void _useOption(int index) {
    _tested = null;
    for (final c in _fields.values) {
      c.dispose();
    }
    _fields.clear();
    _option = index;
    for (final need in _needs) {
      _fields[need['name'] as String] = TextEditingController(
        text: '${need['value'] ?? ''}',
      );
    }
  }

  List<Map<String, dynamic>> get _needs => _server == null
      ? const []
      : (_options(_server!)[_option]['needs'] as List)
            .cast<Map<String, dynamic>>();

  /// Why the fields cannot be used yet, or null.
  String? get _fieldProblem {
    final missing = [
      for (final n in _needs)
        if (n['required'] == true && _fields[n['name']]!.text.trim().isEmpty)
          '${n['name']}'.startsWith('arg:')
              ? '${n['description']}'
              : '${n['name']}',
    ];
    if (missing.isNotEmpty) {
      return tr('Fill in: {0}').replaceAll('{0}', missing.join(', '));
    }
    final leaked = [
      for (final name
          in (_options(_server!)[_option]['on_command_line'] as List)
              .cast<String>())
        if (_fields[name]?.text.trim().isNotEmpty == true) name,
    ];
    if (leaked.isNotEmpty) {
      return tr(
        '{0} would be on the command line, where other users of this PC can read it.',
      ).replaceAll('{0}', leaked.join(', '));
    }
    return null;
  }

  /// Why Preview is off, or null.
  String? get _problem {
    final field = _fieldProblem;
    if (field != null) return field;
    if (!_nameRe.hasMatch(_name.text.trim())) {
      return tr('Letters, digits, - _ . (the agents know it by this name)');
    }
    if (_chosen.isEmpty) {
      return tr('The agents that get it. More later: draw lines on the map.');
    }
    return null;
  }

  /// Test: the chosen way started once (or its address asked) for its tools.
  Future<void> _test() async {
    setState(() {
      _testing = true;
      _tested = null;
    });
    try {
      final answer = await widget.run('mcp.option_test', {
        'option': _options(_server!)[_option]['option'],
        'values': {for (final e in _fields.entries) e.key: e.value.text},
      });
      if (mounted) setState(() => _tested = answer);
    } catch (_) {
      if (mounted) {
        setState(() => _tested = {'status': 'failed', 'error': ''});
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _preview() async {
    await widget.onPreview({
      'option': _options(_server!)[_option]['option'],
      'name': _name.text.trim(),
      'values': {for (final e in _fields.entries) e.key: e.value.text},
      'agents': [
        for (final a in widget.agents)
          if (_chosen.contains(a['command'])) a['command'],
      ],
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (_server != null)
                  IconButton(
                    tooltip: tr('Back'),
                    onPressed: () => setState(() => _server = null),
                    icon: const Icon(Icons.arrow_back),
                  ),
                Expanded(
                  child: Text(tr('MCP servers'), style: text.titleLarge),
                ),
                IconButton(
                  tooltip: tr('Close'),
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Text(
              tr(
                'New tools for your agents: files, web pages, a browser, GitHub…',
              ),
            ),
            const SizedBox(height: 12),
            if (_server != null)
              _details(context)
            else ...[
              SegmentedButton<int>(
                segments: [
                  ButtonSegment(value: 0, label: Text(tr('Recommended'))),
                  ButtonSegment(value: 1, label: Text(tr('MCP registry'))),
                ],
                selected: {_tab},
                onSelectionChanged: (s) => setState(() => _tab = s.first),
              ),
              const SizedBox(height: 12),
              if (_tab == 1) ..._registry(context) else ..._picks(context),
            ],
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Text(
                _error!.replaceAll('{0}', '').trim(),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _picks(BuildContext context) {
    final catalog = _catalog;
    if (catalog == null) return const [];
    final picks = (catalog['picks'] as List).cast<Map<String, dynamic>>();
    return [
      for (final group in (catalog['groups'] as List).cast<Map>()) ...[
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '${group['label']}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        for (final pick in picks.where((p) => p['group'] == group['key']))
          ListTile(
            key: ValueKey('mcp-pick-${pick['key']}'),
            title: Text('${pick['title']}'),
            subtitle: Text('${pick['about']}'),
            trailing: Text('${pick['maker']}'),
            onTap: widget.busy
                ? null
                : () => _open(pick['server'] as Map<String, dynamic>, pick),
          ),
      ],
    ];
  }

  List<Widget> _registry(BuildContext context) {
    final page = _pageIndex;
    final shown = _found.length;
    return [
      TextField(
        key: const ValueKey('mcp-registry-search'),
        controller: _query,
        decoration: InputDecoration(
          labelText: tr('Search servers, e.g. postgres, notion'),
          prefixIcon: const Icon(Icons.search),
        ),
        onSubmitted: _loading ? null : (_) => _search(0),
      ),
      if (_searched && shown == 0) Text(tr('No server found.')),
      if (shown > 0)
        Text(
          tr('Servers found: {0}').replaceAll(
            '{0}',
            _total is int
                ? '$_total'
                : _next.isNotEmpty
                ? tr(
                    'more than {0}',
                  ).replaceAll('{0}', '${page * _page + shown}')
                : '${page * _page + shown}',
          ),
        ),
      for (final server in _found)
        ListTile(
          title: Text(
            '${server['title'] == '' ? server['short'] : server['title']}',
          ),
          subtitle: Text(
            '${server['description']}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text('${(server['publisher'] as Map)['who']}'),
          onTap: widget.busy ? null : () => _open(server, null),
        ),
      if (page > 0 || _next.isNotEmpty)
        Row(
          children: [
            TextButton(
              onPressed: page > 0 && !_loading ? () => _search(page - 1) : null,
              child: Text(tr('‹ Previous {0}').replaceAll('{0}', '$_page')),
            ),
            const Spacer(),
            TextButton(
              onPressed: _next.isNotEmpty && !_loading
                  ? () => _search(page + 1)
                  : null,
              child: Text(tr('Next {0} ›').replaceAll('{0}', '$_page')),
            ),
          ],
        ),
    ];
  }

  Widget _details(BuildContext context) {
    final server = _server!, pick = _pick;
    final text = Theme.of(context).textTheme;
    final options = _options(server);
    final publisher = server['publisher'] as Map;
    final who = pick != null
        ? '${pick['trust']}'
        : switch (publisher['kind']) {
            'github' => tr(
              'GitHub account {0}',
            ).replaceAll('{0}', '${publisher['who']}'),
            'domain' => tr(
              'Domain {0}',
            ).replaceAll('{0}', '${publisher['who']}'),
            _ => '${server['name']}',
          };
    final needs = pick != null
        ? '${pick['needs']}'
        : () {
            final names = {
              for (final o in options)
                for (final n in (o['needs'] as List).cast<Map>())
                  if (n['required'] == true) '${n['name']}',
            }.toList()..sort();
            return names.isEmpty ? tr('nothing to fill in') : names.join(', ');
          }();
    final best = options.indexWhere((o) => o['runnable'] == true);
    final problem = _problem;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SelectableText(
          '${server['title'] == '' ? server['short'] : server['title']}',
          style: text.titleLarge,
        ),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Chip(label: Text(who)),
            if ('${server['version']}'.isNotEmpty)
              Text('${tr('Version')}: ${server['version']}'),
          ],
        ),
        if (pick != null) Text('${pick['trust_hint']}'),
        if (pick == null)
          Text(
            tr(
              'Anyone can publish to the registry. Look at the repository before you add a server: a program from it runs with your rights.',
            ),
          ),
        if ('${server['status']}'.isNotEmpty && server['status'] != 'active')
          Text(
            tr(
              'The publisher marked it {0}.',
            ).replaceAll('{0}', '${server['status']}'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        for (final (url, label) in [
          (server['website'], 'Website'),
          (server['repository'], 'Open on the web'),
        ])
          if ('$url'.startsWith('https://'))
            SelectableText('${tr(label)}: $url'),
        const SizedBox(height: 8),
        SelectableText(
          pick != null
              ? '${pick['about']}'
              : '${server['description']}'.isEmpty
              ? tr('No description.')
              : '${server['description']}',
        ),
        Text('${tr('Needs')}: $needs'),
        if (pick != null && (pick['tries'] as List).isNotEmpty)
          SelectableText(
            [
              tr('Then ask an agent, e.g.:'),
              for (final t in pick['tries'] as List) '“$t”',
            ].join('\n'),
          ),
        const SizedBox(height: 12),
        Text(tr('How it runs'), style: text.titleMedium),
        RadioGroup<int>(
          groupValue: _option,
          onChanged: (i) {
            if (i != null) setState(() => _useOption(i));
          },
          child: Column(
            children: [
              for (final (i, option) in options.indexed)
                RadioListTile<int>(
                  key: ValueKey('mcp-option-$i'),
                  value: i,
                  title: Text(
                    '${tr(_runKind[option['kind']] ?? '${option['kind']}')}'
                    '${i == best && options.length > 1 ? ' · ${tr('recommended')}' : ''}',
                  ),
                  subtitle: Text(
                    [
                      tr(_runText[option['kind']] ?? '{0}').replaceAll(
                        '{0}',
                        '${option['label']}'.split(' · ').skip(1).join(' · '),
                      ),
                      if (option['runnable'] != true)
                        tr(
                          _runners[option['command']] ??
                              'Needs {0}, not installed',
                        ).replaceAll('{0}', '${option['command']}'),
                    ].join('\n'),
                  ),
                ),
            ],
          ),
        ),
        for (final need in _needs)
          TextField(
            key: ValueKey('mcp-need-${need['name']}'),
            controller: _fields[need['name']],
            obscureText: need['secret'] == true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: '${need['name']}'.startsWith('arg:')
                  ? '${need['description']}'
                  : '${need['name']}',
              helperText: [
                if (!'${need['name']}'.startsWith('arg:') &&
                    '${need['description']}'.isNotEmpty)
                  '${need['description']}',
                tr(need['required'] == true ? 'needed' : 'optional'),
              ].join(' · '),
              hintText: '${need['hint']}',
            ),
            onChanged: (_) => setState(() {}),
          ),
        if (pick != null && '${pick['key_url']}'.isNotEmpty)
          SelectableText('${tr('Where do I get it?')} ${pick['key_url']}'),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('mcp-catalog-name'),
          controller: _name,
          decoration: InputDecoration(
            labelText: tr('Name'),
            helperText: tr(
              'Letters, digits, - _ . (the agents know it by this name)',
            ),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Text(tr('The agents that get it. More later: draw lines on the map.')),
        for (final agent in widget.agents.where((a) => a['mcp'] == true))
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${agent['name']}'),
            value: _chosen.contains(agent['command']),
            onChanged: (on) => setState(() {
              on == true
                  ? _chosen.add(agent['command'] as String)
                  : _chosen.remove(agent['command']);
            }),
          ),
        if (problem != null)
          Text(
            problem,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_testing) Text(tr('Asking the server…')),
        if (_tested != null) McpToolsResult(answer: _tested!, tr: tr),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          children: [
            Tooltip(
              message: tr('Start it once and ask for its tools'),
              child: OutlinedButton(
                key: const ValueKey('mcp-catalog-test'),
                onPressed: widget.busy || _testing || _fieldProblem != null
                    ? null
                    : _test,
                child: Text(tr('Test')),
              ),
            ),
            FilledButton(
              onPressed: widget.busy || problem != null ? null : _preview,
              child: Text(tr('Preview')),
            ),
          ],
        ),
      ],
    );
  }
}
