import 'dart:async';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart' show getDirectoryPath;
import 'package:maprisma_core/maprisma_core.dart' show ServiceError;

import 'app_look.dart';
import 'window_popup.dart';

typedef ProjectCenterCall =
    Future<Map<String, dynamic>> Function(
      String operation,
      Map<String, dynamic> params,
    );

class AiProjectCenterPage extends StatefulWidget {
  const AiProjectCenterPage({
    super.key,
    required this.onCall,
    required this.tr,
    required this.onBack,
    this.active = true,
    this.chooseFolder,
  });

  final ProjectCenterCall onCall;
  final String Function(String) tr;
  final VoidCallback onBack;
  final bool active;

  /// The native picker by default; tests can supply a controlled dialog.
  final Future<String?> Function()? chooseFolder;

  @override
  State<AiProjectCenterPage> createState() => AiProjectCenterPageState();
}

class AiProjectCenterPageState extends State<AiProjectCenterPage> {
  final _title = TextEditingController();
  final _brief = TextEditingController();
  final _path = TextEditingController();
  final _plan = TextEditingController();
  final _setupRequest = TextEditingController();
  List<Map<String, dynamic>> _projects = [],
      _profiles = [],
      _runTeam = [],
      _runtimes = [];
  List<Map<String, dynamic>>? _planTeam;
  String _phase = 'run';
  String? _setupAgent;
  final _setupDrafts = <String, String>{};
  List<Map<String, dynamic>> get _team =>
      _phase == 'plan' ? _planTeam ?? _runTeam : _runTeam;
  bool get _teamLocked =>
      _busy || _running || (_phase == 'plan' && _planTeam == null);
  Map<String, dynamic>? _project;
  int? _baseRevision;
  bool _dirty = false, _busy = false, _reading = false, _loaded = false;
  bool _confirming = false;
  String? _error;
  int _tab = 0;
  int _selection = 0;
  Timer? _timer;
  String tr(String key) => widget.tr(key);
  static const _active = {'planning', 'running', 'reviewing', 'pausing'};
  bool get hasActive =>
      _running || _projects.any((p) => _active.contains(p['status']));
  bool get _running => _active.contains(_project?['status']);

