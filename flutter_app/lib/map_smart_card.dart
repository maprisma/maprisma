import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_look.dart' show AppSpace, WindowFooter, WindowHeader, StatusColors;
import 'app_theme.dart' show controlBorder, corners;
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

/// A category's icon and what Ask AI does there (the central window's card).
(IconData, String) _columnAbout(String column) => switch (column) {
  'mcp' => (
    Icons.extension_outlined,
    'Find MCP servers and skills and connect them to your agents.',
  ),
  'agents' => (
    Icons.smart_toy_outlined,
    'Set up agents, check their sign-in, or connect them to providers.',
  ),
  'providers' => (
    Icons.dns_outlined,
    'Set up a provider, or find out why a local LLM is slow.',
  ),
  _ => (
    Icons.view_in_ar_outlined,
    'Find a model that fits this PC, connect it to an agent, or disconnect it.',
  ),
};

String _columnHint(String column) => switch (column) {
  'mcp' => 'Find an MCP server or skill…',
  'agents' => 'Set up or connect an agent…',
  'providers' => 'Set up or tune a provider…',
  'models' => 'Find or connect a model…',
  _ => 'Ask for this column…',
};

/// A category written at the start of the question chooses its checked
/// workflow. The category is UI guidance; the service gets the question only.
({String column, String request}) smartPromptRequest(
  String text,
  String fallback,
  String Function(String) tr,
) {
  final request = text.trim();
  for (final (column, title) in mapSmartColumns) {
    for (final label in {tr(title), title, if (column == 'mcp') 'MCP'}) {
      final prefix = '$label:';
      if (request.toLowerCase().startsWith(prefix.toLowerCase())) {
        return (
          column: column,
          request: request.substring(prefix.length).trim(),
        );
      }
    }
  }
  return (column: fallback, request: request);
}

/// The prompt presets per category: (column, icon, label, prompt). A label
/// ending in "…" starts the question for the user to finish. Tests use the
/// first eight by index: new presets go at the end.
const smartPromptExamples = <(String, IconData, String, String)>[
  (
    'mcp',
    Icons.extension_outlined,
    'Find an MCP server for my notes',
    'Find an MCP server for my notes',
  ),
  (
    'mcp',
    Icons.folder_outlined,
    'Connect a skill folder to an agent',
    'Connect a skill folder to an agent',
  ),
  (
    'agents',
    Icons.person_outline,
    'Which agents need sign-in?',
    'Which agents need sign-in?',
  ),
  (
    'agents',
    Icons.link_outlined,
    'Connect an agent to a provider',
    'Connect an agent to a provider',
  ),
  (
    'providers',
    Icons.speed_outlined,
    'Why is my local LLM slow?',
    'Why is my local LLM slow?',
  ),
  (
    'providers',
    Icons.memory_outlined,
    'Check GPU and context settings',
    'Check GPU and context settings',
  ),
  (
    'models',
    Icons.search_outlined,
    'Find a model that fits my PC',
    'Find a model that fits my PC',
  ),
  (
    'models',
    Icons.link_off_outlined,
    'Disconnect a model from an agent',
    'Disconnect a model from an agent',
  ),
  (
    'mcp',
    Icons.add_circle_outline,
    'Add an MCP server…',
    'Add the MCP server ',
  ),
  (
    'mcp',
    Icons.remove_circle_outline,
    'Remove an MCP server…',
    'Remove the MCP server ',
  ),
  (
    'mcp',
    Icons.update,
    'Which MCP servers have updates?',
    'Which MCP servers have updates?',
  ),
  (
    'agents',
    Icons.add_circle_outline,
    'Set up a new agent…',
    'Set up the agent ',
  ),
  ('agents', Icons.update, 'Update an agent…', 'Update the agent '),
  (
    'agents',
    Icons.system_update_alt,
    'Which agents have updates?',
    'Which agents have updates?',
  ),
  (
    'providers',
    Icons.add_circle_outline,
    'Set up a provider…',
    'Set up the provider ',
  ),
  (
    'providers',
    Icons.link_outlined,
    'Connect a provider to an agent…',
    'Connect the provider ',
  ),
  (
    'providers',
    Icons.play_circle_outline,
    'Which providers are running?',
    'Which providers are running?',
  ),
  (
    'models',
    Icons.download_outlined,
    'Download a model…',
    'Download the model ',
  ),
  ('models', Icons.delete_outline, 'Remove a model…', 'Remove the model '),
  (
    'models',
    Icons.drive_file_move_outline,
    'Move models to another folder',
    'Move models to another folder',
  ),
];

/// At most this many suggestions per category (setting ask_prompts).
const smartPromptMax = 12;

/// The built-in examples of [column]: their indexes in [smartPromptExamples].
List<int> smartBuiltinPrompts(String column) => [
  for (final (i, e) in smartPromptExamples.indexed)
    if (e.$1 == column) i,
];

