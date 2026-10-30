import 'health_card.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'window_popup.dart';
import 'runtime_details_card.dart';

typedef ProviderOperation =
    Future<Map<String, dynamic>?> Function(
      String operation,
      Map<String, dynamic> params,
      String title,
    );

String modelSize(num size) {
  if (size >= 1024 * 1024 * 1024) {
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
  }
  return '${(size / (1024 * 1024)).toStringAsFixed(0)} MiB';
}

class ProvidersView extends StatelessWidget {
  const ProvidersView({
    super.key,
    this.hosted = false,
    required this.data,
    required this.busy,
    required this.tr,
    required this.onOperation,
    required this.onBack,
    this.onRemove,
    this.onDiscover,
    this.onBrowse,
    this.onConfirm,
    this.onInstall,
    this.onPerformance,
    this.onCall,
  });
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
  onCall;
  final ValueChanged<Map<String, dynamic>>? onPerformance;
  final bool hosted;
  final Map<String, dynamic> data;
  final bool busy;
  final String Function(String) tr;
  final ProviderOperation onOperation;
  final VoidCallback onBack;
  final VoidCallback? onDiscover;
  final ValueChanged<Map<String, dynamic>>? onBrowse;
  final Future<bool> Function(String, Map<String, dynamic>)? onConfirm;
  final Future<void> Function(String, String)? onRemove;
  final ValueChanged<String>? onInstall;

