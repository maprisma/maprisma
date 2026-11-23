import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'app_look.dart';
import 'app_theme.dart' show monoFont;

/// A thin bar that moves while an agent works (task 098).
///
/// Still when the platform asks for no animations, and under `flutter test`
/// (a repeating animation never lets `pumpAndSettle` finish).
class WorkingBar extends StatelessWidget {
  const WorkingBar({super.key, this.height = 3});

  final double height;

  /// Whether the bar moves; tests may set it.
  static bool animate = Platform.environment['FLUTTER_TEST'] != 'true';

  @override
  Widget build(BuildContext context) {
    final still =
        !animate || (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    return LinearProgressIndicator(
      key: const ValueKey('working-bar'),
      minHeight: height,
      // A still bar is full: it still reads as "busy", not as progress.
      value: still ? 1 : null,
    );
  }
}

/// What an agent of the project is doing right now, or null when none works.
///
/// From the board card (`active`, `activity`) when there is one, else from
/// the project view (`phase`, `status`, `processes_stopping`). The latest
/// `assignment` (or `setup_started`) event of the current attempt gives the
/// start, the agent and its role; a boundary event before it (`started`,
/// `continued`, `assignment_done`, ...) means the next agent is not yet
/// dispatched, and then the boundary's time counts.
({
  String headline,
  String? detail,
  String output,
  String? key,
  DateTime? since,
})?
projectWork(
  Map<String, dynamic>? card,
  Map<String, dynamic>? project,
  String Function(String) tr,
) {
  if (project == null) return null;
  final status = project['status'];
  final phase = project['phase'] as String?;
  final active = card?['active'] as Map?;
  // The project view (`get`, or a change's answer) is at least as fresh as
  // the board card (`list` runs before it), so it decides whether an agent
  // works; the card only says who. The core derives the same facts.
  final stopping = status == 'pausing' || project['processes_stopping'] == true;
  final running = const {'planning', 'running', 'reviewing'}.contains(status);
  if (!running && !stopping) return null;
  final setup = phase == 'setup';
  // The current attempt's latest dispatch.
  Map? started;
  DateTime? boundary;
  for (final event in (project['events'] as List? ?? const []).reversed) {
    if (event is! Map) continue;
    final type = event['type'];
    if (type == (setup ? 'setup_started' : 'assignment')) {
      started = event;
      break;
    }
    if (_boundaries.contains(type)) {
      if (type == 'started' || type == 'continued') {
        boundary = DateTime.tryParse('${event['at'] ?? ''}');
      }
      break;
    }
  }
  // Who: the card's member at the active position, else the event's
  // "Agent: role".
  String? name;
  String? role;
  var position = -1, count = 0;
  // The card's assignment, unless it is not the one at work (the card is
  // from before a change: an assignment "next" or "stopped", another phase).
  final cardPhase = active?['phase'] as String?;
  final current =
      !setup &&
      const {'active', 'stopping'}.contains(active?['state']) &&
      (phase == null ||
          cardPhase == (phase == 'running' ? 'execution' : phase)) &&
      // The project's member at work (next_member) is the card's.
      (project['next_member'] is! int ||
          project['next_member'] == active?['position']);
  final where = current ? cardPhase : null;
  if (card != null && where != null && active?['position'] is int) {
    position = active!['position'] as int;
    final list = card[where] as List? ?? const [];
    count = list.length;
    final member = list
        .whereType<Map>()
        .where((m) => m['position'] == position)
        .firstOrNull;
    if (member != null) {
      name = '${member['name'] ?? member['agent'] ?? ''}';
      role = member['role'] as String?;
    }
  }
  if (setup) {
    // The project has the helper's id, the card also its name; a card from
    // before the change may name another helper.
    final id = project['setup_agent'];
    final shown = card?['setup_agent'];
    if (shown is Map && (id == null || shown['agent'] == id)) {
      name = '${shown['name'] ?? shown['agent'] ?? ''}';
    } else if (id is String) {
      name = id;
    }
    role = null;
  } else if (name == null && started?['text'] is String) {
    final text = started!['text'] as String;
    final colon = text.lastIndexOf(': ');
    if (colon > 0) {
      name = text.substring(0, colon);
      role = text.substring(colon + 2);
    }
  }
  final reviewer = role == 'reviewer' || status == 'reviewing';
  final String headline;
  if (stopping) {
    headline = 'Stopping the agent';
  } else if (setup) {
    headline = 'AI is setting up the team';
  } else if ((where ?? phase) == 'planning') {
    headline = reviewer ? 'AI is checking the plan' : 'AI is drafting the plan';
  } else {
    headline = reviewer
        ? 'AI is reviewing the changes'
        : 'AI is working on the project';
  }
  final parts = <String>[
    if (name != null && name.trim().isNotEmpty) name,
    if (role != null && !setup) tr(_roleLabel(role)),
    if (position >= 0 && count > 1)
      tr(
        'step {0} of {1}',
      ).replaceAll('{0}', '${position + 1}').replaceAll('{1}', '$count'),
  ];
  return (
    headline: tr(headline),
    detail: parts.isEmpty ? null : parts.join(' · '),
    output: '${project[setup ? 'setup_output' : 'output'] ?? ''}',
    // Which dispatch the output belongs to (see [ProjectWorking]).
    key: started == null ? null : '${started['type']}@${started['at']}',
    since: DateTime.tryParse('${started?['at'] ?? ''}') ?? boundary,
  );
}

/// Events that end or start an attempt or an assignment.
const _boundaries = {
  'started',
  'continued',
  'assignment_done',
  'finished',
  'paused',
  'failed',
  'interrupted',
  'continue_failed',
  'setup_started',
  'setup_failed',
  'setup_paused',
  'setup_interrupted',
  'setup_applied',
};

// The labels the team graph and the board use.
String _roleLabel(String? role) => switch (role) {
  'lead' => 'Lead agent',
  'implementer' => 'Implementer',
  'contributor' => 'Contributor',
  'reviewer' => 'Reviewer',
  _ => 'Agent',
};

final _ansi = RegExp(
  r'\x1B(?:\[[0-9;?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])',
);

/// The agent's latest non-empty output line, without terminal codes.
String? lastOutputLine(String output) {
  final lines = output.replaceAll(_ansi, '').split(RegExp(r'[\r\n]+'));
  for (final line in lines.reversed) {
    final text = line.trim();
    if (text.isNotEmpty) {
      return text.length > 300 ? '${text.substring(0, 300)}…' : text;
    }
  }
  return null;
}

/// "for 3 min" from [since] to [now]; "just started" in the first minute.
String workingFor(DateTime? since, DateTime now, String Function(String) tr) {
  if (since == null) return '';
  final minutes = now.toUtc().difference(since.toUtc()).inMinutes;
  if (minutes < 1) return tr('just started');
  if (minutes < 60) return tr('for {0} min').replaceAll('{0}', '$minutes');
  return tr(
    'for {0} h {1} min',
  ).replaceAll('{0}', '${minutes ~/ 60}').replaceAll('{1}', '${minutes % 60}');
}

/// The project page's strip under the tabs while an agent works (task 098):
/// moving bar, headline, who and how long, the latest output line.
///
/// The stored output is the previous agent's until the current one writes
/// (it is kept on purpose, e.g. as evidence of interrupted work), so the
/// strip shows an output line only once it differs from what was stored
/// when the current dispatch was first seen (after an attempt's start with
/// no dispatch: from the output seen then).
class ProjectWorking extends StatefulWidget {
  const ProjectWorking({
    super.key,
    required this.card,
    required this.project,
    required this.tr,
    this.now,
    this.compact = false,
  });

