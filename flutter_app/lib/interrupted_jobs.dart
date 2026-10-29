import 'package:flutter/material.dart';

/// Downloads a previous run left unfinished (jobs.list, state interrupted):
/// one line each, Continue (it goes on from where it stopped) or Discard.
class InterruptedJobs extends StatelessWidget {
  const InterruptedJobs({
    super.key,
    required this.jobs,
    required this.busy,
    required this.tr,
    required this.onContinue,
    required this.onDiscard,
  });
  final List<Map<String, dynamic>> jobs;
  final bool busy;
  final String Function(String) tr;
  final ValueChanged<Map<String, dynamic>> onContinue;
  final ValueChanged<Map<String, dynamic>> onDiscard;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final job in jobs)
        ListTile(
          key: ValueKey('job-${job['id']}'),
          dense: true,
          leading: const Icon(Icons.pause_circle_outline),
          title: Text('${job['title']}'),
          subtitle: Text(
            tr(
              'Interrupted at {0} · Continue goes on where it stopped',
            ).replaceAll(
              '{0}',
              '${((job['fraction'] as num) * 100).round()} %',
            ),
          ),
          trailing: Wrap(
            spacing: 4,
            children: [
              TextButton(
                onPressed: busy ? null : () => onContinue(job),
                child: Text(tr('Continue')),
              ),
              TextButton(
                onPressed: busy ? null : () => onDiscard(job),
                child: Text(tr('Discard')),
              ),
            ],
          ),
        ),
    ],
  );
}