/// The stored setting ask_prompts as {column: [int | String]}: an int keeps
/// that built-in example, a string is the user's own request. Anything that
/// does not fit is left out (the core checks it too).
Map<String, List<Object>> smartPromptsFromSetting(Object? value) {
  final out = <String, List<Object>>{};
  if (value is! Map) return out;
  for (final entry in value.entries) {
    final column = entry.key;
    final items = entry.value;
    if (column is! String || items is! List) continue;
    final builtins = smartBuiltinPrompts(column);
    out[column] = [
      for (final item in items.take(smartPromptMax))
        if (item is int && builtins.contains(item))
          item
        else if (item is String && item.trim().isNotEmpty)
          item.trim(),
    ];
  }
  return out;
}

/// One line, single spaces: how a request is kept as a suggestion.
String smartPromptOneLine(String text) =>
    text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');

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
  Widget build(BuildContext context) => TaskReview(
    title: Text(
      tr('Move model folder'),
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
    actions: [
      TextButton(onPressed: onCancel, child: Text(tr('Cancel'))),
      FilledButton(
        key: const ValueKey('smart-move-confirm'),
        onPressed: onConfirm,
        child: Text(tr('Move model folder')),
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
/// Tips and updates are information; only actionable problems use an alarm.
class SmartStatusIcon extends StatelessWidget {
  const SmartStatusIcon({super.key, required this.level, this.size = 16});
  final String level;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return switch (level) {
      'warn' => Icon(Icons.error, size: size, color: colors.error),
      'hint' => Icon(Icons.info_outline, size: size, color: colors.primary),
      _ => Icon(Icons.check_circle, size: size, color: StatusColors.ok),
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
    // The core marks only real problems 'warn' (no agent, not signed in, a
    // broken connection, a full disk); tips and updates stay information.
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
  performance,
  error,
}

class MapSmartCard extends StatefulWidget {
  const MapSmartCard({
    super.key,
    this.takesRequests = true,
    this.showBar = true,
    this.onProvider,
    this.onMenu,
    this.performancePage,
    this.onTask,
    required this.column,
    required this.title,
    required this.open,
    this.enabled = true,
    required this.onToggle,
    this.onColumnChanged,
    required this.tr,
    this.helpers = const [],
    this.client,
    this.initialPrompt,
    this.onMoveToColumn,
    this.onApplied,
    this.status,
    this.statusTrigger = 0,
    this.promptTrigger = 0,
    this.width = 266,
  });

  /// A column whose helper is not built yet says so before anyone types.
  final bool takesRequests;

  /// Whether the per-column bar is shown on the canvas; false when hosted
  /// centrally from the header bar.
  final bool showBar;

  /// A provider step the user chose: (install, update, start or stop, key).
  final void Function(String step, String key, String name)? onProvider;

  /// A menu action Ask AI proposed (kind menu_action: area, step, key,
  /// model): the app opens that menu itself, with its own preview, review
  /// and Undo.
  final ValueChanged<Map<String, dynamic>>? onMenu;

  /// A local LLM's Performance as a page of this window (Ask AI keeps it
  /// open): aside runs a review in the window's place (a change, a
  /// measurement), then the window comes back on a fresh Performance page;
  /// back returns to the proposal. Null: Performance opens as its own card.
  final Future<Widget> Function(
    String key, {
    required void Function(Future<bool> Function() review) aside,
    required VoidCallback back,
  })?
  performancePage;

  /// A reviewed task for an agent in a terminal (system.help_apply).
  final ValueChanged<Map<String, dynamic>>? onTask;
  final String column;
  final String title;
  final bool open;
  final bool enabled;
  final VoidCallback onToggle;
  final ValueChanged<String>? onColumnChanged;
  final String Function(String) tr;
  final List<Map<String, dynamic>> helpers;
  final CoreClient? client;
  final String? initialPrompt;
  final void Function(String column, String request)? onMoveToColumn;

  final ValueChanged<Map<String, dynamic>>? onApplied;
  final SmartStatusData? status;
  final int statusTrigger;
  final int promptTrigger;
  final double width;

  @override
  State<MapSmartCard> createState() => _MapSmartCardState();
}

class _MapSmartCardState extends State<MapSmartCard> {
  final _prompt = TextEditingController();
  final _examplesScroll = ScrollController();
  final _barFocus = FocusNode();
  final _cardFocus = FocusNode();
  final _fieldFocus = FocusNode();
  final _portal = OverlayPortalController();
  bool _windowShown = false;

  /// Settings › ask_prompts: the suggestions per category (absent: built-in).
  Map<String, List<Object>> _askPrompts = {};
  int? _editingPrompt;
  final _promptEdit = TextEditingController();
  final _promptEditFocus = FocusNode();
  String _promptNote = '';
  late String _column = widget.column;
  _SmartStep _step = _SmartStep.idle;

  String get _columnTitle =>
      mapSmartColumns.where((c) => c.$1 == _column).firstOrNull?.$2 ??
      widget.title;

  void _retargetPrefixedPrompt(String column) {
    final current = _prompt.text.trim();
    final parsed = smartPromptRequest(current, _column, widget.tr);
    if (parsed.request == current) return;
    final title = mapSmartColumns.where((c) => c.$1 == column).firstOrNull?.$2;
    if (title == null) return;
    final text = '${widget.tr(title)}: ${parsed.request}';
    _prompt.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

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
  Widget? _performancePage;
  int _performanceToken = 0;
  _SmartStep _errorReturnTo = _SmartStep.idle;
  Map<String, dynamic>? _dictation;
  bool _dictationRecording = false;
  bool _dictationTranscribing = false;
  String? _dictationHandle;
  bool _showDictationSetup = false;
  String _dictationError = '';

  void _cancelDictationRecording() {
    if (!_dictationRecording) return;
    final handle = _dictationHandle;
    _dictationRecording = false;
    _dictationHandle = null;
    final client = widget.client;
    if (client != null) {
      unawaited(
        client
            .dictationStop(recording: handle, cancel: true)
            .then((_) {}, onError: (_) {}),
      );
    }
  }

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
      if (_step == _SmartStep.idle &&
          widget.takesRequests &&
          widget.helpers.isNotEmpty) {
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
    unawaited(_loadAskPrompts());
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
    if (widget.column != oldWidget.column && !_atWork) {
      _retargetPrefixedPrompt(widget.column);
      _column = widget.column;
      _editingPrompt = null;
    }
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
    if (widget.promptTrigger != oldWidget.promptTrigger &&
        widget.promptTrigger > 0 &&
        !_atWork &&
        _step == _SmartStep.status) {
      _step = _SmartStep.idle;
      if (widget.open) _focusOpenCard();
    }
    if (oldWidget.enabled && !widget.enabled && _step == _SmartStep.working) {
      _abortWorking();
    }
    if (!oldWidget.open && widget.open) {
      _focusOpenCard();
    } else if (oldWidget.open && !widget.open) {
      _cancelDictationRecording();
      _showDictationSetup = false;
      _dictationError = '';
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
    _cancelDictationRecording();
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
    _cancelDictationRecording();
    // A Performance page still loading never lands in a closed window; opened
    // again, Ask AI shows the proposal (Codex review).
    if (_step == _SmartStep.performance) {
      _performanceToken++;
      setState(() {
        _step = _SmartStep.proposal;
        _performancePage = null;
      });
    }
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

  /// Performance inside the window: a spinner while its settings are read
  /// (that can take ten seconds and more), then the page.
  Future<void> _openPerformance(String key) async {
    final token = ++_performanceToken;
    setState(() {
      _step = _SmartStep.performance;
      _performancePage = null;
    });
    try {
      final page = await widget.performancePage!(
        key,
        aside: (review) => unawaited(_aside(key, review)),
        back: _leavePerformance,
      );
      if (!mounted ||
          token != _performanceToken ||
          _step != _SmartStep.performance) {
        return;
      }
      setState(() => _performancePage = page);
    } catch (error) {
      if (!mounted ||
          token != _performanceToken ||
          _step != _SmartStep.performance) {
        return;
      }
      setState(() {
        _errorText = failureText(widget.tr, error);
        _errorReturnTo = _SmartStep.proposal;
        _step = _SmartStep.error;
      });
    }
  }

  /// A change or a measurement from the Performance page: its review takes
  /// the window's place; afterwards (applied or not) Ask AI is back on the
  /// Performance page, read again, so Back still leads step by step.
  /// The review says whether to come back (false: the user moved on to
  /// something else meanwhile, or another card took its place).
  Future<void> _aside(String key, Future<bool> Function() review) async {
    _performanceToken++;
    _close(refocus: false);
    var back = false;
    try {
      back = await review();
    } finally {
      if (mounted && back && !widget.open) {
        widget.onToggle();
        unawaited(_openPerformance(key));
      }
    }
  }

  void _leavePerformance() {
    _performanceToken++;
    setState(() {
      _step = _SmartStep.proposal;
      _performancePage = null;
    });
  }

  /// Back: from a result to the main Ask AI page (the question stays), from
  /// there to the map (Esc closes at once). A download or a connection under way
  /// goes on in the background: the window only closes.
  void _back() {
    if (_step == _SmartStep.idle ||
        _step == _SmartStep.status ||
        _step == _SmartStep.running ||
        _applyingConnect) {
      _close();
    } else if (_step == _SmartStep.working) {
      _cancelTask();
    } else if (_step == _SmartStep.performance) {
      _leavePerformance();
    } else {
      _backToIdle();
    }
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
    final parsed = smartPromptRequest(_prompt.text, _column, widget.tr);
    final request = parsed.request;
    final helper = _activeHelper;
    final client = widget.client;
    if (request.isEmpty || helper == null || client == null) return;
    if (parsed.column != _column) {
      setState(() => _column = parsed.column);
      widget.onColumnChanged?.call(parsed.column);
    }
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
        column: parsed.column,
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
      for (final field in _mcpFields.values) {
        field.dispose();
      }
      _mcpFields.clear();
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
    } catch (error) {
      if (!mounted || token != _runToken) return;
      setState(() {
        _errorText = failureText(widget.tr, error);
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
              border: controlBorder(context),
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
    } catch (error) {
      if (!mounted || token != _runToken) return;
      _activeTask = null;
      setState(() {
        _errorText = failureText(widget.tr, error);
        _step = _SmartStep.error;
      });
    } finally {
      _applyingConnect = false;
    }
  }

  @override
  void dispose() {
    _cancelDictationRecording();
    smartHelperChosen.removeListener(_helperChanged);
    dictationChanged.removeListener(_loadDictation);
    if (_windowShown) _countWindow(-1);
    _runToken++;
    _prompt.dispose();
    _examplesScroll.dispose();
    _promptEdit.dispose();
    _promptEditFocus.dispose();
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
    // Back in the header leaves the window; the footer only goes on.
    final back = TextButton(
      key: const ValueKey('smart-ask-again'),
      onPressed: _backToIdle,
      child: Text(tr('Ask again')),
    );
    final onFirstAgent = widget.status?.onAction;
    return switch (_step) {
      _SmartStep.idle when !widget.takesRequests => const [],
      _SmartStep.idle when widget.helpers.isEmpty => [
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
      // Ask is the symbol in the field's corner (Enter).
      _SmartStep.idle => const [],
      _SmartStep.status => [
        TextButton(
          key: const ValueKey('health-again'),
          onPressed: widget.status?.onCheckAgain,
          child: Text(tr('Check again')),
        ),
        if (widget.takesRequests)
          FilledButton(
            key: const ValueKey('smart-status-ask'),
            onPressed: _openOnPrompt,
            child: Text(tr('Ask')),
          ),
      ],
      _SmartStep.working => [
        TextButton(onPressed: _cancelTask, child: Text(tr('Cancel'))),
      ],
      _SmartStep.clarify ||
      _SmartStep.redirect ||
      _SmartStep.proposal => [back],
      _SmartStep.mcpForm => [
        TextButton(
          onPressed: () => setState(() => _step = _SmartStep.proposal),
          child: Text(tr('Cancel')),
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
        FilledButton.tonal(onPressed: _tryAgain, child: Text(tr('Try again'))),
      ],
      // Its own footer (TaskReview).
      _SmartStep.performance ||
      _SmartStep.review ||
      _SmartStep.connectReview => const [],
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
        _dictationTranscribing = snap['transcribing'] == true;
      });
    } catch (_) {}
  }

  Future<void> _toggleDictation() async {
    final client = widget.client;
    if (client == null || _dictationTranscribing) return;
    setState(() => _dictationError = '');
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
      } catch (e) {
        if (!mounted) return;
        setState(() => _dictationError = failureText(widget.tr, e));
      }
      return;
    }
    _fieldFocus.requestFocus();
    final handle = _dictationHandle;
    setState(() {
      _dictationRecording = false;
      _dictationHandle = null;
      _dictationTranscribing = true;
    });
    try {
      final stopped = await client.dictationStop(recording: handle);
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
        _dictationTranscribing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _dictationTranscribing = false;
        _dictationError = failureText(widget.tr, e);
      });
    }
  }

  Future<void> _updateDictationEngine(String engine) async {
    final client = widget.client;
    if (client == null) return;
    setState(() => _dictationError = '');
    try {
      await client.settingsUpdate(values: {'dictation_engine': engine});
      dictationChanged.value++;
      await _loadDictation();
    } catch (e) {
      if (!mounted) return;
      setState(() => _dictationError = failureText(widget.tr, e));
    }
  }

  Future<void> _runDictationAction(String action, [String? target]) async {
    final client = widget.client;
    if (client == null) return;
    setState(() => _dictationError = '');
    try {
      await client.dictationRun(action: action, target: target);
      dictationChanged.value++;
      await _loadDictation();
    } catch (e) {
      if (!mounted) return;
      setState(() => _dictationError = failureText(widget.tr, e));
    }
  }

  Widget _buildDictationSuffix(ColorScheme colors, bool ready, String active) {
    final Widget micIcon;
    if (_dictationTranscribing) {
      micIcon = const SizedBox(
        key: ValueKey('smart-dictation-transcribing'),
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (_dictationRecording) {
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
            tooltip: _dictationTranscribing
                ? widget.tr('Transcribing…')
                : _dictationRecording
                ? widget.tr('Stop dictation')
                : ready
                ? widget.tr('Dictate')
                : widget.tr('On · not set up yet'),
            icon: micIcon,
            onPressed: _dictationTranscribing ? null : _toggleDictation,
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

  Future<void> _loadAskPrompts() async {
    final client = widget.client;
    if (client == null) return;
    try {
      final settings = await client.settingsGet();
      if (!mounted) return;
      setState(
        () => _askPrompts = smartPromptsFromSetting(settings['ask_prompts']),
      );
    } catch (_) {
      // Built-in suggestions until the settings can be read.
    }
  }

  List<Object> _promptItems(String column) =>
      _askPrompts[column] ?? smartBuiltinPrompts(column);

  String _promptText(Object item) => item is int
      ? smartPromptOneLine(widget.tr(smartPromptExamples[item].$4))
      : item as String;

  /// Keeps [items] as [column]'s suggestions (null: the built-in ones again)
  /// and saves the setting.
  Future<void> _storePrompts(String column, List<Object>? items) async {
    final next = {..._askPrompts};
    final builtins = smartBuiltinPrompts(column);
    if (items == null ||
        (items.length == builtins.length &&
            [
              for (var i = 0; i < items.length; i++) items[i] == builtins[i],
            ].every((same) => same))) {
      next.remove(column);
    } else {
      next[column] = items;
    }
    setState(() {
      _askPrompts = next;
      _editingPrompt = null;
    });
    final client = widget.client;
    if (client == null) return;
    try {
      await client.settingsUpdate(values: {'ask_prompts': next});
    } catch (_) {
      if (mounted) {
        setState(
          () => _promptNote = widget.tr('Could not save the suggestions.'),
        );
      }
    }
  }

  /// The bookmark by the question: what is typed becomes a suggestion of
  /// this category (its "Category:" prefix left out).
  void _saveAsPrompt() {
    final text = smartPromptOneLine(
      smartPromptRequest(_prompt.text, _column, widget.tr).request,
    );
    final items = _promptItems(_column);
    String note;
    if (text.isEmpty) {
      note = widget.tr('Write a request first, then save it as a suggestion.');
    } else if (text.length > 2000) {
      note = widget.tr('Too long for a suggestion.');
    } else if (items.map(_promptText).contains(text)) {
      note = widget.tr('That is already a suggestion.');
    } else if (items.length >= smartPromptMax) {
      note = widget
          .tr('At most {0} suggestions: remove one first.')
          .replaceAll('{0}', '$smartPromptMax');
    } else {
      unawaited(_storePrompts(_column, [...items, text]));
      note = widget.tr('Saved as suggestion.');
    }
    setState(() => _promptNote = note);
  }

  void _removePrompt(int position) {
    final items = [..._promptItems(_column)];
    if (position < 0 || position >= items.length) return;
    items.removeAt(position);
    unawaited(_storePrompts(_column, items));
  }

  void _startPromptEdit(int position) {
    final items = _promptItems(_column);
    if (position < 0 || position >= items.length) return;
    _promptEdit.text = _promptText(items[position]);
    setState(() {
      _editingPrompt = position;
      _promptNote = '';
    });
    _promptEditFocus.requestFocus();
  }

  /// Enter or ✓ keeps the edit (an empty text removes the suggestion); Esc
  /// ends it unchanged.
  void _finishPromptEdit(bool save) {
    final position = _editingPrompt;
    if (position == null) return;
    final items = [..._promptItems(_column)];
    final text = smartPromptOneLine(_promptEdit.text);
    if (!save ||
        position >= items.length ||
        text == _promptText(items[position])) {
      setState(() => _editingPrompt = null);
    } else if (text.isEmpty) {
      items.removeAt(position);
      unawaited(_storePrompts(_column, items));
    } else if (text.length > 2000) {
      setState(() => _promptNote = widget.tr('Too long for a suggestion.'));
      return;
    } else if ([
      for (final (i, item) in items.indexed)
        if (i != position) _promptText(item),
    ].contains(text)) {
      setState(() => _promptNote = widget.tr('That is already a suggestion.'));
      return;
    } else {
      items[position] = text;
      unawaited(_storePrompts(_column, items));
    }
    _fieldFocus.requestFocus();
  }

  void _pickPrompt(Object item) {
    // A started prompt keeps its trailing space: the user names the item.
    final title = _columnTitle;
    final example = item is int ? smartPromptExamples[item].$4 : item as String;
    final text = item is int ? widget.tr(example.trimRight()) : example;
    final prompt =
        '${widget.tr(title)}: $text${item is int && example.endsWith(' ') ? ' ' : ''}';
    setState(() {
      _prompt.text = prompt;
      _prompt.selection = TextSelection.collapsed(offset: prompt.length);
    });
    _fieldFocus.requestFocus();
  }

  Widget _buildPromptChip(int position, Object item) {
    if (_editingPrompt == position) {
      return Row(
        key: const ValueKey('smart-prompt-editing'),
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 280,
            child: Focus(
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.escape) {
                  _finishPromptEdit(false);
                  _fieldFocus.requestFocus();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                key: const ValueKey('smart-prompt-edit-field'),
                controller: _promptEdit,
                focusNode: _promptEditFocus,
                maxLength: 2000,
                style: const TextStyle(fontSize: 12),
                decoration: InputDecoration(
                  isDense: true,
                  counterText: '',
                  labelText: widget.tr('Edit suggestion'),
                  border: controlBorder(context),
                ),
                onSubmitted: (_) => _finishPromptEdit(true),
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('smart-prompt-edit-done'),
            visualDensity: VisualDensity.compact,
            tooltip: widget.tr('Save'),
            icon: const Icon(Icons.check, size: 16),
            onPressed: () => _finishPromptEdit(true),
          ),
        ],
      );
    }
    final builtin = item is int ? smartPromptExamples[item] : null;
    final text = _promptText(item);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        InputChip(
          key: ValueKey(
            builtin != null ? 'smart-example-$item' : 'smart-own-$position',
          ),
          avatar: builtin != null ? Icon(builtin.$2, size: 16) : null,
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Text(
              builtin != null ? widget.tr(builtin.$3) : text,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          tooltip: text,
          onPressed: () => _pickPrompt(item),
          deleteIcon: const Icon(Icons.close, size: 14),
          deleteButtonTooltipMessage: widget.tr('Remove suggestion'),
          onDeleted: () => _removePrompt(position),
        ),
        IconButton(
          key: ValueKey('smart-prompt-edit-$position'),
          visualDensity: VisualDensity.compact,
          tooltip: widget.tr('Edit suggestion'),
          icon: const Icon(Icons.edit_outlined, size: 14),
          onPressed: () => _startPromptEdit(position),
        ),
      ],
    );
  }

  /// The central window's prompt helps, as in the Launcher's Ask AI: a row
  /// to choose the category, then its card with the examples on one line
  /// that scrolls sideways when it is too long. An example only fills the
  /// question: Ask sends it.
  Widget _buildPromptExamples(ColorScheme colors) {
    final title = _columnTitle;
    final (icon, about) = _columnAbout(_column);
    return Column(
      key: const ValueKey('smart-prompt-examples'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          key: const ValueKey('smart-categories'),
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (col, colTitle) in mapSmartColumns)
              ChoiceChip(
                key: ValueKey('smart-category-$col'),
                selected: _column == col,
                avatar: Icon(_columnAbout(col).$1, size: 16),
                label: Text(widget.tr(colTitle)),
                onSelected: (_) {
                  if (col == _column) return;
                  // A column's own window: the other category is the
                  // other column's window (as Move to).
                  final move = widget.onMoveToColumn;
                  if (widget.showBar && move != null) {
                    move(
                      col,
                      smartPromptRequest(
                        _prompt.text,
                        _column,
                        widget.tr,
                      ).request,
                    );
                    return;
                  }
                  setState(() {
                    _retargetPrefixedPrompt(col);
                    _column = col;
                    _editingPrompt = null;
                  });
                  widget.onColumnChanged?.call(col);
                  _fieldFocus.requestFocus();
                },
              ),
          ],
        ),
        const SizedBox(height: AppSpace.sm),
        Container(
          key: ValueKey('smart-category-card-$_column'),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(corners(context)),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: colors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.tr(title),
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${widget.tr(about)} ${widget.tr('Only Ask sends the question.')}',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              _ScrollArrows(
                key: ValueKey('smart-presets-$_column'),
                controller: _examplesScroll,
                tr: widget.tr,
                child: SingleChildScrollView(
                  controller: _examplesScroll,
                  primary: false,
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final (position, item) in _promptItems(
                        _column,
                      ).indexed)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: _buildPromptChip(position, item),
                        ),
                      if (_askPrompts.containsKey(_column))
                        IconButton(
                          key: const ValueKey('smart-prompts-reset'),
                          visualDensity: VisualDensity.compact,
                          tooltip: widget.tr(
                            'Back to the built-in suggestions',
                          ),
                          icon: const Icon(Icons.undo, size: 16),
                          onPressed: () =>
                              unawaited(_storePrompts(_column, null)),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Ctrl+Enter: a line break at the cursor (Enter alone asks).
  void _newLine() {
    final value = _prompt.value;
    final sel = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    _prompt.value = TextEditingValue(
      text: value.text.replaceRange(sel.start, sel.end, '\n'),
      selection: TextSelection.collapsed(offset: sel.start + 1),
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
        // As the Launcher: Enter asks, Ctrl+Enter starts a new line.
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter, control: true):
                _newLine,
            const SingleActivator(
              LogicalKeyboardKey.numpadEnter,
              control: true,
            ): _newLine,
          },
          child: TextField(
            controller: _prompt,
            focusNode: _fieldFocus,
            autofocus: true,
            minLines: 1,
            maxLines: 4,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) {
              if (!_dictationRecording && !_dictationTranscribing) _ask();
              _fieldFocus.requestFocus();
            },
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: _dictationTranscribing
                  ? widget.tr('Transcribing…')
                  : _dictationRecording
                  ? widget.tr('Listening… Click Stop when done.')
                  : widget.showBar
                  ? widget.tr(_columnHint(_column))
                  : '${widget.tr(_columnTitle)}: ${widget.tr(_columnHint(_column))}',
              border: controlBorder(context),
              // The microphone (when on) and Ask in the field's right corner.
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showMic)
                    _buildDictationSuffix(colors, dictReady, dictActive),
                  IconButton(
                    key: const ValueKey('smart-save-prompt'),
                    tooltip: widget.tr('Save as suggestion'),
                    onPressed: _saveAsPrompt,
                    icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                  ),
                  IconButton(
                    key: const ValueKey('smart-send'),
                    tooltip:
                        '${widget.tr('Ask')} · ${widget.tr('Enter asks, Ctrl+Enter: new line.')}',
                    onPressed: _dictationRecording || _dictationTranscribing
                        ? null
                        : () => _ask(),
                    icon: Icon(Icons.send, color: colors.primary),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        _buildPromptExamples(colors),
        if (_promptNote.isNotEmpty) ...[
          const SizedBox(height: AppSpace.xs),
          Text(
            _promptNote,
            key: const ValueKey('smart-prompt-note'),
            style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
          ),
        ],
        if (_dictationError.isNotEmpty) ...[
          const SizedBox(height: AppSpace.xs),
          Text(
            _dictationError,
            key: const ValueKey('smart-dictation-error'),
            style: TextStyle(fontSize: 11, color: colors.error),
          ),
        ],
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
    final findings = status?.findingsFor(_column) ?? const [];
    final addonHints = status?.addonHintsFor(_column) ?? const [];
    final updates = status?.updatesFor(_column) ?? const [];
    final mcpUpdates = status?.mcpUpdatesFor(_column) ?? const [];
    final empty =
        findings.isEmpty &&
        addonHints.isEmpty &&
        updates.isEmpty &&
        mcpUpdates.isEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.showBar)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (col, colTitle) in mapSmartColumns)
                  ChoiceChip(
                    key: ValueKey('smart-status-$col'),
                    visualDensity: VisualDensity.compact,
                    selected: _column == col,
                    avatar: SmartStatusIcon(
                      level: status?.columnLevel(col) ?? 'ok',
                      size: 14,
                    ),
                    label: Text(
                      widget.tr(colTitle),
                      style: const TextStyle(fontSize: 12),
                    ),
                    onSelected: (_) {
                      setState(() {
                        _retargetPrefixedPrompt(col);
                        _column = col;
                        _editingPrompt = null;
                      });
                      widget.onColumnChanged?.call(col);
                    },
                  ),
              ],
            ),
          ),
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
              .replaceAll('{1}', widget.tr(_columnTitle)),
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
            targetCol != _column) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              onPressed: () {
                final req = (targetReq != null && targetReq.isNotEmpty)
                    ? targetReq
                    : _prompt.text.trim();
                if (widget.onMoveToColumn != null) {
                  widget.onMoveToColumn!(targetCol, req);
                } else {
                  final question = smartPromptRequest(
                    req,
                    _column,
                    widget.tr,
                  ).request;
                  final prefixed = question.isEmpty
                      ? ''
                      : '${widget.tr(targetTitle)}: $question';
                  setState(() {
                    _column = targetCol;
                    _prompt.text = prefixed;
                    _prompt.selection = TextSelection.collapsed(
                      offset: prefixed.length,
                    );
                    _step = _SmartStep.idle;
                  });
                  widget.onColumnChanged?.call(targetCol);
                  _fieldFocus.requestFocus();
                }
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
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceContainer,
                borderRadius: BorderRadius.circular(corners(context)),
                border: Border.all(color: colors.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (c['size'] as int? ?? 0) > 0
                          ? '${c['title']} · ${modelSize(c['size'] as int)}'
                          // A page of the app, named by the core in English.
                          : c['kind'] == 'menu_action' &&
                                '${c['key'] ?? ''}'.isEmpty
                          ? widget.tr('${c['title']}')
                          : '${c['title']}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if ('${c['subtitle'] ?? ''}'.isNotEmpty)
                      Text(
                        c['kind'] == 'agent_action' ||
                                c['kind'] == 'provider_action' ||
                                c['kind'] == 'menu_action'
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
                            if (c['kind'] == 'provider_action' &&
                                c['step'] == 'performance' &&
                                widget.performancePage != null) {
                              // Shown here: the window stays open.
                              _openPerformance('${c['key']}');
                            } else if (c['kind'] == 'menu_action') {
                              // The app's own menu, with its own review.
                              _close(refocus: false);
                              widget.onMenu?.call(
                                Map<String, dynamic>.from(c as Map),
                              );
                            } else if (c['kind'] == 'provider_action') {
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
                                c['kind'] == 'model_disconnect' ||
                                c['kind'] == 'skill_connect' ||
                                c['kind'] == 'map_edit') {
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
    // The agents the manual Connect offers for a local LLM, from the core.
    final connectAgents = [
      for (final a in _activeCandidate?['connect'] as List? ?? const [])
        if (a is Map) a,
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
      child: !widget.showBar
          ? Focus(
              focusNode: _barFocus,
              skipTraversal: true,
              child: const SizedBox.shrink(),
            )
          : SizedBox(
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
                              padding: const EdgeInsets.only(
                                left: 2,
                                right: 10,
                              ),
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
                                      key: const ValueKey(
                                        'smart-helper-chosen',
                                      ),
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
    // A step change can remove the control that had the keyboard; focus then
    // falls back above the window and Esc would no longer reach it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.open || _cardFocus.hasFocus) return;
      final now = FocusManager.instance.primaryFocus;
      if (now == null || _cardFocus.ancestors.contains(now)) {
        // Where opening puts it: the question field when it is shown.
        (_step == _SmartStep.idle &&
                    widget.takesRequests &&
                    widget.helpers.isNotEmpty
                ? _fieldFocus
                : _cardFocus)
            .requestFocus();
      }
    });
    // The central window (no bar) is one window whose category changes: one key, so a
    // category switch keeps its size and the question field. Bar cards are one per column.
    final window = OverlayWindow(
      key: ValueKey(widget.showBar ? 'smart-window-$_column' : 'smart-window'),
      child: Focus(
        focusNode: _cardFocus,
        autofocus: true,
        onKeyEvent: (_, event) {
          // Esc leaves Ask AI for the map at once; Back goes step by step.
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
            WindowHeader(
              title: widget
                  .tr('Ask AI · {0}')
                  .replaceAll('{0}', widget.tr(_columnTitle)),
              tr: widget.tr,
              backKey: const ValueKey('smart-back'),
              onBack: _back,
              actions: [
                // The helper's name and cost: never wider than a third.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 300),
                  child: _buildHelperChoice(colors),
                ),
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
                  icon: const Icon(Icons.rule),
                ),
              ],
            ),
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
            else if (_step == _SmartStep.performance)
              Expanded(
                key: const ValueKey('smart-performance'),
                child:
                    _performancePage ??
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: AppSpace.md),
                          Text(widget.tr('Checking…')),
                        ],
                      ),
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
                  padding: const EdgeInsets.all(AppSpace.lg),
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
                    _SmartStep.performance ||
                    _SmartStep.connectReview => const SizedBox.shrink(),
                  },
                ),
              ),
            if (actions.isNotEmpty) WindowFooter(children: actions),
          ],
        ),
      ),
    );
    return !widget.showBar
        ? KeyedSubtree(key: const ValueKey('smart-card'), child: window)
        : window;
  }
}