  Future<bool> _confirm(
    BuildContext context,
    String title,
    Map<String, dynamic> runtime,
  ) => onConfirm?.call(title, runtime) ?? Future.value(false);

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 950),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (!hosted)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
                label: Text(tr('Back')),
              ),
            ),
          if (!hosted)
            Text(
              tr('Providers and models'),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          if (onDiscover != null)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: busy ? null : onDiscover,
                icon: const Icon(Icons.manage_search),
                label: Text(tr('Find existing AI')),
              ),
            ),
          const SizedBox(height: 20),
          for (final folder in data['folders'] as List? ?? [])
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: SelectableText(folder['path'] as String),
              subtitle: Text(
                tr(
                  folder['available'] == true
                      ? 'Models folder'
                      : 'Folder unavailable',
                ),
              ),
            ),
          for (final rt in data['local'] as List? ?? [])
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      rt['name'] as String,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      tr(
                        rt['running'] == true
                            ? 'Running'
                            : rt['installed'] == true
                            ? 'Stopped'
                            : 'Not installed',
                      ),
                    ),
                    if ((rt['address'] as String).isNotEmpty)
                      SelectableText(rt['address'] as String),
                    if ((rt['models_dir'] as String).isNotEmpty)
                      SelectableText(rt['models_dir'] as String),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (rt['installable'] == true && onInstall != null)
                          FilledButton.icon(
                            onPressed: busy
                                ? null
                                : () => onInstall!(rt['key'] as String),
                            icon: const Icon(Icons.download_for_offline),
                            label: Text(tr('Install')),
                          ),
                        if (rt['can_control'] == true)
                          OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () async {
                                    final stop = rt['running'] == true;
                                    if (stop &&
                                        !await _confirm(
                                          context,
                                          '${tr('Stop')} ${rt['name']}?',
                                          rt as Map<String, dynamic>,
                                        )) {
                                      return;
                                    }
                                    await onOperation(
                                      stop ? 'runtime.stop' : 'runtime.start',
                                      {'key': rt['key']},
                                      '${tr(stop ? 'Stop' : 'Start')} ${rt['name']}',
                                    );
                                  },
                            icon: Icon(
                              rt['running'] == true
                                  ? Icons.stop
                                  : Icons.play_arrow,
                            ),
                            label: Text(
                              tr(rt['running'] == true ? 'Stop' : 'Start'),
                            ),
                          ),
                        if (rt['tunable'] == true && onPerformance != null)
                          OutlinedButton.icon(
                            key: ValueKey('performance-${rt['key']}'),
                            onPressed: busy
                                ? null
                                : () => onPerformance!(
                                    rt as Map<String, dynamic>,
                                  ),
                            icon: const Icon(Icons.speed),
                            label: Text(tr('Performance')),
                          ),
                        if (rt['can_import'] == true)
                          OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () async {
                                    final file = await PopupGuard.around(
                                      () => openFile(
                                        acceptedTypeGroups: [
                                          const XTypeGroup(
                                            label: 'GGUF',
                                            extensions: ['gguf'],
                                          ),
                                        ],
                                      ),
                                    );
                                    if (file != null) {
                                      await onOperation('model.import', {
                                        'key': rt['key'],
                                        'path': file.path,
                                      }, tr('Import model'));
                                    }
                                  },
                            icon: const Icon(Icons.file_open_outlined),
                            label: Text(tr('Import model')),
                          ),
                        if ((rt['download'] as String).isNotEmpty)
                          OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () => onBrowse?.call(
                                    rt as Map<String, dynamic>,
                                  ),
                            icon: const Icon(Icons.download),
                            label: Text(tr('Download model')),
                          ),
                      ],
                    ),
                    if (onCall != null && rt['installed'] == true)
                      RuntimeDetailsCard(
                        key: ValueKey('runtime-details-${rt['key']}'),
                        runtime: rt['key'] as String,
                        call: onCall!,
                        tr: tr,
                      ),
                    if (onCall != null && rt['installed'] == true)
                      HealthCard(
                        key: ValueKey('health-${rt['key']}'),
                        method: 'providers.health',
                        params: {'key': rt['key']},
                        call: onCall!,
                        tr: tr,
                      ),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: Text(
                        '${tr('Models')} (${(rt['models'] as List).length})',
                      ),
                      children: [
                        for (final model in rt['models'] as List)
                          ListTile(
                            title: Text(model as String),
                            trailing:
                                rt['can_load'] != true &&
                                    ((rt['removable'] as String? ?? '')
                                            .isEmpty ||
                                        onRemove == null)
                                ? null
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (rt['can_load'] == true)
                                        IconButton(
                                          tooltip: tr('Load'),
                                          icon: const Icon(Icons.play_arrow),
                                          onPressed: busy
                                              ? null
                                              : () =>
                                                    onOperation('model.load', {
                                                      'key': rt['key'],
                                                      'model': model,
                                                    }, tr('Load')),
                                        ),
                                      if (rt['can_load'] == true)
                                        IconButton(
                                          tooltip: tr('Unload'),
                                          icon: const Icon(
                                            Icons.eject_outlined,
                                          ),
                                          onPressed: busy
                                              ? null
                                              : () async {
                                                  if (await _confirm(
                                                    context,
                                                    '${tr('Unload')} $model?',
                                                    rt as Map<String, dynamic>,
                                                  )) {
                                                    await onOperation(
                                                      'model.unload',
                                                      {
                                                        'key': rt['key'],
                                                        'model': model,
                                                      },
                                                      tr('Unload'),
                                                    );
                                                  }
                                                },
                                        ),
                                      if ((rt['removable'] as String? ?? '')
                                              .isNotEmpty &&
                                          onRemove != null)
                                        IconButton(
                                          tooltip: tr('Remove model'),
                                          icon: const Icon(
                                            Icons.delete_outline,
                                          ),
                                          onPressed: busy
                                              ? null
                                              : () => onRemove!(
                                                  rt['key'] as String,
                                                  model,
                                                ),
                                        ),
                                    ],
                                  ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 20),
          Text(tr('Online'), style: Theme.of(context).textTheme.titleLarge),
          for (final provider in data['online'] as List? ?? [])
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: Text(provider['name'] as String),
            ),
        ],
      ),
    ),
  );
}

