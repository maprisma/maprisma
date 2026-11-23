import 'package:flutter/material.dart';

/// What a chosen agent profile can and cannot do in a project, from the
/// facts of its managed profile (adapters' `[project]` table): the symbol
/// beside the agent of a team member, its hint on hover, long press, tap,
/// Enter or Space.
class AgentAbilities {
  const AgentAbilities(this.can, this.cannot, this.here, this.details);

  final List<String> can, cannot;

  /// What this member does in this team: read-only or editing.
  final String here;

  /// The profile's own permissions sentence (the adapter's text).
  final String details;

  static AgentAbilities of(
    Map<String, dynamic> profile, {
    required String access,
    required String Function(String) tr,
  }) {
    // How it reads (all files, or only code structure like goose) is in the
    // profile's own sentence; the list only names what differs by profile.
    final can = <String>[];
    final cannot = <String>[];
    void add(bool yes, String text) => (yes ? can : cannot).add(tr(text));
    final modes =
        (profile['access_modes'] as List? ??
                const ['read-only', 'project-edit'])
            .cast<Object?>();
    bool option(Object? value) => value is String && value.startsWith('--');
    // Only a member whose access is really project-edit edits (a stale or
    // unknown value is refused by the core, so it is not editing either).
    final editing = modes.contains('project-edit') && access == 'project-edit';
    if (!modes.contains('project-edit')) {
      cannot.add(tr('Edit project files'));
    } else if (!editing) {
      // The profile could, but this member works read-only.
      cannot.add(tr('Edit project files (read-only in this team)'));
    } else {
      can.add(tr('Edit project files'));
    }
    // The same conditions the core checks before it starts the agent.
    final model = option(profile['model_option']);
    add(model, 'Choose a model');
    add(
      model && option(profile['provider_option']),
      'Use a local LLM from the map',
    );
    final definitions = profile['subagent_definitions'];
    add(
      profile['native_subagents'] == true &&
          option(profile['subagent_option']) &&
          definitions is Map &&
          definitions.isNotEmpty,
      'Use native subagents',
    );
    final setup = profile['setup_argv'];
    add(setup is List && setup.isNotEmpty, 'Propose a team');
    final details = '${profile['permissions'] ?? ''}'.trim();
    return AgentAbilities(
      can,
      cannot,
      tr(
        editing
            ? 'In this team: edits project files'
            : 'In this team: read-only',
      ),
      details.isEmpty ? '' : tr(details),
    );
  }

  String get text => [
    here,
    '',
    for (final c in can) '✓ $c',
    for (final c in cannot) '✗ $c',
    if (details.isNotEmpty) ...['', details],
  ].join('\n');
}

class AgentAbilityHint extends StatefulWidget {
  const AgentAbilityHint({
    super.key,
    required this.profile,
    required this.access,
    required this.tr,
  });

  final Map<String, dynamic>? profile;
  final String access;
  final String Function(String) tr;

  @override
  State<AgentAbilityHint> createState() => _AgentAbilityHintState();
}

class _AgentAbilityHintState extends State<AgentAbilityHint> {
  final _tooltip = GlobalKey<TooltipState>();

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    final chosen = widget.profile;
    final message = chosen == null
        ? tr('Choose an agent to see what it can do.')
        : AgentAbilities.of(chosen, access: widget.access, tr: tr).text;
    // A focusable button: hover, long press, tap, Enter or Space shows it;
    // a screen reader reads the whole hint.
    return Tooltip(
      key: _tooltip,
      message: message,
      triggerMode: TooltipTriggerMode.longPress,
      showDuration: const Duration(seconds: 12),
      constraints: const BoxConstraints(maxWidth: 420),
      excludeFromSemantics: true,
      child: IconButton(
        key: const ValueKey('agent-ability-hint'),
        // Label and hint on the button's own node for screen readers.
        icon: Semantics(
          hint: message,
          child: Icon(
            Icons.shield_outlined,
            size: 20,
            semanticLabel: tr('What this agent can and cannot do'),
          ),
        ),
        onPressed: () => _tooltip.currentState?.ensureTooltipVisible(),
      ),
    );
  }
}
