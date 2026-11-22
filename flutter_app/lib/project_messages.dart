import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_look.dart';
import 'app_theme.dart';

/// What the last message action of a project ended with (task 096), shown
/// under its box; an [error] in the error colour. The page keeps it per
/// project, so it survives switching tabs.
class MessageNote {
  const MessageNote(this.text, {this.error = false});
  final String text;
  final bool error;
}

/// The project statuses in which a message is accepted; Send now not while
/// pausing.
const messageStatuses = {'planning', 'running', 'reviewing', 'pausing'};

/// Messages to a running project (task 096): a box with **Send** (the next
/// assignment gets it; the agent at work keeps working) and **Send now**
/// (pauses the agent at work and continues at once with the message), and
/// the project's messages, waiting ones with a remove symbol.
class ProjectMessages extends StatefulWidget {
  const ProjectMessages({
    super.key,
    required this.project,
    required this.controller,
    required this.tr,
    required this.busy,
    this.working = false,
    this.sending = false,
    this.note,
    required this.onSend,
    required this.onDrop,
    this.agentName,
  });

  final Map<String, dynamic> project;

  /// The page keeps the draft (it survives switching tabs).
  final TextEditingController controller;
  final String Function(String) tr;
  final bool busy;

  /// The page waits for the backend (not for one of its questions).
  final bool working;

  /// A message action of this project is on its way (the page's state).
  final bool sending;
  final MessageNote? note;

  /// The page sends, clears the draft once it is stored and keeps the note:
  /// all of it also when this widget is gone meanwhile (another tab).
  final void Function(String text, {required bool now}) onSend;
  final void Function(String messageId) onDrop;

  /// An agent's display name from its profile id.
  final String Function(String agent)? agentName;

  /// The box is offered: the project's run is active (and not its team
  /// setup).
  static bool canSend(Map<String, dynamic>? project) =>
      project != null &&
      messageStatuses.contains(project['status']) &&
      project['run_id'] is String &&
      project['phase'] != 'setup';

  @override
  State<ProjectMessages> createState() => _ProjectMessagesState();
}

