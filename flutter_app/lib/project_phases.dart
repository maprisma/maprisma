import 'package:flutter/material.dart';

import 'app_look.dart';
import 'app_theme.dart' show corners;
import 'project_board.dart';

/// The board's Phases view (task 090): the six stages as columns of compact
/// cards, or a stacked list per stage in a small window. Navigation only: a
/// card opens its project; nothing here changes a status.
class PhasesBoard extends StatelessWidget {
  const PhasesBoard({
    super.key,
    required this.projects,
    required this.tr,
    required this.onOpen,
    this.cardFocus,
    this.onPress,
  });

  /// The shown projects (filtered), most urgent first.
  final List<Map<String, dynamic>> projects;
  final String Function(String) tr;
  final void Function(Map<String, dynamic> project) onOpen;
  final FocusNode Function(String id)? cardFocus;
  final void Function(String id, bool down)? onPress;

  /// The projects per stage, in board order; an unknown stage counts as Goal
  /// (a project is never lost from the view).
  static Map<String, List<Map<String, dynamic>>> byStage(
    List<Map<String, dynamic>> projects,
  ) {
    final known = {for (final (code, _) in boardStages) code};
    final out = {
      for (final (code, _) in boardStages) code: <Map<String, dynamic>>[],
    };
    for (final p in projects) {
      final stage = p['stage'];
      out[known.contains(stage) ? stage as String : 'goal']!.add(p);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final groups = byStage(projects);
    return LayoutBuilder(
      builder: (context, box) {
        // Six readable columns, wider with larger text.
        final column = 170 * MediaQuery.textScalerOf(context).scale(16) / 16;
        final wide =
            box.maxWidth >= boardStages.length * column + 7 * AppSpace.sm;
        if (projects.isEmpty) {
          return Center(
            key: const ValueKey('phases-empty'),
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.md),
              child: Text(tr('No projects here.'), textAlign: TextAlign.center),
            ),
          );
        }
        return wide ? _columns(context, groups) : _stacked(context, groups);
      },
    );
  }

  Widget _card(Map<String, dynamic> project, String stageLabel) {
    final id = '${project['id']}';
    return Listener(
      key: ValueKey('project-press-$id'),
      onPointerDown: (_) => onPress?.call(id, true),
      onPointerUp: (_) => onPress?.call(id, false),
      onPointerCancel: (_) => onPress?.call(id, false),
      child: PhaseCard(
        key: ValueKey('phase-card-$id'),
        project: project,
        stage: stageLabel,
        tr: tr,
        focusNode: cardFocus?.call(id),
        onOpen: () => onOpen(project),
      ),
    );
  }

  Widget _header(BuildContext context, String code, String label, int count) {
    final theme = Theme.of(context);
    return Semantics(
      key: ValueKey('phase-header-$code'),
      header: true,
      label: '$label, ${tr('{0} projects').replaceAll('{0}', '$count')}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
            const SizedBox(width: AppSpace.xs),
            Text(
              '$count',
              key: ValueKey('phase-count-$code'),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _columns(
    BuildContext context,
    Map<String, List<Map<String, dynamic>>> groups,
  ) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      key: const ValueKey('phases-columns'),
      padding: const EdgeInsets.all(AppSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, (code, label)) in boardStages.indexed) ...[
            if (i > 0) const SizedBox(width: AppSpace.sm),
            Expanded(
              child: DecoratedBox(
                key: ValueKey('phase-column-$code'),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(corners(context)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(context, code, tr(label), groups[code]!.length),
                      Expanded(
                        // All cards built (at most 64 projects), so a card
                        // can be scrolled to and focused.
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final p in groups[code]!) ...[
                                _card(p, tr(label)),
                                const SizedBox(height: AppSpace.sm),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stacked(
    BuildContext context,
    Map<String, List<Map<String, dynamic>>> groups,
  ) {
    return SingleChildScrollView(
      key: const ValueKey('phases-stacked'),
      padding: const EdgeInsets.all(AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (code, label) in boardStages)
            if (groups[code]!.isNotEmpty) ...[
              _header(context, code, tr(label), groups[code]!.length),
              for (final p in groups[code]!) ...[
                _card(p, tr(label)),
                const SizedBox(height: AppSpace.sm),
              ],
              const SizedBox(height: AppSpace.sm),
            ],
        ],
      ),
    );
  }
}

/// A compact card in the Phases view: title, bucket symbol and activity, the
/// second line. Opens its project; no quick actions.
class PhaseCard extends StatelessWidget {
  const PhaseCard({
    super.key,
    required this.project,
    required this.stage,
    required this.tr,
    required this.onOpen,
    this.focusNode,
  });

  final Map<String, dynamic> project;

  /// The stage's name as shown (for screen readers).
  final String stage;
  final String Function(String) tr;
  final VoidCallback onOpen;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = '${project['title'] ?? ''}';
    final activity = tr(boardActivity(project['activity'] as String?));
    final second = switch (project['second']) {
      'check_changes_first' => tr('Check the changes first'),
      'approve_again' => tr('Approve again'),
      _ => null,
    };
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        focusNode: focusNode,
        onTap: onOpen,
        // The InkWell keeps its tap and focus for screen readers; they read
        // one line instead of the parts.
        child: Semantics(
          button: true,
          label: [title, stage, activity, ?second].join(', '),
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(boardBucketIcon(project['bucket']), size: 14),
                      const SizedBox(width: AppSpace.xs),
                      Expanded(
                        child: Text(
                          activity,
                          key: const ValueKey('phase-card-activity'),
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                  if (second != null)
                    Text(
                      second,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