  @override
  void initState() {
    super.initState();
    for (final c in [_title, _brief, _path, _plan]) {
      c.addListener(_edited);
    }
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (widget.active && hasActive && !_busy) unawaited(_refresh());
    });
  }

  @override
  void didUpdateWidget(AiProjectCenterPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) unawaited(_refresh(profiles: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _setupRequest.dispose();
    for (final c in [_title, _brief, _path, _plan]) {
      c.dispose();
    }
    super.dispose();
  }

  void _edited() {
    if (!_dirty && mounted) setState(() => _dirty = true);
  }

  List<Map<String, dynamic>> _rows(Object? value) => value is List
      ? [
          for (final v in value)
            if (v is Map) Map<String, dynamic>.from(v),
        ]
      : [];

  void _adopt(Map<String, dynamic>? project) {
    _project = project;
    _title.text = '${project?['title'] ?? ''}';
    _brief.text = '${project?['brief'] ?? ''}';
    _path.text = '${project?['path'] ?? ''}';
    _plan.text = '${project?['plan'] ?? ''}';
    _runTeam = _rows(project?['team']);
    _planTeam = project?['plan_team'] is List
        ? _rows(project?['plan_team'])
        : null;
    if (project == null && _profiles.isNotEmpty) {
      _runTeam = [
        {
          'agent': _profiles.first['id'],
          'role': 'lead',
          'instructions': '',
          'access':
              (_profiles.first['access_modes'] as List? ??
                      ['read-only', 'project-edit'])
                  .last,
        },
      ];
    }
    for (final team in [_runTeam, ?_planTeam]) {
      for (final member in team) {
        final profile = _profiles
            .where((p) => p['id'] == member['agent'])
            .firstOrNull;
        if (!member.containsKey('access') &&
            (profile?['access_modes'] as List? ?? []).length == 1) {
          member['access'] = (profile!['access_modes'] as List).single;
        }
      }
    }
    _baseRevision = project?['revision'] as int?;
    _restoreSetupRequest();
    _dirty = false;
  }

  void _restoreSetupRequest() {
    final key = '${_project?['id'] ?? 'new'}:$_phase';
    final requests = _project?['setup_requests'];
    _setupRequest.text =
        _setupDrafts[key] ??
        (requests is Map
            ? '${requests[_phase] ?? ''}'
            : '${_project?['setup_request'] ?? ''}');
  }

  void _changePhase(String phase) => setState(() {
    _setupDrafts['${_project?['id'] ?? 'new'}:$_phase'] = _setupRequest.text;
    _phase = phase;
    _selection++;
    _restoreSetupRequest();
  });

  String _failure(Object error) {
    if (error is ServiceError) {
      return tr(switch (error.code) {
        'project_changed' ||
        'project_conflict' ||
        'revision_conflict' => 'This project changed. Reload it before saving.',
        'project_unknown' ||
        'project_not_found' => 'The project could not be found.',
        'project_already_running' ||
        'project_busy' => 'This project is already running.',
        'project_plan_not_approved' ||
        'project_unapproved' ||
        'plan_not_approved' => 'Review and approve this plan before running.',
        'project_folder_unavailable' || 'project_folder_changed' =>
          'The working folder is unavailable or changed.',
        'project_folder_busy' => 'Another project is working in this folder.',
        'project_lead_required' => 'Choose exactly one lead agent.',
        'project_agent_unavailable' => 'A selected agent is unavailable.',
        'project_setup_agent_omitted' ||
        'project_setup_runtime_omitted' ||
        'project_setup_exclusion_unexplained' =>
          'The proposed setup omitted a requested agent or runtime. Revise the request or review the exclusions.',
        'project_setup_invalid' || 'project_setup_proposal_unknown' =>
          'The AI setup proposal could not be validated. Review the helper output and try again.',
        'project_setup_model_unknown' =>
          'A selected model or runtime is unavailable.',
        'project_setup_helper_unavailable' => 'No setup helper is available.',
        'project_model_unavailable' ||
        'project_runtime_unavailable' ||
        'project_runtime_invalid' ||
        'project_model_unsupported' ||
        'project_runtime_model_unavailable' ||
        'project_provider_unsupported' ||
        'project_runtime_required' =>
          'A selected model or runtime is unavailable.',
        'project_access_unsupported' =>
          'Choose a supported access mode before saving.',
        'project_review_changes_first' =>
          'Review existing changes before changing this setup.',
        'project_still_pausing' || 'project_processes_still_running' =>
          'Some agent processes are still stopping. Try again shortly.',
        'project_setup_agent_failed' =>
          'Team setup ended without a proposal. The project is unchanged.',
        'project_store_unavailable' ||
        'project_store_full' ||
        'project_store_corrupt' =>
          'The saved project store is unavailable. Check the saved state before continuing.',
        _ => 'The project operation failed.',
      });
    }
    return tr('The project operation failed.');
  }

  Future<void> _refresh({bool profiles = false}) async {
    if (_reading) return;
    _reading = true;
    final selection = _selection;
    final id = _project?['id'];
    try {
      final results = await Future.wait([
        widget.onCall('list', {}),
        if (!_loaded || profiles) widget.onCall('profiles', {}),
      ]);
      final selected = id == null
          ? null
          : (await widget.onCall('get', {'id': id}))['project'];
      if (!mounted) return;
      setState(() {
        _projects = _rows(results[0]['projects']);
        if (results.length > 1) {
          _profiles = _rows(results[1]['profiles']);
          _runtimes = _rows(results[1]['runtimes']);
        }
        if (selected is Map &&
            !_busy &&
            selection == _selection &&
            id == _project?['id']) {
          if (_dirty) {
            _project = Map<String, dynamic>.from(selected);
          } else {
            _adopt(Map<String, dynamic>.from(selected));
          }
        }
        _loaded = true;
      });
    } catch (error) {
      if (mounted) setState(() => _error = _failure(error));
    } finally {
      _reading = false;
    }
  }

  Future<bool> _save() async {
    if (_title.text.trim().isEmpty ||
        _brief.text.trim().isEmpty ||
        _path.text.trim().isEmpty) {
      setState(() => _error = tr('Enter a title, goal and existing folder.'));
      return false;
    }
    try {
      final response = await widget.onCall('save', {
        if (_project != null) 'id': _project!['id'],
        if (_baseRevision != null) 'revision': _baseRevision,
        'title': _title.text.trim(),
        'brief': _brief.text.trim(),
        'path': _path.text.trim(),
        'plan': _plan.text,
        'team': _runTeam,
        'plan_team': _planTeam,
        'setup_requests': {
          for (final phase in ['plan', 'run'])
            phase:
                _setupDrafts['${_project?['id'] ?? 'new'}:$phase'] ??
                ((_project?['setup_requests'] as Map?)?[phase] ?? ''),
        },
      });
      if (!mounted) return false;
      setState(() {
        final prefix = '${_project?['id'] ?? 'new'}:';
        _setupDrafts.removeWhere((key, _) => key.startsWith(prefix));
        _adopt(Map<String, dynamic>.from(response['project'] as Map));
        _error = null;
      });
      await _refresh();
      return true;
    } catch (error) {
      if (mounted) setState(() => _error = _failure(error));
      return false;
    }
  }

  /// The shell calls this before switching pages or closing the window.
  Future<bool> beforeLeave() async {
    if (_busy) return false;
    if (!_dirty) return true;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Save project changes?')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: Text(tr('Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: Text(tr('Discard')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: Text(tr('Save')),
          ),
        ],
      ),
    );
    if (choice == 'discard') {
      if (mounted) {
        setState(() {
          final prefix = '${_project?['id'] ?? 'new'}:';
          _setupDrafts.removeWhere((key, _) => key.startsWith(prefix));
          _adopt(_project);
        });
      }
      return true;
    }
    return choice == 'save' && await _save();
  }

  Future<void> _choose(Map<String, dynamic>? project) async {
    if (!await beforeLeave() || !mounted) return;
    setState(() {
      _selection++;
      _busy = project != null;
      _error = null;
      if (project == null) {
        _setupDrafts.removeWhere((key, _) => key.startsWith('new:'));
      }
    });
    try {
      final result = project == null
          ? null
          : Map<String, dynamic>.from(
              (await widget.onCall('get', {'id': project['id']}))['project']
                  as Map,
            );
      if (mounted) {
        setState(() {
          _adopt(result);
          _tab = 0;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = _failure(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String text, String action) async {
    setState(() => _confirming = true);
    try {
      return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(tr(title)),
              content: Text(tr(text)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(tr('Cancel')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(tr(action)),
                ),
              ],
            ),
          ) ==
          true;
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  Future<void> _perform(String operation) async {
    if (_busy) return;
    final setupText = _setupRequest.text;
    final setupTarget = _phase;
    final setupAgent = _setupHelper;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (operation == 'save') {
        await _save();
        return;
      }
      if ((_dirty || _project == null) && !await _save()) return;
      if (!mounted) return;
      if (operation == 'delete' &&
          !await _confirm(
            'Delete saved project?',
            'The saved project will be removed. Its working folder is kept.',
            'Delete',
          )) {
        return;
      }
      if (operation == 'review' &&
          !await _confirm(
            'Approve this plan?',
            'Review the plan, team, working folder and permissions before approving. Approval applies to this saved plan version.',
            'Approve plan',
          )) {
        return;
      }
      if ((operation == 'continue' ||
              operation == 'run' &&
                  _project?['needs_reconciliation'] == true) &&
          !await _confirm(
            'Continue from saved handoff?',
            'Review existing changes and output first. This starts a new agent session with the saved handoff; incomplete actions may already have changed files.',
            'I reviewed the existing changes',
          )) {
        return;
      }
      final result = await widget.onCall(operation, {
        'id': _project!['id'],
        'revision': _project!['revision'],
        if (operation == 'pause' && _project!['run_id'] != null)
          'run_id': _project!['run_id'],
        if (operation == 'review') 'approved': true,
        if (operation == 'continue') 'acknowledge_interrupted': true,
        if (operation == 'run' && _project?['needs_reconciliation'] == true)
          'acknowledge_interrupted': true,
        if (operation == 'setup') ...{
          'request': setupText,
          'target': setupTarget,
          'agent': ?setupAgent,
        },
      });
      if (!mounted) return;
      setState(() {
        if (operation == 'delete') {
          _adopt(null);
        } else if (result['project'] is Map) {
          if (operation == 'setup_apply') {
            _phase = (_project?['setup_proposal'] as Map?)?['target'] == 'plan'
                ? 'plan'
                : 'run';
            _selection++;
          }
          _adopt(Map<String, dynamic>.from(result['project'] as Map));
          if (operation == 'plan') _tab = 1;
          if (operation == 'run' || operation == 'continue') _tab = 3;
          if (operation == 'setup_apply') _tab = 2;
        }
      });
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = _failure(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _status(Object? status) => tr(switch (status) {
    'planning' => 'Planning',
    'running' => 'Running',
    'reviewing' => 'Reviewing',
    'pausing' => 'Pausing',
    'waiting' => 'Needs attention',
    'awaiting_review' => 'Needs review',
    'paused' => 'Paused',
    'interrupted' => 'Interrupted',
    'completed' || 'done' => 'Completed',
    'failed' => 'Failed',
    'ready' => 'Ready',
    _ => 'Draft',
  });

  Widget _projectList() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.all(AppSpace.sm),
        child: FilledButton.tonalIcon(
          onPressed: _busy ? null : () => _choose(null),
          icon: const Icon(Icons.add),
          label: Text(tr('New project')),
        ),
      ),
      Expanded(
        child: _projects.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(AppSpace.lg),
                child: Text(tr('No saved projects.')),
              )
            : ListView(
                children: [
                  for (final project in _projects)
                    ListTile(
                      selected: project['id'] == _project?['id'],
                      leading: const Icon(Icons.account_tree_outlined),
                      title: Text('${project['title']}'),
                      subtitle: Text(_status(project['status'])),
                      onTap: _busy ? null : () => _choose(project),
                    ),
                ],
              ),
      ),
    ],
  );

  Widget _field(
    TextEditingController controller,
    String label, {
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.lg),
    child: TextField(
      controller: controller,
      enabled: !_busy && !_running,
      minLines: lines,
      maxLines: lines == 1 ? 1 : null,
      decoration: InputDecoration(
        labelText: tr(label),
        border: const OutlineInputBorder(),
      ),
    ),
  );

  Widget _phaseSelector() => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.md),
    child: SegmentedButton<String>(
      segments: [
        ButtonSegment(value: 'plan', label: Text(tr('Planning'))),
        ButtonSegment(value: 'run', label: Text(tr('Execution'))),
      ],
      selected: {_phase},
      onSelectionChanged: _busy
          ? null
          : (values) => _changePhase(values.single),
    ),
  );

  List<Map<String, dynamic>> get _setupHelpers => _profiles
      .where(
        (p) => p['setup_argv'] is List && (p['setup_argv'] as List).isNotEmpty,
      )
      .toList();
  String? get _setupHelper {
    final helpers = _setupHelpers;
    if (helpers.any((p) => p['id'] == _setupAgent)) return _setupAgent;
    final lead = _team.where((m) => m['role'] == 'lead').firstOrNull?['agent'];
    return helpers.where((p) => p['id'] == lead).firstOrNull?['id']
            as String? ??
        helpers.firstOrNull?['id'] as String?;
  }

  Widget _setupPane() {
    final proposal = _project?['setup_proposal'];
    final protectedCheckpoint =
        _project?['phase'] == 'running' &&
        {'paused', 'interrupted', 'failed'}.contains(_project?['status']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _phaseSelector(),
        TextField(
          controller: _setupRequest,
          enabled: !_busy && !_running,
          minLines: 4,
          maxLines: null,
          decoration: InputDecoration(
            labelText: tr('AI setup request'),
            hintText: tr(
              'Example: use Claude with agy and Pi using llama and the optimal model for this project.',
            ),
            border: const OutlineInputBorder(),
          ),
          onChanged: (value) {
            _setupDrafts['${_project?['id'] ?? 'new'}:$_phase'] = value;
            _edited();
          },
        ),
        const SizedBox(height: AppSpace.md),
        if (_setupHelpers.isEmpty)
          Text(tr('No setup helper is available.'))
        else
          DropdownButtonFormField<String>(
            key: ValueKey('setup-helper-$_phase-$_setupHelper'),
            initialValue: _setupHelper,
            decoration: InputDecoration(labelText: tr('Setup helper')),
            items: [
              for (final helper in _setupHelpers)
                DropdownMenuItem(
                  value: '${helper['id']}',
                  child: Text('${helper['name']}'),
                ),
            ],
            onChanged: _busy || _running
                ? null
                : (value) => setState(() => _setupAgent = value),
          ),
        const SizedBox(height: AppSpace.md),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonal(
            onPressed:
                _busy ||
                    _running ||
                    protectedCheckpoint ||
                    _setupHelpers.isEmpty
                ? null
                : () => _perform('setup'),
            child: Text(tr('Propose AI setup')),
          ),
        ),
        const Divider(),
        if (protectedCheckpoint)
          Text(tr('Review existing changes before changing this setup.')),
        if (_project?['setup_error'] != null && proposal is! Map)
          Text(
            tr(
              _project!['setup_error'] == 'paused'
                  ? 'Team setup was stopped. The project is unchanged.'
                  : 'Team setup ended without a proposal. The project is unchanged.',
            ),
          ),
        if (proposal is! Map)
          Text(tr('No AI setup proposal yet.'))
        else ...[
          Text(
            tr('Proposed AI setup'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(
            '${tr('Proposal target')}: ${tr(proposal['target'] == 'plan' ? 'Planning' : 'Execution')}',
          ),
          for (final member in _rows(proposal['team']))
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${_profiles.where((p) => p['id'] == member['agent']).firstOrNull?['name'] ?? member['agent']} · ${tr(switch (member['role']) {
                        'lead' => 'Lead agent',
                        'implementer' => proposal['target'] == 'plan' ? 'Contributor' : 'Implementer',
                        _ => 'Reviewer',
                      })}',
                    ),
                    Text(
                      '${tr('Model (optional)')}: ${member['model'] ?? tr('Agent default')}',
                    ),
                    Text(
                      '${tr('Agent provider')}: ${member['provider'] ?? tr('Agent default')}',
                    ),
                    Text(
                      '${tr('Local runtime')}: ${member['runtime'] ?? tr('Agent default')}',
                    ),
                    Text(
                      '${tr('Effective permissions')}: ${tr(proposal['target'] == 'plan' || member['access'] == 'read-only' || member['role'] == 'reviewer' ? 'Read-only' : 'Edit project files')}',
                    ),
                    if ('${member['instructions'] ?? ''}'.isNotEmpty)
                      Text('${member['instructions']}'),
                  ],
                ),
              ),
            ),
          Text(tr('Rationale'), style: Theme.of(context).textTheme.titleSmall),
          SelectableText('${proposal['rationale'] ?? ''}'),
          if ((proposal['warnings'] as List? ?? []).isNotEmpty) ...[
            Text(tr('Warnings'), style: Theme.of(context).textTheme.titleSmall),
            for (final warning in proposal['warnings'] as List)
              Text('• $warning'),
          ],
          if ((proposal['excluded_agents'] as List? ?? []).isNotEmpty)
            Text(
              '${tr('Excluded agents')}: ${(proposal['excluded_agents'] as List).map((id) => _profiles.where((p) => p['id'] == id).firstOrNull?['name'] ?? id).join(', ')}',
            ),
          if ((proposal['excluded_runtimes'] as List? ?? []).isNotEmpty)
            Text(
              '${tr('Excluded runtimes')}: ${(proposal['excluded_runtimes'] as List).map((id) => _runtimes.where((r) => r['key'] == id).firstOrNull?['name'] ?? id).join(', ')}',
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: _busy || _running || _dirty || protectedCheckpoint
                  ? null
                  : () => _perform('setup_apply'),
              child: Text(tr('Use proposed team')),
            ),
          ),
        ],
        if ('${_project?['setup_output'] ?? ''}'.isNotEmpty) ...[
          const Divider(),
          Text(tr('Setup helper output')),
          SelectableText('${_project!['setup_output']}'),
        ],
      ],
    );
  }

  Widget _teamPane() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _phaseSelector(),
      if (_phase == 'plan') ...[
        if (_planTeam == null)
          Text(tr('Planning follows the execution team until customized.')),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _busy || _running
                ? null
                : () => setState(() {
                    _planTeam = _planTeam == null
                        ? _rows(
                            _runTeam
                                .map((m) => {...m, 'access': 'read-only'})
                                .toList(),
                          )
                        : null;
                    _selection++;
                    _dirty = true;
                  }),
            child: Text(
              tr(
                _planTeam == null
                    ? 'Customize planning team'
                    : 'Use execution team for planning',
              ),
            ),
          ),
        ),
      ],
      Text(tr('Choose the lead agent and optional cooperating agents.')),
      const SizedBox(height: AppSpace.md),
      if (_profiles.isEmpty)
        Text(tr('No project agent profiles are available.')),
      for (var i = 0; i < _team.length; i++) _member(i),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _teamLocked || _profiles.isEmpty
              ? null
              : () => setState(() {
                  _team.add({
                    'agent': _profiles.first['id'],
                    'role': _team.isEmpty ? 'lead' : 'reviewer',
                    'instructions': '',
                    'access': _phase == 'plan' || _team.isNotEmpty
                        ? 'read-only'
                        : (_profiles.first['access_modes'] as List? ??
                                  ['read-only', 'project-edit'])
                              .last,
                  });
                  _dirty = true;
                }),
          icon: const Icon(Icons.person_add_alt),
          label: Text(tr('Add cooperating agent')),
        ),
      ),
      const Divider(),
      Text(tr('Cooperating agents run as separate managed sessions.')),
    ],
  );

  List<Widget> _runtimeFields(
    Map<String, dynamic> member,
    Map<String, dynamic> profile,
    int index,
  ) {
    final agent = member['agent'];
    Map? binding(Map runtime) => (runtime['bindings'] as Map?)?[agent] as Map?;
    final candidates = _runtimes
        .where((r) => binding(r) != null && profile['provider_option'] != null)
        .toList();
    final selected = _runtimes
        .where((r) => r['key'] == member['runtime'])
        .firstOrNull;
    final chosen = '${member['runtime'] ?? ''}';
    final models = selected == null
        ? <String>[]
        : [
            for (final model in binding(selected)?['models'] as List? ?? [])
              '$model',
          ];
    return [
      const SizedBox(height: AppSpace.md),
      DropdownButtonFormField<String>(
        key: ValueKey('runtime-$_selection-$index-$agent-$chosen'),
        initialValue: chosen,
        decoration: InputDecoration(labelText: tr('Local runtime')),
        items: [
          DropdownMenuItem(value: '', child: Text(tr('Agent default'))),
          if (chosen.isNotEmpty && !candidates.any((r) => r['key'] == chosen))
            DropdownMenuItem(
              value: chosen,
              enabled: false,
              child: Text(chosen),
            ),
          for (final runtime in candidates)
            DropdownMenuItem(
              value: '${runtime['key']}',
              enabled:
                  runtime['installed'] == true && runtime['running'] == true,
              child: Text('${runtime['name']}'),
            ),
        ],
        onChanged: _teamLocked
            ? null
            : (value) => setState(() {
                member.remove('runtime');
                member.remove('provider');
                member.remove('model');
                if (value != null && value.isNotEmpty) {
                  final runtime = candidates.firstWhere(
                    (r) => r['key'] == value,
                  );
                  final bound = binding(runtime)!;
                  member['runtime'] = value;
                  member['provider'] = bound['provider'];
                  final choices = bound['models'] as List? ?? [];
                  if (choices.isNotEmpty) member['model'] = choices.first;
                }
                _dirty = true;
              }),
      ),
      Text(
        tr(
          'Connect and start local runtimes on the map before selecting them here.',
        ),
      ),
      if (chosen.isNotEmpty) ...[
        Text('${tr('Agent provider')}: ${member['provider'] ?? ''}'),
        DropdownButtonFormField<String>(
          key: ValueKey(
            'bound-model-$_selection-$index-$chosen-${member['model']}',
          ),
          initialValue: member['model'] as String?,
          decoration: InputDecoration(labelText: tr('Available local model')),
          items: [
            if (member['model'] != null && !models.contains(member['model']))
              DropdownMenuItem(
                value: '${member['model']}',
                enabled: false,
                child: Text('${member['model']}'),
              ),
            for (final model in models)
              DropdownMenuItem(value: model, child: Text(model)),
          ],
          onChanged: _teamLocked
              ? null
              : (value) => setState(() {
                  member['model'] = value;
                  _dirty = true;
                }),
        ),
      ],
    ];
  }

  Widget _member(int index) {
    final member = _team[index];
    final matches = _profiles.where((p) => p['id'] == member['agent']);
    final profile = matches.isEmpty ? null : matches.first;
    final modes =
        (profile?['access_modes'] as List? ?? ['read-only', 'project-edit'])
            .cast<String>();
    final access = _phase == 'plan' || member['role'] == 'reviewer'
        ? 'read-only'
        : member['access'] as String? ?? modes.last;
    final unsupportedAccess = !modes.contains(access);
    String accessLabel(String value) =>
        tr(value == 'read-only' ? 'Read-only' : 'Edit project files');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              key: ValueKey('agent-$_selection-$index'),
              initialValue: profile?['id'] as String?,
              decoration: InputDecoration(labelText: tr('Agent profile')),
              items: [
                for (final p in _profiles)
                  DropdownMenuItem(
                    value: '${p['id']}',
                    child: Text('${p['name']}'),
                  ),
              ],
              onChanged: _teamLocked
                  ? null
                  : (value) => setState(() {
                      member['agent'] = value;
                      member.remove('model');
                      member.remove('subagents');
                      member.remove('runtime');
                      member.remove('provider');
                      final next = _profiles
                          .where((p) => p['id'] == value)
                          .first;
                      member['access'] =
                          _phase == 'plan' || member['role'] == 'reviewer'
                          ? 'read-only'
                          : (next['access_modes'] as List? ??
                                    ['read-only', 'project-edit'])
                                .last;
                      _dirty = true;
                    }),
            ),
            DropdownButtonFormField<String>(
              key: ValueKey('role-$_selection-$index'),
              initialValue: member['role'] as String?,
              decoration: InputDecoration(labelText: tr('Role')),
              items: [
                for (final role in ['lead', 'implementer', 'reviewer'])
                  DropdownMenuItem(
                    value: role,
                    child: Text(
                      tr(switch (role) {
                        'lead' => 'Lead agent',
                        'implementer' =>
                          _phase == 'plan' ? 'Contributor' : 'Implementer',
                        _ => 'Reviewer',
                      }),
                    ),
                  ),
              ],
              onChanged: _teamLocked
                  ? null
                  : (value) => setState(() {
                      member['role'] = value;
                      if (value == 'reviewer') member['access'] = 'read-only';
                      _dirty = true;
                    }),
            ),
            DropdownButtonFormField<String>(
              key: ValueKey(
                'access-$_selection-$index-${member['agent']}-${member['role']}',
              ),
              initialValue: access,
              isExpanded: true,
              decoration: InputDecoration(labelText: tr('Execution access')),
              items: [
                if (unsupportedAccess)
                  DropdownMenuItem(
                    value: access,
                    enabled: false,
                    child: Text(
                      tr(
                        '{0} (unavailable for this profile)',
                      ).replaceAll('{0}', accessLabel(access)),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                for (final mode in modes)
                  DropdownMenuItem(
                    value: mode,
                    child: Text(
                      tr(
                        mode == 'read-only'
                            ? 'Read-only'
                            : 'Edit project files',
                      ),
                    ),
                  ),
              ],
              onChanged:
                  _teamLocked ||
                      _phase == 'plan' ||
                      member['role'] == 'reviewer'
                  ? null
                  : (value) => setState(() {
                      member['access'] = value;
                      _dirty = true;
                    }),
            ),
            if (unsupportedAccess)
              Text(tr('Choose a supported access mode before saving.')),
            TextFormField(
              key: ValueKey('member-$_selection-$index-${member['agent']}'),
              initialValue: '${member['instructions'] ?? ''}',
              enabled: !_teamLocked,
              decoration: InputDecoration(labelText: tr('Role instructions')),
              onChanged: (value) {
                member['instructions'] = value;
                _edited();
              },
            ),
            if (profile != null) ...[
              ..._runtimeFields(member, profile, index),
              if (profile['model_option'] != null && member['runtime'] == null)
                TextFormField(
                  key: ValueKey('model-$_selection-$index-${member['agent']}'),
                  initialValue: '${member['model'] ?? ''}',
                  enabled: !_teamLocked,
                  decoration: InputDecoration(
                    labelText: tr('Model (optional)'),
                  ),
                  onChanged: (value) {
                    if (value.trim().isEmpty) {
                      member.remove('model');
                    } else {
                      member['model'] = value.trim();
                    }
                    _edited();
                  },
                ),
              if (profile['native_subagents'] == true &&
                  profile['subagent_definitions'] is Map) ...[
                const SizedBox(height: AppSpace.md),
                Text(tr('Native subagents')),
                for (final preset
                    in (profile['subagent_definitions'] as Map).keys)
                  CheckboxListTile(
                    title: Text(
                      tr(switch (preset) {
                        'researcher' => 'Researcher',
                        'reviewer' => 'Reviewer',
                        _ => '$preset',
                      }),
                    ),
                    value: (member['subagents'] as List? ?? []).contains(
                      preset,
                    ),
                    onChanged: _teamLocked
                        ? null
                        : (enabled) => setState(() {
                            final chosen = List<String>.from(
                              member['subagents'] as List? ?? [],
                            );
                            if (enabled == true) {
                              chosen.add('$preset');
                            } else {
                              chosen.remove(preset);
                            }
                            member['subagents'] = chosen;
                            _dirty = true;
                          }),
                  ),
              ] else
                Text(tr('Native subagents are unavailable for this profile.')),
              const SizedBox(height: AppSpace.md),
              Text(tr('Effective permissions')),
              Text(
                tr(
                  _phase == 'plan' ||
                          member['access'] == 'read-only' ||
                          member['role'] == 'reviewer'
                      ? 'Read-only'
                      : '${profile['permissions'] ?? ''}',
                ),
              ),
              const SizedBox(height: AppSpace.sm),
              Text(tr('Planning command')),
              SelectableText((profile['plan_argv'] as List? ?? []).join(' ')),
              Text(tr('Execution command')),
              SelectableText(
                ((_phase == 'plan' ||
                                    member['role'] == 'reviewer' ||
                                    member['access'] == 'read-only'
                                ? profile['plan_argv']
                                : profile['run_argv'])
                            as List? ??
                        [])
                    .join(' '),
              ),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _teamLocked
                    ? null
                    : () => setState(() {
                        _team.removeAt(index);
                        _dirty = true;
                      }),
                child: Text(tr('Remove')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _eventText(Map<String, dynamic> event) {
    final text = '${event['text'] ?? ''}';
    String role(String value) => tr(switch (value) {
      'lead' => 'Lead agent',
      'implementer' => 'Implementer',
      'reviewer' => 'Reviewer',
      'setup' => 'Setup helper',
      _ => value,
    });
    if (event['type'] == 'assignment') {
      final match = RegExp(
        r'^(.*): (lead|implementer|reviewer|setup)$',
      ).firstMatch(text);
      if (match != null) {
        return tr(
          '{0}: {1}',
        ).replaceAll('{0}', match[1]!).replaceAll('{1}', role(match[2]!));
      }
    }
    if (event['type'] == 'assignment_done') {
      final match = RegExp(
        r'^(lead|implementer|reviewer|setup) ended successfully\.$',
      ).firstMatch(text);
      if (match != null) {
        return tr('{0} ended successfully.').replaceAll('{0}', role(match[1]!));
      }
    }
    if (event['type'] == 'setup_failed' &&
        RegExp(r'^project_[a-z_]+$').hasMatch(text)) {
      return _failure(ServiceError(text));
    }
    if (event['type'] == 'failed') {
      final match = RegExp(
        r'^The agent ended with exit code (-?\d+)\. Review partial work before continuing\.$',
      ).firstMatch(text);
      if (match != null) {
        return tr(
          'The agent ended with exit code {0}. Review partial work before continuing.',
        ).replaceAll('{0}', match[1]!);
      }
      if (RegExp(r'^project_[a-z_]+$').hasMatch(text)) {
        return _failure(ServiceError(text));
      }
    }
    // The event contains a system message key, not the agent's output. Unknown
    // messages remain readable when a newer backend adds an event.
    return tr(text);
  }

  Widget _activityPane() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(tr('Agent output'), style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: AppSpace.sm),
      SelectableText('${_project?['output'] ?? ''}'),
      if ('${_project?['handoff'] ?? ''}'.isNotEmpty) ...[
        const Divider(),
        Text(
          tr('Saved handoff'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        SelectableText('${_project!['handoff']}'),
      ],
      const Divider(),
      for (final event in _rows(_project?['events']))
        ListTile(
          dense: true,
          title: Text(_eventText(event)),
          subtitle: Text('${event['at'] ?? ''}'),
        ),
    ],
  );

  Widget _editor() {
    final status = _project?['status'];
    final approved =
        _plan.text.trim().isNotEmpty &&
        (_project?['approval_valid'] as bool? ??
            (_project?['approved_version'] != null &&
                _project?['approved_version'] == _project?['plan_version'])) &&
        !_dirty;
    Widget button(String label, String operation, {bool enabled = true}) =>
        FilledButton.tonal(
          onPressed: _busy || !enabled ? null : () => _perform(operation),
          child: Text(tr(label)),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _project == null
                      ? tr('New project')
                      : '${_project!['title']}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(_status(status)),
              if (_dirty)
                Padding(
                  padding: const EdgeInsets.only(left: AppSpace.sm),
                  child: Text(tr('Unsaved changes')),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
          child: Wrap(
            spacing: AppSpace.sm,
            children: [
              for (final (i, label) in [
                'Goal',
                'Plan',
                'Team',
                'Activity',
                'Setup',
              ].indexed)
                ChoiceChip(
                  label: Text(tr(label)),
                  selected: _tab == i,
                  onSelected: (_) => setState(() => _tab = i),
                ),
            ],
          ),
        ),
        const Divider(),
        if (_project?['processes_stopping'] == true)
          Padding(
            padding: const EdgeInsets.all(AppSpace.md),
            child: Text(
              tr('Some agent processes are still stopping. Try again shortly.'),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(AppSpace.md),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: switch (_tab) {
              0 => Column(
                children: [
                  _field(_title, 'Project title'),
                  _field(_brief, 'Project goal', lines: 5),
                  _field(_path, 'Working folder'),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: _busy || _running
                          ? null
                          : () async {
                              final folder = await PopupGuard.around(
                                widget.chooseFolder ?? getDirectoryPath,
                              );
                              if (folder != null && mounted) {
                                _path.text = folder;
                              }
                            },
                      icon: const Icon(Icons.folder_open),
                      label: Text(tr('Choose folder')),
                    ),
                  ),
                ],
              ),
              1 => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _field(_plan, 'Project plan', lines: 10),
                  Text(
                    approved
                        ? tr('This plan version is approved.')
                        : tr('Review this plan and the team before execution.'),
                  ),
                ],
              ),
              2 => _teamPane(),
              4 => _setupPane(),
              _ => _activityPane(),
            },
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: [
              button(
                'Save project',
                'save',
                enabled: !_running && (_dirty || _project == null),
              ),
              button(
                'Draft plan with AI',
                'plan',
                enabled: !_running && (_planTeam ?? _runTeam).isNotEmpty,
              ),
              button(
                'Approve plan',
                'review',
                enabled:
                    !_running &&
                    _plan.text.trim().isNotEmpty &&
                    (!approved || status == 'completed'),
              ),
              button(
                'Run project',
                'run',
                enabled: !_running && approved && status == 'ready',
              ),
              if (_running)
                button(
                  status == 'pausing' ? 'Retry pause' : 'Pause project',
                  'pause',
                ),
              if ({'paused', 'interrupted', 'failed'}.contains(status))
                button('Continue project', 'continue', enabled: !_dirty),
              if (_project != null)
                button('Delete project', 'delete', enabled: !_running),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      WindowHeader(
        title: tr('AI Project Center'),
        tr: tr,
        onBack: () async {
          if (await beforeLeave()) widget.onBack();
        },
        actions: [
          IconButton(
            tooltip: tr('Refresh'),
            onPressed: _busy ? null : () => _refresh(profiles: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      if (_busy && !_confirming) const LinearProgressIndicator(),
      Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 850) {
              return Row(
                children: [
                  SizedBox(width: 250, child: _projectList()),
                  const VerticalDivider(width: 1),
                  Expanded(child: _editor()),
                ],
              );
            }
            return Column(
              children: [
                SizedBox(height: 150, child: _projectList()),
                const Divider(height: 1),
                Expanded(child: _editor()),
              ],
            );
          },
        ),
      ),
    ],
  );
}
