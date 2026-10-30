import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'agent_map.dart';
import 'map_groups.dart';
import 'backend.dart';
import 'window_popup.dart';
import 'providers_view.dart';

const separateMountHint =
    'Already have AI tools on another disk? Mount it first, then use Find existing AI before installing or downloading again.';
const simplifyHint =
    'Reuse a shared model folder instead of downloading models again. Review duplicate files and unused services before changing anything.';
const aiHelpHint =
    'AI help can explain this System Map and propose a simpler setup. Review its plan before approving changes.';

class SystemMapView extends StatefulWidget {
  const SystemMapView({
    super.key,
    required this.data,
    required this.backend,
    required this.tr,
    required this.busy,
    required this.onRefresh,
    required this.onOperation,
    required this.onSaved,
    required this.onSession,
    required this.onShowAI,
    required this.controller,
    this.suspended = false,
    this.onUndo,
    this.onGroups,
    this.onHealthAction,
    this.requestedNode,
  });
  final Map<String, dynamic> data;
  final Backend backend;
  final String Function(String) tr;
  final bool busy;
  final bool suspended;
  final Future<void> Function(bool search) onRefresh;
  final ProviderOperation onOperation;
  final Future<void> Function(Map<String, dynamic>) onSaved;
  final ValueChanged<Map<String, dynamic>> onSession;
  final ValueChanged<Map<String, dynamic>> onShowAI;
  final TransformationController controller;
  final Future<void> Function()? onUndo;
  final VoidCallback? onGroups;
  final ValueChanged<List<dynamic>>? onHealthAction;
  final String? requestedNode;
  @override
  State<SystemMapView> createState() => _SystemMapViewState();
}

class _SystemMapViewState extends State<SystemMapView> {
  String? _selectedId, _helper, _models;
  bool _working = false;
  int? _focusColumn;
  String? _error;
  bool _restored = false;
  void _restore() {
    final view = widget.data['view'] as Map?;
    if (_restored || view == null) return;
    final transform = view['transform'] as List?;
    if (transform != null && transform.length == 16) {
      widget.controller.value = Matrix4.fromList(
        transform.cast<num>().map((n) => n.toDouble()).toList(),
      );
    }
    _selectedId = widget.requestedNode ?? view['selected'] as String?;
    _restored = true;
  }

  @override
  void initState() {
    super.initState();
    _restore();
    _selectedId = widget.requestedNode ?? _selectedId;
  }

  @override
  void didUpdateWidget(SystemMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _restore();
    if (widget.requestedNode != oldWidget.requestedNode) {
      _selectedId = widget.requestedNode;
    }
  }

  Future<void> _saveView() async {
    try {
      await widget.backend.call('system.view', {
        'selected': _selectedId,
        'transform': widget.controller.value.storage.toList(),
      });
    } catch (_) {}
  }

  bool get busy => widget.busy || _working;
  List<Map<String, dynamic>> get nodes =>
      (widget.data['nodes'] as List? ?? []).cast<Map<String, dynamic>>();
  Map<String, dynamic>? get selected =>
      nodes.where((n) => n['id'] == _selectedId).firstOrNull;

