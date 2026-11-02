import 'package:file_selector/file_selector.dart';
import 'backend.dart' show failureText;
import 'window_popup.dart';
import 'package:flutter/material.dart';

class ConnectionAuthoring extends StatefulWidget {
  const ConnectionAuthoring({
    super.key,
    required this.kind,
    required this.agents,
    required this.busy,
    required this.tr,
    required this.onPreview,
    required this.onClose,
    this.chooseFolder,
    this.initial = const {},
  });
  final String kind;
  final List<Map<String, dynamic>> agents;
  final bool busy;
  final String Function(String) tr;
  final Future<void> Function(Map<String, dynamic>) onPreview;
  final VoidCallback onClose;
  final Future<String?> Function()? chooseFolder;

  /// Found on this PC: name, command (program + args) or folder to start
  /// from; everything stays editable.
  final Map<String, dynamic> initial;
  @override
  State<ConnectionAuthoring> createState() => _ConnectionAuthoringState();
}

class _Pair {
  final name = TextEditingController();
  final value = TextEditingController();
  void dispose() {
    name.dispose();
    value.dispose();
  }
}

class _ConnectionAuthoringState extends State<ConnectionAuthoring> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(),
      _command = TextEditingController(),
      _args = TextEditingController(),
      _url = TextEditingController(),
      _folder = TextEditingController();
  final _selected = <String>{};
  final _env = <_Pair>[], _headers = <_Pair>[];
  var _transport = 'stdio';
  var _working = false;
  String? _error;
  bool get _busy => widget.busy || _working;
  bool get _mcp => widget.kind == 'mcp';
  String tr(String key) => widget.tr(key);
  @override
  void initState() {
    super.initState();
    final command = [
      for (final x in widget.initial['command'] as List? ?? const []) '$x',
    ];
    _name.text = '${widget.initial['name'] ?? ''}';
    if (command.isNotEmpty) {
      _command.text = command.first;
      _args.text = command.skip(1).join('\n');
    }
    _folder.text = '${widget.initial['folder'] ?? ''}';
  }

  @override
  void dispose() {
    for (final controller in [_name, _command, _args, _url, _folder]) {
      controller.dispose();
    }
    for (final pair in [..._env, ..._headers]) {
      pair.dispose();
    }
    super.dispose();
  }

  Map<String, String> _values(List<_Pair> pairs) {
    final values = <String, String>{};
    for (final pair in pairs) {
      final key = pair.name.text.trim();
      if (key.isEmpty && pair.value.text.isEmpty) continue;
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_-]{0,127}$').hasMatch(key) ||
          values.containsKey(key)) {
        throw const FormatException();
      }
      values[key] = pair.value.text;
    }
    return values;
  }

  Future<void> _preview() async {
    if (_busy || !_form.currentState!.validate()) return;
    if (_selected.isEmpty) {
      setState(() => _error = tr('Choose at least one agent.'));
      return;
    }
    Map<String, dynamic> params;
    try {
      params = {
        'kind': widget.kind,
        'agents': _selected.toList()..sort(),
        if (!_mcp) 'folder': _folder.text.trim(),
        if (_mcp) ...{
          'name': _name.text.trim(),
          'entry': {
            'transport': _transport,
            'command': _transport == 'stdio' ? _command.text.trim() : '',
            'args': _transport == 'stdio'
                ? _args.text.split('\n').where((s) => s.isNotEmpty).toList()
                : <String>[],
            'url': _transport == 'stdio' ? '' : _url.text.trim(),
            'env': _transport == 'stdio' ? _values(_env) : <String, String>{},
            'headers': _transport == 'stdio'
                ? <String, String>{}
                : _values(_headers),
          },
        },
      };
    } on FormatException {
      setState(() => _error = tr('Use unique variable or header names.'));
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.onPreview(params);
    } catch (_) {
      if (mounted) {
        setState(() => _error = failureText(tr));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Widget _pairs(List<_Pair> pairs, String label) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(tr(label)),
      for (final pair in pairs)
        Padding(
          key: ObjectKey(pair),
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: pair.name,
                  enabled: !_busy,
                  maxLength: 128,
                  decoration: InputDecoration(labelText: tr('Name')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: pair.value,
                  enabled: !_busy,
                  obscureText: true,
                  maxLength: 8192,
                  decoration: InputDecoration(labelText: tr('Value')),
                ),
              ),
              IconButton(
                tooltip: tr('Remove'),
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        pairs.remove(pair);
                        pair.dispose();
                      }),
              ),
            ],
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _busy || pairs.length >= 64
              ? null
              : () => setState(() => pairs.add(_Pair())),
          icon: const Icon(Icons.add),
          label: Text(tr('Add')),
        ),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr(_mcp ? 'Add MCP server' : 'Add skills'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            if (_mcp) ...[
              Text(
                tr(
                  'Maprisma saves configuration only. Agents may start this server when they read it.',
                ),
              ),
              TextFormField(
                key: const ValueKey('mcp-name'),
                controller: _name,
                enabled: !_busy,
                maxLength: 64,
                decoration: InputDecoration(labelText: tr('Name')),
                validator: (s) =>
                    RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(s?.trim() ?? '')
                    ? null
                    : tr('Give it a name: letters, digits, - _ .'),
              ),
              DropdownButtonFormField<String>(
                initialValue: _transport,
                decoration: InputDecoration(labelText: tr('Transport')),
                items: [
                  for (final kind in ['stdio', 'http', 'sse'])
                    DropdownMenuItem(value: kind, child: Text(kind)),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _transport = value!),
              ),
              if (_transport == 'stdio') ...[
                TextFormField(
                  key: const ValueKey('mcp-command'),
                  controller: _command,
                  enabled: !_busy,
                  maxLength: 4096,
                  decoration: InputDecoration(labelText: tr('Command')),
                  validator: (s) =>
                      s?.trim().isNotEmpty == true ? null : tr('No command'),
                ),
                TextField(
                  key: const ValueKey('mcp-args'),
                  controller: _args,
                  enabled: !_busy,
                  minLines: 2,
                  maxLines: 5,
                  maxLength: 32768,
                  decoration: InputDecoration(
                    labelText: tr('Arguments (one per line)'),
                  ),
                ),
                _pairs(_env, 'Environment variables'),
              ] else ...[
                TextFormField(
                  key: const ValueKey('mcp-url'),
                  controller: _url,
                  enabled: !_busy,
                  maxLength: 4096,
                  decoration: InputDecoration(labelText: tr('Server URL')),
                  validator: (s) {
                    final uri = Uri.tryParse(s ?? '');
                    return uri != null &&
                            ['http', 'https'].contains(uri.scheme) &&
                            uri.host.isNotEmpty
                        ? null
                        : tr('Use an HTTP or HTTPS URL.');
                  },
                ),
                _pairs(_headers, 'HTTP headers'),
              ],
            ] else ...[
              Text(
                tr(
                  'Choose the folder that contains skill folders, each with SKILL.md.',
                ),
              ),
              Text(
                tr(
                  'The original skill files stay in place. Agents read linked skills; later edits take effect there too.',
                ),
              ),
              Text(tr('Skills may include scripts that agents can run.')),
              TextFormField(
                key: const ValueKey('skill-folder'),
                controller: _folder,
                enabled: !_busy,
                maxLength: 4096,
                decoration: InputDecoration(labelText: tr('Skill-set folder')),
                validator: (s) =>
                    s?.trim().isNotEmpty == true ? null : tr('Choose folder…'),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.folder_open),
                  label: Text(tr('Choose folder…')),
                  onPressed: _busy
                      ? null
                      : () async {
                          final selected = await PopupGuard.around(
                            () =>
                                widget.chooseFolder?.call() ??
                                getDirectoryPath(),
                          );
                          if (mounted && selected != null) {
                            setState(() => _folder.text = selected);
                          }
                        },
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(tr('Agents'), style: Theme.of(context).textTheme.titleMedium),
            for (final agent in widget.agents.where(
              (a) => a[widget.kind] == true,
            ))
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(agent['name'] as String),
                value: _selected.contains(agent['command']),
                onChanged: _busy
                    ? null
                    : (on) => setState(() {
                        on == true
                            ? _selected.add(agent['command'] as String)
                            : _selected.remove(agent['command']);
                      }),
              ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _busy ? null : widget.onClose,
                  child: Text(tr('Cancel')),
                ),
                FilledButton(
                  onPressed: _busy ? null : _preview,
                  child: Text(tr('Preview')),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