/// A sideways line with ‹ › at its ends while there is more to see that way
/// (the mouse wheel does not scroll sideways).
class _ScrollArrows extends StatefulWidget {
  const _ScrollArrows({
    super.key,
    required this.controller,
    required this.tr,
    required this.child,
  });
  final ScrollController controller;
  final String Function(String) tr;
  final Widget child;
  @override
  State<_ScrollArrows> createState() => _ScrollArrowsState();
}

class _ScrollArrowsState extends State<_ScrollArrows> {
  bool _left = false, _right = false;

  @override
  void initState() {
    super.initState();
    // The first layout: the right arrow when the line is already too long.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = widget.controller;
      if (mounted && c.hasClients && c.position.hasContentDimensions) {
        _update(c.position);
      }
    });
  }

  void _update(ScrollMetrics m) {
    final left = m.pixels > m.minScrollExtent + 1;
    final right = m.pixels < m.maxScrollExtent - 1;
    if (left != _left || right != _right) {
      setState(() {
        _left = left;
        _right = right;
      });
    }
  }

  void _step(double direction) {
    final c = widget.controller;
    if (!c.hasClients) return;
    final p = c.position;
    c.animateTo(
      (p.pixels + direction * p.viewportDimension * .8).clamp(
        p.minScrollExtent,
        p.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Widget _arrow(Key key, IconData icon, String tip, double direction) =>
      IconButton(
        key: key,
        visualDensity: VisualDensity.compact,
        tooltip: widget.tr(tip),
        onPressed: () => _step(direction),
        icon: Icon(icon, size: 20),
      );

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (_left)
        _arrow(
          const ValueKey('smart-presets-left'),
          Icons.chevron_left,
          'Scroll left',
          -1,
        ),
      Expanded(
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: (n) {
            _update(n.metrics);
            return false;
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              _update(n.metrics);
              return false;
            },
            child: widget.child,
          ),
        ),
      ),
      if (_right)
        _arrow(
          const ValueKey('smart-presets-right'),
          Icons.chevron_right,
          'Scroll right',
          1,
        ),
    ],
  );
}
