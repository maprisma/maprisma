import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core_client.g.dart';

class ActivityLogDialog extends StatefulWidget {
  const ActivityLogDialog({super.key, required this.client, required this.tr});
  final CoreClient client;
  final String Function(String) tr;

  @override
  State<ActivityLogDialog> createState() => _ActivityLogDialogState();
}

class _ActivityLogDialogState extends State<ActivityLogDialog> {
  late Future<Map<String, dynamic>> _result = widget.client.activitylogReport();

  DateTimeRange? _range;
  String _day(DateTime date) => date.toIso8601String().split('T').first;

  Future<Map<String, dynamic>> _fetch([int? cursor]) =>
      widget.client.activitylogReport(
        cursor: cursor,
        fromDay: _range == null ? null : _day(_range!.start),
        throughDay: _range == null ? null : _day(_range!.end),
      );

  Future<void> _chooseRange() async {
    final now = DateTime.now();
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day - 364),
      lastDate: now,
      initialDateRange: _range,
    );
    if (!mounted || selected == null) return;
    setState(() {
      _range = selected;
      _result = _fetch();
    });
  }

  String _duration(int ms) =>
      Duration(milliseconds: ms).toString().split('.').first;

  String _text(Map<String, dynamic> result) => [
    '${result['from_day']} – ${result['through_day']}',
    for (final row in result['entries'] as List)
      [
        '${row['source']}',
        if (row['project'] is String) '${row['project']}',
        if (row['topic'] == 'testing') widget.tr('Writing or running tests'),
        if (row['topic'] == 'editing') widget.tr('Editing'),
        DateTime.parse(
          row['started_at'] as String,
        ).toLocal().toString().split('.').first,
        _duration(row['duration_ms'] as int),
      ].join(' · '),
    for (final (key, heading) in const [
      ('by_source', 'By agent or runtime'),
      ('by_project', 'By project'),
      ('by_day', 'By day'),
      ('by_week', 'By week'),
    ])
      if ((result[key] as List? ?? []).isNotEmpty) ...[
        '',
        widget.tr(heading),
        for (final row in result[key] as List)
          [
            '${row['key']}',
            '${row['count']}',
            _duration(row['duration_ms'] as int),
            if (row['tokens_in'] != null && row['tokens_out'] != null)
              "${widget.tr('Tokens')} ↑${row['tokens_in']} ↓${row['tokens_out']}",
          ].join(' · '),
      ],
  ].join('\n');

  Future<void> _save(String text, String extension) async {
    final location = await getSaveLocation(
      suggestedName: 'maprisma-activity.$extension',
    );
    if (location == null) return;
    try {
      await XFile.fromData(utf8.encode(text)).saveTo(location.path);
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.tr('Could not save the log.'))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _result,
    builder: (context, snapshot) {
      final report = snapshot.data;
      final text = report == null ? '' : _text(report);
      final next = report?['next_cursor'] as int?;
      return AlertDialog(
        title: Text(widget.tr('AI activity log')),
        content: SizedBox(
          width: 640,
          height: 410,
          child: report == null
              ? Center(
                  child: snapshot.hasError
                      ? Text(widget.tr('No details available'))
                      : const CircularProgressIndicator(),
                )
              : SingleChildScrollView(
                  child: SelectableText(
                    (report['entries'] as List).isEmpty
                        ? widget.tr('No details available')
                        : text,
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: _chooseRange,
            child: Text(widget.tr('Date range')),
          ),
          if (report != null) ...[
            if (next != null)
              TextButton(
                onPressed: () => setState(() {
                  _result = _fetch(next);
                }),
                child: Text(widget.tr('Next')),
              ),
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: text)),
              child: Text(widget.tr('Copy')),
            ),
            TextButton(
              onPressed: () => _save(text, 'txt'),
              child: const Text('TXT'),
            ),
            TextButton(
              onPressed: () => _save(
                const JsonEncoder.withIndent('  ').convert(report),
                'json',
              ),
              child: const Text('JSON'),
            ),
          ],
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(widget.tr('Close')),
          ),
        ],
      );
    },
  );
}
