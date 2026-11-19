import 'dart:convert';

String formatTopicReport(
  Map<String, dynamic> report,
  String format, {
  String Function(String)? translate,
}) {
  if (format == 'json') {
    return const JsonEncoder.withIndent('  ').convert(report);
  }
  if (format != 'text' && format != 'markdown') {
    throw const FormatException('Unknown export format');
  }
  String label(String key) => translate?.call(key) ?? key;
  final markdown = format == 'markdown';
  return [
    "${markdown ? '# ' : ''}${report['title']}",
    "${report['from_day']} – ${report['through_day']}",
    for (final topic in report['topics'] as List) ...[
      '',
      "${markdown ? '## ' : ''}${topic['name']}",
      "${topic['summary']}",
      '',
      [
        ...?topic['sources'] as List?,
        ...?topic['projects'] as List?,
        if (topic['spans'] != null) "${label('Spans')} ${topic['spans']}",
        if (topic['elapsed_ms'] case final int elapsed)
          Duration(milliseconds: elapsed).toString().split('.').first,
        if (topic['tokens_in'] != null || topic['tokens_out'] != null)
          "${label('Tokens')} ↑${topic['tokens_in'] ?? '–'} ↓${topic['tokens_out'] ?? '–'}",
        if (topic['usage_unknown'] case final int n when n > 0)
          "${label('Unknown usage')} $n",
      ].join(' · '),
    ],
    '',
    "${report['text']}",
    if (report['note'] != null) ...['', "${report['note']}"],
  ].join('\n');
}
