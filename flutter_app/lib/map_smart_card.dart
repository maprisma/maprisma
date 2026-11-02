import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_look.dart' show AppSpace;
import 'app_theme.dart' show corners;
import 'backend.dart' show failureText;
import 'connections_view.dart' show ConnectionReview;
import 'agent_action_dialog.dart';
import 'dictation_card.dart';
import 'model_removal_dialog.dart';
import 'overlay_window.dart';
import 'core_client.g.dart';
import 'providers_view.dart' show modelSize;
import 'task_card.dart' show TaskReview;

/// Opens the rules of what may be done; the app sets it.
VoidCallback? smartOpenRules;

/// Ask AI windows on screen: the app's keys and header wait for them.
final smartWindowsShown = ValueNotifier<int>(0);

/// After the frame: the app redraws its header on this.
void _countWindow(int change) => WidgetsBinding.instance.addPostFrameCallback(
  (_) => smartWindowsShown.value += change,
);

const mapSmartColumns = [
  ('mcp', 'MCP servers and skills'),
  ('agents', 'Agents'),
  ('providers', 'Providers'),
  ('models', 'Models'),
];

String _columnHint(String column) => switch (column) {
  'mcp' => 'Find an MCP server or skill…',
  'agents' => 'Set up or connect an agent…',
  'providers' => 'Set up or tune a provider…',
  'models' => 'Find or connect a model…',
  _ => 'Ask for this column…',
};

String smartFitLabel(String? fit, String Function(String) tr) => switch (fit) {
  'ok' => tr('Fits in VRAM'),
  'tight' => tr('Uses RAM offload'),
  'too_large' => tr('Too large for this PC'),
  _ => '',
};

class SmartModelDownloadReview extends StatelessWidget {
  const SmartModelDownloadReview({
    super.key,
    required this.review,
    required this.tr,
    required this.onConfirm,
    required this.onCancel,
  });

  final Map<String, dynamic> review;
  final String Function(String) tr;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final title = '${review['title'] ?? ''}';
    final subtitle = '${review['subtitle'] ?? ''}';
    final runtime = '${review['runtime'] ?? ''}';
    final size = modelSize(review['size'] as int? ?? 0);
    final fit = smartFitLabel(review['fit'] as String?, tr);
    return TaskReview(
      title: Text(
        tr('Download {0}?').replaceAll('{0}', title),
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subtitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(subtitle, style: const TextStyle(fontSize: 12)),
            ),
          if (runtime.isNotEmpty)
            Text(
              '${tr('Runtime')}: $runtime',
              style: const TextStyle(fontSize: 12),
            ),
          Text(
            '${tr('Download')}: $size',
            style: const TextStyle(fontSize: 12),
          ),
          if (fit.isNotEmpty)
            Text(
              '${tr('This PC')}: $fit',
              style: const TextStyle(fontSize: 12),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: onCancel, child: Text(tr('Cancel'))),
        FilledButton(onPressed: onConfirm, child: Text(tr('Download'))),
      ],
    );
  }
}

/// The review of a model folder move: its notes and files.
class SmartMoveReview extends StatelessWidget {
  const SmartMoveReview({
    super.key,
    required this.plan,
    required this.title,
    required this.subtitle,
    required this.tr,
    required this.onConfirm,
    required this.onCancel,
  });
  final Map<String, dynamic> plan;
  final String title, subtitle;
  final String Function(String) tr;
  final VoidCallback onConfirm, onCancel;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr('Move model folder'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text('$title $subtitle', style: const TextStyle(fontSize: 12)),
              for (final note in plan['notes'] as List? ?? const [])
                Text(tr('$note'), style: const TextStyle(fontSize: 12)),
              for (final file in plan['files'] as List? ?? const [])
                SelectableText(
                  '${(file as Map)['path']}',
                  style: const TextStyle(fontSize: 11),
                ),
            ],
          ),
        ),
      ),
      OverflowBar(
        alignment: MainAxisAlignment.end,
        children: [
          TextButton(onPressed: onCancel, child: Text(tr('Cancel'))),
          FilledButton(
            key: const ValueKey('smart-move-confirm'),
            onPressed: onConfirm,
            child: Text(tr('Move model folder')),
          ),
        ],
      ),
    ],
  );
}

const smartActionLabels = {
  'details': 'Details',
  'runtime': 'Details',
  'models': 'Models…',
  'install': 'Install…',
  'link': 'Map',
  'firstagent': 'Get started',
  'addmcp': 'Add MCP server',
  'addskills': 'Add skills',
};

/// A column's or header's state: check mark in green circle ('ok'),
/// '!' in yellow triangle ('hint'), '!' in red circle ('warn').
class SmartStatusIcon extends StatelessWidget {
  const SmartStatusIcon({super.key, required this.level, this.size = 16});
  final String level;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return switch (level) {
      'warn' => Icon(Icons.error, size: size, color: colors.error),
      'hint' => Icon(Icons.warning, size: size, color: Colors.amber.shade800),
      _ => Icon(Icons.check_circle, size: size, color: Colors.green),
    };
  }
}

/// The helper chosen in any Ask AI window, for all four cards; main.dart
/// loads and saves it (setting smart_helper).
final smartHelperChosen = ValueNotifier<String?>(null);

class SmartStatusData {
  const SmartStatusData({
    this.report,
    this.findings = const [],
    this.updates = const [],
    this.addonHints = const [],
    this.mcpUpdates = const [],
    this.mcpTaskAgent,
    this.onAction,
    this.onUpdate,
    this.onAddonHint,
    this.onMcpUpdate,
    this.onCheckAgain,
  });

  final Map<String, dynamic>? report;
  final List<Map<String, dynamic>> findings;
  final List<Map<String, dynamic>> updates;
  final List<Map<String, dynamic>> addonHints;
  final List<Map<String, dynamic>> mcpUpdates;
  final String? mcpTaskAgent;
  final void Function(List<String> action)? onAction;
  final ValueChanged<Map<String, dynamic>>? onUpdate;
  final void Function(Map<String, dynamic> line, String action)? onAddonHint;
  final void Function(Map<String, dynamic> update, String action)? onMcpUpdate;
  final VoidCallback? onCheckAgain;

  List<Map<String, dynamic>> get _allFindings => [
    ...findings,
    for (final a in report?['areas'] as List? ?? const [])
      for (final f in (a as Map)['findings'] as List? ?? const [])
        Map<String, dynamic>.from(f as Map),
  ];

  static String _findingColumn(Map<String, dynamic> f) {
    final col = f['column'];
    if (col is String && col.isNotEmpty) return col;
    return 'agents';
  }

  static String _updateColumn(Map<String, dynamic> u) {
    final col = u['column'];
    if (col is String && col.isNotEmpty) return col;
    return u['kind'] == 'agent' ? 'agents' : 'providers';
  }

  static String _addonHintColumn(Map<String, dynamic> h) {
    final col = h['column'];
    return col is String && col.isNotEmpty ? col : 'agents';
  }

  static String _mcpUpdateColumn(Map<String, dynamic> u) {
    final col = u['column'];
    if (col is String && col.isNotEmpty) return col;
    return 'mcp';
  }

