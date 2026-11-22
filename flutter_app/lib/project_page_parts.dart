import 'package:flutter/material.dart';

import 'app_look.dart';
import 'app_theme.dart' show corners;
import 'project_board.dart';

/// The project page's large stage rail (task 089): the six stops with their
/// names, the current one lit, Approval as a gate; the activity and the
/// second line beside it. Compact: only the current stage's name.
class LargeStageRail extends StatelessWidget {
  const LargeStageRail({
    super.key,
    required this.project,
    required this.tr,
    this.compact = false,
  });

  final Map<String, dynamic> project;
  final String Function(String) tr;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final stage = project['stage'] as String?;
    final index = boardStages.indexWhere((s) => s.$1 == stage);
    final activity = tr(boardActivity(project['activity'] as String?));
    final second = project['second'];
    final secondText = switch (second) {
      'check_changes_first' => tr('Check the changes first'),
      'approve_again' => tr('Approve again'),
      _ => null,
    };
    final current = index < 0 ? null : tr(boardStages[index].$2);
    return Semantics(
      label: [
        if (current != null) '${tr('Stage')}: $current',
        activity,
        ?secondText,
      ].join(', '),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.md,
          vertical: AppSpace.xs,
        ),
        child: compact
            ? Row(
                key: const ValueKey('large-rail-compact'),
                children: [
                  Icon(Icons.timeline, size: 18, color: colors.primary),
                  const SizedBox(width: AppSpace.sm),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          [?current, activity].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        // The next step on its own line, never cut off.
                        if (secondText != null)
                          Text(
                            secondText,
                            key: const ValueKey('large-rail-second'),
                            style: theme.textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                ],
              )
            : Column(
                key: const ValueKey('large-rail'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      for (final (i, (code, label)) in boardStages.indexed)
                        Expanded(
                          child: _Stop(
                            label: tr(label),
                            gate: code == 'approval',
                            done: i < index,
                            current: i == index,
                            first: i == 0,
                            last: i == boardStages.length - 1,
                            colors: colors,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.xs),
                  // Wraps: the next step is never cut off.
                  Text(
                    [activity, ?secondText].join(' · '),
                    key: const ValueKey('large-rail-activity'),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
      ),
    );
  }
}

class _Stop extends StatelessWidget {
  const _Stop({
    required this.label,
    required this.gate,
    required this.done,
    required this.current,
    required this.first,
    required this.last,
    required this.colors,
  });

  final String label;
  final bool gate, done, current, first, last;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    final lit = done || current;
    final color = lit ? colors.primary : colors.outlineVariant;
    return Column(
      children: [
        SizedBox(
          height: 18,
          child: CustomPaint(
            painter: _StopPainter(
              color: color,
              line: colors.outlineVariant,
              lineDone: colors.primary,
              gate: gate,
              current: current,
              done: done,
              first: first,
              last: last,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            fontWeight: current ? FontWeight.w600 : FontWeight.w400,
            color: lit ? colors.onSurface : colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _StopPainter extends CustomPainter {
  _StopPainter({
    required this.color,
    required this.line,
    required this.lineDone,
    required this.gate,
    required this.current,
    required this.done,
    required this.first,
    required this.last,
  });

  final Color color, line, lineDone;
  final bool gate, current, done, first, last;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final stroke = Paint()..strokeWidth = 2;
    if (!first) {
      stroke.color = done || current ? lineDone : line;
      canvas.drawLine(Offset(0, c.dy), Offset(c.dx, c.dy), stroke);
    }
    if (!last) {
      stroke.color = done ? lineDone : line;
      canvas.drawLine(Offset(c.dx, c.dy), Offset(size.width, c.dy), stroke);
    }
    final paint = Paint()..color = color;
    final r = current ? 7.0 : 5.0;
    if (gate) {
      final path = Path()
        ..moveTo(c.dx, c.dy - r - 1)
        ..lineTo(c.dx + r + 1, c.dy)
        ..lineTo(c.dx, c.dy + r + 1)
        ..lineTo(c.dx - r - 1, c.dy)
        ..close();
      canvas.drawPath(path, paint);
    } else {
      canvas.drawCircle(c, r, paint);
    }
  }

  @override
  bool shouldRepaint(_StopPainter old) =>
      old.color != color ||
      old.line != line ||
      old.lineDone != lineDone ||
      old.current != current ||
      old.done != done ||
      old.gate != gate ||
      old.first != first ||
      old.last != last;
}

/// The Team tab's graph (task 089): Planning and Execution rows in launch
/// order; each member a box with a line to its explicitly chosen provider or
/// runtime, else an "Agent default" box; the marked member as on the card;
/// read only. One text line per member for screen readers.
class TeamGraph extends StatelessWidget {
  const TeamGraph({super.key, required this.project, required this.tr});

  final Map<String, dynamic> project;
  final String Function(String) tr;

  @override
  Widget build(BuildContext context) {
    final rows = [('planning', 'Planning'), ('execution', 'Execution')];
    return Column(
      key: const ValueKey('team-graph'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (phase, label) in rows) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.xs),
            child: Text(
              tr(label),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          _PhaseRow(project: project, phase: phase, tr: tr),
          const SizedBox(height: AppSpace.md),
        ],
      ],
    );
  }
}

class _PhaseRow extends StatelessWidget {
  const _PhaseRow({
    required this.project,
    required this.phase,
    required this.tr,
  });

  final Map<String, dynamic> project;
  final String phase;
  final String Function(String) tr;

  @override
  Widget build(BuildContext context) {
    final members = [
      for (final a in project[phase] as List? ?? const [])
        if (a is Map) a,
    ];
    if (members.isEmpty) {
      return Text(
        tr('No agents in this phase yet.'),
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    final active = project['active'] as Map?;
    final marked = active?['phase'] == phase ? active!['position'] : null;
    return Wrap(
      spacing: AppSpace.md,
      runSpacing: AppSpace.md,
      children: [
        for (final member in members)
          _MemberBox(
            member: member,
            state: marked is int && member['position'] == marked
                ? active!['state'] as String?
                : null,
            tr: tr,
          ),
      ],
    );
  }
}

class _MemberBox extends StatelessWidget {
  const _MemberBox({
    required this.member,
    required this.state,
    required this.tr,
  });

  final Map member;
  final String? state;
  final String Function(String) tr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final radius = BorderRadius.circular(corners(context));
    final name = '${member['name'] ?? member['agent'] ?? ''}';
    final initials = name
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    final role = tr(switch (member['role']) {
      'lead' => 'Lead agent',
      'implementer' => 'Implementer',
      'contributor' => 'Contributor',
      'reviewer' => 'Reviewer',
      _ => 'Agent',
    });
    // Only an explicit choice is drawn as a target; otherwise "Agent
    // default" (no guessed provider), with an explicit model beside it.
    String? text(Object? value) =>
        value is String && value.isNotEmpty ? value : null;
    final runtime = text(member['runtime']);
    final provider = text(member['provider']);
    final model = text(member['model']);
    final target = [?runtime, ?provider].join(' · ');
    final config = [
      target.isEmpty ? tr('Agent default') : target,
      ?model,
    ].join(' · ');
    final explicit = target.isNotEmpty;
    final stateText = switch (state) {
      'active' => tr('Working'),
      'stopping' => tr('Stopping'),
      'stopped' => tr('Stopped'),
      'next' => tr('Next'),
      _ => null,
    };
    final stateIcon = switch (state) {
      'active' => Icons.play_arrow,
      'stopping' => Icons.hourglass_bottom,
      'stopped' => Icons.stop,
      'next' => Icons.skip_next,
      _ => null,
    };
    final ring = switch (state) {
      'active' => colors.primary,
      'stopping' || 'stopped' => colors.error,
      'next' => colors.tertiary,
      _ => colors.outlineVariant,
    };
    final problems = [
      for (final issue in member['issues'] as List? ?? const [])
        if (issue is Map) tr(boardIssue(issue['code'] as String?)),
    ];
    final problem = problems.isEmpty ? null : problems.join(' · ');
    final phase = tr(member['phase'] == 'planning' ? 'Planning' : 'Execution');
    return Semantics(
      label: [phase, role, name, config, ?stateText, ?problem].join(', '),
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            flex: 3,
            child: Container(
              key: ValueKey(
                'graph-member-${member['phase']}-${member['position']}',
              ),
              constraints: const BoxConstraints(maxWidth: 220),
              padding: const EdgeInsets.all(AppSpace.sm),
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: ring, width: state == null ? 1 : 2.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        key: const ValueKey('graph-member-initials'),
                        radius: MediaQuery.textScalerOf(context).scale(12),
                        backgroundColor: colors.surfaceContainerHighest,
                        child: Text(
                          initials,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      const SizedBox(width: AppSpace.xs),
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    role,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                  // The state on its own line, with its symbol: never hidden
                  // behind a long role, never colour alone.
                  if (stateText != null)
                    Row(
                      key: const ValueKey('graph-member-state'),
                      children: [
                        Icon(stateIcon, size: 14, color: ring),
                        const SizedBox(width: AppSpace.xs),
                        Expanded(
                          child: Text(
                            stateText,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  if (problem != null)
                    Text(
                      problem,
                      key: const ValueKey('graph-member-issue'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
          // The line to the provider or runtime box.
          SizedBox(
            width: 20,
            child: Divider(
              thickness: 2,
              color: explicit ? colors.primary : colors.outlineVariant,
            ),
          ),
          Flexible(
            flex: 2,
            child: Container(
              key: ValueKey(
                'graph-target-${member['phase']}-${member['position']}',
              ),
              constraints: const BoxConstraints(maxWidth: 200),
              padding: const EdgeInsets.all(AppSpace.sm),
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: colors.outlineVariant),
                color: explicit
                    ? colors.primaryContainer.withValues(alpha: 0.4)
                    : null,
              ),
              child: Text(
                config,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
