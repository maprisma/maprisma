import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_core/maprisma_core.dart' show formatTopicReport;

import 'app_look.dart';
import 'window_popup.dart';

String? reportDay(DateTime? date) => date?.toIso8601String().split('T').first;

Future<DateTimeRange?> chooseReportRange(
  BuildContext context,
  DateTimeRange? range,
) {
  final now = DateTime.now();
  return showDateRangePicker(
    context: context,
    firstDate: DateTime(now.year, now.month, now.day - 364),
    lastDate: now,
    initialDateRange: range,
  );
}

List<Widget> reportExportButtons(
  BuildContext context,
  Map<String, dynamic> report,
  String Function(String) tr,
) => [
  TextButton(
    onPressed: () => Clipboard.setData(
      ClipboardData(text: formatTopicReport(report, 'text', translate: tr)),
    ),
    child: Text(tr('Copy')),
  ),
  MenuAnchor(
    menuChildren: [
      for (final (ext, format, title) in const [
        ('txt', 'text', 'TXT'),
        ('md', 'markdown', 'Markdown'),
        ('json', 'json', 'JSON'),
      ])
        MenuItemButton(
          onPressed: () => saveReportFile(
            context,
            tr,
            "maprisma-report-${report['from_day']}-${report['through_day']}.$ext",
            formatTopicReport(report, format, translate: tr),
          ),
          child: Text(title == 'Markdown' ? tr(title) : title),
        ),
    ],
    builder: (_, controller, _) => TextButton(
      onPressed: () =>
          controller.isOpen ? controller.close() : controller.open(),
      child: Text(tr('Export')),
    ),
  ),
];

Future<void> saveReportFile(
  BuildContext context,
  String Function(String) tr,
  String name,
  String content,
) async {
  try {
    final location = await PopupGuard.around(
      () => getSaveLocation(suggestedName: name),
    );
    if (location != null) {
      await XFile.fromData(utf8.encode(content)).saveTo(location.path);
    }
  } on Exception {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Could not export the report.'))),
      );
    }
  }
}

class ReportOutput extends StatelessWidget {
  const ReportOutput({
    super.key,
    required this.report,
    required this.tr,
    this.showTitle = true,
  });
  final Map<String, dynamic> report;
  final String Function(String) tr;
  final bool showTitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SectionCard(
        title: showTitle ? report['title'] as String : null,
        child: Text(
          "${report['from_day']} – ${report['through_day']} · ${report['helper']}",
        ),
      ),
      for (final topic in report['topics'] as List) ...[
        const SizedBox(height: AppSpace.md),
        SectionCard(
          title: topic['name'] as String,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(topic['summary'] as String),
              const SizedBox(height: AppSpace.sm),
              Text(
                [
                  ...(topic['sources'] as List).cast<String>(),
                  ...(topic['projects'] as List).cast<String>(),
                ].join(' · '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                [
                  "${tr('Spans')} ${topic['spans']}",
                  Duration(
                    milliseconds: topic['elapsed_ms'] as int,
                  ).toString().split('.').first,
                  if (topic['tokens_in'] != null || topic['tokens_out'] != null)
                    "${tr('Tokens')} ↑${topic['tokens_in'] ?? '–'} ↓${topic['tokens_out'] ?? '–'}",
                  if (topic['usage_unknown'] != 0)
                    "${tr('Unknown usage')} ${topic['usage_unknown']}",
                ].join(' · '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
      const SizedBox(height: AppSpace.md),
      SectionCard(child: SelectableText(report['text'] as String)),
      if (report['note'] case final String note) ...[
        const SizedBox(height: AppSpace.md),
        SectionCard(title: tr('Note'), child: SelectableText(note)),
      ],
    ],
  );
}