  final Map<String, dynamic>? card;
  final Map<String, dynamic>? project;
  final String Function(String) tr;

  /// The clock (tests); the page rebuilds every 2 s while agents run.
  final DateTime? now;
  final bool compact;

  @override
  State<ProjectWorking> createState() => _ProjectWorkingState();
}

class _ProjectWorkingState extends State<ProjectWorking> {
  // The dispatch seen and the output that is not its own (each agent's live
  // output starts empty and replaces the stored one). [_last] is the output
  // of the previous build.
  bool _seen = false;
  String? _key;
  String? _baseline;
  String? _last;
  bool _lastSetup = false;
  Object? _projectId;

  @override
  Widget build(BuildContext context) {
    final work = projectWork(widget.card, widget.project, widget.tr);
    final id = widget.project?['id'];
    if (work == null || id != _projectId) {
      _projectId = id;
      _seen = false;
      _last = null;
    }
    if (work == null) return const SizedBox.shrink();
    // Team setup writes setup_output, the agents output.
    final setup = work.key?.startsWith('setup_started@') ?? false;
    if (!_seen || (work.key != _key && setup != _lastSetup)) {
      _seen = true;
      _key = work.key;
      _baseline = work.output;
    } else if (work.key != _key) {
      // After no dispatch (an attempt's start) the output seen then is not
      // the new agent's; after another agent, its final output stays stored
      // until the new one writes, so what is stored now is not.
      _baseline = _key == null ? _last : work.output;
      _key = work.key;
    }
    _last = work.output;
    _lastSetup = setup;
    // No dispatch yet (the attempt just started or continued): the stored
    // output is the last attempt's.
    final output = work.key == null || work.output == _baseline
        ? null
        : lastOutputLine(work.output);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final elapsed = workingFor(
      work.since,
      widget.now ?? DateTime.now(),
      widget.tr,
    );
    final detail = [?work.detail, if (elapsed.isNotEmpty) elapsed].join(' · ');
    final small = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return Semantics(
      key: const ValueKey('project-working'),
      liveRegion: true,
      label: work.headline,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const WorkingBar(),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: AppSpace.md,
              vertical: widget.compact ? AppSpace.xs : AppSpace.sm,
            ),
            // One line each, the full width (long translations, large text).
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.auto_awesome, size: 18, color: colors.primary),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Text(
                        '${work.headline}…',
                        key: const ValueKey('working-headline'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: colors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    key: const ValueKey('working-detail'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: small,
                  ),
                if (output != null && !widget.compact)
                  Text(
                    output,
                    key: const ValueKey('working-output'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: small?.copyWith(fontFamily: monoFont(context)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
