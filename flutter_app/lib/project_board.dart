import 'package:flutter/material.dart';

import 'app_look.dart';
import 'project_phases.dart';

/// The filters of the Projects board, in the core's bucket order (task 088).
enum BoardFilter {
  running('running', 'Running', Icons.play_arrow),
  attention('attention', 'Attention', Icons.error_outline),
  needsYou('needs_you', 'Needs you', Icons.front_hand_outlined),
  ready('ready', 'Ready', Icons.check_circle_outline),
  drafts('drafts', 'Drafts', Icons.edit_note),
  finished('finished', 'Agents finished', Icons.flag_outlined);

  const BoardFilter(this.code, this.label, this.icon);

  /// The bucket's machine code in the board projection.
  final String code;
  final String label;
  final IconData icon;
}

/// The board's two views (task 090): cards, or stage columns.
enum BoardView {
  cards('Cards', Icons.grid_view),
  phases('Phases', Icons.view_column_outlined);

  const BoardView(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// A bucket's symbol (the filter's).
IconData boardBucketIcon(Object? bucket) => BoardFilter.values
    .firstWhere((f) => f.code == bucket, orElse: () => BoardFilter.drafts)
    .icon;

/// The stage rail's stops, as the core names them.
const boardStages = [
  ('goal', 'Goal'),
  ('plan', 'Plan'),
  ('approval', 'Approval'),
  ('ready', 'Ready'),
  ('run', 'Run'),
  ('finished', 'Agents finished'),
];

/// An activity code as the user reads it.
String boardActivity(String? code) => switch (code) {
  'stopping' => 'Stopping',
  'setting_up_team' => 'Setting up team',
  'planning' => 'Planning',
  'reviewing_plan' => 'Reviewing plan',
  'reviewing' => 'Reviewing',
  'running' => 'Running',
  'paused' => 'Paused',
  'interrupted' => 'Interrupted',
  'failed' => 'Failed',
  'needs_review' => 'Needs your review',
  'approve_again' => 'Approve again',
  'approved_blocked' => 'Approved · blocked',
  'ready_to_run' => 'Approved, ready to run',
  'agents_finished' => 'Agents finished',
  _ => 'Draft',
};

/// An issue code as the user reads it.
String boardIssue(String? code) => switch (code) {
  'folder_missing' => 'The folder is missing',
  'folder_changed' => 'The folder has changed',
  'no_lead' => 'No lead agent',
  'empty_goal' => 'No goal yet',
  'agent_unavailable' => 'An agent is not available',
  'profile_invalid' => 'An agent profile cannot start',
  'runtime_stopped' => 'A local runtime is stopped',
  'model_unavailable' => 'A model is not available',
  'provider_unavailable' => 'A provider is not available',
  'runtime_required' => 'A model needs its local runtime',
  _ => 'Cannot start as it is',
};

/// Where an issue is fixed (task 092): `map` only with a box to go to and a
/// shell that can go there ([map]); else the project's `goal` or `team` tab
/// (an older backend without `fix`: team).
String issueFix(Map issue, {bool map = true}) {
  final fix = issue['fix'];
  final node = issue['node'];
  if (fix == 'map' && map && node is String && node.isNotEmpty) return 'map';
  if (fix == 'goal') return 'goal';
  return 'team';
}

/// The link's words for [issueFix]'s answer.
String issueFixLabel(String fix) => switch (fix) {
  'map' => 'Fix on map',
  'goal' => 'Go to Goal',
  _ => 'Go to Team',
};

/// The Projects board: the summary row with its filters and the project
/// cards (docs/plan-main-layout.md, "Projects tab: the board").
class ProjectBoard extends StatelessWidget {
  const ProjectBoard({
    super.key,
    required this.projects,
    required this.tr,
    required this.onOpen,
    required this.onNew,
    required this.onReview,
    required this.onPause,
    this.filter,
    this.onFilter,
    this.busyIds = const {},
    this.cardFocus,
    this.eventText,
    this.unavailable = false,
    this.onPress,
    this.controller,
    this.newFocus,
    this.reveal,
    this.onRevealed,
    this.view = BoardView.cards,
    this.onView,
    this.agentName,
    this.onClearAgent,
    this.onFix,
    this.mapFix = false,
  });

  /// An issue's link on a card (task 092); [mapFix]: Fix on map is possible.
  final void Function(Map<String, dynamic> project, Map issue)? onFix;
  final bool mapFix;

  /// The agent chip (from the map's "Used in N projects", task 091): the
  /// projects are already narrowed to that agent; × or All clears it.
  final String? agentName;
  final VoidCallback? onClearAgent;

  /// Cards or Phases (navigation only).
  final BoardView view;
  final ValueChanged<BoardView>? onView;

  /// The board projection, most urgent first.
  final List<Map<String, dynamic>> projects;
  final String Function(String) tr;
  final BoardFilter? filter;
  final ValueChanged<BoardFilter?>? onFilter;
  final void Function(Map<String, dynamic> project) onOpen;
  final VoidCallback? onNew;
  final void Function(Map<String, dynamic> project) onReview;
  final void Function(Map<String, dynamic> project) onPause;

  /// Projects with a quick action on its way (a second click does nothing).
  final Set<String> busyIds;

  /// The focus node of a card (focus returns to it from the project page).
  final FocusNode Function(String id)? cardFocus;

  /// A last event as the user reads it (the project page's translation).
  final String Function(Map<String, dynamic> event)? eventText;

  /// The list could not be read: counts say so instead of numbers.
  final bool unavailable;

  /// A pointer pressed (true) or released a card: the board holds its order
  /// meanwhile.
  final void Function(String id, bool down)? onPress;

  /// The grid's scroll position (the page keeps it across a project).
  final ScrollController? controller;

  /// New project's focus (where the keyboard goes when no card is left).
  final FocusNode? newFocus;

  /// A card to scroll into view (back from its project); [onRevealed] runs
  /// once it is built there.
  final String? reveal;
  final VoidCallback? onRevealed;

  /// The core files stopping projects under Running too.
  int _count(BoardFilter f) =>
      projects.where((p) => p['bucket'] == f.code).length;

  @override
  Widget build(BuildContext context) {
    final shown = filter == null
        ? projects
        : [
            for (final p in projects)
              if (p['bucket'] == filter!.code) p,
          ];
    return LayoutBuilder(
      builder: (context, box) {
        final narrow = box.maxWidth < 700;
        final columns = box.maxWidth >= 1100
            ? 3
            : box.maxWidth >= 700
            ? 2
            : 1;
        // Taller with larger text (the family's text size).
        final extent =
            (narrow ? 310 : 300) *
            MediaQuery.textScalerOf(context).scale(16) /
            16;
        final target = reveal;
        if (target != null && view == BoardView.phases) {
          // Every compact card is built: scroll its column or list to it.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            // Only a shown card (never a focus node for a gone one).
            final card = shown.any((p) => '${p['id']}' == target)
                ? cardFocus?.call(target).context
                : null;
            if (card != null && card.mounted) {
              Scrollable.ensureVisible(card, alignment: 0.5);
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => onRevealed?.call(),
              );
              WidgetsBinding.instance.scheduleFrame();
            } else {
              onRevealed?.call();
            }
          });
        } else if (target != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final index = shown.indexWhere((p) => '${p['id']}' == target);
            final scroll = controller;
            var moved = false;
            if (index >= 0 && scroll != null && scroll.hasClients) {
              // The card's real place, checked before any clamping.
              final top =
                  AppSpace.md + (index ~/ columns) * (extent + AppSpace.md);
              final viewport = scroll.position.viewportDimension;
              if (top < scroll.offset ||
                  top + extent > scroll.offset + viewport) {
                scroll.jumpTo(top.clamp(0.0, scroll.position.maxScrollExtent));
                moved = true;
              }
            }
            if (moved) {
              // Built there with the next frame (asked for), then focused.
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => onRevealed?.call(),
              );
              WidgetsBinding.instance.scheduleFrame();
            } else {
              onRevealed?.call();
            }
          });
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SummaryRow(
              counts: unavailable
                  ? null
                  : {for (final f in BoardFilter.values) f: _count(f)},
              total: projects.length,
              filter: filter,
              onFilter: onFilter,
              onNew: onNew,
              newFocus: newFocus,
              view: view,
              onView: onView,
              agentName: agentName,
              onClearAgent: onClearAgent,
              tr: tr,
            ),
            const Divider(height: 1),
            Expanded(
              child: projects.isEmpty && agentName == null
                  ? _EmptyBoard(onNew: onNew, tr: tr)
                  // A filter or the agent chip that leaves nothing.
                  : shown.isEmpty
                  ? Center(
                      key: const ValueKey('board-none'),
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpace.md),
                        child: Text(
                          tr('No projects here.'),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : view == BoardView.phases
                  ? PhasesBoard(
                      projects: shown,
                      tr: tr,
                      onOpen: onOpen,
                      cardFocus: cardFocus,
                      onPress: onPress,
                    )
                  : GridView.builder(
                      controller: controller,
                      // A refresh keeps each card's element by its id.
                      findChildIndexCallback: (key) {
                        if (key is! ValueKey<String>) return null;
                        final i = shown.indexWhere(
                          (p) => 'project-press-${p['id']}' == key.value,
                        );
                        return i < 0 ? null : i;
                      },
                      padding: const EdgeInsets.all(AppSpace.md),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: AppSpace.md,
                        crossAxisSpacing: AppSpace.md,
                        mainAxisExtent: extent,
                      ),
                      itemCount: shown.length,
                      itemBuilder: (context, i) {
                        final project = shown[i];
                        final id = '${project['id']}';
                        final card = ProjectCard(
                          key: ValueKey('project-card-$id'),
                          project: project,
                          tr: tr,
                          narrow: narrow,
                          busy: busyIds.contains(id),
                          focusNode: cardFocus?.call(id),
                          eventText: eventText,
                          onOpen: () => onOpen(project),
                          onReview: () => onReview(project),
                          onPause: () => onPause(project),
                          onFix: onFix == null
                              ? null
                              : (issue) => onFix!(project, issue),
                          mapFix: mapFix,
                        );
                        return Listener(
                          key: ValueKey('project-press-$id'),
                          onPointerDown: (_) => onPress?.call(id, true),
                          onPointerUp: (_) => onPress?.call(id, false),
                          onPointerCancel: (_) => onPress?.call(id, false),
                          child: card,
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.counts,
    required this.total,
    required this.filter,
    required this.onFilter,
    required this.onNew,
    required this.tr,
    this.newFocus,
    this.view = BoardView.cards,
    this.onView,
    this.agentName,
    this.onClearAgent,
  });

  final FocusNode? newFocus;
  final String? agentName;
  final VoidCallback? onClearAgent;
  final BoardView view;
  final ValueChanged<BoardView>? onView;

  /// Null while the list cannot be read (status unavailable, never zero).
  final Map<BoardFilter, int>? counts;
  final int total;
  final BoardFilter? filter;
  final ValueChanged<BoardFilter?>? onFilter;
  final VoidCallback? onNew;
  final String Function(String) tr;

  @override
  Widget build(BuildContext context) {
    Widget chip(BoardFilter? f) {
      final label = counts == null
          ? tr(f?.label ?? 'All')
          : '${tr(f?.label ?? 'All')} ${f == null ? total : counts![f] ?? 0}';
      return Padding(
        padding: const EdgeInsets.only(right: AppSpace.xs),
        child: FilterChip(
          key: ValueKey('board-filter-${f?.code ?? 'all'}'),
          avatar: Icon(f?.icon ?? Icons.apps, size: 16),
          label: Text(label),
          selected: filter == f,
          showCheckmark: false,
          onSelected: onFilter == null
              ? null
              // Chosen again clears; All resets both filter and agent.
              : (_) {
                  onFilter!(filter == f ? null : f);
                  if (f == null) onClearAgent?.call();
                },
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, box) {
        // Names only with room for them (larger text needs more).
        final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
        return _row(
          context,
          box.maxWidth < 600 * scale,
          chip,
          named: box.maxWidth >= 1000 * scale,
        );
      },
    );
  }

  Widget _row(
    BuildContext context,
    bool narrow,
    Widget Function(BoardFilter?) chip, {
    required bool named,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.sm,
      ),
      child: Row(
        children: [
          Expanded(
            // The filters scroll sideways in a narrow window.
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  if (agentName case final name?)
                    Padding(
                      padding: const EdgeInsets.only(right: AppSpace.xs),
                      child: InputChip(
                        key: const ValueKey('board-agent'),
                        avatar: const Icon(Icons.smart_toy_outlined, size: 16),
                        label: Text(name),
                        selected: true,
                        showCheckmark: false,
                        onDeleted: onClearAgent,
                        deleteButtonTooltipMessage: tr('Show all agents'),
                      ),
                    ),
                  chip(null),
                  for (final f in BoardFilter.values) chip(f),
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          // Cards | Phases; without room: symbols only (names as tooltips).
          SegmentedButton<BoardView>(
            key: const ValueKey('board-view'),
            showSelectedIcon: false,
            segments: [
              for (final v in BoardView.values)
                ButtonSegment(
                  value: v,
                  icon: Icon(v.icon, size: 18),
                  tooltip: named ? null : tr(v.label),
                  label: !named
                      ? null
                      : Text(
                          tr(v.label),
                          key: ValueKey('board-view-${v.name}'),
                        ),
                ),
            ],
            selected: {view},
            onSelectionChanged: onView == null
                ? null
                : (chosen) => onView!(chosen.first),
          ),
          const SizedBox(width: AppSpace.sm),
          // Narrow: the symbol only (its name as tooltip and label).
          if (narrow)
            IconButton.filledTonal(
              key: const ValueKey('board-new'),
              focusNode: newFocus,
              tooltip: tr('New project'),
              onPressed: onNew,
              icon: const Icon(Icons.add),
            )
          else
            FilledButton.tonalIcon(
              key: const ValueKey('board-new'),
              focusNode: newFocus,
              onPressed: onNew,
              icon: const Icon(Icons.add),
              label: Text(tr('New project')),
            ),
        ],
      ),
    );
  }
}

class _EmptyBoard extends StatelessWidget {
  const _EmptyBoard({required this.onNew, required this.tr});
  final VoidCallback? onNew;
  final String Function(String) tr;

  @override
  Widget build(BuildContext context) => Center(
    // Scrolls in a small window with large text.
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpace.md),
      child: Card(
        child: InkWell(
          key: const ValueKey('board-empty-new'),
          onTap: onNew,
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.add_circle_outline, size: 40),
                const SizedBox(height: AppSpace.sm),
                Text(
                  tr('New project'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpace.xs),
                Text(
                  tr('Give a team of agents a goal and a folder.'),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// One project on the board.
class ProjectCard extends StatelessWidget {
  const ProjectCard({
    super.key,
    required this.project,
    required this.tr,
    required this.onOpen,
    required this.onReview,
    required this.onPause,
    this.narrow = false,
    this.busy = false,
    this.focusNode,
    this.eventText,
    this.onFix,
    this.mapFix = false,
  });

  /// The first issue's link (task 092): Fix on map, Go to Team or Goal.
  final ValueChanged<Map>? onFix;
  final bool mapFix;

  final Map<String, dynamic> project;
  final String Function(Map<String, dynamic> event)? eventText;
  final String Function(String) tr;
  final VoidCallback onOpen, onReview, onPause;
  final bool narrow, busy;
  final FocusNode? focusNode;

  static String shortPath(String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    return parts.length <= 2
        ? path
        : '…/${parts.sublist(parts.length - 2).join('/')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final activity = tr(boardActivity(project['activity'] as String?));
    final second = project['second'];
    final issues = [
      for (final i in project['issues'] as List? ?? const [])
        if (i is Map) tr(boardIssue(i['code'] as String?)),
    ];
    final firstIssue = [
      for (final i in project['issues'] as List? ?? const [])
        if (i is Map) i,
    ].firstOrNull;
    final event = project['last_event'];
    final active = project['active'] as Map?;
    final status = project['status'];
    // Pause while an assignment or the team setup runs; not while old
    // processes are still stopping.
    final canPause =
        (active?['state'] == 'active' ||
            project['activity'] == 'setting_up_team') &&
        status != 'pausing' &&
        project['processes_stopping'] != true;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        focusNode: focusNode,
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${project['title'] ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
              Text(
                shortPath('${project['path'] ?? ''}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpace.xs),
              Row(
                children: [
                  Icon(boardBucketIcon(project['bucket']), size: 16),
                  const SizedBox(width: AppSpace.xs),
                  Expanded(
                    child: Text(
                      activity,
                      key: const ValueKey('card-activity'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (second is String)
                Text(
                  tr(
                    second == 'check_changes_first'
                        ? 'Check the changes first'
                        : 'Approve again',
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              const SizedBox(height: AppSpace.sm),
              StageRail(
                stage: project['stage'] as String?,
                tr: tr,
                compact: narrow,
              ),
              const SizedBox(height: AppSpace.sm),
              TeamNodes(project: project, tr: tr, max: narrow ? 3 : 4),
              const Spacer(),
              if (issues.isNotEmpty)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        issues.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.error,
                        ),
                      ),
                    ),
                    if (onFix != null && firstIssue != null)
                      Flexible(
                        child: TextButton(
                          key: const ValueKey('card-fix'),
                          // As tall as the issue line: the card's height is
                          // fixed.
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            minimumSize: const Size(0, 24),
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpace.xs,
                            ),
                          ),
                          onPressed: () => onFix!(firstIssue),
                          child: Text(
                            tr(
                              issueFixLabel(issueFix(firstIssue, map: mapFix)),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                  ],
                ),
              if (event is Map)
                Text(
                  _eventLine(context, Map<String, dynamic>.from(event)),
                  key: const ValueKey('card-event'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              const SizedBox(height: AppSpace.xs),
              Row(
                children: [
                  _action('card-open', 'Open', onOpen),
                  if (project['activity'] == 'needs_review')
                    _action('card-review', 'Review plan', onReview),
                  if (canPause || status == 'pausing')
                    _action(
                      'card-pause',
                      status == 'pausing' ? 'Retry pause' : 'Pause',
                      busy ? null : onPause,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A quick action that shortens its label rather than overflow.
  Widget _action(String key, String label, VoidCallback? onPressed) => Flexible(
    child: TextButton(
      key: ValueKey(key),
      onPressed: onPressed,
      child: Text(tr(label), maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
  );

  /// The last event in the user's language, with its time (today: the
  /// time; earlier: the date).
  String _eventLine(BuildContext context, Map<String, dynamic> event) {
    final text = eventText?.call(event) ?? '${event['text'] ?? ''}';
    final at = DateTime.tryParse('${event['at'] ?? ''}')?.toLocal();
    if (at == null) return text;
    final local = MaterialLocalizations.of(context);
    final now = DateTime.now();
    final today =
        at.year == now.year && at.month == now.month && at.day == now.day;
    final when = today
        ? local.formatTimeOfDay(TimeOfDay.fromDateTime(at))
        : local.formatShortMonthDay(at);
    return '$when · $text';
  }
}

/// The stage rail: six stops, the current one lit, Approval drawn as a gate;
/// its text names the current stage (screen readers read it).
class StageRail extends StatelessWidget {
  const StageRail({
    super.key,
    required this.stage,
    required this.tr,
    this.compact = false,
  });

  final String? stage;
  final String Function(String) tr;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final index = boardStages.indexWhere((s) => s.$1 == stage);
    final label = index < 0 ? '' : tr(boardStages[index].$2);
    return Semantics(
      label: '${tr('Stage')}: $label',
      excludeSemantics: true,
      child: Row(
        children: [
          SizedBox(
            width: compact ? 90 : 132,
            height: 14,
            child: CustomPaint(
              painter: _RailPainter(
                current: index,
                lit: colors.primary,
                dim: colors.outlineVariant,
              ),
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              label,
              key: const ValueKey('card-stage'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _RailPainter extends CustomPainter {
  _RailPainter({required this.current, required this.lit, required this.dim});
  final int current;
  final Color lit, dim;

  @override
  void paint(Canvas canvas, Size size) {
    final n = boardStages.length;
    final step = (size.width - 10) / (n - 1);
    final y = size.height / 2;
    final line = Paint()
      ..strokeWidth = 2
      ..color = dim;
    canvas.drawLine(Offset(5, y), Offset(size.width - 5, y), line);
    for (var i = 0; i < n; i++) {
      final c = Offset(5 + i * step, y);
      final paint = Paint()..color = i <= current ? lit : dim;
      if (boardStages[i].$1 == 'approval') {
        // The gate: a small diamond.
        final path = Path()
          ..moveTo(c.dx, c.dy - 5)
          ..lineTo(c.dx + 5, c.dy)
          ..lineTo(c.dx, c.dy + 5)
          ..lineTo(c.dx - 5, c.dy)
          ..close();
        canvas.drawPath(path, paint);
      } else {
        canvas.drawCircle(c, i == current ? 5 : 3.5, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.current != current || old.lit != lit || old.dim != dim;
}

/// The team as nodes: execution (planning before a plan exists), at most
/// [max] with "+N"; the active, stopping, stopped or next one always shown.
class TeamNodes extends StatelessWidget {
  const TeamNodes({
    super.key,
    required this.project,
    required this.tr,
    this.max = 4,
  });

  final Map<String, dynamic> project;
  final String Function(String) tr;
  final int max;

  @override
  Widget build(BuildContext context) {
    final active = project['active'] as Map?;
    final phase =
        active?['phase'] as String? ??
        (const {'goal', 'plan'}.contains(project['stage'])
            ? 'planning'
            : 'execution');
    final setup = project['phase'] == 'setup' && project['setup_agent'] is Map;
    final team = [
      // In a team setup its helper comes first (the core marks no member).
      if (setup)
        {
          'agent': (project['setup_agent'] as Map)['agent'],
          'name': (project['setup_agent'] as Map)['name'],
          'role': 'setup',
          'issues': const [],
        },
      for (final a
          in (project[phase] as List?)?.isNotEmpty == true
              ? project[phase] as List
              // A draft without its planning team yet: the other one.
              : project[phase == 'planning' ? 'execution' : 'planning']
                        as List? ??
                    const [])
        if (a is Map) a,
    ];
    if (team.isEmpty) return const SizedBox(height: 40);
    final setupState = switch (project['activity']) {
      'setting_up_team' => 'active',
      'stopping' => 'stopping',
      'paused' || 'interrupted' || 'failed' => 'stopped',
      _ => null,
    };
    final raw = setup
        ? 0
        : active?['phase'] == phase
        ? active!['position']
        : null;
    final position = raw is int && raw >= 0 && raw < team.length ? raw : null;
    final markedState = setup ? setupState : active?['state'] as String?;
    // The first [max] members, but the marked one always among them.
    var shown = team.take(max).toList();
    if (position != null && !shown.contains(team[position])) {
      shown = [...shown.take(max - 1), team[position]];
    }
    final more = team.length - shown.length;
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (final member in shown)
          Expanded(
            child: _Node(
              member: member,
              state: position != null && member == team[position]
                  ? markedState
                  : null,
              tr: tr,
              colors: colors,
            ),
          ),
        if (more > 0)
          Padding(
            padding: const EdgeInsets.only(left: AppSpace.xs),
            child: Text('+$more', key: const ValueKey('team-more')),
          ),
      ],
    );
  }
}

class _Node extends StatelessWidget {
  const _Node({
    required this.member,
    required this.state,
    required this.tr,
    required this.colors,
  });

  final Map member;
  final String? state;
  final String Function(String) tr;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    final name = '${member['name'] ?? member['agent'] ?? ''}';
    final initials = name
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    final detail = member['model'] ?? member['runtime'] ?? member['provider'];
    final config = detail is String && detail.isNotEmpty
        ? detail
        : tr('Agent default');
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
    final role = tr(switch (member['role']) {
      'lead' => 'Lead agent',
      'implementer' => 'Implementer',
      'contributor' => 'Contributor',
      'reviewer' => 'Reviewer',
      'setup' => 'Setup helper',
      _ => 'Agent',
    });
    // The marked member says in which phase it works.
    final phase = state == null || member['role'] == 'setup'
        ? null
        : tr(member['phase'] == 'planning' ? 'Planning' : 'Execution');
    final issues = member['issues'] as List? ?? const [];
    final size = MediaQuery.textScalerOf(context).scale(32);
    return Semantics(
      label: [
        name,
        ?phase,
        role,
        config,
        ?stateText,
        if (issues.isNotEmpty) tr('has a problem'),
      ].join(', '),
      excludeSemantics: true,
      child: Tooltip(
        message: [?phase, role, config, ?stateText].join(' · '),
        child: Padding(
          padding: const EdgeInsets.only(right: AppSpace.xs),
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: size,
                    height: size,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: ring,
                        width: state == null ? 1 : 2.5,
                      ),
                    ),
                    child: Text(initials, style: const TextStyle(fontSize: 12)),
                  ),
                  if (stateIcon != null)
                    Positioned(
                      right: -4,
                      bottom: -4,
                      child: Icon(stateIcon, size: 14, color: ring),
                    ),
                  if (issues.isNotEmpty)
                    Positioned(
                      right: -4,
                      top: -4,
                      child: Icon(
                        Icons.error,
                        key: const ValueKey('node-issue'),
                        size: 14,
                        color: colors.error,
                      ),
                    ),
                ],
              ),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
              // The configuration stays visible; the state is the ring, its
              // symbol and the label read out.
              Text(
                config,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
