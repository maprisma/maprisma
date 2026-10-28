import 'dart:async';
import 'package:flutter/material.dart';
import 'backend.dart';

class SubagentsDialog extends StatefulWidget {
  const SubagentsDialog({
    super.key,
    required this.backend,
    required this.command,
    required this.initial,
    required this.tr,
  });
  final Backend backend;
  final String command;
  final Map<String, dynamic> initial;
  final String Function(String) tr;
  @override
  State<SubagentsDialog> createState() => _SubagentsDialogState();
}

class _SubagentsDialogState extends State<SubagentsDialog> {
  late Map<String, dynamic> _data;
  late final Timer _timer;
  bool _pending = false;
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    _data = widget.initial;
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  Future<void> _refresh() async {
    if (_pending || _data['subagents_supported'] != true) return;
    _pending = true;
    try {
      final result = await widget.backend.call('agents.activity', {
        'command': widget.command,
      });
      if (mounted) {
        setState(() {
          _data = result;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      _pending = false;
    }
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.tr('Subagents')} · ${widget.command}'),
    content: SizedBox(
      width: 650,
      height: 400,
      child: _data['subagents_supported'] != true
          ? Text(
              widget.tr(
                'Subagent tracking is not available for this agent yet.',
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_failed)
                  Text(
                    widget.tr('The application service could not be reached.'),
                  ),
                if ((_data['children'] as List).isEmpty)
                  Text(widget.tr('No recent subagents observed')),
                Expanded(
                  child: ListView(
                    children: [
                      for (final child in _data['children'] as List)
                        ListTile(
                          leading: Icon(
                            child['running'] == true
                                ? Icons.play_arrow
                                : Icons.history,
                          ),
                          title: Text(child['kind'] as String),
                          subtitle: Text(
                            '${child['folder']} · ${(child['age'] as num).round()} s',
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(widget.tr('Close')),
      ),
    ],
  );
}