  List<Map<String, dynamic>> findingsFor(String column) {
    final all = _allFindings;
    return [
      for (final f in all)
        if (_findingColumn(f) == column && f['level'] == 'warn') f,
      for (final f in all)
        if (_findingColumn(f) == column && f['level'] == 'hint') f,
    ];
  }

  List<Map<String, dynamic>> updatesFor(String column) => [
    for (final u in updates)
      if (_updateColumn(u) == column) u,
  ];

  List<Map<String, dynamic>> addonHintsFor(String column) => [
    for (final h in addonHints)
      if (_addonHintColumn(h) == column) h,
  ];

  List<Map<String, dynamic>> mcpUpdatesFor(String column) => [
    for (final u in mcpUpdates)
      if (_mcpUpdateColumn(u) == column) u,
  ];

  String columnLevel(String column) {
    final colFindings = findingsFor(column);
    if (colFindings.any((f) => f['level'] == 'warn')) return 'warn';
    if (colFindings.isNotEmpty ||
        updatesFor(column).isNotEmpty ||
        addonHintsFor(column).isNotEmpty ||
        mcpUpdatesFor(column).isNotEmpty) {
      return 'hint';
    }
    return 'ok';
  }

  int columnCount(String column) =>
      findingsFor(column).length +
      updatesFor(column).length +
      addonHintsFor(column).length +
      mcpUpdatesFor(column).length;

  String get overallLevel {
    var hasHint = false;
    for (final (col, _) in mapSmartColumns) {
      final l = columnLevel(col);
      if (l == 'warn') return 'warn';
      if (l == 'hint') hasHint = true;
    }
    return hasHint ? 'hint' : 'ok';
  }

  String get firstConcernedColumn {
    for (final (col, _) in mapSmartColumns) {
      if (columnLevel(col) == 'warn') return col;
    }
    for (final (col, _) in mapSmartColumns) {
      if (columnLevel(col) == 'hint') return col;
    }
    return 'agents';
  }
}

enum _SmartStep {
  idle,
  status,
  working,
  clarify,
  redirect,
  proposal,
  review,
  running,
  done,
  connectReview,
  mcpForm,
  error,
}

class MapSmartCard extends StatefulWidget {
  const MapSmartCard({
    super.key,
    this.takesRequests = true,
    this.onProvider,
    this.onTask,
    required this.column,
    required this.title,
    required this.open,
    this.enabled = true,
    required this.onToggle,
    required this.tr,
    this.helpers = const [],
    this.client,
    this.initialPrompt,
    this.onMoveToColumn,
    this.onApplied,
    this.status,
    this.statusTrigger = 0,
    this.width = 266,
  });

  /// A column whose helper is not built yet says so before anyone types.
  final bool takesRequests;

  /// A provider step the user chose: (install, update, start or stop, key).
  final void Function(String step, String key, String name)? onProvider;

  /// A reviewed task for an agent in a terminal (system.help_apply).
  final ValueChanged<Map<String, dynamic>>? onTask;
  final String column;
  final String title;
  final bool open;
  final bool enabled;
  final VoidCallback onToggle;
  final String Function(String) tr;
  final List<Map<String, dynamic>> helpers;
  final CoreClient? client;
  final String? initialPrompt;
  final void Function(String column, String request)? onMoveToColumn;

  final ValueChanged<Map<String, dynamic>>? onApplied;
  final SmartStatusData? status;
  final int statusTrigger;
  final double width;

  @override
  State<MapSmartCard> createState() => _MapSmartCardState();
}

class _MapSmartCardState extends State<MapSmartCard> {
  final _prompt = TextEditingController();
  final _barFocus = FocusNode();
  final _cardFocus = FocusNode();
  final _fieldFocus = FocusNode();
  final _portal = OverlayPortalController();
  bool _windowShown = false;
  _SmartStep _step = _SmartStep.idle;
  String? _activeTask;
  int _runToken = 0;
  Map<String, dynamic> _reply = const {};
  String? _activeProposal;
  Map<String, dynamic>? _activeCandidate;
  Set<String> _mcpAgents = {};
  final _mcpFields = <String, TextEditingController>{};
  Map<String, dynamic> _reviewData = const {};
  Map<String, dynamic> _connectPlan = const {};
  bool _applyingConnect = false;
  double? _runFraction;
  String _runText = '';
  String _errorText = '';
  _SmartStep _errorReturnTo = _SmartStep.idle;
  Map<String, dynamic>? _dictation;
  bool _dictationRecording = false;
  String? _dictationHandle;
  bool _showDictationSetup = false;

  Map<String, dynamic>? get _activeHelper {
    if (widget.helpers.isEmpty) return null;
    for (final h in widget.helpers) {
      if (h['command'] == smartHelperChosen.value) return h;
    }
    return widget.helpers.first;
  }

  bool _chosen(Map<String, dynamic> helper) =>
      helper['command'] == smartHelperChosen.value;

  void _helperChanged() {
    if (mounted) setState(() {});
  }

