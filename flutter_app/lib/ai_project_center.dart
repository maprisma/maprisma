import 'dart:async';
import 'dart:math' show min;

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart' show getDirectoryPath;
import 'package:maprisma_core/maprisma_core.dart' show ServiceError;

import 'app_look.dart';
import 'project_board.dart';
import 'project_page_parts.dart';
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
    this.onBack,
    this.onBoard,
    this.active = true,
    this.chooseFolder,
    this.agent,
    this.onClearAgent,
    this.onShowOnMap,
    this.onFixOnMap,
  });

  /// Fix on map (task 092), by the AI Map box id an issue names.
  final ValueChanged<String>? onFixOnMap;

  /// The agent chip from the map's "Used in N projects" (task 091): the
  /// board shows only projects whose planning or execution names it.
  final ({String command, String name})? agent;
  final VoidCallback? onClearAgent;

  /// Show on map from a Team graph member (by agent command).
  final ValueChanged<String>? onShowOnMap;

  final ProjectCenterCall onCall;
  final String Function(String) tr;

  /// Null inside the Projects tab: the tab replaces Back (task 086).
  final VoidCallback? onBack;

  /// Back from a project to the board through the shell's guards (task 088);
  /// without it the page goes back by itself.
  final Future<bool> Function()? onBoard;
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

  /// The backend draws the board (its `list` lists the capability `board`;
  /// task 088). Without it the tab keeps the page with its list.
  bool _board = false;

  /// The backend keeps the user's board order and importance marks (its
  /// `list` lists the capability `order`; task 095): cards can be moved and
  /// marked, and a read shows the order as it comes.
  bool _order = false;

  /// A project (or a new one) is open over the board.
  bool _projectOpen = false;
  BoardFilter? _filter;
  BoardImportance? _importance;

  /// A card's move is on its way (one at a time); [_orderSeq] counts the
  /// moves sent, so a read from before one does not undo it on the board.
  bool _moving = false;
  int _orderSeq = 0;

  /// Importance marks on their way, by project: a read meanwhile keeps them.
  final _marking = <String, String>{};

  /// Marks sent and answered, by project (both count): a read begun before
  /// either keeps the mark the page shows now.
  final _markGen = <String, int>{};

  /// The mark the page shows now for [id] (one on its way first).
  String? _localMark(String id) =>
      _marking[id] ??
      _projects.where((p) => p['id'] == id).firstOrNull?['importance']
          as String? ??
      (_project?['id'] == id ? _project!['importance'] as String? : null);

  /// A read's [project] keeps the shown mark when one was sent or answered
  /// since the read began ([since]: the generations then).
  void _keepMark(Map project, Map<String, int> since) {
    final id = project['id'];
    if (id is! String) return;
    if (!_marking.containsKey(id) && (_markGen[id] ?? 0) == (since[id] ?? 0)) {
      return;
    }
    if (_localMark(id) case final code?) project['importance'] = code;
  }

  /// Whether the board shows [p] (the filters and the agent [agent]).
  bool _shows(Map<String, dynamic> p, String? agent) =>
      (_filter == null || p['bucket'] == _filter!.code) &&
      (_importance == null ||
          BoardImportance.of(p['importance']) == _importance) &&
      namesAgent(p, agent);

  /// Cards or Phases; kept while the app runs (task 090).
  BoardView _view = BoardView.cards;
  final _cardFocus = <String, FocusNode>{};
  String? _openedId;

  /// Projects with a quick action on its way.
  final _quick = <String>{};

  /// The card the board brings into view (back from its project).
  String? _reveal;
  final _boardScroll = ScrollController();
  final _newFocus = FocusNode(debugLabel: 'new project');

  void _revealed() {
    final id = _reveal;
    if (!mounted || id == null) return;
    setState(() => _reveal = null);
    final node = _cardFocus[id];
    // A deleted card's node keeps its old context: it must still be there.
    if (node?.context?.mounted ?? false) {
      node!.requestFocus();
    } else {
      _newFocus.requestFocus();
    }
  }

  /// Cards a pointer is pressing now.
  final _pressed = <String>{};

  /// A board message that the next read keeps (a failed quick action).
  int _keepError = 0;

  /// Failed quick actions so far, and the latest one's reason: a card's
  /// reason newer than a step's start is shown again after that step, over a
  /// stale read's message.
  int _quickFailures = 0;
  String? _quickReason;

  /// Two-second ticks since the last read (the board's quiet rhythm).
  int _ticks = 0;

  /// The list could not be read (the backend is unreachable): status
  /// unavailable, never zero.
  bool _unavailable = false;

  /// The project store's fault from the list's summary (a banner, not a
  /// project).
  String? _storeError;

  /// The project page is open (Esc and the Projects tab lead back to the
  /// board).
  bool get projectOpen => _board && _projectOpen;

  /// Back from the project page to the board: unsaved changes ask first; the
  /// keyboard goes to the card that was opened.
  Future<bool> backToBoard() async {
    if (!projectOpen) return true;
    if (!await beforeLeave() || !mounted) return false;
    // A new project saved meanwhile is the card to come back to.
    final id = _openedId ?? _project?['id'] as String?;
    var agentCleared = false;
    setState(() {
      _projectOpen = false;
      // The project page's message stays with the page.
      if (_keepError == 0) _error = null;
      // The opened card is shown again even when it left the filter (or
      // the agent chip).
      final card = _projects.where((p) => p['id'] == id).firstOrNull;
      if (card != null && _filter != null && card['bucket'] != _filter!.code) {
        _filter = null;
      }
      if (card != null &&
          _importance != null &&
          BoardImportance.of(card['importance']) != _importance) {
        _importance = null;
      }
      if (card != null && !namesAgent(card, widget.agent?.command)) {
        agentCleared = true;
      }
    });
    if (agentCleared) widget.onClearAgent?.call();
    final agent = agentCleared ? null : widget.agent?.command;
    // The board scrolls the card into view, then it gets the keyboard; for a
    // card deleted meanwhile the first one the filter shows takes its place,
    // and with none left, New project.
    final shown = [
      for (final p in _projects)
        if (_shows(p, agent)) '${p['id']}',
    ];
    setState(() => _reveal = shown.contains(id) ? id : shown.firstOrNull ?? '');
    return true;
  }

  /// An issue's link (task 092): the map for a box it can act on, else the
  /// project's Goal or Team tab (from the board: the project opens there).
  Future<void> _fixIssue(Map<String, dynamic>? project, Map issue) async {
    final fix = issueFix(issue, map: widget.onFixOnMap != null);
    if (fix == 'map') {
      widget.onFixOnMap!(issue['node'] as String);
      return;
    }
    final tab = fix == 'goal' ? 0 : 2;
    if (_projectOpen) {
      setState(() => _tab = tab);
    } else {
      await _openFromBoard(project, tab: tab);
    }
  }

  Future<void> _openFromBoard(
    Map<String, dynamic>? project, {
    int tab = 0,
  }) async {
    // Opened only once it was read (a deleted project stays on the board,
    // with the reason).
    if (!await _choose(project) || !mounted) return;
    setState(() {
      _openedId = project?['id'] as String?;
      _projectOpen = true;
      _tab = tab;
    });
  }

  /// The board could not be read: status unavailable, with Retry.
  Widget _unavailableNote({bool center = false}) {
    final note = Padding(
      key: const ValueKey('board-unavailable'),
      padding: const EdgeInsets.all(AppSpace.sm),
      child: Wrap(
        alignment: center ? WrapAlignment.center : WrapAlignment.start,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: AppSpace.sm,
        children: [
          const Icon(Icons.cloud_off_outlined),
          Text(tr('Project status unavailable')),
          TextButton(
            key: const ValueKey('board-retry'),
            onPressed: () => unawaited(_refresh(profiles: true)),
            child: Text(tr('Retry')),
          ),
        ],
      ),
    );
    return center ? Center(child: note) : note;
  }

  /// The board's order after a read. With the user's order (task 095) the
  /// read's order is shown, unless a move was sent after the read began or
  /// is still on its way ([moved]): then the cards stay as moved (new ones on
  /// top). An older backend sorts by urgency: while a card has the keyboard
  /// or is pressed, and while a project is open, the cards stay where they
  /// are (new ones at the end); the core's order returns with the next read
  /// after.
  List<Map<String, dynamic>> _holdOrder(
    List<Map<String, dynamic>> fresh, {
    bool moved = false,
  }) {
    if (!_board) return fresh;
    final focused = _cardFocus.values.any((node) => node.hasFocus);
    final hold = _order
        ? moved
        : focused || _pressed.isNotEmpty || _projectOpen;
    if (!hold) return fresh;
    final byId = {for (final p in fresh) '${p['id']}': p};
    final kept = [for (final old in _projects) ?byId.remove('${old['id']}')];
    return _order ? [...byId.values, ...kept] : [...kept, ...byId.values];
  }

  /// [projects] in the order of [ids] (others after them, as they were).
  static List<Map<String, dynamic>> _ordered(
    List<Map<String, dynamic>> projects,
    List<String> ids,
  ) {
    final byId = {for (final p in projects) '${p['id']}': p};
    return [for (final id in ids) ?byId.remove(id), ...byId.values];
  }

  /// A card moved on the board (drag, Move menu or keyboard): [target] null
  /// is the top (or with [after] the end); after a card means before the
  /// next card the board shows, else before the next one of the whole
  /// order (a filter hides it), else the end.
  void _moveFromBoard(String id, String? target, bool after) {
    final ids = [for (final p in _projects) '${p['id']}'];
    String? before;
    if (target == null) {
      before = after ? null : ids.where((i) => i != id).firstOrNull;
      if (!after && before == null) return;
    } else if (!after) {
      before = target;
    } else {
      final agent = widget.agent?.command;
      final shown = [
        for (final p in _projects)
          if (_shows(p, agent)) '${p['id']}',
      ];
      // A card gone meanwhile: no place to go after.
      final whole = ids.indexOf(target);
      if (whole < 0) return;
      final there = shown.indexOf(target);
      before =
          (there < 0
              ? null
              : shown.skip(there + 1).where((i) => i != id).firstOrNull) ??
          ids.skip(whole + 1).where((i) => i != id).firstOrNull;
    }
    unawaited(_move(id, before));
  }

  /// Sends `move`: the card moves at once, then takes the answer's order; a
  /// refusal puts it back and keeps its reason on the board.
  Future<void> _move(String id, String? before) async {
    if (!_order || _moving || _quick.contains(id) || _unavailable) return;
    final old = [for (final p in _projects) '${p['id']}'];
    final rest = [...old]..remove(id);
    final at = before == null ? rest.length : rest.indexOf(before);
    if (at < 0 || !old.contains(id)) return;
    final moved = [...rest]..insert(at, id);
    if (moved.join('\n') == old.join('\n')) return;
    setState(() {
      _moving = true;
      _orderSeq++;
      _projects = _ordered(_projects, moved);
      // The keyboard stays with the card, also when it left the view.
      _reveal = id;
    });
    var kept = false;
    try {
      final answer = await widget.onCall('move', {'id': id, 'before': before});
      final order = answer['order'];
      if (mounted && order is List) {
        setState(() {
          _projects = _ordered(_projects, [for (final i in order) '$i']);
          // The answer may place it elsewhere: kept in view.
          _reveal = id;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _projects = _ordered(_projects, old);
          // Back where it was, in view again.
          _reveal = id;
          _error = _failure(error);
          _keepError++;
          _quickFailures++;
          _quickReason = _error;
          kept = true;
        });
      }
    } finally {
      // Counted again: a read begun while it was on its way is older too.
      if (mounted) {
        setState(() {
          _moving = false;
          _orderSeq++;
        });
      }
    }
    // A refused move (an unknown card): the board is read again; the reason
    // stays through that read.
    if (kept) {
      if (mounted) await _refresh();
      _keepError--;
    }
  }

  /// Sends `set_importance` from a card's mark or the Goal tab: the mark
  /// changes at once (the open project's draft stays as it is); a refusal
  /// puts it back with its reason.
  Future<void> _setImportance(String id, BoardImportance value) async {
    if (!_order ||
        _marking.containsKey(id) ||
        _quick.contains(id) ||
        _unavailable) {
      return;
    }
    String? was;
    void mark(String? code) {
      for (final p in [..._projects.where((p) => p['id'] == id), ?_project]) {
        if (p['id'] != id) continue;
        if (code == null) {
          p.remove('importance');
        } else {
          p['importance'] = code;
        }
      }
    }

    setState(() {
      was =
          _projects.where((p) => p['id'] == id).firstOrNull?['importance']
              as String? ??
          (_project?['id'] == id ? _project!['importance'] as String? : null);
      _marking[id] = value.code;
      _markGen[id] = (_markGen[id] ?? 0) + 1;
      mark(value.code);
    });
    var kept = false;
    try {
      final answer = await widget.onCall('set_importance', {
        'id': id,
        'importance': value.code,
      });
      final project = answer['project'];
      if (mounted && project is Map && project['importance'] is String) {
        setState(() => mark(project['importance'] as String));
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          mark(was);
          _error = _failure(error);
          _keepError++;
          _quickFailures++;
          _quickReason = _error;
          kept = true;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _marking.remove(id);
          _markGen[id] = (_markGen[id] ?? 0) + 1;
        });
      }
    }
    if (kept) {
      if (mounted) await _refresh();
      _keepError--;
    }
  }

  /// Pause or Retry pause from a card, for the run the card shows.
  Future<void> _pauseFromBoard(Map<String, dynamic> project) async {
    final id = '${project['id']}';
    if (_quick.contains(id)) return;
    setState(() => _quick.add(id));
    var kept = false;
    try {
      await widget.onCall('pause', {
        'id': id,
        if (project['run_id'] != null) 'run_id': project['run_id'],
      });
    } catch (error) {
      // A newer run than the card showed: the board is read again; the
      // reason stays readable through that read.
      if (mounted) {
        setState(() {
          _error = _failure(error);
          _keepError++;
          _quickFailures++;
          _quickReason = _error;
          kept = true;
        });
      }
    } finally {
      // The card's Pause stays off until the board shows the new state; the
      // reason stays through that read (also when a poll was on its way).
      if (mounted) await _refresh();
      if (kept) _keepError--;
      if (mounted) setState(() => _quick.remove(id));
    }
  }

  /// The card's trash symbol (task 094): the footer's question, then the
  /// saved project is removed (its folder is kept); a refusal keeps its
  /// reason on the board. The page is busy meanwhile, so the shell's keys and
  /// the window's close wait for the question.
  Future<void> _deleteFromBoard(Map<String, dynamic> project) async {
    final id = '${project['id']}';
    if (_quick.contains(id) || _busy || _confirming) return;
    setState(() => _busy = true);
    var kept = false;
    var asked = false;
    try {
      if (!await _confirm(
            'Delete saved project?',
            'The saved project will be removed. Its working folder is kept.',
            'Delete',
          ) ||
          !mounted) {
        return;
      }
      asked = true;
      setState(() => _quick.add(id));
      await widget.onCall('delete', {
        'id': id,
        'revision': project['revision'],
      });
      _setupDrafts.removeWhere((key, _) => key.startsWith('$id:'));
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = _failure(error);
          _keepError++;
          _quickFailures++;
          _quickReason = _error;
          kept = true;
        });
      }
    } finally {
      if (mounted && asked) await _refresh();
      if (kept) _keepError--;
      if (mounted) {
        setState(() {
          _quick.remove(id);
          _busy = false;
        });
      }
    }
  }

  int _selection = 0;
  Timer? _timer;
  String tr(String key) => widget.tr(key);
  static const _active = {'planning', 'running', 'reviewing', 'pausing'};

  /// A project of the list is active, or the open one is (a project kept
  /// behind the board does not count: its status is no longer read).
  bool get hasActive =>
      (_running && (!_board || _projectOpen)) ||
      _projects.any((p) => _active.contains(p['status']));
  bool get _running => _active.contains(_project?['status']);

  @override
  void initState() {
    super.initState();
    for (final c in [_title, _brief, _path, _plan]) {
      c.addListener(_edited);
    }
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!widget.active || _busy) return;
      _ticks++;
      final stopping = _projects.any((p) => p['processes_stopping'] == true);
      // Every 2 s while something runs or stops, else about every 15 s (also
      // to retry after the backend could not be reached).
      final quiet = _ticks >= 8;
      if (hasActive || stopping || ((_board || _unavailable) && quiet)) {
        unawaited(_refresh());
      }
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
    for (final node in _cardFocus.values) {
      node.dispose();
    }
    _boardScroll.dispose();
    _newFocus.dispose();
    // A refresh someone waits on ends with the page.
    _readDone?.complete();
    _readDone = null;
    _setupRequest.dispose();
    for (final c in [_title, _brief, _path, _plan]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The four fields as the project was adopted: a click or a cursor move
  /// in a field (the controllers report those too) is not a change.
  List<String> _adoptedTexts = const ['', '', '', ''];
  List<String> get _texts => [_title.text, _brief.text, _path.text, _plan.text];

  /// An edit outside the four fields (a member's instructions): always a change.
  void _changed() {
    if (!_dirty && mounted) setState(() => _dirty = true);
  }

  /// The four fields' controllers: only a text that differs counts.
  void _edited() {
    if (_dirty || !mounted) return;
    final now = _texts;
    for (var i = 0; i < now.length; i++) {
      if (now[i] != _adoptedTexts[i]) {
        setState(() => _dirty = true);
        return;
      }
    }
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
    _adoptedTexts = _texts;
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

  /// A refresh asked for while one reads (F5, the focus back): one more
  /// afterwards, so it is never lost.
  bool _readAgain = false, _readAgainProfiles = false;

  /// Completes when the read running now, and the one queued after it, ended.
  Completer<void>? _readDone;

  Future<void> _refresh({bool profiles = false}) async {
    if (_reading) {
      _readAgain = true;
      _readAgainProfiles |= profiles;
      return (_readDone ??= Completer<void>()).future;
    }
    _reading = true;
    final selection = _selection;
    final moves = _orderSeq;
    final marks = Map.of(_markGen);
    final failures = _quickFailures;
    // Full details only for the open project (the board needs none).
    final id = _board && !_projectOpen ? null : _project?['id'];
    try {
      // The list decides whether the board is there; the profiles (for the
      // editor) are read on their own, so their failure is only a message.
      final listed = await widget.onCall('list', {});
      Map<String, dynamic>? profileAnswer;
      Object? profileError;
      if (!_loaded || profiles) {
        try {
          profileAnswer = await widget.onCall('profiles', {});
        } catch (error) {
          profileError = error;
        }
      }
      final results = [listed, ?profileAnswer];
      // The open project's details: a failure there is the project's, not the
      // board's (the list was read).
      Object? selected;
      Object? detailError;
      if (id != null) {
        try {
          selected = (await widget.onCall('get', {'id': id}))['project'];
        } catch (error) {
          detailError = error;
        }
      }
      if (!mounted) return;
      setState(() {
        final caps = results[0]['capabilities'];
        _board = caps is List && caps.contains('board');
        _order = _board && caps is List && caps.contains('order');
        final fresh = _rows(results[0]['projects']);
        // A mark on its way stays (the read may be older than it).
        for (final p in fresh) {
          _keepMark(p, marks);
        }
        _projects = _holdOrder(fresh, moved: _moving || moves != _orderSeq);
        _ticks = 0;
        _unavailable = false;
        final summary = results[0]['summary'];
        final fault = summary is Map ? summary['error'] : null;
        _storeError = fault is String && fault.isNotEmpty ? fault : null;
        // An earlier board message ends with a read (a failed quick action's
        // survives the read it asked for).
        if (_board && !_projectOpen && _keepError == 0) _error = null;
        if (results.length > 1) {
          _profiles = _rows(results[1]['profiles']);
          _runtimes = _rows(results[1]['runtimes']);
        }
        if (selected is Map &&
            !_busy &&
            selection == _selection &&
            id == _project?['id']) {
          _keepMark(selected, marks);
          if (_dirty) {
            _project = Map<String, dynamic>.from(selected);
          } else {
            _adopt(Map<String, dynamic>.from(selected));
          }
        }
        _loaded = true;
        // A late answer about a project that was closed meanwhile is not shown.
        if (detailError != null &&
            selection == _selection &&
            (!_board || _projectOpen)) {
          _error = _failure(detailError);
        } else if (profileError != null && !_board) {
          _error = _failure(profileError);
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          // A card's action that failed meanwhile keeps its reason.
          _error = _quickFailures == failures ? _failure(error) : _quickReason;
          _unavailable = true;
          _ticks = 0;
        });
      }
    } finally {
      _reading = false;
    }
    if (_readAgain && mounted) {
      final again = _readAgainProfiles;
      _readAgain = _readAgainProfiles = false;
      final done = _readDone;
      _readDone = null;
      await _refresh(profiles: again);
      done?.complete();
    } else {
      final done = _readDone;
      _readDone = null;
      done?.complete();
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

  /// Saving, starting or pausing: leaving now must wait.
  bool get busy => _busy;

  /// Refresh and F5 in the shell (the refresh flag travels with the call).
  Future<void> refresh() => _refresh(profiles: true);

  /// The shell calls this before switching pages or closing the window.
  Future<bool> beforeLeave() async {
    final commit = await prepareLeave();
    commit?.call();
    return commit != null;
  }

  /// Asks Save / Discard / Cancel without taking a discard yet: the shell
  /// calls the returned function only once the whole departure succeeded
  /// (closing the window asks more first); null keeps the page as it is.
  Future<VoidCallback?> prepareLeave() async {
    // One question at a time (the project list, a header action and closing
    // the window can all ask).
    if (_busy || _leaving) return null;
    if (!_dirty) return () {};
    _leaving = true;
    try {
      return await _askLeave();
    } finally {
      _leaving = false;
    }
  }

  bool _leaving = false;

  /// Its save question is open or its save runs.
  bool get leaving => _leaving;

  /// One of its own questions is open (delete, approve, continue).
  bool get confirming => _confirming;

  Future<VoidCallback?> _askLeave() async {
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
      return () {
        if (!mounted) return;
        setState(() {
          final prefix = '${_project?['id'] ?? 'new'}:';
          _setupDrafts.removeWhere((key, _) => key.startsWith(prefix));
          _adopt(_project);
        });
      };
    }
    if (choice != 'save' || !mounted) return null;
    // Saving locks the page, so nothing typed meanwhile is overwritten.
    setState(() => _busy = true);
    var saved = false;
    try {
      saved = await _save();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return saved ? () {} : null;
  }

  /// Shows [project] (null: a new one); false when it could not be read.
  Future<bool> _choose(Map<String, dynamic>? project) async {
    if (!await beforeLeave() || !mounted) return false;
    setState(() {
      _selection++;
      _busy = project != null;
      _error = null;
      if (project == null) {
        _setupDrafts.removeWhere((key, _) => key.startsWith('new:'));
      }
    });
    final marks = Map.of(_markGen);
    try {
      final result = project == null
          ? null
          : Map<String, dynamic>.from(
              (await widget.onCall('get', {'id': project['id']}))['project']
                  as Map,
            );
      if (!mounted) return false;
      setState(() {
        if (result != null) _keepMark(result, marks);
        _adopt(result);
        _tab = 0;
      });
      return true;
    } catch (error) {
      if (mounted) setState(() => _error = _failure(error));
      return false;
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
    var backAfterDelete = false;
    final failures = _quickFailures;
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
      // Deleting asks first and never saves the draft it removes.
      if (operation == 'delete') {
        if (_project == null) return;
      } else if ((_dirty || _project == null) && !await _save()) {
        return;
      }
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
          final gone = _project?['id'];
          _setupDrafts.removeWhere((key, _) => key.startsWith('$gone:'));
          // A read of the deleted project still on its way is outdated: its
          // failure must not show on the board.
          _selection++;
          // So is a message about it from an earlier read.
          _error = _quickFailures == failures ? null : _quickReason;
          _adopt(null);
          _projects.removeWhere((p) => p['id'] == gone);
          backAfterDelete = _board && _projectOpen;
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
      if (mounted) {
        setState(() {
          _busy = false;
          // Deleted from its own page: back to the board, the keyboard on
          // the first card the board shows (or New project), once it is
          // read again and New project can take the focus.
          if (backAfterDelete && _projectOpen) {
            _projectOpen = false;
            _openedId = null;
            // An older read's failure ends with the board read after the
            // delete (unless that read failed too).
            // A card's failed quick action keeps its reason.
            if (!_unavailable) {
              _error = _quickFailures == failures ? null : _quickReason;
            }
            final shown = [
              for (final p in _projects)
                if (_shows(p, widget.agent?.command)) '${p['id']}',
            ];
            _reveal = shown.firstOrNull ?? '';
          }
        });
      }
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
            _changed();
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
                _changed();
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
                    _changed();
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
    final approved =
        _plan.text.trim().isNotEmpty &&
        (_project?['approval_valid'] as bool? ??
            (_project?['approved_version'] != null &&
                _project?['approved_version'] == _project?['plan_version'])) &&
        !_dirty;
    // A narrow window (task 088): the breadcrumb names the project, the tabs
    // become one selector, so the body keeps its height.
    return LayoutBuilder(
      builder: (context, box) {
        // Compact when narrow, and also when low for the text size (a wide
        // but short window would leave the body no height).
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final compact = box.maxWidth < 600 || box.maxHeight < 460 * scale;
        return _editorFor(compact, approved);
      },
    );
  }

  /// The open project as its board card describes it (stage, activity,
  /// effective teams); null for a new project or without the board.
  Map<String, dynamic>? get _openCard {
    final id = _project?['id'];
    if (!_board || id == null) return null;
    return _projects.where((p) => p['id'] == id).firstOrNull;
  }

  /// The Team tab: the form, and on the board the team as a graph beside it
  /// (below it when narrow), read only (task 089).
  Widget _teamWithGraph() {
    final card = _openCard;
    if (card == null) return _teamPane();
    final graph = TeamGraph(
      project: card,
      tr: tr,
      onShowOnMap: widget.onShowOnMap,
    );
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth >= 900
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: _teamPane()),
                const SizedBox(width: AppSpace.lg),
                Expanded(flex: 2, child: graph),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _teamPane(),
                const SizedBox(height: AppSpace.lg),
                graph,
              ],
            ),
    );
  }

  /// The Goal tab's importance (task 095): set at once, never part of the
  /// draft; only for a saved project of a backend that keeps marks.
  Widget? _importanceRow() {
    final id = _project?['id'];
    final value = BoardImportance.of(_project?['importance']);
    if (!_order || id is! String || value == null) return null;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.md),
      child: LayoutBuilder(
        builder: (context, box) {
          // Without room (narrow, large text, long words): the label above,
          // the choices across the width without symbols.
          final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
          final compact = box.maxWidth < 520 * scale;
          final selector = SegmentedButton<BoardImportance>(
            key: const ValueKey('goal-importance'),
            showSelectedIcon: false,
            expandedInsets: compact ? EdgeInsets.zero : null,
            segments: [
              for (final i in BoardImportance.values)
                ButtonSegment(
                  value: i,
                  icon: compact ? null : Icon(i.icon, size: 18),
                  label: Text(tr(i.label)),
                ),
            ],
            selected: {value},
            // Not while the page saves, deletes or reads the project.
            onSelectionChanged:
                _busy || _marking.containsKey(id) || _unavailable
                ? null
                : (chosen) => _setImportance(id, chosen.single),
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(tr('Importance')),
                const SizedBox(height: AppSpace.xs),
                selector,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: Text(tr('Importance'))),
              const SizedBox(width: AppSpace.md),
              selector,
            ],
          );
        },
      ),
    );
  }

  /// The open tab's content (goal, plan, team, activity or setup).
  Widget _tabBody(bool approved) => switch (_tab) {
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
        ?_importanceRow(),
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
    2 => _teamWithGraph(),
    4 => _setupPane(),
    _ => _activityPane(),
  };

  Widget _editorFor(bool narrow, bool approved) {
    final status = _project?['status'];
    Widget button(String label, String operation, {bool enabled = true}) =>
        FilledButton.tonal(
          onPressed: _busy || !enabled ? null : () => _perform(operation),
          child: Text(tr(label)),
        );
    final onBoard = _board && _projectOpen;
    const tabs = ['Goal', 'Plan', 'Team', 'Activity', 'Setup'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The project's way (task 089), from its board card's facts.
        if (onBoard && _openCard != null)
          LargeStageRail(project: _openCard!, tr: tr, compact: narrow),
        // On the board's project page the breadcrumb row carries title,
        // status and "Unsaved changes".
        if (!onBoard)
          Padding(
            padding: narrow
                ? const EdgeInsets.symmetric(
                    horizontal: AppSpace.md,
                    vertical: AppSpace.xs,
                  )
                : const EdgeInsets.all(AppSpace.md),
            child: Row(
              children: [
                Expanded(
                  child: onBoard
                      ? const SizedBox.shrink()
                      : Text(
                          _project == null
                              ? tr('New project')
                              : '${_project!['title']}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                ),
                // Long translations shorten instead of overflowing.
                Flexible(
                  child: Text(
                    _status(status),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_dirty)
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(left: AppSpace.sm),
                      child: Text(
                        tr('Unsaved changes'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
          child: narrow
              ? DropdownButton<int>(
                  key: const ValueKey('project-tab-select'),
                  isDense: true,
                  value: _tab,
                  isExpanded: true,
                  onChanged: (i) => setState(() => _tab = i ?? _tab),
                  items: [
                    for (final (i, label) in tabs.indexed)
                      DropdownMenuItem(value: i, child: Text(tr(label))),
                  ],
                )
              : Wrap(
                  spacing: AppSpace.sm,
                  children: [
                    for (final (i, label) in tabs.indexed)
                      ChoiceChip(
                        label: Text(tr(label)),
                        selected: _tab == i,
                        onSelected: (_) => setState(() => _tab = i),
                      ),
                  ],
                ),
        ),
        Divider(height: narrow ? 1 : 16),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpace.lg),
            // Warnings scroll with the body (a small window keeps the footer).
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // What stops the project (task 092): scrolls with the body,
                // so every issue stays reachable in any window.
                if (onBoard && _openCard != null)
                  ProjectIssues(
                    project: _openCard!,
                    tr: tr,
                    mapFix: widget.onFixOnMap != null,
                    onFix: (issue) => _fixIssue(null, issue),
                  ),
                if (_project?['processes_stopping'] == true)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.md),
                    child: Text(
                      tr(
                        'Some agent processes are still stopping. Try again shortly.',
                      ),
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.md),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                _tabBody(approved),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: EdgeInsets.all(narrow ? AppSpace.sm : AppSpace.md),
          child: LayoutBuilder(
            builder: (context, box) {
              // Each action with whether it can run now, in order.
              final actions = <(String, String, bool)>[
                (
                  'Save project',
                  'save',
                  !_running && (_dirty || _project == null),
                ),
                (
                  'Draft plan with AI',
                  'plan',
                  !_running && (_planTeam ?? _runTeam).isNotEmpty,
                ),
                (
                  'Approve plan',
                  'review',
                  !_running &&
                      _plan.text.trim().isNotEmpty &&
                      (!approved || status == 'completed'),
                ),
                (
                  'Run project',
                  'run',
                  !_running && approved && status == 'ready',
                ),
                if (_running)
                  (
                    status == 'pausing' ? 'Retry pause' : 'Pause project',
                    'pause',
                    true,
                  ),
                if ({'paused', 'interrupted', 'failed'}.contains(status))
                  ('Continue project', 'continue', !_dirty),
                if (_project != null) ('Delete project', 'delete', !_running),
              ];
              if (!narrow && box.maxWidth >= 600) {
                return Wrap(
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.sm,
                  children: [
                    for (final (label, op, enabled) in actions)
                      button(label, op, enabled: enabled),
                  ],
                );
              }
              // Narrow: the one primary action for this state, the others
              // in a menu, so the body keeps its height.
              // Edited: saving comes first (an edit voids the approval).
              final preferred = [
                if (_dirty) 'save',
                'pause',
                'continue',
                'run',
                'review',
                'save',
                'plan',
              ];
              final primary = preferred
                  .map(
                    (op) =>
                        actions.where((a) => a.$2 == op && a.$3).firstOrNull,
                  )
                  .nonNulls
                  .firstOrNull;
              return Row(
                children: [
                  if (primary != null)
                    Expanded(child: button(primary.$1, primary.$2))
                  else
                    const Spacer(),
                  const SizedBox(width: AppSpace.sm),
                  PopupMenuButton<String>(
                    key: const ValueKey('project-more'),
                    tooltip: tr('More'),
                    enabled: !_busy,
                    onSelected: _perform,
                    itemBuilder: (context) => [
                      for (final (label, op, enabled) in actions)
                        if (op != primary?.$2)
                          PopupMenuItem(
                            value: op,
                            enabled: enabled,
                            child: Text(tr(label)),
                          ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (widget.onBack case final onBack?)
        WindowHeader(
          title: tr('AI Project Center'),
          tr: tr,
          onBack: () async {
            if (await beforeLeave()) onBack();
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
      if (widget.onBack == null && !_loaded)
        // Until the first list answer: loading, or unavailable with Retry
        // (never the old page and never zero counts).
        Expanded(
          child: _unavailable
              ? _unavailableNote(center: true)
              : const Center(
                  key: ValueKey('board-loading'),
                  child: CircularProgressIndicator(),
                ),
        )
      else if (_board)
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The board stays while a project is open: its scroll position
              // and the opened card are there to return to.
              Offstage(
                offstage: _projectOpen,
                child: ExcludeFocus(
                  excluding: _projectOpen,
                  child: TickerMode(
                    enabled: !_projectOpen,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_storeError != null)
                          Container(
                            key: const ValueKey('board-store-fault'),
                            color: Theme.of(context).colorScheme.errorContainer,
                            padding: const EdgeInsets.all(AppSpace.sm),
                            child: Row(
                              children: [
                                const Icon(Icons.warning_amber),
                                const SizedBox(width: AppSpace.sm),
                                Expanded(
                                  child: Text(
                                    tr('The project list has a problem'),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (_unavailable) _unavailableNote(),
                        if (_error != null && !_unavailable)
                          Padding(
                            padding: const EdgeInsets.all(AppSpace.sm),
                            child: Text(
                              _error!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        Expanded(
                          child: ProjectBoard(
                            projects: [
                              for (final p in _projects)
                                if (namesAgent(p, widget.agent?.command)) p,
                            ],
                            agentName: widget.agent?.name,
                            onFix: (p, issue) => _fixIssue(p, issue),
                            onDelete: _deleteFromBoard,
                            mapFix: widget.onFixOnMap != null,
                            onClearAgent: widget.onClearAgent,
                            tr: tr,
                            unavailable: _unavailable,
                            filter: _filter,
                            onFilter: (f) => setState(() => _filter = f),
                            importance: _importance,
                            onImportanceFilter: (i) =>
                                setState(() => _importance = i),
                            onMove: _order ? _moveFromBoard : null,
                            // Move to top / to end judge the whole board,
                            // also under the agent chip.
                            firstId: _projects.firstOrNull?['id'] as String?,
                            lastId: _projects.lastOrNull?['id'] as String?,
                            onImportance: _order
                                ? (p, value) =>
                                      _setImportance('${p['id']}', value)
                                : null,
                            view: _view,
                            onView: (v) => setState(() => _view = v),
                            onOpen: (p) => _openFromBoard(p),
                            onNew: _busy || _unavailable
                                ? null
                                : () => _openFromBoard(null),
                            onReview: (p) => _openFromBoard(p, tab: 1),
                            onPause: _pauseFromBoard,
                            busyIds: {..._quick, ..._marking.keys},
                            eventText: _eventText,
                            controller: _boardScroll,
                            newFocus: _newFocus,
                            reveal: _reveal,
                            onRevealed: _revealed,
                            onPress: (id, down) =>
                                down ? _pressed.add(id) : _pressed.remove(id),
                            cardFocus: (id) => _cardFocus[id] ??= FocusNode(
                              debugLabel: 'card $id',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_projectOpen)
                Material(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpace.sm,
                          AppSpace.xs,
                          AppSpace.sm,
                          0,
                        ),
                        child: Row(
                          children: [
                            TextButton(
                              key: const ValueKey('breadcrumb-projects'),
                              // Through the shell's guard when there is one.
                              onPressed: () => unawaited(
                                widget.onBoard?.call() ?? backToBoard(),
                              ),
                              child: Text(tr('Projects')),
                            ),
                            const Icon(Icons.chevron_right, size: 18),
                            Expanded(
                              child: Text(
                                _project == null
                                    ? tr('New project')
                                    : '${_project!['title']}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Flexible(
                              child: Text(
                                [
                                  _status(_project?['status']),
                                  if (_dirty) tr('Unsaved changes'),
                                ].join(' · '),
                                key: const ValueKey('project-status-line'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.end,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(child: _editor()),
                    ],
                  ),
                ),
            ],
          ),
        )
      else ...[
        if (_loaded && widget.onBack == null)
          Padding(
            key: const ValueKey('board-needs-update'),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.md,
              vertical: AppSpace.xs,
            ),
            child: Text(
              tr(
                'The AI Project Center backend needs an update for the board.',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
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
                  SizedBox(
                    // A small window keeps room for the editor.
                    height: min(150, constraints.maxHeight * 0.3),
                    child: _projectList(),
                  ),
                  const Divider(height: 1),
                  Expanded(child: _editor()),
                ],
              );
            },
          ),
        ),
      ],
    ],
  );
}

/// Whether a board card's planning or execution names the agent [command]
/// (null: every card).
bool namesAgent(Map<String, dynamic> project, String? command) =>
    command == null ||
    [
      for (final phase in ['planning', 'execution'])
        ...?(project[phase] as List?),
    ].any((m) => m is Map && m['agent'] == command);
