import 'package:flutter/material.dart';
import 'providers_view.dart' show modelSize;

/// What Find existing AI found on this PC: a model folder to reuse, a local
/// LLM to reconnect to one of the folders.
class FoundOnPcView extends StatefulWidget {
  const FoundOnPcView({
    super.key,
    required this.nodes,
    required this.tr,
    required this.onReconnect,
    required this.onClose,
  });

  /// `system.refresh`'s nodes.
  final List<Map<String, dynamic>> nodes;
  final String Function(String) tr;
  final void Function(Map<String, dynamic> source, Map<String, dynamic>? target)
  onReconnect;
  final VoidCallback onClose;

  @override
  State<FoundOnPcView> createState() => _FoundOnPcViewState();
}

class _FoundOnPcViewState extends State<FoundOnPcView> {
  final _chosen = <String, String>{};

  List<Map<String, dynamic>> get _found => [
    for (final n in widget.nodes)
      if (n['found'] != null && n['status'] != 'missing') n,
  ];

  Widget _runtime(Map<String, dynamic> node) {
    final tr = widget.tr;
    final id = '${node['id']}';
    final folders = [
      for (final n in _found)
        if (n['kind'] != 'runtime' &&
            (n['provider'] == '' || n['provider'] == node['provider']))
          n,
    ];
    final chosen = _chosen[id];
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            key: ValueKey('found-folder-$id'),
            initialValue: chosen,
            isExpanded: true,
            decoration: InputDecoration(labelText: tr('Models folder')),
            items: [
              for (final f in folders)
                DropdownMenuItem(
                  value: '${f['id']}',
                  child: Text('${f['path']}', overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(() {
              if (v != null) _chosen[id] = v;
            }),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          key: ValueKey('found-reconnect-$id'),
          onPressed: chosen == null
              ? null
              : () => widget.onReconnect(
                  node,
                  folders.firstWhere((f) => f['id'] == chosen),
                ),
          child: Text(tr('Reconnect')),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    final found = [
      for (final n in _found)
        if (n['kind'] == 'runtime' || n['kind'] == 'models') n,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: found.isEmpty
              ? Center(child: Text(tr('Nothing new found.')))
              : ListView(
                  children: [
                    for (final n in found)
                      Card(
                        key: ValueKey('found-${n['id']}'),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                '${n['label']}',
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              SelectableText('${n['path'] ?? ''}'),
                              const SizedBox(height: 8),
                              if (n['kind'] == 'runtime')
                                _runtime(n)
                              else
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: FilledButton(
                                    key: ValueKey('found-reuse-${n['id']}'),
                                    onPressed: () =>
                                        widget.onReconnect(n, null),
                                    child: Text(tr('Reuse model folder')),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: widget.onClose,
            child: Text(tr('Close')),
          ),
        ),
      ],
    );
  }
}

const _preserved =
    'Existing files are preserved. Services stay stopped. Undo removes the new connecting files.';

/// The preview of `existing.preview`: true when the user applies it.
Future<bool> confirmExisting(
  BuildContext context,
  Map<String, dynamic> plan,
  String Function(String) tr,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Preview')),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(tr(_preserved)),
                for (final note in plan['notes'] as List? ?? [])
                  Text(tr(note as String)),
                for (final file in plan['files'] as List? ?? []) ...[
                  const SizedBox(height: 12),
                  SelectableText(file['path'] as String),
                  if (file['text'] != null)
                    SelectableText(file['text'] as String),
                ],
                for (final name in plan['model_files'] as List? ?? [])
                  SelectableText(name as String),
                if (plan['source'] != null)
                  SelectableText('${plan['source']} → ${plan['destination']}'),
                if (plan['size'] != null) Text(modelSize(plan['size'] as num)),
                if (plan['empty'] == true) Text(tr('No changes to apply')),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: plan['empty'] == true
                ? null
                : () => Navigator.pop(context, true),
            child: Text(tr('Apply')),
          ),
        ],
      ),
    ) ==
    true;