  void _focusOpenCard() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.open) return;
      if (_step == _SmartStep.idle && widget.helpers.isNotEmpty) {
        _fieldFocus.requestFocus();
      } else if (!_cardFocus.hasFocus) {
        _cardFocus.requestFocus();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    smartHelperChosen.addListener(_helperChanged);
    dictationChanged.addListener(_loadDictation);
    _portal.show();
    if (widget.initialPrompt != null && widget.initialPrompt!.isNotEmpty) {
      _prompt.text = widget.initialPrompt!;
    }
    if (widget.statusTrigger > 0) {
      _step = _SmartStep.status;
    }
    if (widget.open) {
      _focusOpenCard();
    }
  }

  @override
  void didUpdateWidget(covariant MapSmartCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialPrompt != null &&
        widget.initialPrompt != oldWidget.initialPrompt &&
        widget.initialPrompt!.isNotEmpty) {
      _prompt.text = widget.initialPrompt!;
      _step = _SmartStep.idle;
    }
    if (widget.statusTrigger != oldWidget.statusTrigger &&
        widget.statusTrigger > 0 &&
        !_atWork) {
      _step = _SmartStep.status;
    }
    if (oldWidget.enabled && !widget.enabled && _step == _SmartStep.working) {
      _abortWorking();
    }
    if (!oldWidget.open && widget.open) {
      _focusOpenCard();
    } else if (oldWidget.open && !widget.open) {
      _showDictationSetup = false;
      if (_step == _SmartStep.redirect) _step = _SmartStep.idle;
    }
  }

  /// A helper, a preview or a confirmed job is at work: closing the status
  /// view would cancel it, so its progress stays on the card.
  bool get _atWork =>
      _step == _SmartStep.working ||
      _step == _SmartStep.running ||
      _applyingConnect ||
      _activeTask != null;

  void _openOnStatus() {
    if (_atWork) {
      if (!widget.open) widget.onToggle();
      return;
    }
    if (!widget.open) {
      setState(() => _step = _SmartStep.status);
      widget.onToggle();
      return;
    }
    if (_step == _SmartStep.status) {
      _close();
      return;
    }
    setState(() => _step = _SmartStep.status);
    _focusOpenCard();
  }

  void _openOnPrompt() {
    if (!widget.open) {
      if (_step == _SmartStep.status) {
        setState(() => _step = _SmartStep.idle);
      }
      widget.onToggle();
      return;
    }
    if (_step == _SmartStep.status) {
      setState(() => _step = _SmartStep.idle);
      _focusOpenCard();
      return;
    }
    _close();
  }

  void _abortWorking() {
    _runToken++;
    final taskId = _activeTask;
    _activeTask = null;
    _step = _SmartStep.idle;
    _errorText = '';
    if (taskId != null && widget.client != null) {
      unawaited(
        widget.client!.tasksCancel(task: taskId).then((_) {}, onError: (_) {}),
      );
    }
  }

  /// [refocus] false when what comes next takes the keyboard: a task card, a
  /// terminal, a page.
  void _close({bool refocus = true}) {
    if (_step == _SmartStep.working) {
      setState(_abortWorking);
    } else if (_step != _SmartStep.running && !_applyingConnect) {
      _runToken++;
      final taskId = _activeTask;
      _activeTask = null;
      if (taskId != null && widget.client != null) {
        unawaited(
          widget.client!
              .tasksCancel(task: taskId)
              .then((_) {}, onError: (_) {}),
        );
      }
    }
    widget.onToggle();
    if (!refocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.open) _barFocus.requestFocus();
    });
  }

  void _backToIdle() {
    setState(() {
      _step = _SmartStep.idle;
      _errorText = '';
      _errorReturnTo = _SmartStep.idle;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.open && _step == _SmartStep.idle) {
        _fieldFocus.requestFocus();
      }
    });
  }

  void _tryAgain() {
    if (_errorReturnTo == _SmartStep.proposal &&
        _reply['status'] == 'proposal') {
      setState(() {
        _errorText = '';
        _step = _SmartStep.proposal;
      });
    } else {
      _backToIdle();
    }
  }

  void _cancelTask({_SmartStep returnTo = _SmartStep.idle}) {
    _runToken++;
    final taskId = _activeTask;
    _activeTask = null;
    if (taskId != null && widget.client != null) {
      unawaited(
        widget.client!.tasksCancel(task: taskId).then((_) {}, onError: (_) {}),
      );
    }
    if (returnTo == _SmartStep.idle) {
      _backToIdle();
    } else {
      setState(() => _step = returnTo);
    }
  }

  Future<void> _ask({String? answer}) async {
    final request = _prompt.text.trim();
    final helper = _activeHelper;
    final client = widget.client;
    if (request.isEmpty || helper == null || client == null) return;
    final token = ++_runToken;
    setState(() {
      _step = _SmartStep.working;
      _activeTask = null;
      _errorText = '';
      _errorReturnTo = _SmartStep.idle;
    });
    _focusOpenCard();
    try {
      final started = await client.mapSmartAsk(
        column: widget.column,
        command: '${helper['command']}',
        request: request,
        answer: answer,
      );
      if (!mounted || token != _runToken) return;
      final taskId = started['task'] as String?;
      if (taskId == null || taskId.isEmpty) {
        setState(() {
          _errorText = failureText(widget.tr);
          _step = _SmartStep.error;
        });
        return;
      }
      _activeTask = taskId;
      while (mounted && token == _runToken) {
        final status = await client.tasksStatus(task: taskId);
        if (!mounted || token != _runToken) return;
        final state = status['state'] as String?;
        if (state == 'done') {
          _activeTask = null;
          final result =
              (status['result'] as Map?)?.cast<String, dynamic>() ?? const {};
          setState(() {
            _reply = result;
            switch (result['status']) {
              case 'clarify':
                _step = _SmartStep.clarify;
              case 'redirect':
                _step = _SmartStep.redirect;
              case 'proposal':
                _step = _SmartStep.proposal;
              default:
                _errorText =
                    '${result['summary'] ?? widget.tr('The action could not be completed.')}';
                _step = _SmartStep.error;
            }
          });
          return;
        }
        if (state == 'stopped') {
          _activeTask = null;
          _backToIdle();
          return;
        }
        if (state != 'running') {
          _activeTask = null;
          setState(() {
            _errorText = failureText(widget.tr);
            _step = _SmartStep.error;
          });
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    } catch (_) {
      if (!mounted || token != _runToken) return;
      _activeTask = null;
      setState(() {
        _errorText = failureText(widget.tr);
        _step = _SmartStep.error;
      });
    }
  }

  /// The helper that gave this reply, also after the menu changed.
  String get _replyHelperName =>
      widget.helpers
              .where((h) => h['command'] == _reply['helper'])
              .firstOrNull?['name']
          as String? ??
      '';

  /// The look-up's answer as a task: the app shows the prompt, the agent then
  /// works in a terminal and asks before each step.
  Future<void> _doIt(Map candidate) async {
    final client = widget.client;
    final proposal = _reply['proposal'] as String?;
    if (client == null || proposal == null) return;
    try {
      final plan = await client.mapSmartReview(
        proposal: proposal,
        candidate: '${candidate['id']}',
      );
      if (!mounted) return;
      _close(refocus: false);
      widget.onTask?.call(plan);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorText = failureText(widget.tr);
        _step = _SmartStep.error;
      });
    }
  }

  /// An MCP candidate: the form when something is to choose or fill in, else
  /// the normal review at once.
  void _openMcp(String proposal, Map<String, dynamic> candidate) {
    _activeProposal = proposal;
    _activeCandidate = candidate;
    if (candidate['kind'] != 'mcp_add') {
      unawaited(
        _planMcp([
          for (final a in candidate['agents'] as List? ?? const []) '$a',
        ]),
      );
      return;
    }
    for (final field in _mcpFields.values) {
      field.dispose();
    }
    _mcpFields.clear();
    for (final need in (candidate['needs'] as List? ?? const []).cast<Map>()) {
      _mcpFields['${need['name']}'] = TextEditingController(
        text: '${need['value'] ?? ''}',
      );
    }
    setState(() {
      _mcpAgents = {
        for (final a in candidate['agents'] as List? ?? const []) '$a',
      };
      _step = _SmartStep.mcpForm;
    });
  }

  Future<void> _planMcp(List<String> agents) async {
    final client = widget.client;
    final proposal = _activeProposal;
    final candidate = _activeCandidate;
    if (client == null || proposal == null || candidate == null) return;
    final token = ++_runToken;
    try {
      final plan = await client.mapSmartPlan(
        proposal: proposal,
        candidate: '${candidate['id']}',
        agents: agents,
        values: {for (final e in _mcpFields.entries) e.key: e.value.text},
      );
      if (!mounted || token != _runToken) return;
      setState(() {
        _connectPlan = plan;
        _step = _SmartStep.connectReview;
      });
    } catch (_) {
      if (!mounted || token != _runToken) return;
      setState(() {
        _errorText = failureText(widget.tr);
        _step = _SmartStep.error;
      });
    }
  }

  Widget _buildMcpForm(ColorScheme colors) {
    final candidate = _activeCandidate ?? const {};
    final agents = (_reply['agents'] as List? ?? const []).cast<Map>();
    final needs = (candidate['needs'] as List? ?? const []).cast<Map>();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${candidate['title'] ?? ''}',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          widget.tr('Connect it to these agents'),
          style: const TextStyle(fontSize: 11),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final agent in agents.where((a) => a['mcp'] != false))
              FilterChip(
                key: ValueKey('smart-mcp-agent-${agent['command']}'),
                visualDensity: VisualDensity.compact,
                label: Text('${agent['name']}'),
                selected: _mcpAgents.contains('${agent['command']}'),
                onSelected: (on) => setState(() {
                  on
                      ? _mcpAgents.add('${agent['command']}')
                      : _mcpAgents.remove('${agent['command']}');
                }),
              ),
          ],
        ),
        for (final need in needs) ...[
          const SizedBox(height: 8),
          TextField(
            key: ValueKey('smart-mcp-need-${need['name']}'),
            controller: _mcpFields['${need['name']}'],
            obscureText: need['secret'] == true,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              labelText: '${need['name']}',
              helperText: '${need['description'] ?? ''}'.isEmpty
                  ? null
                  : '${need['description']}',
              helperMaxLines: 2,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _openReview(
    String proposal,
    Map<String, dynamic> candidate,
  ) async {
    final client = widget.client;
    if (client == null) return;
    final token = ++_runToken;
    try {
      var review = await client.mapSmartReview(
        proposal: proposal,
        candidate: '${candidate['id']}',
      );
      // A folder move works out its preview as a task.
      if (review['task'] is String) {
        setState(() => _step = _SmartStep.working);
        final task = review['task'] as String;
        _activeTask = task;
        while (mounted && token == _runToken) {
          final status = await client.tasksStatus(task: task);
          if (!mounted || token != _runToken) return;
          if (status['state'] == 'running') {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            continue;
          }
          _activeTask = null;
          if (status['state'] != 'done') {
            throw StateError('no preview');
          }
          review = (status['result'] as Map).cast<String, dynamic>();
          if (review['ok'] == false) throw StateError('no preview');
          break;
        }
      }
      if (!mounted || token != _runToken) return;
      setState(() {
        _activeProposal = proposal;
        _activeCandidate = candidate;
        _reviewData = review;
        _step = _SmartStep.review;
      });
    } catch (_) {
      if (!mounted || token != _runToken) return;
      _activeTask = null;
      setState(() {
        _errorText = failureText(widget.tr);
        _step = _SmartStep.error;
      });
    }
  }

  void _closeForTerminal() {
    setState(() => _step = _SmartStep.idle);
    if (widget.open) _close(refocus: false);
  }

  /// The others of the proposal stay to choose, one by one.
  void _nextOrClose(Map<String, dynamic> candidate) {
    final left = [
      for (final c in _reply['candidates'] as List? ?? const [])
        if ((c as Map)['id'] != candidate['id']) c,
    ];
    if (left.isEmpty) {
      setState(() => _step = _SmartStep.idle);
      if (widget.open) _close();
      return;
    }
    setState(() {
      _reply = {..._reply, 'candidates': left};
      _step = _SmartStep.proposal;
    });
  }

  Future<void> _confirmReview() async {
    final client = widget.client;
    final proposal = _activeProposal;
    final candidate = _activeCandidate;
    if (client == null || proposal == null || candidate == null) return;
    final token = ++_runToken;
    setState(() {
      _step = _SmartStep.running;
      _activeTask = null;
      _runFraction = null;
      _runText = '${candidate['title'] ?? ''}';
      _errorReturnTo = _SmartStep.proposal;
    });
    _focusOpenCard();
    try {
      final started = await client.mapSmartRun(
        proposal: proposal,
        candidate: '${candidate['id']}',
      );
      if (!mounted || token != _runToken) return;
      if (candidate['kind'] == 'agent_action') {
        // It runs in a terminal, not as a task: the app shows that terminal.
        _closeForTerminal();
        widget.onApplied?.call(started);
        return;
      }
      final taskId = started['task'] as String?;
      if (taskId == null || taskId.isEmpty) {
        setState(() {
          _errorText = failureText(widget.tr);
          _step = _SmartStep.error;
        });
        return;
      }
      _activeTask = taskId;
      while (mounted && token == _runToken) {
        final status = await client.tasksStatus(task: taskId);
        if (!mounted || token != _runToken) return;
        final state = status['state'] as String?;
        if (state == 'done') {
          _activeTask = null;
          final result =
              (status['result'] as Map?)?.cast<String, dynamic>() ?? const {};
          if (result['ok'] == false) {
            // A move that could not be rolled back all the way can be undone.
            if (result['move_undo'] is String) {
              widget.onApplied?.call({'move_undo': result['move_undo']});
            }
            setState(() {
              _errorText =
                  '${result['message'] ?? widget.tr('The action could not be completed.')}';
              _step = _SmartStep.error;
            });
            return;
          }
          if (result['session'] != null) {
            _closeForTerminal();
            widget.onApplied?.call(result);
            return;
          }
          widget.onApplied?.call(result);
          if (candidate['kind'] != null) {
            _nextOrClose(candidate);
            return;
          }
          setState(() => _step = _SmartStep.done);
          return;
        }
        if (state == 'stopped') {
          _activeTask = null;
          setState(() => _step = _SmartStep.proposal);
          return;
        }
        if (state != 'running') {
          _activeTask = null;
          setState(() {
            _errorText = failureText(widget.tr);
            _step = _SmartStep.error;
          });
          return;
        }
        setState(() {
          _runFraction = (status['fraction'] as num?)?.toDouble();
          final text = '${status['text'] ?? ''}';
          if (text.isNotEmpty) _runText = text;
        });
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    } catch (_) {
      if (!mounted || token != _runToken) return;
      _activeTask = null;
      setState(() {
        _errorText = failureText(widget.tr);
        _step = _SmartStep.error;
      });
    }
  }

  Future<void> _openConnect(String agentCommand) async {
    final client = widget.client;
    final proposal = _activeProposal;
    final candidate = _activeCandidate;
    if (client == null || proposal == null || candidate == null) return;
    final token = ++_runToken;
    try {
      final plan = await client.mapSmartConnect(
        proposal: proposal,
        candidate: '${candidate['id']}',
        agent: agentCommand,
      );
      if (!mounted || token != _runToken) return;
      setState(() {
        _connectPlan = plan;
        _step = _SmartStep.connectReview;
      });
    } catch (_) {
      if (!mounted || token != _runToken) return;
      setState(() {
        _errorText = failureText(widget.tr);
        _step = _SmartStep.error;
      });
    }
  }

  Future<void> _applyConnect() async {
    final client = widget.client;
    final planToken = _connectPlan['plan'] as String?;
    if (client == null || planToken == null || _applyingConnect) return;
    final token = ++_runToken;
    _applyingConnect = true;
    try {
      var result = await client.connectionsApply(plan: planToken);
      if (!mounted || token != _runToken) return;
      final taskId = result['task'] as String?;
      if (taskId != null && taskId.isNotEmpty) {
        _activeTask = taskId;
        while (mounted && token == _runToken) {
          final status = await client.tasksStatus(task: taskId);
          if (!mounted || token != _runToken) return;
          if (status['state'] == 'done') {
            _activeTask = null;
            result =
                (status['result'] as Map?)?.cast<String, dynamic>() ?? const {};
            break;
          }
          if (status['state'] != 'running') {
            _activeTask = null;
            setState(() {
              _errorText = failureText(widget.tr);
              _step = _SmartStep.error;
            });
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      widget.onApplied?.call({
        ...result,
        if (_activeCandidate?['kind'] == 'model_disconnect')
          'models_left': true,
      });
      final done = _activeCandidate;
      if (done?['kind'] != null) {
        _nextOrClose(done!);
        return;
      }
      setState(() => _step = _SmartStep.idle);
      if (widget.open) _close();
    } catch (_) {
      if (!mounted || token != _runToken) return;
      _activeTask = null;
      setState(() {
        _errorText = failureText(widget.tr);
        _step = _SmartStep.error;
      });
    } finally {
      _applyingConnect = false;
    }
  }

  @override
  void dispose() {
    smartHelperChosen.removeListener(_helperChanged);
    dictationChanged.removeListener(_loadDictation);
    if (_windowShown) _countWindow(-1);
    _runToken++;
    _prompt.dispose();
    for (final field in _mcpFields.values) {
      field.dispose();
    }
    _barFocus.dispose();
    _cardFocus.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  /// The window's header: who answers and what it costs. It can be changed
  /// while nothing has been asked yet.
  Widget _buildHelperChoice(ColorScheme colors) {
    final helper = _activeHelper;
    if (helper == null) return const SizedBox.shrink();
    final cost = widget.tr(
      helper['local'] == true ? 'Local, no tokens' : 'Uses plan/tokens',
    );
    final free =
        _step == _SmartStep.idle ||
        _step == _SmartStep.clarify ||
        _step == _SmartStep.error ||
        _step == _SmartStep.status;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          flex: 3,
          child: widget.helpers.length > 1
              ? SizedBox(
                  width: 220,
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      key: const ValueKey('smart-helper-select'),
                      isExpanded: true,
                      isDense: true,
                      value: '${helper['command']}',
                      onChanged: free
                          ? (value) {
                              if (value != null) {
                                smartHelperChosen.value = value;
                              }
                            }
                          : null,
                      items: [
                        for (final h in widget.helpers)
                          DropdownMenuItem<String>(
                            value: '${h['command']}',
                            child: Row(
                              children: [
                                if (_chosen(h)) ...[
                                  const SmartStatusIcon(level: 'ok', size: 14),
                                  const SizedBox(width: 4),
                                ],
                                Expanded(
                                  child: Text(
                                    '${h['name']}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                )
              : Text(
                  '${helper['name']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
        ),
        const SizedBox(width: 6),
        Flexible(
          flex: 2,
          child: Text(
            cost,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  /// The window's footer: what can be done at this step.
  List<Widget> _actions() {
    final tr = widget.tr;
    final close = TextButton(onPressed: _close, child: Text(tr('Close')));
    final back = TextButton(onPressed: _backToIdle, child: Text(tr('← Back')));
    final onFirstAgent = widget.status?.onAction;
    return switch (_step) {
      _SmartStep.idle when !widget.takesRequests => [close],
      _SmartStep.idle when widget.helpers.isEmpty => [
        close,
        if (onFirstAgent != null)
          OutlinedButton(
            key: const ValueKey('smart-no-helper-action'),
            onPressed: () {
              _close(refocus: false);
              onFirstAgent(const ['firstagent']);
            },
            child: Text(tr('Get started')),
          ),
      ],
      _SmartStep.idle => [
        close,
        FilledButton(onPressed: () => _ask(), child: Text(tr('Ask'))),
      ],
      _SmartStep.status => [
        TextButton(
          key: const ValueKey('health-again'),
          onPressed: widget.status?.onCheckAgain,
          child: Text(tr('Check again')),
        ),
        close,
      ],
      _SmartStep.working => [
        TextButton(onPressed: _cancelTask, child: Text(tr('Cancel'))),
      ],
      _SmartStep.clarify ||
      _SmartStep.redirect ||
      _SmartStep.proposal => [back, close],
      _SmartStep.mcpForm => [
        TextButton(
          onPressed: () => setState(() => _step = _SmartStep.proposal),
          child: Text(tr('← Back')),
        ),
        FilledButton(
          key: const ValueKey('smart-mcp-review'),
          onPressed:
              _mcpAgents.isNotEmpty &&
                  _mcpFields.values.every((f) => f.text.trim().isNotEmpty)
              ? () => _planMcp(_mcpAgents.toList())
              : null,
          child: Text(tr('Review')),
        ),
      ],
      _SmartStep.running => [
        TextButton(
          onPressed: () => _cancelTask(returnTo: _SmartStep.proposal),
          child: Text(tr('Cancel')),
        ),
      ],
      _SmartStep.done => [
        FilledButton.tonal(
          onPressed: () {
            _step = _SmartStep.idle;
            _close();
          },
          child: Text(tr('Done')),
        ),
      ],
      _SmartStep.error => [
        close,
        FilledButton.tonal(onPressed: _tryAgain, child: Text(tr('Try again'))),
      ],
      _SmartStep.review || _SmartStep.connectReview => const [],
    };
  }

  Widget _buildIdle(ColorScheme colors) => !widget.takesRequests
      ? Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.tr('This column does not take requests yet.'),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        )
      : _buildAsk(colors);

  Future<void> _loadDictation() async {
    final client = widget.client;
    if (client == null) return;
    try {
      final snap = await client.dictationSnapshot();
      if (!mounted) return;
      setState(() {
        _dictation = snap;
        _dictationRecording = snap['recording'] == true;
      });
    } catch (_) {}
  }

  Future<void> _toggleDictation() async {
    final client = widget.client;
    if (client == null) return;
    if (_dictation == null) {
      await _loadDictation();
      if (!mounted) return;
    }
    final snap = _dictation;
    if (snap == null || snap['ready'] != true) {
      setState(() => _showDictationSetup = !_showDictationSetup);
      return;
    }
    if (!_dictationRecording) {
      _fieldFocus.requestFocus();
      try {
        final started = await client.dictationStart();
        if (!mounted) return;
        setState(() {
          _dictationRecording = true;
          _dictationHandle = started['recording'] as String?;
        });
      } catch (_) {}
      return;
    }
    try {
      final stopped = await client.dictationStop(recording: _dictationHandle);
      if (!mounted) return;
      final text = (stopped['text'] as String? ?? '').trim();
      if (text.isNotEmpty) {
        final current = _prompt.text.trim();
        _prompt.text = current.isEmpty ? text : '$current $text';
        _prompt.selection = TextSelection.fromPosition(
          TextPosition(offset: _prompt.text.length),
        );
      }
      setState(() {
        _dictationRecording = false;
        _dictationHandle = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _dictationRecording = false;
        _dictationHandle = null;
      });
    }
  }

  Future<void> _updateDictationEngine(String engine) async {
    final client = widget.client;
    if (client == null) return;
    try {
      await client.settingsUpdate(values: {'dictation_engine': engine});
      dictationChanged.value++;
      await _loadDictation();
    } catch (_) {}
  }

  Future<void> _runDictationAction(String action, [String? target]) async {
    final client = widget.client;
    if (client == null) return;
    try {
      await client.dictationRun(action: action, target: target);
      dictationChanged.value++;
      await _loadDictation();
    } catch (_) {}
  }

  Widget _buildDictationSuffix(ColorScheme colors, bool ready, String active) {
    final Widget micIcon;
    if (_dictationRecording) {
      micIcon = Icon(Icons.stop_circle, size: 20, color: colors.error);
    } else if (!ready) {
      micIcon = Stack(
        clipBehavior: Clip.none,
        children: const [
          Icon(Icons.mic_none, size: 20),
          Positioned(
            right: -4,
            top: -4,
            child: SmartStatusIcon(
              key: ValueKey('smart-dictation-unconfigured'),
              level: 'hint',
              size: 12,
            ),
          ),
        ],
      );
    } else if (active == 'online') {
      micIcon = Stack(
        clipBehavior: Clip.none,
        children: const [
          Icon(Icons.mic, size: 20),
          Positioned(
            right: -4,
            top: -4,
            child: SmartStatusIcon(
              key: ValueKey('smart-dictation-online-indicator'),
              level: 'hint',
              size: 12,
            ),
          ),
        ],
      );
    } else {
      micIcon = const Icon(Icons.mic, size: 20);
    }

    return ExcludeFocusTraversal(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const ValueKey('smart-dictation-mic'),
            visualDensity: VisualDensity.compact,
            tooltip: _dictationRecording
                ? widget.tr('Stop dictation')
                : ready
                ? widget.tr('Dictate')
                : widget.tr('On · not set up yet'),
            icon: micIcon,
            onPressed: _toggleDictation,
          ),
          IconButton(
            key: const ValueKey('smart-dictation-manage'),
            visualDensity: VisualDensity.compact,
            tooltip: widget.tr('Dictation'),
            icon: const Icon(Icons.tune, size: 16),
            onPressed: () {
              if (_dictation == null) unawaited(_loadDictation());
              setState(() => _showDictationSetup = !_showDictationSetup);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAsk(ColorScheme colors) {
    if (widget.helpers.isEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.tr('No AI helper is set up yet.'),
            style: const TextStyle(fontSize: 12),
          ),
        ],
      );
    }
    final dict = _dictation;
    final dictEnabled = dict == null ? true : dict['enabled'] != false;
    final dictReady = dict?['ready'] == true;
    final dictActive = dict?['active'] as String? ?? '';
    final dictCostHint = dict?['cost_hint'] as String? ?? '';
    final showMic = dictEnabled && widget.client != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _prompt,
          focusNode: _fieldFocus,
          autofocus: true,
          minLines: 2,
          maxLines: 3,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            isDense: true,
            hintText: _dictationRecording
                ? widget.tr('Listening… Click Stop when done.')
                : widget.tr(_columnHint(widget.column)),
            border: const OutlineInputBorder(),
            suffixIcon: showMic
                ? _buildDictationSuffix(colors, dictReady, dictActive)
                : null,
          ),
        ),
        if (showMic && dictCostHint.isNotEmpty && !_showDictationSetup) ...[
          const SizedBox(height: AppSpace.xs),
          Row(
            key: const ValueKey('smart-dictation-cost-hint'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2, right: AppSpace.xs),
                child: SmartStatusIcon(level: 'hint', size: 13),
              ),
              Expanded(
                child: Text(
                  dictCostHint,
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (showMic && _showDictationSetup) ...[
          const SizedBox(height: AppSpace.sm),
          Material(
            key: const ValueKey('smart-dictation-panel'),
            color: colors.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(corners(context)),
              side: BorderSide(color: colors.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.sm),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.tr(dictReady ? 'Dictation' : 'Set up dictation'),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  DictationControls(
                    snapshot: dict ?? fallbackDictationSnapshot(const {}),
                    busy: false,
                    tr: widget.tr,
                    compact: true,
                    onEngineChanged: _updateDictationEngine,
                    onAction: _runDictationAction,
                    onRefresh: _loadDictation,
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  static final _statusButtonStyle = OutlinedButton.styleFrom(
    visualDensity: VisualDensity.compact,
    minimumSize: const Size(48, 28),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    textStyle: const TextStyle(fontSize: 12),
  );

  Widget _buildStatusFinding(Map<String, dynamic> f) {
    final level = '${f['level'] ?? 'hint'}';
    final title = '${f['title'] ?? ''}';
    final text = '${f['text'] ?? ''}';
    final action = [for (final x in f['action'] as List? ?? const []) '$x'];
    final label = action.isEmpty ? null : smartActionLabels[action.first];
    final onAction = widget.status?.onAction;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2, right: 6),
                child: SmartStatusIcon(level: level, size: 15),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (text.isNotEmpty)
                      Text(text, style: const TextStyle(fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              if (label != null && onAction != null)
                OutlinedButton(
                  style: _statusButtonStyle,
                  onPressed: () {
                    _close(refocus: false);
                    onAction(action);
                  },
                  child: Text(widget.tr(label)),
                ),
              if (widget.takesRequests)
                OutlinedButton(
                  key: ValueKey('smart-ask-finding-$title'),
                  style: _statusButtonStyle,
                  onPressed: () {
                    setState(() {
                      _prompt.text = text.isEmpty ? title : '$title — $text';
                      _step = _SmartStep.idle;
                    });
                    _focusOpenCard();
                  },
                  child: Text(widget.tr('Ask AI')),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusAddonHint(Map<String, dynamic> h) {
    final onAddonHint = widget.status?.onAddonHint;
    final buttons = <(String, String)>[
      if (h['kind'] == 'updates') ('update_all', 'Update all'),
      if (h['kind'] == 'found' || h['kind'] == 'versions') ...[
        if (h['mcp'] == true) ('mcp', 'Add MCP server…'),
        if (h['skills'] == true) ('skills', 'Add skills…'),
      ] else
        ('addons', h['kind'] == 'new' ? 'Get add-ons' : 'Add-ons'),
    ];
    return Padding(
      key: ValueKey('addon-hint-${h['kind']}'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2, right: 6),
                child: Icon(
                  h['kind'] == 'updates'
                      ? Icons.upgrade
                      : h['kind'] == 'found' || h['kind'] == 'versions'
                      ? Icons.new_releases
                      : Icons.extension,
                  size: 15,
                ),
              ),
              Expanded(
                child: Text(
                  '${h['text']}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          if (onAddonHint != null && buttons.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final (action, label) in buttons)
                  OutlinedButton(
                    style: _statusButtonStyle,
                    onPressed: () {
                      _close(refocus: false);
                      onAddonHint(h, action);
                    },
                    child: Text(widget.tr(label)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusUpdate(Map<String, dynamic> u) {
    final onUpdate = widget.status?.onUpdate;
    return Padding(
      key: ValueKey('update-${u['key']}'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2, right: 6),
                child: Icon(Icons.upgrade, size: 15),
              ),
              Expanded(
                child: Text(
                  widget
                      .tr('{0} {1} is available (you have {2})')
                      .replaceAll('{0}', '${u['name']}')
                      .replaceAll('{1}', '${u['available']}')
                      .replaceAll('{2}', '${u['current']}'),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          if (onUpdate != null) ...[
            const SizedBox(height: 4),
            OutlinedButton(
              style: _statusButtonStyle,
              onPressed: () {
                _close(refocus: false);
                onUpdate(u);
              },
              child: Text(widget.tr('Update')),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusMcpUpdate(Map<String, dynamic> u) {
    final onMcpUpdate = widget.status?.onMcpUpdate;
    final taskAgent = widget.status?.mcpTaskAgent;
    final notes = '${u['notes'] ?? ''}';
    final buttons = <(String, String)>[
      if (u['on_pc'] == true)
        ('use', widget.tr('Use it…'))
      else ...[
        ('release', widget.tr('Release page')),
        if (taskAgent != null)
          ('task', widget.tr('Do it with {0}…').replaceAll('{0}', taskAgent)),
      ],
    ];
    return Padding(
      key: ValueKey('mcp-update-${u['name']}'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2, right: 6),
                child: Icon(Icons.upgrade, size: 15),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${u['text']}', style: const TextStyle(fontSize: 12)),
                    if (notes.isNotEmpty)
                      Text(notes, style: const TextStyle(fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
          if (onMcpUpdate != null && buttons.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final (action, label) in buttons)
                  OutlinedButton(
                    key: ValueKey('mcp-$action-${u['name']}'),
                    style: _statusButtonStyle,
                    onPressed: () {
                      if (action != 'release') _close(refocus: false);
                      onMcpUpdate(u, action);
                    },
                    child: Text(label),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatus() {
    final status = widget.status;
    final findings = status?.findingsFor(widget.column) ?? const [];
    final addonHints = status?.addonHintsFor(widget.column) ?? const [];
    final updates = status?.updatesFor(widget.column) ?? const [];
    final mcpUpdates = status?.mcpUpdatesFor(widget.column) ?? const [];
    final empty =
        findings.isEmpty &&
        addonHints.isEmpty &&
        updates.isEmpty &&
        mcpUpdates.isEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (empty)
          Text(
            widget.tr('Nothing to fix.'),
            style: const TextStyle(fontSize: 12),
          ),
        for (final f in findings) _buildStatusFinding(f),
        for (final h in addonHints) _buildStatusAddonHint(h),
        for (final u in updates) _buildStatusUpdate(u),
        for (final u in mcpUpdates) _buildStatusMcpUpdate(u),
      ],
    );
  }

  Widget _buildWorking() {
    final helperName = '${_activeHelper?['name'] ?? ''}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _prompt.text.trim(),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        const LinearProgressIndicator(),
        const SizedBox(height: 8),
        Text(
          widget
              .tr('{0} is checking {1}…')
              .replaceAll('{0}', helperName)
              .replaceAll('{1}', widget.tr(widget.title)),
          style: const TextStyle(fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildClarify(ColorScheme colors) {
    final question = '${_reply['question'] ?? ''}';
    final choices = (_reply['choices'] as List? ?? const [])
        .map((c) => '$c')
        .toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          question,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final choice in choices)
              ActionChip(
                label: Text(choice, style: const TextStyle(fontSize: 12)),
                onPressed: () => _ask(answer: choice),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildRedirect() {
    final instead =
        (_reply['instead'] as Map?)?.cast<String, dynamic>() ?? const {};
    final hint = '${instead['hint'] ?? ''}';
    final targetCol = instead['column'] as String?;
    final targetTitle = mapSmartColumns
        .where((c) => c.$1 == targetCol)
        .firstOrNull
        ?.$2;
    final targetReq = instead['request'] as String?;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SelectableText(hint, style: const TextStyle(fontSize: 12)),
        for (final c in (_reply['candidates'] as List? ?? const []).cast<Map>())
          if (c['kind'] == 'agent_task' && _reply['proposal'] is String) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                key: const ValueKey('smart-do-it'),
                onPressed: () => _doIt(c),
                child: Text(
                  widget
                      .tr('Do it with {0}…')
                      .replaceAll('{0}', _replyHelperName),
                ),
              ),
            ),
          ],
        if (targetCol != null &&
            targetTitle != null &&
            targetCol != widget.column) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              onPressed: () {
                final req = (targetReq != null && targetReq.isNotEmpty)
                    ? targetReq
                    : _prompt.text.trim();
                widget.onMoveToColumn?.call(targetCol, req);
              },
              child: Text(
                widget
                    .tr('Move to {0}')
                    .replaceAll('{0}', widget.tr(targetTitle)),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildProposal(ColorScheme colors) {
    final summary = '${_reply['summary'] ?? ''}';
    final proposal = _reply['proposal'] as String?;
    final limits =
        (_reply['limits'] as Map?)?.cast<String, dynamic>() ?? const {};
    final candidates = (_reply['candidates'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final vram = limits['vram'] as int?;
    final ram = limits['ram'] as int?;
    final freeDisk = limits['free_disk'] as int?;
    final limitsLine = (ram != null || freeDisk != null)
        ? (vram != null && vram > 0
              ? widget
                    .tr('PC: {0} VRAM · {1} RAM · {2} free')
                    .replaceAll('{0}', modelSize(vram))
                    .replaceAll('{1}', modelSize(ram ?? 0))
                    .replaceAll('{2}', modelSize(freeDisk ?? 0))
              : widget
                    .tr('PC: {0} RAM · {1} free')
                    .replaceAll('{0}', modelSize(ram ?? 0))
                    .replaceAll('{1}', modelSize(freeDisk ?? 0)))
        : '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (summary.isNotEmpty) ...[
          Text(summary, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 6),
        ],
        if (limitsLine.isNotEmpty) ...[
          Text(
            limitsLine,
            style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
        ],
        for (final c in candidates)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceContainer,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (c['size'] as int? ?? 0) > 0
                          ? '${c['title']} · ${modelSize(c['size'] as int)}'
                          : '${c['title']}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if ('${c['subtitle'] ?? ''}'.isNotEmpty)
                      Text(
                        c['kind'] == 'agent_action' ||
                                c['kind'] == 'provider_action'
                            ? widget.tr('${c['subtitle']}')
                            : '${c['subtitle']}',
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    if (smartFitLabel(
                      c['fit'] as String?,
                      widget.tr,
                    ).isNotEmpty)
                      Text(
                        smartFitLabel(c['fit'] as String?, widget.tr),
                        style: TextStyle(
                          fontSize: 11,
                          color: c['fit'] == 'too_large'
                              ? colors.error
                              : colors.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    if ('${c['reason'] ?? ''}'.isNotEmpty)
                      Text(
                        '${c['reason']}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    if (c['fit'] != 'too_large' && proposal != null) ...[
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.tonal(
                          key: ValueKey('smart-review-${c['id']}'),
                          onPressed: () {
                            if (c['kind'] == 'provider_action') {
                              // Its own page has the review.
                              _close(refocus: false);
                              widget.onProvider?.call(
                                '${c['step']}',
                                '${c['key']}',
                                '${c['title']}',
                              );
                            } else if ('${c['kind'] ?? ''}'.startsWith(
                                  'mcp_',
                                ) ||
                                c['kind'] == 'model_disconnect') {
                              _openMcp(proposal, c);
                            } else {
                              _openReview(proposal, c);
                            }
                          },
                          child: Text(widget.tr('Review')),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildRunning() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        '${_activeCandidate?['title'] ?? ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      LinearProgressIndicator(value: _runFraction),
      const SizedBox(height: 8),
      if (_runText.isNotEmpty)
        Text(_runText, style: const TextStyle(fontSize: 12)),
    ],
  );

  Widget _buildDone() {
    final title = '${_activeCandidate?['title'] ?? ''}';
    final connectAgents = [
      for (final h in widget.helpers)
        if (h['command'] != 'local-helper') h,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.tr('{0} is ready.').replaceAll('{0}', title),
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        if (connectAgents.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            widget.tr('Connect it to an agent now? (Optional)'),
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final agent in connectAgents)
                ActionChip(
                  label: Text(
                    '${agent['name']}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  onPressed: () => _openConnect('${agent['command']}'),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildError(ColorScheme colors) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(_errorText, style: TextStyle(fontSize: 12, color: colors.error)),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(corners(context));
    final helper = _activeHelper;
    final statusCount = widget.status?.columnCount(widget.column) ?? 0;
    final statusLevel = widget.status?.columnLevel(widget.column) ?? 'ok';
    final statusLabel = statusCount > 0
        ? widget
              .tr('{0}: {1} to fix')
              .replaceAll('{0}', widget.tr(widget.title))
              .replaceAll('{1}', '$statusCount')
        : widget.tr('{0}: all fine').replaceAll('{0}', widget.tr(widget.title));
    final statusButton = Semantics(
      button: true,
      label: statusLabel,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('smart-status-${widget.column}'),
        onTap: _openOnStatus,
        child: SizedBox(
          width: 30,
          height: 38,
          child: Center(
            child: SizedBox(
              key: const ValueKey('smart-status-slot'),
              width: 16,
              height: 16,
              child: SmartStatusIcon(level: statusLevel),
            ),
          ),
        ),
      ),
    );
    final shown = widget.open && Visibility.of(context);
    if (shown != _windowShown) {
      _windowShown = shown;
      _countWindow(shown ? 1 : -1);
      if (shown) _focusOpenCard();
    }
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (_) =>
          shown ? _buildWindow(colors) : const SizedBox.shrink(),
      child: SizedBox(
        width: widget.width,
        height: 38,
        child: Material(
          color: colors.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: colors.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              statusButton,
              Expanded(
                child: Semantics(
                  button: true,
                  toggled: false,
                  label:
                      '${widget.tr('Ask AI…')} · ${widget.tr(widget.title)}${helper == null ? '' : ' · ${helper['name']}'}',
                  child: InkWell(
                    focusNode: _barFocus,
                    onTap: _openOnPrompt,
                    child: SizedBox(
                      height: 38,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 2, right: 10),
                        child: Row(
                          children: [
                            Icon(
                              Icons.auto_awesome,
                              size: 15,
                              color: colors.primary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              widget.tr('Ask AI…'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (helper != null && _chosen(helper)) ...[
                              const SizedBox(width: 6),
                              SmartStatusIcon(
                                key: const ValueKey('smart-helper-chosen'),
                                level: 'ok',
                                size: 14,
                              ),
                            ],
                            if (helper != null)
                              Expanded(
                                child: Text(
                                  ' · ${helper['name']}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              )
                            else
                              const Spacer(),
                            Icon(
                              Icons.expand_more,
                              size: 18,
                              color: colors.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWindow(ColorScheme colors) {
    final actions = _actions();
    return OverlayWindow(
      key: ValueKey('smart-window-${widget.column}'),
      child: Focus(
        focusNode: _cardFocus,
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            _close();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      button: _step == _SmartStep.status,
                      child: InkWell(
                        onTap: _step == _SmartStep.status
                            ? _openOnPrompt
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.max,
                            children: [
                              Icon(
                                Icons.auto_awesome,
                                size: 15,
                                color: colors.primary,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  widget
                                      .tr('Ask AI · {0}')
                                      .replaceAll(
                                        '{0}',
                                        widget.tr(widget.title),
                                      ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Flexible(child: _buildHelperChoice(colors)),
                  IconButton(
                    key: const ValueKey('smart-rules'),
                    tooltip: widget.tr('What may be done'),
                    // A review waits on what was checked when it opened.
                    onPressed:
                        _step == _SmartStep.review ||
                            _step == _SmartStep.connectReview ||
                            _step == _SmartStep.mcpForm
                        ? null
                        : () {
                            // One window at a time: the rules take its place.
                            _close();
                            smartOpenRules?.call();
                          },
                    icon: const Icon(Icons.rule, size: 18),
                  ),
                  IconButton(
                    tooltip: widget.tr('Collapse'),
                    onPressed: _close,
                    icon: const Icon(Icons.expand_less, size: 18),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (_step == _SmartStep.review)
              Expanded(
                child: _activeCandidate?['kind'] == 'agent_action'
                    ? AgentActionReview(
                        plan: _reviewData,
                        tr: widget.tr,
                        onConfirm: _confirmReview,
                        onCancel: () =>
                            setState(() => _step = _SmartStep.proposal),
                      )
                    : _activeCandidate?['kind'] == 'model_move'
                    ? SmartMoveReview(
                        plan: _reviewData,
                        title: '${_activeCandidate?['title'] ?? ''}',
                        subtitle: '${_activeCandidate?['subtitle'] ?? ''}',
                        tr: widget.tr,
                        onConfirm: _confirmReview,
                        onCancel: () =>
                            setState(() => _step = _SmartStep.proposal),
                      )
                    : _reviewData['removal'] != null
                    ? ModelRemovalReview(
                        preview: _reviewData,
                        tr: widget.tr,
                        onConfirm: _confirmReview,
                        onCancel: () =>
                            setState(() => _step = _SmartStep.proposal),
                      )
                    : SmartModelDownloadReview(
                        review: _reviewData,
                        tr: widget.tr,
                        onConfirm: _confirmReview,
                        onCancel: () =>
                            setState(() => _step = _SmartStep.proposal),
                      ),
              )
            else if (_step == _SmartStep.connectReview)
              Expanded(
                child: ConnectionReview(
                  plan: _connectPlan,
                  tr: widget.tr,
                  onConfirm: _applyConnect,
                  onCancel: () {
                    // An apply under way finishes: it has no way back.
                    if (_applyingConnect) return;
                    setState(
                      () => _step = _activeCandidate?['kind'] == null
                          ? _SmartStep.done
                          : _SmartStep.proposal,
                    );
                  },
                ),
              )
            else
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(10),
                  child: switch (_step) {
                    _SmartStep.status => _buildStatus(),
                    _SmartStep.idle => _buildIdle(colors),
                    _SmartStep.working => _buildWorking(),
                    _SmartStep.clarify => _buildClarify(colors),
                    _SmartStep.redirect => _buildRedirect(),
                    _SmartStep.proposal => _buildProposal(colors),
                    _SmartStep.mcpForm => _buildMcpForm(colors),
                    _SmartStep.running => _buildRunning(),
                    _SmartStep.done => _buildDone(),
                    _SmartStep.error => _buildError(colors),
                    _SmartStep.review ||
                    _SmartStep.connectReview => const SizedBox.shrink(),
                  },
                ),
              ),
            if (actions.isNotEmpty) ...[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 6,
                  children: actions,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