class _ProjectMessagesState extends State<ProjectMessages> {
  String tr(String key) => widget.tr(key);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(ProjectMessages old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  bool get _canSend => ProjectMessages.canSend(widget.project);
  bool get _hasText => widget.controller.text.trim().isNotEmpty;
  bool get _idle => !widget.busy && !widget.sending;
  bool get _enabled => _canSend && _hasText && _idle;
  bool get _nowEnabled => _enabled && widget.project['status'] != 'pausing';

  void _send({required bool now}) {
    if (!(now ? _nowEnabled : _enabled)) return;
    widget.onSend(widget.controller.text, now: now);
  }

  List<Map<String, dynamic>> get _messages => [
    for (final m in widget.project['messages'] as List? ?? const [])
      if (m is Map) Map<String, dynamic>.from(m),
  ];

  /// An implementer works as a contributor while planning.
  String _role(Object? role, {bool planning = false}) => tr(switch (role) {
    'lead' => 'Lead agent',
    'implementer' when planning => 'Contributor',
    'implementer' => 'Implementer',
    'reviewer' => 'Reviewer',
    'contributor' => 'Contributor',
    _ => '${role ?? ''}',
  });

  /// Today the time, earlier the date.
  String _when(BuildContext context, Object? at) {
    final time = DateTime.tryParse('${at ?? ''}')?.toLocal();
    if (time == null) return '';
    final local = MaterialLocalizations.of(context);
    final now = DateTime.now();
    final today =
        time.year == now.year && time.month == now.month && time.day == now.day;
    return today
        ? local.formatTimeOfDay(TimeOfDay.fromDateTime(time))
        : local.formatShortMonthDay(time);
  }

  String _state(BuildContext context, Map<String, dynamic> message) {
    if (message['state'] == 'delivered') {
      final to = message['delivered_to'];
      final when = _when(context, message['delivered_at'] ?? message['at']);
      if (to is! Map) {
        return [tr('Delivered'), if (when.isNotEmpty) when].join(' · ');
      }
      final agent = '${to['agent'] ?? ''}';
      final who = [
        if (agent.isNotEmpty) widget.agentName?.call(agent) ?? agent,
        if (to['role'] != null)
          _role(to['role'], planning: to['phase'] == 'planning'),
      ].join(' · ');
      final phase = tr(to['phase'] == 'planning' ? 'Planning' : 'Execution');
      final line = tr(
        'Delivered to {0} ({1})',
      ).replaceAll('{0}', who).replaceAll('{1}', phase);
      return [line, if (when.isNotEmpty) when].join(' · ');
    }
    final when = _when(context, message['at']);
    return [
      tr('Waiting for the next assignment'),
      if (when.isNotEmpty) when,
    ].join(' · ');
  }

  Widget _row(BuildContext context, Map<String, dynamic> message) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final waiting = message['state'] != 'delivered';
    final id = '${message['id'] ?? ''}';
    return Padding(
      key: ValueKey('project-message-$id'),
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            waiting ? Icons.schedule : Icons.done_all,
            size: 18,
            color: waiting ? colors.primary : colors.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  '${message['text'] ?? ''}',
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  _state(context, message),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (waiting && id.isNotEmpty)
            IconButton(
              key: const ValueKey('message-drop'),
              tooltip: tr('Remove message'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 18),
              onPressed: _idle ? () => widget.onDrop(id) : null,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final messages = _messages;
    final canSend = _canSend;
    final note = widget.note;
    if (!canSend && messages.isEmpty && note == null) {
      return const SizedBox.shrink();
    }
    final pausing = widget.project['status'] == 'pausing';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.lg),
      child: SectionCard(
        key: const ValueKey('project-messages'),
        title: tr('Message to the team'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (canSend) ...[
              CallbackShortcuts(
                bindings: {
                  const SingleActivator(
                    LogicalKeyboardKey.enter,
                    control: true,
                  ): () =>
                      _send(now: false),
                  const SingleActivator(
                    LogicalKeyboardKey.numpadEnter,
                    control: true,
                  ): () =>
                      _send(now: false),
                },
                child: TextField(
                  key: const ValueKey('message-text'),
                  controller: widget.controller,
                  minLines: 2,
                  maxLines: 6,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(
                    hintText: tr('Add instructions for the next step…'),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        cornerSizes(context).control,
                      ),
                    ),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.sm),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: AppSpace.sm,
                runSpacing: AppSpace.sm,
                children: [
                  Tooltip(
                    message: pausing
                        ? tr(
                            'The agent is stopping. Send waits for the continuation.',
                          )
                        : tr(
                            'Stops the agent at work and continues at once with your message.',
                          ),
                    child: OutlinedButton(
                      key: const ValueKey('message-send-now'),
                      onPressed: _nowEnabled ? () => _send(now: true) : null,
                      child: Text(tr('Send now')),
                    ),
                  ),
                  Tooltip(
                    message: tr(
                      'The next agent gets it; the one at work keeps working (Ctrl+Enter).',
                    ),
                    child: FilledButton(
                      key: const ValueKey('message-send'),
                      onPressed: _enabled ? () => _send(now: false) : null,
                      child: Text(tr('Send')),
                    ),
                  ),
                ],
              ),
            ],
            // Send now returns once the new agent started: show it works.
            if (widget.sending && widget.working)
              const Padding(
                padding: EdgeInsets.only(top: AppSpace.sm),
                child: LinearProgressIndicator(
                  key: ValueKey('message-progress'),
                ),
              ),
            if (note != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.sm),
                child: Text(
                  note.text,
                  key: const ValueKey('message-note'),
                  style: TextStyle(
                    color: note.error ? colors.error : colors.onSurface,
                  ),
                ),
              ),
            if (messages.isNotEmpty) ...[
              if (canSend || note != null)
                Divider(height: AppSpace.lg, color: colors.outlineVariant),
              for (final message in messages.reversed) _row(context, message),
            ],
          ],
        ),
      ),
    );
  }
}

/// The board card's count of waiting messages (task 096).
class MessagesBadge extends StatelessWidget {
  const MessagesBadge({super.key, required this.count, required this.tr});

  final int count;
  final String Function(String) tr;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label = count == 1
        ? tr('1 message waiting')
        : tr('{0} messages waiting').replaceAll('{0}', '$count');
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        excludeSemantics: true,
        child: Container(
          key: const ValueKey('card-messages'),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
          decoration: BoxDecoration(
            color: colors.secondaryContainer,
            borderRadius: BorderRadius.circular(cornerSizes(context).small),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.mail_outline,
                size: 14,
                color: colors.onSecondaryContainer,
              ),
              const SizedBox(width: AppSpace.xs),
              Text(
                '$count',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colors.onSecondaryContainer,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