  Future<void> _forgetDisk(Map<String, dynamic> node) async {
    setState(() => _working = true);
    try {
      final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(widget.tr('Forget this disk')),
          content: Text(
            '${node['path']}\n${widget.tr('Remove this missing disk from the saved map only. Files and settings are kept.')}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(widget.tr('Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(widget.tr('Forget this disk')),
            ),
          ],
        ),
      );
      if (yes != true || !mounted) return;
      final result = await widget.backend.call('system.forget_disk', {
        'node': node['id'],
      });
      if (mounted) {
        setState(() {
          _selectedId = null;
          _models = null;
        });
      }
      await widget.onSaved(result);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = widget.tr('The action could not be completed.'),
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _scanFolder() async {
    final path = await PopupGuard.around(getDirectoryPath);
    if (path == null || !mounted) return;
    setState(() => _working = true);
    try {
      final result = await widget.onOperation('existing.scan', {
        'path': path,
      }, widget.tr('Find existing AI'));
      if (result != null) await widget.onSaved(result);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<bool> _confirm(Map<String, dynamic> plan) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(widget.tr('Preview')),
          content: SizedBox(
            width: 720,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.tr(
                      'Existing files are preserved. Services stay stopped. Undo removes the new connecting files.',
                    ),
                  ),
                  for (final note in plan['notes'] as List? ?? [])
                    Text(widget.tr(note as String)),
                  for (final file in plan['files'] as List? ?? []) ...[
                    const SizedBox(height: 12),
                    SelectableText(file['path'] as String),
                    if (file['text'] != null)
                      SelectableText(file['text'] as String),
                  ],
                  for (final command in plan['commands'] as List? ?? [])
                    SelectableText(command as String),
                  if ((plan['url'] as String? ?? '').isNotEmpty)
                    SelectableText(plan['url'] as String),
                  if ((plan['commands'] as List? ?? []).isNotEmpty)
                    Text(
                      widget.tr(
                        'This runs in a separate terminal; passwords are entered there. Refresh when it finishes.',
                      ),
                    ),
                  if ((plan['url'] as String? ?? '').isNotEmpty)
                    Text(
                      widget.tr(
                        'Open the vendor instructions in your browser.',
                      ),
                    ),
                  for (final name in plan['model_files'] as List? ?? [])
                    SelectableText(name as String),
                  if (plan['source'] != null)
                    SelectableText(
                      '${plan['source']} → ${plan['destination']}',
                    ),
                  if (plan['size'] != null)
                    Text(modelSize(plan['size'] as num)),
                  if (plan['empty'] == true)
                    Text(widget.tr('No changes to apply')),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(widget.tr('Cancel')),
            ),
            FilledButton(
              onPressed: plan['empty'] == true
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text(widget.tr('Apply')),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _reconnect(
    Map<String, dynamic> source,
    Map<String, dynamic>? target,
  ) async {
    setState(() => _working = true);
    try {
      final plan = await widget.backend.call('existing.preview', {
        'found': source['found'],
        'models': target?['found'],
      });
      if (!mounted || !await _confirm(plan)) return;
      final result = await widget.onOperation('existing.apply', {
        'plan': plan['plan'],
      }, widget.tr('Apply'));
      if (result != null) await widget.onSaved(result);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = widget.tr('The action could not be completed.'),
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _check(Map<String, dynamic> node) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.tr('Check program')),
        content: Text(
          '${widget.tr('This runs the discovered program with --version.')}\n${node['path']}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(widget.tr('Continue')),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => _working = true);
    try {
      final result = await widget.onOperation(
        node['kind'] == 'tool' ? 'system.tool_check' : 'existing.check',
        node['kind'] == 'tool'
            ? {'node': node['id']}
            : {'found': node['found']},
        widget.tr('Check program'),
      );
      if (result != null && mounted) {
        setState(
          () => _error = widget.tr(
            result['ok'] == true
                ? 'Program check passed'
                : 'Program check failed',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _stack(String part) async {
    setState(() => _working = true);
    try {
      final plan = await widget.backend.call('system.stack_preview', {
        'part': part,
      });
      if (!mounted || !await _confirm(plan)) return;
      final result = await widget.backend.call('system.stack_apply', {
        'preview': plan['preview'],
      });
      await widget.onSaved(result);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = widget.tr('The action could not be completed.'),
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _help(String topic, [String? finding]) async {
    setState(() => _working = true);
    try {
      final plan = await widget.backend.call(
        finding == null ? 'system.help_preview' : 'system.fix_preview',
        finding == null
            ? {'command': _helper, 'topic': topic}
            : {'command': _helper, 'finding': finding},
      );
      if (!mounted) return;
      final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${widget.tr('AI help')} · ${plan['name']}'),
          content: SizedBox(
            width: 760,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.tr(
                      'The selected AI agent and, for an online model, its service receive this System Map, including folder paths. Its use may consume your plan or tokens.',
                    ),
                  ),
                  SelectableText(plan['prompt'] as String),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(widget.tr('Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(widget.tr('Continue')),
            ),
          ],
        ),
      );
      if (yes != true || !mounted) return;
      if (topic == 'check' && finding == null) {
        final result = await widget.onOperation('system.help_apply', {
          'preview': plan['preview'],
        }, widget.tr('Check this system with AI'));
        if (result != null) await widget.onSaved(result);
      } else {
        final result = await widget.backend.call('system.help_apply', {
          'preview': plan['preview'],
        });
        widget.onSession(result);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = widget.tr('The action could not be completed.'),
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _drop(
    Map<String, dynamic> source,
    Map<String, dynamic> target,
  ) async {
    if (busy) return;
    if (source['kind'] == 'runtime' &&
        target['found'] != null &&
        target['kind'] != 'runtime') {
      await _reconnect(source, target);
    } else if (target['kind'] == 'runtime' &&
        target['found'] != null &&
        source['found'] != null) {
      await _reconnect(target, source);
    } else if (target['kind'] == 'disk' && source['kind'] != 'runtime') {
      setState(() => _working = true);
      try {
        final plan = await widget.onOperation('system.move_preview', {
          'source': source['id'],
          'target': target['id'],
        }, widget.tr('Move model folder'));
        if (plan == null || !mounted || !await _confirm(plan)) return;
        final result = await widget.onOperation('system.move_apply', {
          'preview': plan['preview'],
        }, widget.tr('Move model folder'));
        if (result != null) await widget.onSaved(result);
      } catch (_) {
        if (mounted) {
          setState(
            () => _error = widget.tr('The action could not be completed.'),
          );
        }
      } finally {
        if (mounted) setState(() => _working = false);
      }
    }
  }

  void _helpSheet() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.tr('System Map'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Text(widget.tr(separateMountHint)),
              Text(widget.tr(simplifyHint)),
              Text(widget.tr(aiHelpHint)),
              Text(
                widget.tr(
                  'Drag a found runtime onto a model folder to preview Reconnect. Drag a GGUF folder onto a disk to preview a move.',
                ),
              ),
              Text(
                widget.tr(
                  'The saved map opens immediately. Visits refresh status; Refresh searches mounted disks and measures sizes. Missing disks stay visible.',
                ),
              ),
              Text(
                widget.tr(
                  'Duplicate names do not prove duplicate files. Keep backups and check which programs use a folder before moving or removing it.',
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(widget.tr('Close')),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (widget.suspended) return const SizedBox.shrink();
    final node = selected;
    final helpers = widget.data['helpers'] as List? ?? [];
    final findings =
        (widget.data['analysis'] as Map?)?['findings'] as List? ?? [];
    final checked = widget.data['checked_at'] as num?;
    final counts = <String, int>{};
    final nodeIds = nodes.map((n) => n['id']).toSet();
    for (final finding in [
      ...(widget.data['health'] as List? ?? []),
      ...findings,
    ]) {
      final id = nodeIds.contains(finding['node'])
          ? finding['node'] as String
          : 'pc';
      counts[id] = (counts[id] ?? 0) + 1;
    }
    final graph = {
      ...widget.data,
      'nodes': [
        for (final n in nodes) {...n, 'badges': counts[n['id']] ?? 0},
      ],
    };
    final helper = helpers.where((h) => h['command'] == _helper).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (widget.onGroups != null)
                TextButton(
                  onPressed: busy ? null : widget.onGroups,
                  child: Text(widget.tr('Add-ons')),
                ),
              Text(
                widget.tr('System Map'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              if (checked != null)
                Text(
                  '${widget.tr('Last checked')}: ${DateTime.fromMillisecondsSinceEpoch((checked * 1000).toInt()).toLocal()}',
                ),
              OutlinedButton(
                onPressed: busy ? null : () => widget.onRefresh(true),
                child: Text(
                  widget.tr(
                    widget.data['search_done'] == true
                        ? 'Refresh'
                        : 'Look at this PC',
                  ),
                ),
              ),
              OutlinedButton(
                onPressed: busy ? null : _scanFolder,
                child: Text(widget.tr('Choose folder…')),
              ),
              if (widget.onUndo != null)
                TextButton(
                  onPressed: busy ? null : widget.onUndo,
                  child: Text(widget.tr('Undo')),
                ),
              IconButton(
                onPressed: busy ? null : _helpSheet,
                tooltip: widget.tr('Help'),
                icon: const Icon(Icons.help_outline),
              ),
            ],
          ),
        ),
        if (widget.busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(padding: const EdgeInsets.all(8), child: Text(_error!)),
        Expanded(
          child: _focusColumn != null
              ? MapFocus(
                  title: const [
                    'This PC',
                    'Disks and home',
                    'Programs',
                    'Tools',
                    'Folders',
                  ][_focusColumn!],
                  tr: widget.tr,
                  onBack: () => setState(() => _focusColumn = null),
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final n in nodes.where(
                        (n) => n['column'] == _focusColumn,
                      ))
                        Card(
                          child: ListTile(
                            title: Text(widget.tr(n['label'] as String)),
                            subtitle: Text(n['detail'] as String),
                            onTap: () {
                              setState(() {
                                _selectedId = n['id'] as String;
                                _models = null;
                                _focusColumn = null;
                              });
                              _saveView();
                            },
                          ),
                        ),
                    ],
                  ),
                )
              : Row(
                  children: [
                    Expanded(
                      child: AgentMap(
                        graph: graph,
                        groups: MapGroup.fromGraph(graph, const [
                          'This PC',
                          'Disks and home',
                          'Programs',
                          'Tools',
                          'Folders',
                        ]),
                        onExpandGroup: (col) =>
                            setState(() => _focusColumn = col),
                        focusedNode: _selectedId,
                        tr: widget.tr,
                        onAgent: (_) {},
                        controller: widget.controller,
                        columns: const [
                          'This PC',
                          'Disks and home',
                          'Programs',
                          'Tools',
                          'Folders',
                        ],
                        onNode: (n) {
                          setState(() {
                            _selectedId = n['id'] as String;
                            _models = null;
                          });
                          _saveView();
                        },
                        onViewChanged: _saveView,
                        onNodeDrop: _drop,
                      ),
                    ),
                    SizedBox(
                      width: 340,
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          if (widget.data['search_done'] != true)
                            Text(
                              widget.tr(
                                'Only this PC is inspected. Nothing is sent and no detected program is run. You can skip the disk search.',
                              ),
                            ),
                          Text(
                            widget.tr('What we found'),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text('${nodes.length} ${widget.tr('Components')}'),
                          if (node != null) ...[
                            const Divider(),
                            Text(
                              widget.tr(node['label'] as String),
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            SelectableText(
                              (node['launch_path'] ?? node['path']) as String,
                            ),
                            Text(node['detail'] as String),
                            Text(
                              node['kind'] == 'runtime' &&
                                      RegExp(
                                        r'^\d+$',
                                      ).hasMatch(node['info'] as String)
                                  ? '${node['info']} ${widget.tr('Models')}'
                                  : node['info'] as String,
                            ),
                            if ((node['fstab'] as String? ?? '')
                                .isNotEmpty) ...[
                              Text(
                                widget.tr(
                                  'Mount configuration suggestion: review before adding it to fstab.',
                                ),
                              ),
                              SelectableText(node['fstab'] as String),
                            ],
                            if (node['size'] != null)
                              Text(
                                '${node['size_partial'] == true ? '≥ ' : ''}${modelSize(node['size'] as num)}',
                              ),
                            if (node['status'] == 'missing')
                              Text(
                                widget.tr(
                                  'A model folder is unavailable. Check its mount before downloading again.',
                                ),
                              ),
                            if (node['status'] == 'missing' &&
                                node['kind'] == 'disk')
                              Tooltip(
                                message: widget.tr(
                                  'Remove this missing disk from the saved map only. Files and settings are kept.',
                                ),
                                child: OutlinedButton(
                                  onPressed: busy
                                      ? null
                                      : () => _forgetDisk(node),
                                  child: Text(widget.tr('Forget this disk')),
                                ),
                              ),
                            if (node['status'] != 'missing' &&
                                (node['found'] != null ||
                                    node['kind'] == 'tool')) ...[
                              if (node['kind'] == 'runtime' ||
                                  node['kind'] == 'tool')
                                OutlinedButton(
                                  onPressed: busy ? null : () => _check(node),
                                  child: Text(widget.tr('Check program')),
                                ),
                              if (node['kind'] == 'models')
                                FilledButton(
                                  onPressed: busy
                                      ? null
                                      : () => _reconnect(node, null),
                                  child: Text(widget.tr('Reuse model folder')),
                                ),
                              if (node['kind'] == 'runtime' &&
                                  node['found'] != null) ...[
                                DropdownButtonFormField<String>(
                                  key: ValueKey(node['id']),
                                  initialValue: _models,
                                  isExpanded: true,
                                  decoration: InputDecoration(
                                    labelText: widget.tr('Models folder'),
                                  ),
                                  items: [
                                    for (final model in nodes.where(
                                      (n) =>
                                          n['found'] != null &&
                                          n['kind'] != 'runtime' &&
                                          n['status'] != 'missing' &&
                                          (n['provider'] == '' ||
                                              n['provider'] ==
                                                  node['provider']),
                                    ))
                                      DropdownMenuItem(
                                        value: model['id'] as String,
                                        child: Text(
                                          model['path'] as String,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                  onChanged: busy
                                      ? null
                                      : (v) => setState(() => _models = v),
                                ),
                                FilledButton(
                                  onPressed: busy || _models == null
                                      ? null
                                      : () => _reconnect(
                                          node,
                                          nodes.firstWhere(
                                            (n) => n['id'] == _models,
                                          ),
                                        ),
                                  child: Text(widget.tr('Reconnect')),
                                ),
                              ],
                            ],
                            if (node['kind'] == 'runtime' ||
                                node['kind'] == 'agent' ||
                                node['kind'] == 'models' ||
                                node['kind'] == 'folder')
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => widget.onShowAI(node),
                                child: Text(widget.tr('Show on AI Map')),
                              ),
                            if (node['stack'] != null) ...[
                              const Divider(),
                              Text(widget.tr('GPU stacks')),
                              for (final part in node['stack']['torch'] as List)
                                Text(
                                  '${part['where']} · ${part['backend']} ${part['version']}',
                                ),
                              for (final missing
                                  in node['stack']['missing'] as List)
                                OutlinedButton(
                                  onPressed: busy
                                      ? null
                                      : () => _stack(missing as String),
                                  child: Text(
                                    '${widget.tr('Install')} $missing',
                                  ),
                                ),
                            ],
                          ],
                          const Divider(),
                          for (final note
                              in widget.data['notes'] as List? ?? [])
                            Text(widget.tr(note as String)),
                          for (final finding
                              in widget.data['health'] as List? ?? [])
                            if (node == null || finding['node'] == node['id'])
                              ListTile(
                                title: Text(finding['title'] as String),
                                subtitle: Text(finding['text'] as String),
                                trailing:
                                    widget.onHealthAction != null &&
                                        (finding['action'] as List? ?? [])
                                            .isNotEmpty
                                    ? IconButton(
                                        tooltip: widget.tr('Continue'),
                                        onPressed: busy
                                            ? null
                                            : () => widget.onHealthAction!(
                                                finding['action'] as List,
                                              ),
                                        icon: const Icon(Icons.arrow_forward),
                                      )
                                    : null,
                              ),
                          for (final scan
                              in widget.data['scan_limits'] as List? ?? []) ...[
                            if ((scan['limits'] as List? ?? []).isNotEmpty)
                              Text(scan['path'] as String),
                            for (final reason in scan['limits'] as List? ?? [])
                              Text(
                                widget
                                    .tr(
                                      const {
                                            'depth':
                                                'Folders deeper than {0} levels were skipped.',
                                            'entries':
                                                'The scan stopped at its entry limit. Choose a smaller folder.',
                                            'time':
                                                'The scan stopped at its time limit. Choose a smaller folder.',
                                            'results':
                                                'The scan stopped at its result limit. Choose a smaller folder.',
                                            'response':
                                                'The scan stopped at its response size limit. Choose a smaller folder.',
                                          }[reason] ??
                                          'Scan limit reached. Choose a smaller folder to find more.',
                                    )
                                    .replaceAll('{0}', '${scan['depth']}'),
                              ),
                            if ((scan['notices'] as List? ?? []).contains(
                              'ownership',
                            ))
                              Text(
                                widget.tr(
                                  'Folders owned by another user were skipped; they may contain AI installations.',
                                ),
                              ),
                            if ((scan['notices'] as List? ?? []).contains(
                              'filesystem',
                            ))
                              Text(
                                widget.tr(
                                  'Other filesystems or nested subvolumes were skipped. Scan them from their own mount point.',
                                ),
                              ),
                            if ((scan['foreign'] as List? ?? []).isNotEmpty)
                              Text(
                                widget.tr(
                                  'AI candidates found but owned by another user:',
                                ),
                              ),
                            for (final path in scan['foreign'] as List? ?? [])
                              SelectableText(path as String),
                          ],
                          if (nodes.any((n) => n['kind'] == 'models'))
                            Text(
                              widget.tr(
                                'GGUF folders may contain speech or vision models. Check the model type before connecting a language model server.',
                              ),
                            ),
                          const Divider(),
                          Text(
                            widget.tr('AI help'),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text(widget.tr(aiHelpHint)),
                          if (helpers.isNotEmpty) ...[
                            DropdownButtonFormField<String>(
                              initialValue: _helper,
                              decoration: InputDecoration(
                                labelText: widget.tr('AI help'),
                              ),
                              items: [
                                for (final h in helpers)
                                  DropdownMenuItem(
                                    value: h['command'] as String,
                                    child: Text(h['name'] as String),
                                  ),
                              ],
                              onChanged: busy
                                  ? null
                                  : (v) => setState(() => _helper = v),
                            ),
                            FilledButton(
                              onPressed:
                                  busy ||
                                      _helper == null ||
                                      helper?['check'] != true
                                  ? null
                                  : () => _help('check'),
                              child: Text(
                                widget.tr('Check this system with AI'),
                              ),
                            ),
                            OutlinedButton(
                              onPressed:
                                  busy ||
                                      _helper == null ||
                                      helper?['task'] == false
                                  ? null
                                  : () => _help('simplify'),
                              child: Text(widget.tr('Ask AI for a plan')),
                            ),
                          ] else
                            Text(
                              widget.tr(
                                'Enable an installed AI agent add-on to offer guarded AI help here.',
                              ),
                            ),
                          if (widget.data['analysis'] != null)
                            Text(
                              '${widget.tr('Setup analysis')} · ${widget.data['analysis']['agent']} · ${widget.data['analysis']['when']}',
                            ),
                          if (widget.data['analysis'] != null)
                            Text(widget.data['analysis']['summary'] as String),
                          for (final f in findings)
                            if (node == null ||
                                !nodeIds.contains(f['node']) ||
                                f['node'] == node['id'])
                              ListTile(
                                title: Text(f['title'] as String),
                                subtitle: Text(f['detail'] as String),
                                trailing: IconButton(
                                  tooltip: widget.tr('Fix it with AI'),
                                  onPressed:
                                      busy ||
                                          _helper == null ||
                                          helper?['task'] == false
                                      ? null
                                      : () => _help('fix', f['id'] as String),
                                  icon: const Icon(Icons.auto_fix_high),
                                ),
                              ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}
