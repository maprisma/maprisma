import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/project_board.dart';
import 'package:maprisma/project_schedule.dart';

/// The app reads its texts only from assets/translations (built by
/// tools/flutter-assets.py from its KEYS): every text the Projects tab and
/// the AI Project Center page show must be there in all eight languages
/// (task 086 review round 2).
void main() {
  test('the Projects tab and the Project Center page are translated', () {
    final used = RegExp(r"""tr\(\s*'((?:[^'\\]|\\.)*)'\s*[,)]""");
    final keys = {
      for (final file in [
        'lib/ai_project_center.dart',
        'lib/main_tabs.dart',
        'lib/project_board.dart',
        'lib/project_messages.dart',
        'lib/project_page_parts.dart',
        'lib/project_schedule.dart',
        'lib/project_phases.dart',
      ])
        for (final match in used.allMatches(File(file).readAsStringSync()))
          match.group(1)!.replaceAll(r"\'", "'"),
    };
    expect(keys, isNotEmpty);
    for (final code in ['de', 'es', 'fr', 'it', 'nl', 'pl', 'pt']) {
      final table =
          jsonDecode(File('assets/translations/$code.json').readAsStringSync())
              as Map<String, dynamic>;
      final missing = [
        for (final key in keys)
          if (table[key] is! String) key,
      ];
      expect(missing, isEmpty, reason: '$code is missing these texts');
    }
  });

  test('the board\'s looked-up texts are translated too', () {
    final keys = {
      for (final f in BoardFilter.values) f.label,
      for (final (_, label) in boardStages) label,
      for (final v in BoardView.values) v.label,
      for (final fix in ['map', 'goal', 'team']) issueFixLabel(fix),
      // Fix on map's answer for a box that is not there (main.dart).
      'This is not on the map.',
      for (final code in [
        'stopping',
        'setting_up_team',
        'planning',
        'reviewing_plan',
        'reviewing',
        'running',
        'paused',
        'interrupted',
        'failed',
        'needs_review',
        'approve_again',
        'approved_blocked',
        'ready_to_run',
        'agents_finished',
        'draft',
      ])
        boardActivity(code),
      for (final code in [
        'folder_missing',
        'folder_changed',
        'no_lead',
        'empty_goal',
        'agent_unavailable',
        'profile_invalid',
        'runtime_stopped',
        'model_unavailable',
        'provider_unavailable',
        'runtime_required',
        'other',
      ])
        boardIssue(code),
      'All',
      'Open',
      'Pause',
      'Retry pause',
      'Review plan',
      'Working',
      'Stopping',
      'Stopped',
      'Next',
      'Planning',
      'Execution',
      'Lead agent',
      'Implementer',
      'Contributor',
      'Reviewer',
      'Setup helper',
      'Agent default',
      'Check the changes first',
      'Approve again',
      // The core's message events (task 096), shown through tr(text).
      'Message received. Pausing the agent to continue with it now.',
      'Message queued for the next assignment.',
      'A message arrived after the last assignment had started. It waits for the next assignment.',
      'A waiting message was removed.',
      // Board order and importance (task 095).
      for (final i in BoardImportance.values) i.label,
      'Move',
      'Move up',
      'Move down',
      'Move to top',
      'Move to end',
      // Schedules (task 101): choices, weekdays and the core's reasons.
      for (final r in ScheduleRepeat.values) r.label,
      ...scheduleWeekdays,
      'The project is still running.',
      'The last run stopped before it ended. Review its changes and continue or approve again.',
      'The plan is not approved. Review and approve it first.',
      'The approval no longer fits: the plan, the team, the folder or an agent changed. Approve again.',
      'A rule refuses starting one of its agents.',
      'Another project works in the same folder now.',
      'Too many projects are running now.',
      'The working folder changed or is missing.',
      'An agent of its team is not available.',
      'The approval no longer fits. Approve again.',
      'Some of its processes are still stopping.',
      'Maprisma: a scheduled project did not run',
      'Maprisma is open but did not take the scheduled run. Open its Projects page and try again.',
      // Timers that cannot be kept (task 103).
      'Maprisma: a project schedule needs attention',
      'The timer of its schedule could not be removed. Maprisma tries again at its next start.',
      'The timer of its schedule could not be set up, so it does not run on time. Maprisma tries again at its next start.',
      'Maprisma cannot read the folder of its timers (~/.config/systemd/user). Timers it no longer needs stay until it can.',
      'Maprisma could not record the scheduled run. Open its Projects page to check the project.',
      'The scheduled run could not be handed over to Maprisma. Its timer starts it again at the next planned time.',
    };
    for (final code in ['de', 'es', 'fr', 'it', 'nl', 'pl', 'pt']) {
      final table =
          jsonDecode(File('assets/translations/$code.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(
        [
          for (final key in keys)
            if (table[key] is! String) key,
        ],
        isEmpty,
        reason: '$code is missing these texts',
      );
    }
  });
}
