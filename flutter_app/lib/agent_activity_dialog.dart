import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AgentActivityDialog extends StatefulWidget {
  const AgentActivityDialog({super.key, required this.fetch, required this.tr});

  final Future<Map<String, dynamic>> Function(String? instance) fetch;
  final String Function(String) tr;

  @override
  State<AgentActivityDialog> createState() => _AgentActivityDialogState();
}

class _AgentActivityDialogState extends State<AgentActivityDialog> {
  Timer? _refresh;
  Map<String, dynamic>? _data;
  String? _instance;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _refresh = Timer.periodic(const Duration(seconds: 3), (_) => _load());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    final instance = _instance;
    try {
      final data = await widget.fetch(instance);
      if (mounted && instance == _instance) {
        setState(() {
          _data = data;
          final report = data['report'];
          if (report is Map) _instance = report['instance']['id'] as String;
        });
      }
    } on Exception {
      if (mounted && _data == null) setState(() => _data = {});
    } finally {
      _loading = false;
    }
  }

  String _report(Map data) {
    final tr = widget.tr;
    final details = data['details'] as Map;
    final progress = data['progress'] as Map?;
    final request = details['request'] as Map?;
    final origin = data['origin'] as Map;
    final lines = <String>[
      '${tr('What is it doing?')} · ${data['instance']['label']}',
      tr(switch (data['phase']) {
        'planning' => 'Planning',
        'editing' => 'Editing',
        'testing' => 'Writing or running tests',
        'finished' => 'Finished',
        _ => 'No details available',
      }),
      '',
      if (data['stuck'] != null) tr('Possibly stuck'),
      tr('Current work'),
      if (request != null) '${request['text']}',
      for (final answer in details['answers'] as List) '${answer['text']}',
      for (final tool in details['tool_calls'] as List) '• ${tool['name']}',
      for (final edit in details['edited_files'] as List) '• ${edit['path']}',
      if (request == null &&
          (details['answers'] as List).isEmpty &&
          (details['tool_calls'] as List).isEmpty)
        tr('No details available'),
      if (progress != null) ...[
        '${progress['done']}/${progress['total']} · ${progress['step']}',
        if (progress['note'] != null) '${progress['note']}',
      ],
      '',
      tr('Activity timeline'),
      for (final group in data['timeline'] as List)
        '${_time(group['from'])}–${_time(group['to'])} '
            '${tr(group['kind'] == 'testing' ? 'Writing or running tests' : 'Editing')}\n'
            '${(group['files'] as List).map((file) => file['path']).join('\n')}',
      '',
      tr('Helper processes'),
      for (final helper in data['helpers'] as List)
        '${helper['label']} · ${Duration(milliseconds: helper['elapsed_ms'] as int).toString().split('.').first}',
      '',
      tr('Started by'),
      if (origin['terminal_title'] != null) '${origin['terminal_title']}',
      if (origin['close_risk'] == 'possible')
        tr('Closing this terminal may stop the work.'),
      (origin['ancestors'] as List)
          .map((process) => '${process['label']} (${process['pid']})')
          .join(' ← '),
    ];
    return lines.join('\n');
  }

  String _time(String value) {
    final time = DateTime.parse(value).toLocal();
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    final report = _data?['report'] as Map?;
    final text = report == null ? '' : _report(report);
    final instances = _data?['instances'] as List? ?? [];
    return AlertDialog(
      title: Text(tr('What is it doing?')),
      content: SizedBox(
        width: 660,
        height: 440,
        child: _data == null
            ? const Center(child: CircularProgressIndicator())
            : report != null
            ? SingleChildScrollView(child: SelectableText(text))
            : _data?['status'] == 'choose_instance'
            ? ListView(
                children: [
                  for (final instance in instances)
                    ListTile(
                      title: Text(instance['label'] as String),
                      onTap: () {
                        setState(() => _instance = instance['id'] as String);
                        unawaited(_load());
                      },
                    ),
                ],
              )
            : Center(child: Text(tr('No details available'))),
      ),
      actions: [
        if (text.isNotEmpty)
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
            child: Text(tr('Copy')),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('Close')),
        ),
      ],
    );
  }
}