class ModelBrowser extends StatefulWidget {
  const ModelBrowser({
    super.key,
    this.hosted = false,
    required this.runtime,
    required this.tr,
    required this.onOperation,
    required this.onClose,
  });
  final bool hosted;
  final VoidCallback onClose;
  final Map<String, dynamic> runtime;
  final String Function(String) tr;
  final ProviderOperation onOperation;
  @override
  State<ModelBrowser> createState() => _ModelBrowserState();
}

class _ModelBrowserState extends State<ModelBrowser> {
  final _query = TextEditingController();
  final _pullName = TextEditingController();
  List _repos = [];
  List _files = [];
  String? _repo;
  bool _busy = false;
  @override
  void dispose() {
    _query.dispose();
    _pullName.dispose();
    super.dispose();
  }

  Future<void> _pull() async {
    final chosen = _pullName.text.trim();
    if (chosen.isEmpty || _busy) return;
    setState(() => _busy = true);
    final result = await widget.onOperation('models.pull', {
      'key': widget.runtime['key'],
      'name': chosen,
    }, widget.tr('Download model'));
    if (!mounted) return;
    setState(() => _busy = false);
    if (result?['ok'] == true) widget.onClose();
  }

  Future<void> _search() async {
    if (_query.text.trim().isEmpty || _busy) return;
    setState(() => _busy = true);
    final result = await widget.onOperation('models.search', {
      'query': _query.text.trim(),
    }, widget.tr('Search models'));
    if (mounted) {
      setState(() {
        _repos = result?['repos'] as List? ?? [];
        _files = [];
        _repo = null;
        _busy = false;
      });
    }
  }

  Future<void> _select(String repo) async {
    setState(() => _busy = true);
    final result = await widget.onOperation('models.files', {
      'repo': repo,
    }, widget.tr('Model files'));
    if (mounted) {
      setState(() {
        _files = result?['files'] as List? ?? [];
        _repo = repo;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.hosted ? double.infinity : 760,
    height: widget.hosted ? double.infinity : 620,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.hosted)
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${widget.tr('Download model')} · ${widget.runtime['name']}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: widget.tr('Close'),
                  onPressed: _busy ? null : widget.onClose,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _query,
                  enabled: !_busy,
                  decoration: InputDecoration(
                    labelText: widget.tr('Search Hugging Face'),
                  ),
                  onSubmitted: (_) => _search(),
                ),
              ),
              IconButton(
                tooltip: widget.tr('Search'),
                onPressed: _busy ? null : _search,
                icon: const Icon(Icons.search),
              ),
            ],
          ),
          if (_repo != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_repo!),
            ),
          Expanded(
            child: ListView(
              children: _repo == null
                  ? [
                      for (final repo in _repos)
                        ListTile(
                          title: Text(repo['id'] as String),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _busy
                              ? null
                              : () => _select(repo['id'] as String),
                        ),
                    ]
                  : [
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _repo = null;
                                _files = [];
                              }),
                        child: Text(widget.tr('Back')),
                      ),
                      for (final file in _files)
                        ListTile(
                          title: Text(file['name'] as String),
                          subtitle: Text(
                            '${file['quant']} · ${modelSize(file['size'] as num)}',
                          ),
                          trailing: IconButton(
                            tooltip: widget.tr('Download'),
                            icon: const Icon(Icons.download),
                            onPressed: _busy
                                ? null
                                : () async {
                                    setState(() => _busy = true);
                                    final result = await widget
                                        .onOperation('models.download', {
                                          'key': widget.runtime['key'],
                                          'repo': _repo,
                                          'file': file['name'],
                                          'size': file['size'],
                                        }, widget.tr('Download model'));
                                    if (!mounted) return;
                                    setState(() => _busy = false);
                                    if (result?['ok'] == true &&
                                        context.mounted) {
                                      widget.onClose();
                                    }
                                  },
                          ),
                        ),
                    ],
            ),
          ),
          if (widget.runtime['download'] == 'pull')
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _busy ? null : _pull,
                child: Text(widget.tr('Download by name')),
              ),
            ),
        ],
      ),
    ),
  );
}
