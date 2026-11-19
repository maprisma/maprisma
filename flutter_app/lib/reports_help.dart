import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart' show corners;
import 'core_client.g.dart';

const reportingHelpSections = <(String, String)>[
  (
    'The log',
    'While Maprisma runs, the log stores activity times, agent and project names, file names and available usage counts. It stays in the local ai-log folder for the number of days you choose. File contents are not copied.',
  ),
  (
    'Outside Maprisma',
    'Collect history reads past sessions from supported agents. Collect activity from agent history controls collection. Use the agent\'s request as topic controls request topics. Topics are shortened and secret-looking text is redacted.',
  ),
  (
    'Topic reports',
    'Collect first, then choose a date range, filters and a focus and select Generate. The helper receives log entries, including request topics while that option is on. Online helpers require the activity-log permission in Maprisma Settings under AI.',
  ),
  (
    'Library',
    'Save a draft to the library to keep it until you delete it. Search saved reports, edit their title and note, or copy and export them. Log retention does not delete saved reports.',
  ),
  (
    'Tips',
    'Collect first, then generate. Use the focus for one project or question. History with incomplete timing or usage is marked partial, and missing usage stays unknown.',
  ),
];

Future<void> showReportingHelp(
  BuildContext context,
  CoreClient client,
  String Function(String) tr,
  List<Map<String, dynamic>> sources,
) async {
  final text = [
    tr('How reporting works'),
    for (final (title, body) in reportingHelpSections) ...[
      tr(title),
      tr(body),
      if (title == 'Outside Maprisma')
        for (final source in sources)
          "${source['name']} · ${tr(source['supported'] == true ? 'Supported' : 'Unsupported')}",
    ],
  ].join('\n\n');
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(corners(context)),
      ),
      title: Text(tr('How reporting works')),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (title, body) in reportingHelpSections) ...[
                Text(tr(title), style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Text(tr(body)),
                if (title == 'Outside Maprisma')
                  for (final source in sources)
                    Text(
                      "${source['name']} · ${tr(source['supported'] == true ? 'Supported' : 'Unsupported')}",
                    ),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: text)),
          child: Text(tr('Copy')),
        ),
        TextButton(
          onPressed: () async {
            try {
              final result = await client.helpOpenManual();
              if (context.mounted && result['opened'] != true) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(tr('The action could not be completed.')),
                  ),
                );
              }
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(tr('The action could not be completed.')),
                  ),
                );
              }
            }
          },
          child: Text(tr('Open user manual')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('Close')),
        ),
      ],
    ),
  );
}
