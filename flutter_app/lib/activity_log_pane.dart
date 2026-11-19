import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_look.dart';
import 'core_client.g.dart';
import 'reports_output.dart';

class ActivityLogPane extends StatefulWidget {
  const ActivityLogPane({
    super.key,
    required this.client,
    required this.tr,
    required this.active,
  });
  final CoreClient client;
  final String Function(String) tr;
  final bool active;

  @override
  State<ActivityLogPane> createState() => ActivityLogPaneState();
}

class ActivityLogPaneState extends State<ActivityLogPane> {
  DateTimeRange? _range;
  Timer? _timer;
  Map<String, dynamic>? _report;
  bool _pending = false, _refreshQueued = false, _failed = false;
  int? _cursor;
  bool _selected = false;
  Map<String, dynamic>? _deferredReport;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(ActivityLogPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (!widget.active) return;
    unawaited(refresh(preserveSelection: true));
    _timer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => refresh(preserveSelection: true),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _selectionChanged(TextSelection selection, SelectionChangedCause? _) {
    final selected = !selection.isCollapsed;
    if (_selected == selected) return;
    _selected = selected;
    final deferred = _deferredReport;
    if (!selected && deferred != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _selected || _deferredReport != deferred) return;
        setState(() {
          _report = deferred;
          _deferredReport = null;
          _failed = false;
        });
      });
    }
  }

  Future<void> refresh({bool preserveSelection = false}) async {
    if (_pending) {
      _refreshQueued = true;
      return;
    }
    _pending = true;
    try {
      final result = await widget.client.activitylogReport(
        cursor: _cursor,
        fromDay: reportDay(_range?.start),
        throughDay: reportDay(_range?.end),
      );
      if (mounted && !_refreshQueued) {
        if (preserveSelection && _selected) {
          _deferredReport = result;
        } else {
          setState(() {
            _report = result;
            _deferredReport = null;
            _failed = false;
          });
        }
      }
    } catch (_) {
      if (mounted && !_refreshQueued) setState(() => _failed = true);
    } finally {
      _pending = false;
      if (mounted && _refreshQueued) {
        _refreshQueued = false;
        unawaited(refresh());
      }
    }
  }

  Future<void> _chooseRange() async {
    final selected = await chooseReportRange(context, _range);
    if (!mounted || selected == null) return;
    _range = selected;
    _cursor = null;
    await refresh();
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

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.xs,
          children: [
            OutlinedButton(
              onPressed: _chooseRange,
              child: Text(widget.tr('Date range')),
            ),
            TextButton(onPressed: refresh, child: Text(widget.tr('Refresh'))),
            if (_cursor != null)
              TextButton(
                onPressed: () {
                  _cursor = null;
                  refresh();
                },
                child: Text(widget.tr('First page')),
              ),
            if (report?['next_cursor'] case final int cursor)
              TextButton(
                onPressed: () {
                  _cursor = cursor;
                  refresh();
                },
                child: Text(widget.tr('Next')),
              ),
            if (report != null) ...[
              TextButton(
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: _text(report))),
                child: Text(widget.tr('Copy')),
              ),
              TextButton(
                onPressed: () => saveReportFile(
                  context,
                  widget.tr,
                  'maprisma-activity.txt',
                  _text(report),
                ),
                child: const Text('TXT'),
              ),
              TextButton(
                onPressed: () => saveReportFile(
                  context,
                  widget.tr,
                  'maprisma-activity.json',
                  const JsonEncoder.withIndent('  ').convert(report),
                ),
                child: const Text('JSON'),
              ),
            ],
          ],
        ),
        const SizedBox(height: AppSpace.md),
        if (report != null)
          SectionCard(
            child: SelectableText(
              onSelectionChanged: _selectionChanged,
              (report['entries'] as List).isEmpty
                  ? widget.tr('No details available')
                  : _text(report),
            ),
          )
        else if (!_failed)
          const LinearProgressIndicator(),
        if (_failed) Text(widget.tr('No details available')),
      ],
    );
  }
}
