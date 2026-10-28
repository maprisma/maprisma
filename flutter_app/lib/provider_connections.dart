import 'package:flutter/material.dart';

class ProviderConnections extends StatefulWidget {
  const ProviderConnections({
    super.key,
    required this.provider,
    required this.agents,
    required this.busy,
    required this.tr,
    required this.onPreview,
  });
  final Map<String, dynamic> provider;
  final List agents;
  final bool busy;
  final String Function(String) tr;
  final Future<void> Function(Map<String, dynamic>) onPreview;
  @override
  State<ProviderConnections> createState() => _ProviderConnectionsState();
}

class _ProviderConnectionsState extends State<ProviderConnections> {
  String? _model;
  bool _useNow = true;

  void _preview(String command, bool remove, String? model, bool useNow) =>
      widget.onPreview({
        'kind': 'provider',
        'command': command,
        'item': widget.provider['id'],
        'remove': remove,
        'model': model ?? '',
        'use_now': useNow,
      });

  @override
  Widget build(BuildContext context) {
    final models = (widget.provider['models'] as List).cast<String>();
    final chosen = models.contains(_model)
        ? _model
        : (models.isEmpty ? null : models.first);
    return Card(
      child: ExpansionTile(
        title: Text(widget.provider['name'] as String),
        subtitle: Text(widget.provider['address'] as String),
        childrenPadding: const EdgeInsets.all(12),
        children: [
          DropdownButtonFormField<String>(
            key: ValueKey(chosen),
            initialValue: chosen,
            isExpanded: true,
            decoration: InputDecoration(labelText: widget.tr('Model')),
            items: [
              for (final model in models)
                DropdownMenuItem(
                  value: model,
                  child: Text(model, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: widget.busy
                ? null
                : (value) => setState(() => _model = value),
          ),
          CheckboxListTile(
            title: Text(widget.tr('Use now')),
            value: _useNow,
            onChanged: widget.busy
                ? null
                : (value) => setState(() => _useNow = value == true),
          ),
          for (final agent in widget.agents)
            if (agent['provider'] == true)
              ListTile(
                title: Text(agent['name'] as String),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if ((widget.provider['agents'] as List).contains(
                          agent['command'],
                        ) &&
                        chosen != null)
                      IconButton(
                        tooltip: widget.tr('Use now'),
                        icon: const Icon(Icons.play_arrow),
                        onPressed: widget.busy
                            ? null
                            : () => _preview(
                                agent['command'] as String,
                                false,
                                chosen,
                                true,
                              ),
                      ),
                    Switch(
                      value: (widget.provider['agents'] as List).contains(
                        agent['command'],
                      ),
                      onChanged:
                          widget.busy ||
                              (chosen == null &&
                                  _useNow &&
                                  !(widget.provider['agents'] as List).contains(
                                    agent['command'],
                                  ))
                          ? null
                          : (on) => _preview(
                              agent['command'] as String,
                              !on,
                              chosen,
                              _useNow,
                            ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
