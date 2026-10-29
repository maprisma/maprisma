import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';

import 'backend.dart';
import 'map_benchmark.dart';
import 'map_snapshot.dart';
import 'task_card.dart';
import 'agent_terminal.dart';
import 'agent_map.dart';
import 'agent_list_view.dart';
import 'agent_details_view.dart';
import 'settings_view.dart';
import 'app_theme.dart';
import 'project_start_menu.dart';
import 'addon_details.dart';
import 'map_groups.dart';
import 'map_welcome.dart';
import 'map_addons_focus.dart';
import 'first_agent_view.dart';
import 'installer_review.dart';
import 'agent_security_view.dart';
import 'api_key_review.dart';
import 'performance_view.dart';
import 'interrupted_jobs.dart';
import 'help_view.dart';
import 'map_layout.dart' show withAgentLinks;
import 'open_problems_view.dart';
import 'agent_action_dialog.dart';
import 'providers_view.dart';
import 'system_map_view.dart';
import 'provider_task_dialog.dart';
import 'connections_view.dart';
import 'model_removal_dialog.dart';
import 'subagents_dialog.dart';

void main(List<String> args) async {
  if (args.isNotEmpty && args.first.startsWith('--map-benchmark')) {
    final options = MapBenchmarkOptions.parse(args);
    WidgetsFlutterBinding.ensureInitialized();
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1600, 1400));
    runApp(MapBenchmark(options: options));
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  runApp(const AsterismApp());
}

class AsterismApp extends StatefulWidget {
  const AsterismApp({super.key, this.connectBackend});

  /// Allows isolated service fixtures; production always starts its bundled service.
  final Future<Backend> Function()? connectBackend;

  @override
  State<AsterismApp> createState() => _AsterismAppState();
}

class _AsterismAppState extends State<AsterismApp> with WindowListener {
  final _navigator = GlobalKey<NavigatorState>();
  final _terminals = <AgentTerminal>[];
  final _startMenu = ProjectStartMenuController();
  AgentTerminal? _visibleTerminal;
  bool _closing = false;
  int _reviewDepth = 0;
  Backend? _backend;
  Map<String, dynamic>? _snapshot;
  Map<String, String> _strings = {};
  String? _selected;
  bool _busy = true;
  bool _failed = false;
  Locale? _locale;
  String _search = '';
  bool _showMap = true;
  bool _showSystemMap = false;
  bool _systemRefreshing = false;
  Map<String, dynamic> _system = {
    'nodes': [],
    'edges': [],
    'notes': [],
    'helpers': [],
    'limited': false,
  };
  final _aiTransform = TransformationController();
  final _systemTransform = TransformationController();
  Map<String, dynamic>? _graph;
  Map<String, dynamic>? _agentInfo;
  bool _showSettings = false;
  int? _focusCategory;
  bool _welcome = false;
  bool _skipWelcomeSearch = false;
  bool _detectionComplete = false;
  Map<String, dynamic> _guide = {};
  bool _setupDetecting = false;
  bool _setupDetectionFailed = false;
  int _setupRevision = 0;
  Set<String> _setupDetected = {};
  bool _startupChecked = false;
  List<Map<String, dynamic>> _addons = [];
  List<Map<String, dynamic>>? _addonEntries;
  bool _taskActive = false;
  Map<String, dynamic> _providers = {'local': [], 'online': []};
  Map<String, dynamic> _connections = {'agents': [], 'mcp': [], 'skills': []};
  String? _connectionUndo;
  String? _moveUndo;
  String? _systemSelection;
  String? _aiFocus;
  final _mapSelection = <String>{};
  Timer? _liveTimer;
  Map<String, dynamic>? _mapLayoutOverride;
  Timer? _mapLayoutTimer;
  void _saveMapLayout(Map<String, dynamic> value) {
    _mapLayoutOverride = value;
    _mapLayoutTimer?.cancel();
    _mapLayoutTimer = Timer(const Duration(milliseconds: 300), () async {
      try {
        await _backend?.call('settings.update', {
          'values': {'flutter_map_layout': value},
        });
      } catch (_) {
        if (mounted) _actionFailed();
      }
    });
  }

  bool _livePending = false;
  bool _windowFocused = true;
  DateTime? _nextMapScan;
  DateTime? _nextSystemMountCheck;

  double _mapAreaWidth = 0;
  TaskCardSpec? _card;
  final _viewBodyKeys = <String, GlobalKey>{};
  VoidCallback? _cancelReview;
  String? _view;
  String? _connectionCommand;
  Map<String, dynamic>? _browser;
  bool get _showGuide => _view == 'guide';
  set _showGuide(bool value) {
    if (value) {
      if (_taskActive) return;
      _card = null;
      _browser = null;
      _view = 'guide';
    } else if (_showGuide) {
      _view = null;
    }
  }

  bool get _showProviders => _view == 'providers';
  set _showProviders(bool value) {
    if (value) {
      if (_taskActive) return;
      _card = null;
      _browser = null;
      _view = 'providers';
    } else if (_showProviders) {
      _view = null;
    }
  }

  bool get _showConnections => _view == 'connections';
  set _showConnections(bool value) {
    if (value) {
      if (_taskActive) return;
      _card = null;
      _browser = null;
      _view = 'connections';
    } else if (_showConnections) {
      _view = null;
    }
  }

  Set<String> _focusOf(Map<String, dynamic> reply) =>
      (reply['focus'] as List? ?? []).cast<String>().toSet();

  void _closeCard() {
    if (_card?.closable != true) return;
    final cancel = _cancelReview;
    _cancelReview = null;
    setState(() => _card = null);
    cancel?.call();
  }

  Future<bool> _cardReview(
    String title,
    Map<String, dynamic> plan,
    Widget Function(VoidCallback, VoidCallback) build,
  ) async {
    final answer = Completer<bool>();
    final wasBusy = _busy;
    void finish(bool value) {
      if (answer.isCompleted) return;
      _cancelReview = null;
      if (mounted) setState(() => _busy = wasBusy);
      if (value && mounted) {
        setState(
          () => _card = TaskCardSpec(
            title: title,
            focus: _focusOf(plan),
            closable: false,
            child: const Center(child: CircularProgressIndicator()),
          ),
        );
      }
      // Keep the review's map visible until the next phase replaces the card.
      if (!value && mounted) setState(() => _card = null);
      answer.complete(value);
    }

    setState(() {
      _busy = true;
      _cancelReview = () => finish(false);
      _card = TaskCardSpec(
        title: title,
        focus: _focusOf(plan),
        child: build(() => finish(true), () => finish(false)),
      );
    });
    return _review(() => answer.future);
  }

  bool get _navigationBlocked =>
      _busy || _taskActive || _reviewDepth > 0 || _card?.closable == false;

  bool get _hasTaskView =>
      _showGuide ||
      _showConnections ||
      _showProviders ||
      (_showMap &&
          !_showSettings &&
          _visibleTerminal == null &&
          _focusCategory != null);

  bool _halfTaskMapVisible(TaskCardWidth width, Set<String> focus) =>
      TaskHost.usesHalfCard(
        width,
        _mapAreaWidth,
        (_graph?['nodes'] as List? ?? []).any((n) => focus.contains(n['id'])),
      );

  static const _dataTasks = {
    'models.search',
    'models.files',
    'addons.catalog',
    'guide.snapshot',
    'system.refresh',
    'existing.scan',
    'existing.check',
    'system.move_preview',
    'system.tool_check',
    'installers.preview',
  };

  Future<Map<String, dynamic>?> _runTask({
    required String title,
    required String operation,
    Map<String, dynamic> params = const {},
    String? existingTask,
    Set<String> focus = const {},
    TaskCardWidth width = TaskCardWidth.half,
  }) async {
    final result = Completer<Map<String, dynamic>?>();
    if (operation.startsWith('system.') ||
        operation.startsWith('existing.') ||
        operation.startsWith('models.') && operation != 'models.remove' ||
        operation == 'guide.snapshot' ||
        operation == 'addons.catalog') {
      width = TaskCardWidth.full;
    }
    final prior = _card;
    final effectiveFocus = focus.isEmpty ? prior?.focus ?? focus : focus;
    setState(() {
      _taskActive = true;
      _card = TaskCardSpec(
        title: title,
        width: width,
        focus: effectiveFocus,
        closable: false,
        child: TaskProgress(
          key: GlobalKey(),
          backend: _backend!,
          operation: operation,
          params: params,
          existingTask: existingTask,
          title: title,
          tr: tr,
          onFocus: (ids) {
            if (!mounted || _card == null) return;
            setState(
              () => _card = TaskCardSpec(
                title: title,
                width: width,
                focus: ids,
                closable: false,
                child: _card!.child,
              ),
            );
          },
          onComplete: (value) {
            if (!result.isCompleted) result.complete(value);
          },
        ),
      );
    });
    final value = await result.future;
    final resultFocus = _card?.focus ?? effectiveFocus;
    if (!mounted) return value;
    if (!_dataTasks.contains(operation)) {
      await _refresh(refreshMap: _halfTaskMapVisible(width, resultFocus));
    }
    if (!mounted) return value;
    if (value?['undo'] is String) _connectionUndo = value!['undo'] as String;
    if (value?['move_undo'] is String) {
      _moveUndo = value!['move_undo'] as String;
    }
    setState(() => _taskActive = false);
    // Data-selection tasks return straight to the retained browser/overview.
    if (const [
          'models.search',
          'models.files',
          'addons.catalog',
          'guide.snapshot',
          'system.refresh',
          'existing.scan',
        ].contains(operation) &&
        value != null &&
        value['ok'] != false) {
      setState(() => _card = null);
    } else {
      _taskResult(title, value, resultFocus, width: width);
    }
    return value?['ok'] == false ? null : value;
  }

  void _taskResult(
    String title,
    Map<String, dynamic>? value,
    Set<String> focus, {
    Future<void> Function()? undo,
    TaskCardWidth width = TaskCardWidth.half,
  }) {
    if (!mounted) return;
    setState(
      () => _card = TaskCardSpec(
        title: title,
        width: width,
        focus: focus,
        child: TaskReview(
          content: Text(
            tr(
              value == null
                  ? 'Cancelled'
                  : value['ok'] == false
                  ? 'The action could not be completed.'
                  : value['external'] == true
                  ? 'This runs in a separate terminal; passwords are entered there. Refresh when it finishes.'
                  : 'Succeeded',
            ),
          ),
          actions: [
            if (undo != null ||
                value?['undo'] != null && value?['undo'] == _connectionUndo ||
                value?['move_undo'] != null)
              TextButton.icon(
                onPressed: () => _undoTask(
                  title,
                  focus,
                  width,
                  undo ??
                      () async {
                        if (value?['move_undo'] != null) {
                          final started = await _backend!.call(
                            'system.move_undo',
                            {'undo': value!['move_undo']},
                          );
                          final restored = await _runTask(
                            title: tr('Undo'),
                            operation: 'system.move_undo',
                            existingTask: started['task'] as String,
                            width: TaskCardWidth.full,
                          );
                          if (restored?['ok'] != true) {
                            throw StateError('Undo failed');
                          }
                          _moveUndo = null;
                          await _reloadSystem();
                        } else if (!await _undoConnection(refresh: false)) {
                          throw StateError('Undo failed');
                        }
                      },
                ),
                icon: const Icon(Icons.undo),
                label: Text(tr('Undo')),
              ),
            TextButton(onPressed: _closeCard, child: Text(tr('Close'))),
          ],
        ),
      ),
    );
  }

  Future<void> _undoTask(
    String title,
    Set<String> focus,
    TaskCardWidth width,
    Future<void> Function() undo,
  ) async {
    if (_busy || _taskActive) return;
    setState(() {
      _busy = true;
      _taskActive = true;
      _card = TaskCardSpec(
        title: title,
        focus: focus,
        width: width,
        closable: false,
        child: const Center(child: CircularProgressIndicator()),
      );
    });
    var ok = false;
    try {
      await undo();
      await _refresh(refreshMap: _halfTaskMapVisible(width, focus));
      ok = true;
    } catch (_) {
      // Keep failures in the same result card, without consuming another action.
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _taskActive = false;
        });
        _taskResult(
          title,
          {'ok': ok},
          focus,
          width: width,
          undo: ok ? null : undo,
        );
      }
    }
  }

  Widget _viewHost(
    String title,
    Widget child,
    VoidCallback close, {
    Set<String> focus = const {},
    TaskCardWidth width = TaskCardWidth.full,
  }) => _host(
    TaskCardSpec(
      title: tr(title),
      child: KeyedSubtree(
        key: _viewBodyKeys.putIfAbsent(title, () => GlobalKey()),
        child: child,
      ),
      width: width,
      focus: focus,
    ),
    close,
  );

  Widget _host(TaskCardSpec spec, VoidCallback close) => TaskHost(
    spec: spec,
    graph: _graph ?? const {'nodes': [], 'edges': []},
    tr: tr,
    onClose: close,
  );

  String tr(String key) => _strings[key] ?? key;

  void _actionFailed() {
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (_card?.child is! TaskProgress) _card = null;
    });
    ScaffoldMessenger.of(_navigator.currentContext!).showSnackBar(
      SnackBar(content: Text(tr('The action could not be completed.'))),
    );
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _liveTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _refreshLive(),
    );
    _connect();
  }

  Future<void> _connect() async {
    if (_terminals.any((terminal) => !terminal.ended)) {
      return;
    }
    for (final terminal in _terminals) {
      terminal.dispose();
    }
    _terminals.clear();
    _visibleTerminal = null;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      // Development location is explicit; release packaging will bundle the service.
      const definedRoot = String.fromEnvironment('ASTERISM_SOURCE');
      final root = definedRoot.isNotEmpty
          ? definedRoot
          : File(Platform.resolvedExecutable).parent.path;
      final backend =
          await (widget.connectBackend?.call() ?? Backend.start(root));
      if (!mounted) {
        backend.dispose();
        return;
      }
      _backend?.dispose();
      _backend = backend;
      await _refresh();
      if (mounted) unawaited(_loadSystem());
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _busy = false;
        });
      }
    }
  }

  @override
  void onWindowClose() async {
    if (_closing) return;
    _closing = true;
    if (_terminals.any((terminal) => !terminal.ended) ||
        _taskActive ||
        _reviewDepth > 0 ||
        _card?.closable == false) {
      final close = await showDialog<bool>(
        context: _navigator.currentContext!,
        builder: (context) => AlertDialog(
          content: Text(
            tr(
              _taskActive
                  ? 'Close Asterism? Running agents will stop; committed changes will finish.'
                  : 'Close Asterism and stop its running agents?',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('Close')),
            ),
          ],
        ),
      );
      if (close != true) {
        _closing = false;
        return;
      }
    }
    for (final terminal in _terminals) {
      try {
        await terminal.stop();
      } catch (_) {
        /* Service shutdown also closes owned PTYs. */
      }
    }
    if (mounted) setState(() => _busy = true);
    _mapLayoutTimer?.cancel();
    if (_mapLayoutOverride != null) {
      try {
        await _backend?.call('settings.update', {
          'values': {'flutter_map_layout': _mapLayoutOverride},
        });
      } catch (_) {
        /* Keep normal close available if the service has disconnected. */
      }
    }
    await _backend?.shutdown();
    await windowManager.destroy();
  }

  Future<void> _start(Map<String, dynamic> choice) async {
    if (_busy || !mounted) return;
    final command = choice['command'] as String;
    setState(() => _busy = true);
    try {
      final result = await _backend!.call('sessions.start', choice);
      if (!mounted) return;
      if (result['session'] != null) {
        final terminal = AgentTerminal(
          _backend!,
          result['session'] as String,
          command,
          result['path'] as String,
          tr: tr,
        );
        setState(() {
          _terminals.add(terminal);
          _visibleTerminal = terminal;
        });
      }
      await _refresh();
    } catch (_) {
      _actionFailed();
    }
  }

  Future<void> _stopTerminal(AgentTerminal terminal) async {
    if (!terminal.ended) {
      final stop = await showDialog<bool>(
        context: _navigator.currentContext!,
        builder: (context) => AlertDialog(
          content: Text('${tr('Stop')} ${terminal.command}?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('Stop')),
            ),
          ],
        ),
      );
      if (stop != true) return;
    }
    try {
      if (_backend?.isConnected ?? false) await terminal.stop();
      if (!mounted) return;
      setState(() {
        _terminals.remove(terminal);
        if (_visibleTerminal == terminal) _visibleTerminal = null;
      });
      terminal.dispose();
    } catch (_) {
      _actionFailed();
    }
  }

  Future<void> _retry() {
    if (!(_backend?.isConnected ?? false)) return _connect();
    if (_showSystemMap) return _refreshSystem(true);
    if (_card != null) {
      return _refresh(
        refreshMap: _halfTaskMapVisible(_card!.width, _card!.focus),
      );
    }
    return _refresh();
  }

  @override
  void onWindowFocus() {
    setState(() => _windowFocused = true);
  }

  @override
  void onWindowBlur() {
    setState(() => _windowFocused = false);
  }

  Future<Map<String, dynamic>> _freshMap() async {
    var result = await _backend!.call('map.snapshot', {'force': true});
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (mounted &&
        result['pending'] == true &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      result = await _backend!.call('map.snapshot', {'poll': true});
    }
    return result;
  }

  Future<void> _refreshLive() async {
    if (_busy || _livePending || !(_backend?.isConnected ?? false)) return;
    _livePending = true;
    try {
      final appearance = await _backend!.call('app.theme');
      if (!mounted) return;
      if (_snapshot != null &&
          !mapEquals(
            _snapshot!['theme'] as Map?,
            appearance['theme'] as Map?,
          )) {
        setState(() => _snapshot!['theme'] = appearance['theme']);
      }
      if (_taskActive || _reviewDepth > 0 || _card?.closable == false) return;
      final idleTaskSurface = _card != null || _browser != null;
      if (_showSystemMap) {
        final settings = _snapshot?['settings'] as Map? ?? const {};
        final interval = settings['map_scan_interval'] as int? ?? 6;
        if (!_systemRefreshing &&
            interval > 0 &&
            (settings['map_scan_pause_unfocused'] == false || _windowFocused) &&
            !(_nextSystemMountCheck?.isAfter(DateTime.now()) ?? false)) {
          _nextSystemMountCheck = DateTime.now().add(
            Duration(seconds: interval < 15 ? 15 : interval),
          );
          final changed = await _backend!.call('system.mount_signature');
          if (mounted &&
              _showSystemMap &&
              changed['signature'] != _system['mount_signature']) {
            unawaited(_refreshSystem(false, quiet: true));
          }
        }
        return;
      }
      if (!idleTaskSurface &&
          (!_showMap ||
              _showSystemMap ||
              _showProviders ||
              _showConnections ||
              _showSettings ||
              _showGuide ||
              _visibleTerminal != null)) {
        return;
      }
      final settings = _snapshot?['settings'] as Map? ?? const {};
      final interval = settings['map_scan_interval'] as int? ?? 6;
      final pending = _graph?['pending'] == true;
      if (!pending &&
          (interval == 0 ||
              (settings['map_scan_pause_unfocused'] != false &&
                  !_windowFocused) ||
              (_nextMapScan?.isAfter(DateTime.now()) ?? false))) {
        return;
      }
      final graph = await _backend!.call(
        'map.snapshot',
        pending ? {'poll': true} : const {},
      );
      if (!pending) {
        _nextMapScan = DateTime.now().add(Duration(seconds: interval));
      }
      final next = retainMapSnapshot(_graph, graph);
      if (mounted && (!identical(next, _graph) || _failed)) {
        setState(() {
          _graph = next;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      _livePending = false;
    }
  }

  Future<void> _openSubagents(String command) async {
    setState(() => _busy = true);
    try {
      final initial = await _backend!.call('agents.activity', {
        'command': command,
      });
      if (!mounted) return;
      await showDialog<void>(
        context: _navigator.currentContext!,
        builder: (context) => SubagentsDialog(
          backend: _backend!,
          command: command,
          initial: initial,
          tr: tr,
        ),
      );
    } catch (_) {
      _actionFailed();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _selectAgent(String command) {
    setState(() {
      _selected = command;
      _agentInfo = null;
      _showMap = false;
      _showSystemMap = false;
      _showSettings = false;
      _showProviders = false;
      _showConnections = false;
    });
    _refresh();
  }

  Future<void> _updateSettings(Map<String, dynamic> values) async {
    setState(() => _busy = true);
    try {
      await _backend!.call('settings.update', {'values': values});
      await _refresh();
    } catch (_) {
      _actionFailed();
    }
  }

  Future<T> _review<T>(Future<T> Function() open) async {
    if (mounted) setState(() => _reviewDepth++);
    try {
      return await open();
    } finally {
      if (mounted) setState(() => _reviewDepth--);
    }
  }

  // Only sessions owned by this app depend on its currently loaded adapters.
  bool get _agentsRunning => _terminals.any((t) => !t.ended);

  Map<String, dynamic> get _mapGraph =>
      _welcome && !_addons.any((i) => i['enabled'] == true)
      ? {'nodes': <dynamic>[], 'edges': <dynamic>[]}
      : _graph == null
      ? {'nodes': <dynamic>[], 'edges': <dynamic>[]}
      : withAgentLinks(_graph!);

  Map<int, int> get _groupAvailable => {
    for (final col in [1, 2])
      col: {
        ..._addons
            .where(
              (i) =>
                  (col == 1 ? i['kind'] == 'agent' : i['kind'] != 'agent') &&
                  i['enabled'] != true,
            )
            .map((i) => i['id']),
        ...(_addonEntries ?? [])
            .where(
              (i) =>
                  (col == 1 ? i['kind'] == 'agent' : i['kind'] == 'provider') &&
                  i['action'] == 'install',
            )
            .map((i) => i['id']),
      }.length,
  };

  Map<int, int> get _groupFound => {
    for (final col in [1, 2])
      col: _addons
          .where(
            (i) =>
                (col == 1 ? i['kind'] == 'agent' : i['kind'] != 'agent') &&
                i['enabled'] != true &&
                _setupDetected.contains(i['id']),
          )
          .length,
  };

  void _offerAddonUndo(Future<void> Function() undo) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(_navigator.currentContext!);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(tr('Add-ons')),
        action: SnackBarAction(
          label: tr('Undo'),
          onPressed: () async {
            if (_busy || _agentsRunning) {
              _actionFailed();
              return;
            }
            setState(() => _busy = true);
            try {
              await undo();
            } catch (_) {
              _actionFailed();
            } finally {
              if (mounted) setState(() => _busy = false);
            }
          },
        ),
      ),
    );
  }

  Widget _groupFocus() {
    final category = _focusCategory!;
    return MapAddonsFocus(
      hosted: true,
      key: ValueKey('focus-$category'),
      category: category,
      items: _addons,
      detected: _setupDetected,
      nodes: (_mapGraph['nodes'] as List? ?? [])
          .cast<Map<String, dynamic>>()
          .where((n) => n['column'] == category)
          .toList(),
      entries: _addonEntries,
      busy: _busy,
      running: _agentsRunning,
      online: (_snapshot?['settings'] as Map?)?['addons_online'] != false,
      tr: tr,
      welcome: _welcome && category == 1,
      detecting: _setupDetecting && _reviewDepth == 0,
      detectionFailed: _setupDetectionFailed,
      onDetect: _detectSetup,
      onApply: _finishSetup,
      onLater: () => _finishSetup(null),
      onBack: () => setState(() => _focusCategory = null),
      onToggle: _toggleAddon,
      onFile: _installAddonFile,
      onCatalog: _loadAddonCatalog,
      onOnline: (on) => _updateSettings({'addons_online': on}),
      onInstall: _installAddon,
      onMenu: _addonMenu,
      onNodeMenu: _nodeMenu,
      onLogin: (command) => _agentAction(command, 'login'),
      onNode: _aiNode,
      onModels: () => _guideAction('', 'providers'),
      onConnections: () => _guideAction('', 'connections'),
      onFolders: _openExisting,
    );
  }

  void _nodeMenu(BuildContext context, Map<String, dynamic> node) {
    final id = (node['id'] as String).split(':').skip(1).join(':');
    final item = _addons
        .where((a) => (a['provides'] as List? ?? []).contains(id))
        .firstOrNull;
    if (item != null) {
      _addonMenu(context, item);
    } else {
      _aiNode(node);
    }
  }

  Future<void> _addonMenu(
    BuildContext context,
    Map<String, dynamic> item,
  ) async {
    final update = (_addonEntries ?? [])
        .where(
          (e) =>
              e['id'] == item['id'] &&
              e['action'] == 'update' &&
              e['preview'] != null,
        )
        .firstOrNull;
    final blocked = _busy || _agentsRunning;
    await _review(
      () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheet) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheet).height * .85,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                '${item['name']} · ${item['version']}',
                style: Theme.of(sheet).textTheme.titleLarge,
              ),
              AddonDetails(item: item, tr: tr),
              if (_agentsRunning)
                Text(tr('Finish running agents before changing add-ons.')),
              TextButton(
                onPressed:
                    blocked ||
                        item['supported'] != true ||
                        (item['verified'] != true && item['enabled'] != true)
                    ? null
                    : () {
                        Navigator.pop(sheet);
                        _toggleAddon(
                          item['id'] as String,
                          item['enabled'] != true,
                        );
                      },
                child: Text(
                  tr(item['enabled'] == true ? 'Switch off' : 'Switch on'),
                ),
              ),
              if (update != null)
                TextButton(
                  onPressed: blocked
                      ? null
                      : () {
                          Navigator.pop(sheet);
                          _installAddon(update);
                        },
                  child: Text(
                    tr(
                      'Update add-on to {0}',
                    ).replaceAll('{0}', update['version'] as String),
                  ),
                ),
              for (final agent in item['sign_ins'] as List? ?? [])
                TextButton(
                  onPressed: _busy
                      ? null
                      : () {
                          Navigator.pop(sheet);
                          _agentAction(agent['command'] as String, 'login');
                        },
                  child: Text(
                    tr(
                      'Sign in to {0}…',
                    ).replaceAll('{0}', agent['name'] as String),
                  ),
                ),
              if (item['kind'] == 'agent')
                for (final command in item['provides'] as List? ?? [])
                  if (_catalog.any((a) => a['command'] == command))
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () {
                              Navigator.pop(sheet);
                              _selectAgent(command as String);
                            },
                      child: Text(tr('Details')),
                    ),
              if (item['removable'] == true)
                TextButton(
                  onPressed: blocked
                      ? null
                      : () {
                          Navigator.pop(sheet);
                          _removeAddon(item);
                        },
                  child: Text(tr('Remove')),
                ),
              TextButton(
                onPressed: () => Navigator.pop(sheet),
                child: Text(tr('Close')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _removeAddon(Map<String, dynamic> item) async {
    if (_busy || _agentsRunning) return;
    try {
      final plan = await _backend!.call('addons.remove_preview', {
        'id': item['id'],
      });
      if (!mounted) return;
      final yes = await _cardReview(
        tr('Remove'),
        plan,
        (yes, no) => AddonRemovalReview(
          plan: plan,
          tr: tr,
          onConfirm: yes,
          onCancel: no,
        ),
      );
      if (yes != true || !mounted) return;
      setState(() => _busy = true);
      final result = await _backend!.call('addons.remove_apply', {
        'preview': plan['preview'],
      });
      _addonEntries = null;
      _taskResult(
        tr('Remove'),
        result,
        _focusOf(plan),
        undo: () async {
          await _backend!.call('addons.remove_undo', {'undo': result['undo']});
        },
      );
      await _refresh();
    } catch (_) {
      if (mounted) _actionFailed();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleAddon(String id, bool on) async {
    if (_busy || _agentsRunning) return;
    final before =
        _addons.where((i) => i['id'] == id).firstOrNull?['enabled'] == true;
    setState(() => _busy = true);
    try {
      await _backend!.call('addons.set_enabled', {'id': id, 'enabled': on});
      if (!mounted) return;
      setState(() {
        _selected = null;
        _agentInfo = null;
      });
      await _refresh();
      _offerAddonUndo(() async {
        await _backend!.call('addons.set_enabled', {
          'id': id,
          'enabled': before,
        });
        await _refresh();
      });
    } catch (_) {
      _actionFailed();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Map<String, dynamic>?> _addonOperation(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (_busy) return null;
    setState(() {
      _busy = true;
      _taskActive = true;
    });
    try {
      final started = await _backend!.call(method, params);
      if (!mounted) return null;
      return await _runTask(
        operation: method,
        params: const {},
        existingTask: started['task'] as String,
        title: tr(
          (method.startsWith('existing.') || method == 'system.refresh')
              ? (method == 'system.refresh' ? 'System Map' : 'Find existing AI')
              : method == 'guide.snapshot'
              ? 'Your first agent'
              : method.startsWith('installers.')
              ? 'Install'
              : 'Add-ons',
        ),
      );
    } catch (_) {
      _actionFailed();
      return null;
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _taskActive = false;
        });
      }
    }
  }

  Future<void> _loadSystem() async {
    Map<String, dynamic> data;
    try {
      data = await _backend!.call('system.cached');
    } catch (_) {
      return;
    }
    if (mounted) {
      setState(() {
        _system = data;
        _moveUndo = data['move_undo'] as String?;
      });
    }
    if (mounted) await _refreshSystem(false, quiet: true);
  }

  Future<void> _reloadSystem() async {
    final data = await _backend!.call('system.cached');
    if (mounted) {
      setState(() {
        _system = data;
        _moveUndo = data['move_undo'] as String?;
      });
    }
  }

  /// The last tips per local LLM (llm_help_page.llm_tuning_answers).
  final _tuningAnswers = <String, Map<String, dynamic>>{};

  /// A local LLM's performance (models.tuning); a setting or a model's
  /// context changed through the connection preview (backup, Undo).
  Future<void> _performance(Map<String, dynamic> runtime) async {
    if (_busy) return;
    final key = runtime['key'] as String;
    Map<String, dynamic> facts;
    setState(() => _busy = true);
    try {
      facts = await _quietTask('models.tuning', {'key': key});
    } catch (_) {
      _actionFailed();
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    (String, String, String)? change;
    await _cardReview(
      '${tr('Performance')} · ${runtime['name']}',
      {'focus': runtime['focus'] ?? const []},
      (yes, no) => PerformanceView(
        facts: facts,
        tr: tr,
        answer: _tuningAnswers[key],
        onAsk: (command) async {
          final answer = await _quietTask('models.tuning_ask', {
            'key': key,
            'command': command,
          });
          _tuningAnswers[key] = answer;
          return answer;
        },
        onChange: (section, setting, value) {
          change = (section, setting, value);
          no();
        },
        onClose: no,
      ),
    );
    final chosen = change;
    if (!mounted || chosen == null) return;
    await _connectionPreview({
      'key': key,
      'section': chosen.$1,
      'setting': chosen.$2,
      'value': chosen.$3,
    }, method: 'models.tuning_preview');
  }

  /// The health report (health.report): the header's "!" while something
  /// needs fixing or there are tips; Open problems lists them.
  Map<String, dynamic>? _healthReport;
  int get _healthCount =>
      (_healthReport?['warn'] as int? ?? 0) +
      (_healthReport?['hint'] as int? ?? 0) +
      _updates.length +
      _addonHints.length +
      _foundHints.length;

  Timer? _limitsTimer;

  /// Newer versions of agents and local LLMs (updates.check, cached 6 h).
  List<Map<String, dynamic>> _updates = [];

  /// check_new_apps: programs with an MCP server and skill sets from apps
  /// on this PC (found.scan, read only and cached), and the hint for the new
  /// ones (found.hints).
  List<Map<String, dynamic>> _foundHints = [];
  bool _showFound = false;

  Future<void> _lookForNewApps() async {
    try {
      await _quietTask('found.scan', {});
    } catch (_) {
      return; // Looked for again at the next start.
    }
    await _loadFoundHints();
  }

  Future<void> _loadFoundHints() async {
    if (_backend?.isConnected != true) return;
    try {
      final found = await _backend!.call('found.hints');
      if (mounted) {
        setState(
          () => _foundHints = (found['lines'] as List? ?? const [])
              .cast<Map<String, dynamic>>(),
        );
      }
    } catch (_) {
      // Shown next time.
    }
  }

  /// ai_popup.look_for_addons: add-ons whose agent or local LLM is on this
  /// PC but not on the map, and add-on updates ready (addons.hints).
  List<Map<String, dynamic>> _addonHints = [];

  Future<void> _loadAddonHints() async {
    if (_backend?.isConnected != true) return;
    try {
      final found = await _backend!.call('addons.hints');
      if (mounted) {
        setState(
          () => _addonHints = (found['lines'] as List? ?? const [])
              .cast<Map<String, dynamic>>(),
        );
      }
    } catch (_) {
      // Shown next time.
    }
  }

  /// The signed catalog in the background at start (cached; online only
  /// when looking for add-ons online is on), for the add-on hints only: the
  /// Add-ons list still waits for the user's own look. A catalog read makes
  /// new install previews in the core, so the user's look waits for this one.
  Future<void>? _quietCatalog;

  Future<void> _quietAddonCatalog() async {
    try {
      await _quietTask('addons.catalog', {});
    } catch (_) {
      // No hints: the Add-ons focus reads the catalog itself.
    }
    await _loadAddonHints();
  }

  /// update_all_addons: every add-on with a newer version, one after the
  /// other; one message says what happened.
  Future<void> _updateAllAddons(Map<String, dynamic> line) async {
    final updates = (line['updates'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    if (updates.isEmpty || _busy || _agentsRunning) return;
    final yes = await _cardReview(
      tr('Update all'),
      line,
      (yes, no) => TaskReview(
        title: Text(
          tr('Update all'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final u in updates)
              ListTile(
                dense: true,
                leading: const Icon(Icons.extension),
                title: Text('${u['name']}'),
                subtitle: Text('${u['current']} → ${u['version']}'),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: no, child: Text(tr('Cancel'))),
          FilledButton(
            key: const ValueKey('addons-update-all'),
            onPressed: yes,
            child: Text(tr('Update all')),
          ),
        ],
      ),
    );
    if (!yes || !mounted) return;
    setState(() => _card = null);
    final done = <String>[], failed = <String>[];
    for (final u in updates) {
      final result = await _addonOperation('addons.install', {
        'preview': u['preview'],
      });
      if (!mounted) return;
      (result == null ? failed : done).add('${u['name']}');
    }
    if (_backend?.isConnected ?? false) await _reloadAddonCatalog();
    await _refresh();
    if (!mounted) return;
    final message = [
      if (done.isNotEmpty)
        tr('Add-ons updated: {0}').replaceAll('{0}', done.join(', ')),
      if (failed.isNotEmpty)
        tr('Not updated: {0}').replaceAll('{0}', failed.join('; ')),
    ].join(' · ');
    ScaffoldMessenger.of(
      _navigator.currentContext!,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _checkUpdates() async {
    try {
      final found = await _quietTask('updates.check', {});
      if (mounted) {
        setState(
          () => _updates = (found['updates'] as List? ?? const [])
              .cast<Map<String, dynamic>>(),
        );
      }
    } catch (_) {
      // Shown next time.
    }
  }

  /// Update: its own command in a terminal, or the app's install review.
  Future<void> _runUpdate(Map<String, dynamic> update) async {
    if ((update['command'] as List? ?? const []).isEmpty) {
      await _installProgram(
        update['kind'] == 'runtime' ? 'runtime' : 'agent',
        '${update['key']}',
      );
      return;
    }
    try {
      await _backend!.call('updates.run', {'key': update['key']});
      if (mounted) {
        setState(
          () => _updates = [
            for (final u in _updates)
              if (u['key'] != update['key']) u,
          ],
        );
      }
    } catch (_) {
      _actionFailed();
    }
  }

  Future<void> _checkHealth() async {
    try {
      final report = await _quietTask('health.report', {});
      if (mounted) setState(() => _healthReport = report);
    } catch (_) {
      // No "!": the rest of the app is unaffected.
    }
  }

  Future<void> _openProblems() async {
    final report = _healthReport;
    if (report == null || _busy) return;
    await _cardReview(
      tr('Open problems'),
      const {},
      (yes, no) => OpenProblemsView(
        report: report,
        tr: tr,
        onAction: (action) {
          _cancelReview?.call();
          _healthAction(action);
        },
        updates: _updates,
        onUpdate: (update) {
          _cancelReview?.call();
          _runUpdate(update);
        },
        addonHints: [..._foundHints, ..._addonHints],
        onAddonHint: (line, action) {
          _cancelReview?.call();
          switch (action) {
            case 'update_all':
              _updateAllAddons(line);
            case 'mcp' || 'skills':
              setState(() {
                _showConnections = true;
                _showFound = true;
                _showProviders = false;
                _showSystemMap = false;
              });
            default:
              setState(() => _focusCategory = line['column'] as int? ?? 1);
          }
        },
        onCheckAgain: () async {
          _cancelReview?.call();
          await Future.wait([_checkHealth(), _checkUpdates()]);
          if (mounted) await _openProblems();
        },
        onClose: no,
      ),
    );
  }

  /// ai_popup.health_action: each finding opens where it is fixed.
  void _healthAction(List<String> action) {
    switch (action.first) {
      case 'details':
        _selectAgent(action[1]);
      case 'firstagent':
        _openGuide();
      case 'install':
        _installProgram('runtime', action[1]);
      case 'runtime' || 'models':
        setState(() {
          _showProviders = true;
          _showConnections = false;
          _showSystemMap = false;
        });
      case 'addmcp' || 'addskills':
        setState(() {
          _showConnections = true;
          _showFound = true;
          _showProviders = false;
          _showSystemMap = false;
        });
      case 'reorganize':
        _openSystem();
      default:
        setState(() {
          _showMap = true;
          _showConnections = false;
          _showProviders = false;
          _showSystemMap = false;
        });
    }
  }

  /// Help (F1): the user manual and where to start.
  Future<void> _openHelp() async {
    if (_busy) return;
    var manual = false;
    try {
      manual = (await _backend!.call('help.snapshot'))['manual'] == true;
    } catch (_) {
      // Shown without the manual.
    }
    if (!mounted) return;
    VoidCallback after(void Function() open) => () {
      _cancelReview?.call();
      open();
    };
    await _cardReview(
      tr('Help'),
      const {},
      (yes, no) => HelpView(
        manual: manual,
        tr: tr,
        onOpenManual: () async =>
            (await _backend!.call('help.open_manual'))['opened'] == true,
        starts: [
          ('Your first agent', Icons.rocket_launch_outlined, after(_openGuide)),
          ('Find existing AI', Icons.manage_search, after(_openExisting)),
          (
            'Providers and models',
            Icons.memory,
            after(
              () => setState(() {
                _showProviders = true;
                _showConnections = false;
                _showSystemMap = false;
              }),
            ),
          ),
          (
            'Connections',
            Icons.account_tree_outlined,
            after(
              () => setState(() {
                _showConnections = true;
                _showProviders = false;
                _showSystemMap = false;
              }),
            ),
          ),
        ],
        onClose: no,
      ),
    );
  }

  /// Downloads a previous run left unfinished (jobs.list), shown in a
  /// banner until each is continued or discarded.
  List<Map<String, dynamic>> _interrupted = [];

  Future<void> _loadJobs() async {
    try {
      final reply = await _backend!.call('jobs.list');
      if (!mounted) return;
      _interrupted = [
        for (final job in (reply['jobs'] as List).cast<Map<String, dynamic>>())
          if (job['state'] == 'interrupted') job,
      ];
      _showJobs();
    } catch (_) {
      // Nothing to continue.
    }
  }

  void _showJobs() {
    final messenger = ScaffoldMessenger.of(_navigator.currentContext!);
    messenger.clearMaterialBanners();
    if (_interrupted.isEmpty) return;
    messenger.showMaterialBanner(
      MaterialBanner(
        key: const ValueKey('interrupted-jobs'),
        leading: const Icon(Icons.download),
        content: InterruptedJobs(
          jobs: _interrupted,
          busy: _busy,
          tr: tr,
          onContinue: _continueJob,
          onDiscard: _discardJob,
        ),
        actions: [
          TextButton(
            onPressed: messenger.clearMaterialBanners,
            child: Text(tr('Close')),
          ),
        ],
      ),
    );
  }

  Future<void> _discardJob(Map<String, dynamic> job) async {
    try {
      await _backend!.call('jobs.discard', {'id': job['id']});
    } catch (_) {
      _actionFailed();
    }
    _interrupted = [
      for (final j in _interrupted)
        if (j['id'] != job['id']) j,
    ];
    if (mounted) _showJobs();
  }

  Future<void> _continueJob(Map<String, dynamic> job) async {
    if (_busy) return;
    _interrupted = [
      for (final j in _interrupted)
        if (j['id'] != job['id']) j,
    ];
    _showJobs();
    setState(() {
      _taskActive = true;
      _busy = true;
    });
    try {
      final started = await _backend!.call('jobs.continue', {'id': job['id']});
      if (!mounted) return;
      await _runTask(
        operation: job['kind'] == 'pull' ? 'models.pull' : 'models.download',
        existingTask: started['task'] as String,
        focus: (started['focus'] as List? ?? const []).cast<String>().toSet(),
        title: '${job['title']}',
      );
      await _refresh();
    } catch (_) {
      _actionFailed();
    } finally {
      if (mounted) {
        setState(() {
          _taskActive = false;
          _busy = false;
        });
      }
    }
  }

  /// A service task started and waited for without a task card (the view
  /// that asked shows its own progress).
  Future<Map<String, dynamic>> _quietTask(
    String method,
    Map<String, dynamic> params,
  ) async {
    final started = await _backend!.call(method, params);
    while (true) {
      final status = await _backend!.call('tasks.status', {
        'task': started['task'],
      });
      if (status['state'] == 'done') {
        return status['result'] as Map<String, dynamic>;
      }
      if (status['state'] != 'running' || !mounted) {
        throw StateError('$method failed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  Future<void> _refreshSystem(bool search, {bool quiet = false}) async {
    if (_systemRefreshing) return;
    setState(() => _systemRefreshing = true);
    try {
      Map<String, dynamic>? result;
      if (quiet) {
        final started = await _backend!.call('system.refresh', {
          'search': search,
        });
        while (mounted) {
          final status = await _backend!.call('tasks.status', {
            'task': started['task'],
          });
          if (status['state'] == 'done') {
            result = status['result'] as Map<String, dynamic>;
            break;
          }
          if (status['state'] != 'running') {
            throw StateError('System refresh failed');
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      } else {
        result = await _addonOperation('system.refresh', {'search': search});
      }
      if (result != null && mounted) setState(() => _system = result!);
    } catch (_) {
      if (mounted && !quiet) _actionFailed();
    } finally {
      if (mounted) setState(() => _systemRefreshing = false);
    }
  }

  Future<void> _openSystem({bool search = false}) async {
    if (!mounted) return;
    setState(() {
      _card = null;
      _browser = null;
      _showSystemMap = true;
      _showGuide = false;
      _showConnections = false;
      _showProviders = false;
      _showSettings = false;
      _visibleTerminal = null;
    });
    await _refreshSystem(search, quiet: !search);
  }

  Future<void> _openExisting() => _openSystem(search: true);

  Future<void> _systemSaved(Map<String, dynamic> result) async {
    if (result['ok'] == false) _actionFailed();
    if (result.containsKey('move_undo')) {
      _moveUndo = result['move_undo'] as String?;
    }
    if (result['undo'] != null) {
      _connectionUndo = result['undo'] as String;
      _moveUndo = null;
    }
    if (_card != null &&
        (result['undo'] != null || result['move_undo'] != null)) {
      _taskResult(_card!.title, result, _card!.focus, width: _card!.width);
    }
    await _reloadSystem();
    await _refreshSystem(false, quiet: true);
  }

  void _systemSession(Map<String, dynamic> result) {
    final terminal = AgentTerminal(
      _backend!,
      result['session'] as String,
      result['command'] as String,
      result['path'] as String,
      tr: tr,
    );
    setState(() {
      _terminals.add(terminal);
      _visibleTerminal = terminal;
      _showSystemMap = false;
    });
  }

  Future<void> _systemFolderOnAI(
    Map<String, dynamic> source,
    Map<String, dynamic> target,
  ) async {
    if (_busy || source['found'] == null || target['kind'] != 'runtime') return;
    setState(() => _busy = true);
    try {
      final plan = await _backend!.call('system.folder_preview', {
        'found': source['found'],
        'runtime': (target['id'] as String).substring(8),
      });
      if (!mounted ||
          !await _cardReview(
            tr('Preview'),
            plan,
            (yes, no) => ConnectionReview(
              plan: plan,
              tr: tr,
              onConfirm: yes,
              onCancel: no,
            ),
          )) {
        return;
      }
      final started = await _backend!.call('connections.apply', {
        'plan': plan['plan'],
      });
      if (!mounted) return;
      await _runTask(
        operation: 'connections.apply',
        params: const {},
        existingTask: started['task'] as String,
        title: tr('Apply'),
      );
    } catch (_) {
      _actionFailed();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openUsage() async {
    try {
      final result = await _backend!.call('usage.snapshot');
      if (!mounted) return;
      await showDialog<void>(
        context: _navigator.currentContext!,
        builder: (context) => AlertDialog(
          title: Text(tr('Usage')),
          content: SizedBox(
            width: 720,
            child: ListView(
              shrinkWrap: true,
              children: [
                Text(tr('Last 30 days')),
                if ((result['categories'] as List).isEmpty)
                  Text(tr('No AI runs recorded in the last 30 days.')),
                for (final c in result['categories'] as List)
                  ExpansionTile(
                    title: Text('${c['plugin']} · ${tr(c['task'] as String)}'),
                    subtitle: Text(
                      '${c['runs']} ${tr('Sessions')} · ${c['totals']['tokens']} ${tr('Tokens')} · ${c['totals']['unknown']} ${tr('Unknown')}',
                    ),
                    children: [
                      for (final run in c['entries'] as List)
                        ListTile(
                          title: Text('${run['when']} · ${run['agent']}'),
                          subtitle: Text(
                            '${tr(run['ok'] == true ? 'Succeeded' : 'Failed')} · ${run['tokens'] ?? '—'} ${tr('Tokens')}',
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('Close')),
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted) _actionFailed();
    }
  }

  Future<void> _showAI(Map<String, dynamic> node) async {
    if ((node['id'] as String).startsWith('agent:')) {
      final command = (node['id'] as String).substring(6);
      if (!_catalog.any((a) => a['command'] == command)) {
        await _openGroups();
        return;
      }
      _selectAgent(command);
      return;
    }
    final graph = await _freshMap();
    if (!mounted) return;
    final target = (graph['nodes'] as List)
        .where(
          (n) =>
              n['id'] == node['id'] ||
              (n['group'] != null && n['group'] == node['path']),
        )
        .firstOrNull;
    setState(() {
      _showSystemMap = false;
      _showMap = true;
      _graph = graph;
      _aiFocus = target?['id'] as String?;
    });
    if (target == null) {
      ScaffoldMessenger.of(_navigator.currentContext!).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'This component has no AI Map node yet. Enable its add-on or connect a runtime first.',
            ),
          ),
        ),
      );
    }
  }

  void _aiNode(Map<String, dynamic> node) {
    if (node['kind'] == 'agent') {
      _selectAgent((node['id'] as String).substring(6));
      return;
    }
    String? target;
    if (node['kind'] == 'runtime') {
      target = node['id'] as String;
    } else {
      final group = node['group'] as String?;
      target =
          (_system['nodes'] as List)
                  .where((n) => group != null && n['path'] == group)
                  .firstOrNull?['id']
              as String?;
      if (target == null && node['kind'] == 'model') {
        final id = node['id'] as String;
        if (id.startsWith('model:runtime:')) {
          target = 'runtime:${id.split(':')[2]}';
        }
      }
    }
    setState(() => _systemSelection = target);
    _openSystem();
  }

  Future<void> _loadAddonCatalog() async {
    await _quietCatalog;
    final result = await _addonOperation('addons.catalog', const {});
    if (!mounted || result == null) return;
    setState(
      () => _addonEntries = (result['entries'] as List)
          .cast<Map<String, dynamic>>(),
    );
    unawaited(_loadAddonHints());
  }

  Future<void> _reloadAddonCatalog() async {
    await _quietCatalog;
    // Refresh the already-consented catalog without replacing the install result.
    final prior = _card;
    setState(() {
      _busy = true;
      _taskActive = true;
      if (prior != null) {
        _card = TaskCardSpec(
          title: prior.title,
          child: prior.child,
          focus: prior.focus,
          width: prior.width,
          closable: false,
        );
      }
    });
    try {
      final started = await _backend!.call('addons.catalog');
      while (mounted) {
        final status = await _backend!.call('tasks.status', {
          'task': started['task'],
        });
        if (status['state'] == 'done') {
          final result = status['result'] as Map<String, dynamic>;
          setState(
            () => _addonEntries = (result['entries'] as List)
                .cast<Map<String, dynamic>>(),
          );
          return;
        }
        if (status['state'] != 'running') {
          throw StateError('Catalog refresh failed');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _addonEntries = null);
        ScaffoldMessenger.of(_navigator.currentContext!).showSnackBar(
          SnackBar(content: Text(tr('The action could not be completed.'))),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _card = prior;
          _busy = false;
          _taskActive = false;
        });
      }
    }
  }

  /// An add-on .zip chosen on this PC: its own signature decides; it is
  /// reviewed like a catalog entry before the worker installs it.
  Future<void> _installAddonFile() async {
    if (_busy) return;
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: tr('Add-on (.zip)'), extensions: const ['zip']),
      ],
    );
    if (file == null || !mounted) return;
    Map<String, dynamic> preview;
    try {
      preview = await _backend!.call('addons.file_preview', {
        'path': file.path,
      });
    } catch (_) {
      _actionFailed();
      return;
    }
    if (!mounted) return;
    final confirmed = await _cardReview(
      tr('Add-ons'),
      preview,
      (yes, no) => AddonInstallReview(
        item: preview,
        tr: tr,
        onConfirm: yes,
        onCancel: no,
      ),
    );
    if (!mounted || !confirmed) {
      if (mounted) setState(() => _card = null);
      return;
    }
    final result = await _addonOperation('addons.file_install', {
      'preview': preview['preview'],
    });
    if (!mounted || result == null) return;
    setState(() {
      _selected = null;
      _agentInfo = null;
    });
    ScaffoldMessenger.of(_navigator.currentContext!).showSnackBar(
      SnackBar(
        content: Text(
          tr(
            '{0} is installed; switch it on on its card.',
          ).replaceAll('{0}', '${preview['name']}'),
        ),
      ),
    );
  }

  Future<void> _installAddon(Map<String, dynamic> entry) async {
    if (_busy) return;
    final confirmed = await _cardReview(
      tr('Add-ons'),
      entry,
      (yes, no) =>
          AddonInstallReview(item: entry, tr: tr, onConfirm: yes, onCancel: no),
    );
    if (!mounted || !confirmed) return;
    final result = await _addonOperation('addons.install', {
      'preview': entry['preview'],
    });
    if (!mounted) return;
    if (_backend?.isConnected ?? false) await _reloadAddonCatalog();
    if (!mounted || result == null) return;
    setState(() {
      _selected = null;
      _agentInfo = null;
    });
    if (result['enabled'] == true && result['loaded'] != true) _actionFailed();
  }

  /// A step of the first-agent guide left it (providers, connections, a
  /// sign-in or test terminal): Back returns to the guide, refreshed, so the
  /// step just done shows as done.
  /// The app's short name (app.identity), for names the user sees in
  /// systemctl; loaded when Settings first opens.
  String? _shortName;

  bool _guideReturn = false;
  final _guideTerminals = <AgentTerminal>{};

  Future<void> _loadShortName() async {
    try {
      final identity = await _backend!.call('app.identity', const {});
      if (mounted) setState(() => _shortName = '${identity['short_name']}');
    } catch (_) {
      // the description then names no service
    }
  }

  void _backToGuideIfFromIt() {
    if (!_guideReturn) return;
    _guideReturn = false;
    _openGuide();
  }

  Future<void> _openGuide() async {
    final result = await _addonOperation('guide.snapshot', const {});
    if (!mounted || result == null) return;
    _guideReturn = false;
    setState(() {
      _guide = result;
      _showGuide = true;
      _showSystemMap = false;
      _showProviders = false;
      _showConnections = false;
      _showSettings = false;
      _visibleTerminal = null;
    });
  }

  Future<void> _chooseGuide(String route) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _backend!.call('guide.choose', {'route': route});
    } catch (_) {
      _actionFailed();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _openGuide();
  }

  void _guideAction(String command, String action) {
    _connectionCommand = command.isEmpty ? null : command;
    _guideReturn = action != 'addons' && action != 'existing';
    if (action != 'existing') setState(() => _showSystemMap = false);
    if (action == 'addons') {
      _openGroups();
      return;
    }
    if (action == 'existing') {
      _openExisting();
      return;
    }
    if (['install', 'login', 'verify'].contains(action)) {
      _agentAction(command, action);
      return;
    }
    // The agent the app installs itself has no checksummed release to take
    // here: its recipe (an installer step shows what to do).
    if (action == 'install-agent') {
      _agentAction(command, 'install');
      return;
    }
    if (action == 'install-node') {
      _agentAction('node', 'install', kind: 'tool');
      return;
    }
    if (action == 'install-tool' || action == 'install-runtime') {
      _installProgram(action == 'install-tool' ? 'tool' : 'runtime', command);
      return;
    }
    setState(() {
      _showGuide = false;
      _showProviders = action == 'providers';
      _showConnections = action == 'connections';
      _showSettings = false;
    });
    _refresh();
  }

  /// A program the app installs itself (mise, a local LLM): the release is
  /// looked up, reviewed (build, service) and installed in the worker.
  Future<void> _installProgram(String kind, String key) async {
    if (_busy) return;
    Map<String, dynamic> params = {'kind': kind, 'key': key};
    while (true) {
      final preview = await _addonOperation('installers.preview', params);
      if (!mounted || preview == null) return;
      final choice = InstallerChoice(preview['build'] as String? ?? '');
      final title = tr('Install {0}').replaceAll('{0}', '${preview['name']}');
      if (!await _cardReview(
            title,
            preview,
            (yes, no) => InstallerReview(
              preview: preview,
              choice: choice,
              tr: tr,
              onConfirm: yes,
              onCancel: no,
            ),
          ) ||
          !mounted) {
        if (mounted) setState(() => _card = null);
        return;
      }
      if (choice.build != (preview['build'] ?? '')) {
        params = {...params, 'build': choice.build};
        continue; // another build: its release is looked up again
      }
      final result = await _addonOperation('installers.install', {
        'installer': preview['installer'],
        'start_now': choice.startNow,
        'start_at_login': choice.startAtLogin,
      });
      if (!mounted || result == null) return;
      setState(() => _card = null);
      ScaffoldMessenger.of(_navigator.currentContext!).showSnackBar(
        SnackBar(
          content: Text(
            tr('{0} is installed.').replaceAll('{0}', '${preview['name']}'),
          ),
        ),
      );
      if (_showGuide) {
        await _openGuide();
      } else {
        await _refresh();
      }
      return;
    }
  }

  /// An API key put where the agent reads it: reviewed, typed into a hidden
  /// field, handed to the worker; the field is cleared right away.
  /// What an agent may do without asking (agents.security); a changed
  /// setting is reviewed as a connection preview (backup, Undo).
  Future<void> _security(String command) async {
    if (_busy) return;
    Map<String, dynamic> report;
    try {
      report = await _backend!.call('agents.security', {'command': command});
    } catch (_) {
      _actionFailed();
      return;
    }
    if (!mounted) return;
    (String, dynamic)? change;
    await _cardReview(
      tr('Security settings'),
      report,
      (yes, no) => AgentSecurityView(
        report: report,
        tr: tr,
        onChange: (key, value) {
          change = (key, value);
          no();
        },
        onClose: no,
      ),
    );
    final chosen = change;
    if (!mounted || chosen == null) return;
    await _connectionPreview({
      'command': command,
      'key': chosen.$1,
      'value': chosen.$2,
    }, method: 'agents.security_preview');
  }

  Future<void> _apiKey(String command) async {
    if (_busy) return;
    Map<String, dynamic> preview;
    try {
      preview = await _backend!.call('agents.key_preview', {
        'command': command,
      });
    } catch (_) {
      _actionFailed();
      return;
    }
    if (!mounted) return;
    final field = TextEditingController();
    final name = '${preview['name']}';
    final confirmed = await _cardReview(
      tr('API key for {0}').replaceAll('{0}', name),
      preview,
      (yes, no) => ApiKeyReview(
        preview: preview,
        controller: field,
        tr: tr,
        onConfirm: yes,
        onCancel: no,
      ),
    );
    final key = field.text.trim();
    field.clear();
    // Freed once the card that used it is gone.
    WidgetsBinding.instance.addPostFrameCallback((_) => field.dispose());
    if (!mounted || !confirmed) {
      if (mounted) setState(() => _card = null);
      return;
    }
    Map<String, dynamic>? result;
    try {
      final started = await _backend!.call('agents.key_apply', {
        'preview': preview['preview'],
        'key': key,
      });
      if (!mounted) return;
      result = await _runTask(
        operation: 'agents.key',
        existingTask: started['task'] as String,
        title: tr('API key for {0}').replaceAll('{0}', name),
      );
    } catch (_) {
      result = null;
    }
    if (!mounted) return;
    setState(() => _card = null);
    final ok = result?['ok'] == true;
    final message = '${result?['message'] ?? ''}';
    ScaffoldMessenger.of(_navigator.currentContext!).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? tr('{0}: the API key is set up.').replaceAll('{0}', name)
              : tr('{0} did not take the key: {1}')
                    .replaceAll('{0}', name)
                    .replaceAll('{1}', message.isEmpty ? '?' : message),
        ),
      ),
    );
    await _refresh();
  }

  Future<void> _agentAction(
    String command,
    String action, {
    String? kind,
  }) async {
    if (action == 'key') {
      await _apiKey(command);
      return;
    }
    if (action == 'security') {
      await _security(command);
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    try {
      var plan = await _backend!.call('agents.action_preview', {
        'command': command,
        'action': action,
        'kind': ?kind,
      });
      if (!mounted) return;
      if (action == 'login' && (plan['logins'] as List).length > 1) {
        int? index;
        final chosen = await _cardReview(
          tr('Sign in…'),
          plan,
          (yes, no) => TaskReview(
            content: Column(
              children: [
                for (var i = 0; i < (plan['logins'] as List).length; i++)
                  ListTile(
                    title: Text(plan['logins'][i] as String),
                    onTap: () {
                      index = i;
                      yes();
                    },
                  ),
              ],
            ),
            actions: [TextButton(onPressed: no, child: Text(tr('Cancel')))],
          ),
        );
        if (!chosen || index == null) return;
        plan = await _backend!.call('agents.action_preview', {
          'command': command,
          'action': action,
          'login': index,
        });
      }
      if (!mounted ||
          !await _cardReview(
            tr(actionLabel(action)),
            plan,
            (yes, no) => AgentActionReview(
              plan: plan,
              tr: tr,
              onConfirm: yes,
              onCancel: no,
            ),
          )) {
        return;
      }
      final result = await _backend!.call('agents.action_apply', {
        'preview': plan['preview'],
      });
      if (!mounted) return;
      _taskResult(tr(actionLabel(action)), result, _focusOf(plan));
      if (result['session'] != null) {
        final terminal = AgentTerminal(
          _backend!,
          result['session'] as String,
          result['command'] as String,
          result['path'] as String,
          tr: tr,
        );
        if (_guideReturn) _guideTerminals.add(terminal);
        setState(() {
          _card = null;
          _terminals.add(terminal);
          _visibleTerminal = terminal;
          _showGuide = false;
        });
      }
      await _refresh();
    } catch (_) {
      _actionFailed();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Map<String, dynamic>?> _providerOperation(
    String operation,
    Map<String, dynamic> params,
    String title,
  ) async {
    setState(() {
      _taskActive = true;
      _busy = true;
    });
    try {
      final result = await _runTask(
        operation: operation,
        params: params,
        title: title,
      );
      return result;
    } finally {
      if (mounted) {
        setState(() {
          _taskActive = false;
          _busy = false;
        });
      }
    }
  }

  Widget _mapControls(Map<String, dynamic> node) {
    final command = (node['id'] as String).replaceFirst('agent:', '');
    final terminals = _terminals
        .where((t) => t.command == command && !t.ended)
        .toList();
    return SizedBox(
      height: 26,
      child: Row(
        children: [
          IconButton(
            padding: EdgeInsets.zero,
            tooltip: tr('Open'),
            onPressed: () => _aiNode(node),
            icon: const Icon(Icons.open_in_new, size: 16),
          ),
          if (node['kind'] == 'runtime')
            IconButton(
              padding: EdgeInsets.zero,
              tooltip: tr(node['status'] == 'running' ? 'Stop' : 'Start'),
              onPressed: () => _mapRuntimeControl(node),
              icon: Icon(
                node['status'] == 'running' ? Icons.stop : Icons.play_arrow,
                size: 18,
              ),
            ),
          if (node['kind'] == 'agent') ...[
            IconButton(
              padding: EdgeInsets.zero,
              tooltip: tr('Start'),
              onPressed: () {
                final projects =
                    (_snapshot?['projects'] as Map?)?[command] as Map?;
                if (projects != null) {
                  _start({
                    'command': command,
                    'path': projects['default'],
                    'outside': false,
                  });
                }
              },
              icon: const Icon(Icons.play_arrow, size: 18),
            ),
            if (terminals.isNotEmpty) ...[
              IconButton(
                padding: EdgeInsets.zero,
                tooltip: tr('Console'),
                onPressed: () =>
                    setState(() => _visibleTerminal = terminals.first),
                icon: const Icon(Icons.terminal, size: 16),
              ),
              IconButton(
                padding: EdgeInsets.zero,
                tooltip: tr('Stop'),
                onPressed: () => _stopTerminal(terminals.first),
                icon: const Icon(Icons.stop, size: 16),
              ),
            ],
            IconButton(
              padding: EdgeInsets.zero,
              tooltip: tr('Stop external instance'),
              onPressed: () => _haltMapAgent(command),
              icon: const Icon(Icons.stop_circle_outlined, size: 16),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _mapRuntimeControl(Map<String, dynamic> node) async {
    if (_busy) return;
    final action = node['status'] == 'running' ? 'Stop' : 'Start';
    final yes = await _cardReview(
      tr(action),
      {
        'focus': [node['id']],
      },
      (confirm, cancel) => TaskReview(
        content: Text('${tr(action)} ${node['label']}?'),
        actions: [
          TextButton(onPressed: cancel, child: Text(tr('Cancel'))),
          FilledButton(onPressed: confirm, child: Text(tr(action))),
        ],
      ),
    );
    if (!yes) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    await _providerOperation(
      action == 'Stop' ? 'runtime.stop' : 'runtime.start',
      {'key': (node['id'] as String).substring(8)},
      tr(action),
    );
  }

  Future<void> _haltMapAgent(String command) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final reply = await _backend!.call('agents.halt_preview', {
        'command': command,
      });
      if (!mounted) return;
      String? token;
      final yes = await _cardReview(
        tr('Stop external instance'),
        {
          'focus': ['agent:$command'],
        },
        (confirm, cancel) => TaskReview(
          content: Column(
            children: [
              for (final item in reply['instances'] as List)
                ListTile(
                  title: Text(item['label'] as String),
                  onTap: () {
                    token = item['preview'] as String;
                    confirm();
                  },
                ),
            ],
          ),
          actions: [TextButton(onPressed: cancel, child: Text(tr('Cancel')))],
        ),
      );
      if (!yes || token == null) return;
      final result = await _backend!.call('agents.halt_apply', {
        'preview': token,
      });
      await _runTask(
        operation: 'agents.halt',
        params: const {},
        existingTask: result['task'] as String,
        title: tr('Stop'),
      );
    } catch (_) {
      _actionFailed();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _mapEdit(Map<String, dynamic> edit) async {
    if (_busy) return;
    final nodes = {
      for (final n in (_mapGraph['nodes'] as List).cast<Map<String, dynamic>>())
        n['id'] as String: n,
    };
    Map<String, dynamic>? edge = edit['edge'] as Map<String, dynamic>?;
    if (edit['failure'] != null) {
      edge = edit['failure'] as Map<String, dynamic>;
      var repair = false;
      final chosen = await _cardReview(
        tr('Connection'),
        {
          'focus': [edge['source'], edge['target']],
        },
        (yes, no) => TaskReview(
          content: Column(
            children: [
              for (final hint in edge!['hints'] as List)
                Text(tr(hint['text'] as String)),
            ],
          ),
          actions: [
            TextButton(onPressed: no, child: Text(tr('Cancel'))),
            TextButton(onPressed: yes, child: Text(tr('Disconnect'))),
            FilledButton(
              onPressed: () {
                repair = true;
                yes();
              },
              child: Text(tr('Repair')),
            ),
          ],
        ),
      );
      if (mounted) setState(() => _busy = false);
      if (!chosen) return;
      if (repair) {
        return _connectionPreview({
          'agent': edge['source'],
          'target': edge['target'],
        }, method: 'connections.repair_preview');
      }
      return _mapEdit({'source': edge['source'], 'target': null, 'edge': edge});
    }
    final source = nodes[edit['source']], target = nodes[edit['target']];
    if (source == null) return;
    if (edge != null) {
      final old = nodes[edge['target']];
      if (source['kind'] == 'agent' && old?['kind'] == 'cloud') {
        await _agentAction((source['id'] as String).substring(6), 'logout');
        return;
      }
      if (['runtime', 'cloud'].contains(source['kind']) &&
          old?['kind'] == 'model') {
        await _connectionPreview({
          'provider': source['id'],
          'old': old!['id'],
          'new': target?['id'],
        }, method: 'models.switch_preview');
        return;
      }
      if (source['kind'] == 'agent' && old?['kind'] == 'model') {
        if (target != null) {
          return _mapEdit({'source': source['id'], 'target': target['id']});
        }
        final provider = (_mapGraph['edges'] as List)
            .cast<Map<String, dynamic>>()
            .where((e) => e['kind'] == 'serves' && e['target'] == old!['id'])
            .firstOrNull;
        if (provider == null) return;
        return _mapEdit({
          'source': source['id'],
          'target': null,
          'edge': {'source': source['id'], 'target': provider['source']},
        });
      }
      await _connectionPreview({
        'agent': source['id'],
        'old': edge['target'],
        'new': target?['id'],
      }, method: 'connections.move_preview');
      return;
    }
    if (target == null) return;
    final agent = source['kind'] == 'agent'
        ? source
        : target['kind'] == 'agent'
        ? target
        : null;
    final item = source['kind'] == 'model'
        ? source
        : target['kind'] == 'model'
        ? target
        : agent == source
        ? target
        : source;
    if (item['kind'] == 'model') {
      final provider = (_mapGraph['edges'] as List)
          .cast<Map<String, dynamic>>()
          .where((e) => e['kind'] == 'serves' && e['target'] == item['id'])
          .firstOrNull;
      if (provider == null) return;
      final selected = <String>{
        if (agent != null) (agent['id'] as String).substring(6),
      };
      if (agent == null) {
        final candidates = nodes.values
            .where((n) => n['kind'] == 'agent')
            .toList();
        final chosen = await _cardReview(
          tr('Agents'),
          {
            'focus': [provider['source'], item['id']],
          },
          (yes, no) => StatefulBuilder(
            builder: (context, update) => TaskReview(
              content: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final n in candidates)
                      CheckboxListTile(
                        title: Text(n['label'] as String),
                        value: selected.contains(
                          (n['id'] as String).substring(6),
                        ),
                        onChanged: (v) => update(() {
                          final c = (n['id'] as String).substring(6);
                          if (v == true) {
                            selected.add(c);
                          } else {
                            selected.remove(c);
                          }
                        }),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: no, child: Text(tr('Cancel'))),
                FilledButton(onPressed: yes, child: Text(tr('Preview'))),
              ],
            ),
          ),
        );
        if (mounted) setState(() => _busy = false);
        if (!chosen) return;
      }
      await _connectionPreview({
        'provider': provider['source'],
        'model': item['id'],
        'agents': selected.toList(),
      }, method: 'models.attach_preview');
      return;
    }
    if (agent == null) return;
    final command = (agent['id'] as String).substring(6);
    if (item['kind'] == 'cloud') {
      await _agentAction(command, 'login');
      return;
    }
    final kind = item['kind'] == 'runtime' ? 'provider' : item['kind'];
    if (!['provider', 'mcp', 'skills'].contains(kind)) return;
    await _connectionPreview({
      'kind': kind,
      'command': command,
      'item': (item['id'] as String).substring(
        (item['kind'] as String).length + 1,
      ),
      'remove': false,
      if (kind == 'provider') 'model': '',
      if (kind == 'provider') 'use_now': false,
    });
  }

  Future<void> _connectionPreview(
    Map<String, dynamic> params, {
    bool author = false,
    String? method,
  }) async {
    setState(() => _busy = true);
    var applied = false;
    try {
      final plan = await _backend!.call(
        method ??
            (author ? 'connections.author_preview' : 'connections.preview'),
        params,
      );
      if (!mounted) return;
      final apply = await _cardReview(
        tr('Preview'),
        plan,
        (yes, no) =>
            ConnectionReview(plan: plan, tr: tr, onConfirm: yes, onCancel: no),
      );
      if (apply) {
        setState(() => _taskActive = true);
        var result = await _backend!.call('connections.apply', {
          'plan': plan['plan'],
        });
        final queued = result['task'] != null;
        if (queued && mounted) {
          final finished = await _runTask(
            operation: 'connections.apply',
            params: const {},
            existingTask: result['task'] as String,
            title: tr('Apply'),
          );
          if (finished == null) return;
          result = finished;
        }
        if (!queued) {
          _connectionUndo = result['undo'] as String?;
          await _refresh(
            refreshMap: _halfTaskMapVisible(TaskCardWidth.half, _focusOf(plan)),
          );
          _taskResult(tr('Apply'), result, _focusOf(plan));
        }
        applied = true;
        if ((result['context_failures'] as num? ?? 0) > 0 && mounted) {
          ScaffoldMessenger.of(_navigator.currentContext!).showSnackBar(
            SnackBar(
              content: Text(
                tr(
                  'Configuration saved; some model operations could not be completed.',
                ),
              ),
            ),
          );
        }
      }
    } catch (_) {
      _actionFailed();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _taskActive = false;
        });
      }
    }
    // connect_page.sync_model_slots: after a provider, model or line change,
    // each local LLM keeps as many models loaded as its agents use.
    if (applied &&
        mounted &&
        (const {
              'models.switch_preview',
              'models.attach_preview',
              'connections.move_preview',
              'connections.repair_preview',
            }.contains(method) ||
            method == null && !author && params['kind'] == 'provider')) {
      await _syncSlots();
    }
  }

  Future<void> _syncSlots() async {
    Map<String, dynamic> plan;
    try {
      plan = await _backend!.call('models.slots_preview');
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final warnings = (plan['warnings'] as List? ?? const []).cast<String>();
    if (plan['empty'] == true || plan['plan'] is! String) {
      for (final text in warnings) {
        ScaffoldMessenger.of(_navigator.currentContext!).showSnackBar(
          SnackBar(content: Text(text), duration: const Duration(seconds: 12)),
        );
      }
      return;
    }
    final shown = {
      ...plan,
      'notes': [...(plan['notes'] as List? ?? const []), ...warnings],
    };
    final apply = await _cardReview(
      tr('Preview'),
      shown,
      (yes, no) =>
          ConnectionReview(plan: shown, tr: tr, onConfirm: yes, onCancel: no),
    );
    if (!apply || !mounted) return;
    setState(() => _busy = true);
    try {
      var result = await _backend!.call('connections.apply', {
        'plan': plan['plan'],
      });
      if (result['task'] != null && mounted) {
        result =
            await _runTask(
              operation: 'connections.apply',
              params: const {},
              existingTask: result['task'] as String,
              title: tr('Apply'),
            ) ??
            const {};
      } else {
        _connectionUndo = result['undo'] as String?;
      }
      if (plan['reload'] == true) await _backend!.call('models.slots_reload');
      await _refresh();
    } catch (_) {
      _actionFailed();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _undoConnection({bool refresh = true}) async {
    final token = _connectionUndo;
    if (token == null) return false;
    setState(() => _busy = true);
    try {
      final result = await _backend!.call('connections.undo', {'undo': token});
      _connectionUndo = null;
      if (mounted) {
        ScaffoldMessenger.of(_navigator.currentContext!).showSnackBar(
          SnackBar(
            content: Text(
              '${tr('Restored files')}: ${(result['restored'] as List).length}',
            ),
          ),
        );
      }
      if (refresh) await _refresh();
      return true;
    } catch (_) {
      _actionFailed();
      return false;
    }
  }

  Future<void> _removeModel(String key, String model) async {
    setState(() => _busy = true);
    try {
      final preview = await _backend!.call('models.remove_preview', {
        'key': key,
        'model': model,
      });
      if (!mounted ||
          !await _cardReview(
            tr('Remove model'),
            preview,
            (yes, no) => ModelRemovalReview(
              preview: preview,
              tr: tr,
              onConfirm: yes,
              onCancel: no,
            ),
          )) {
        return;
      }
      setState(() => _taskActive = true);
      final started = await _backend!.call('models.remove_apply', {
        'removal': preview['removal'],
      });
      if (!mounted) return;
      await _runTask(
        operation: 'models.remove',
        params: const {},
        existingTask: started['task'] as String,
        title: tr('Remove model'),
      );
    } catch (_) {
      _actionFailed();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _taskActive = false;
        });
      }
    }
  }

  Future<void> _openGroups({int category = 1}) async {
    if (_busy) return;
    setState(() {
      _focusCategory = category;
      _showMap = true;
      _showSystemMap = false;
      _showGuide = false;
      _showConnections = false;
      _showProviders = false;
      _showSettings = false;
      _visibleTerminal = null;
    });
    await _refresh();
    if (!_detectionComplete) unawaited(_detectSetup());
  }

  Future<void> _detectSetup() async {
    if (_setupDetecting) return;
    final revision = _setupRevision;
    setState(() {
      _setupDetecting = true;
      _setupDetectionFailed = false;
    });
    try {
      final started = await _backend!.call('setup.detect');
      while (mounted && revision == _setupRevision) {
        final status = await _backend!.call('tasks.status', {
          'task': started['task'],
        });
        if (status['state'] == 'done') {
          final result = status['result'] as Map<String, dynamic>;
          _detectionComplete = true;
          setState(
            () => _setupDetected = (result['installed'] as List)
                .cast<String>()
                .toSet(),
          );
          return;
        }
        if (status['state'] != 'running') throw StateError('Detection failed');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    } catch (_) {
      if (mounted && revision == _setupRevision) {
        setState(() => _setupDetectionFailed = true);
      }
    } finally {
      if (mounted && revision == _setupRevision) {
        setState(() => _setupDetecting = false);
      }
    }
  }

  Future<void> _finishSetup(List<String>? selected) async {
    if (_busy || (selected != null && _agentsRunning)) return;
    final before = _addons
        .where((i) => i['enabled'] == true)
        .map((i) => i['id'] as String)
        .toList();
    final enabled = selected == null
        ? null
        : <String>{
            ...selected,
            ..._addons
                .where((i) => i['kind'] != 'agent' && i['enabled'] == true)
                .map((i) => i['id'] as String),
          }.toList();
    setState(() => _busy = true);
    try {
      await _backend!.call(
        enabled == null ? 'setup.later' : 'setup.apply',
        enabled == null ? const {} : {'enabled': enabled},
      );
      if (!mounted) return;
      setState(() {
        _welcome = false;
        _focusCategory = null;
        _showGuide = false;
        _showMap = true;
      });
      await _refresh();
      if (enabled != null) {
        _offerAddonUndo(() async {
          if (_agentsRunning) return;
          await _backend!.call('setup.apply', {'enabled': before});
          await _refresh();
        });
      }
    } catch (_) {
      _actionFailed();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh({bool? refreshMap}) async {
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final snapshot = await _backend!.call('app.snapshot');
      final connections = _showConnections
          ? await _backend!.call('connections.snapshot', {
              if (_connectionCommand != null) 'command': _connectionCommand,
            })
          : null;
      final providerData = _showProviders
          ? await _backend!.call('providers.snapshot')
          : null;
      final firstSnapshot = !_startupChecked;
      final openSetup = firstSnapshot && snapshot['setup_needed'] == true;
      final addons = await _backend!.call('addons.list');
      final mapVisible =
          _showMap &&
          !_showSystemMap &&
          !_showSettings &&
          !_showGuide &&
          !_showProviders &&
          !_showConnections &&
          _visibleTerminal == null;
      final graph =
          (refreshMap ?? (mapVisible && _card == null && _browser == null))
          ? await _freshMap()
          : _graph;
      if (graph != _graph) _nextMapScan = null;
      final selected = _selected;
      final info = selected == null
          ? null
          : await _backend!.call('agents.details', {'command': selected});
      final setting = snapshot['language'] as String? ?? 'auto';
      var language = setting == 'auto'
          ? WidgetsBinding.instance.platformDispatcher.locale.languageCode
          : setting;
      if (![
        'en',
        'de',
        'es',
        'fr',
        'it',
        'nl',
        'pl',
        'pt',
      ].contains(language)) {
        language = 'en';
      }
      final raw = await rootBundle.loadString(
        'assets/translations/$language.json',
      );
      final strings = Map<String, String>.from(jsonDecode(raw) as Map);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        if (connections != null) _connections = connections;
        if (providerData != null) _providers = providerData;
        _startupChecked = true;
        if (openSetup) {
          _welcome = true;
          _focusCategory = 1;
          _showMap = true;
          _showSystemMap = false;
          _setupRevision++;
        }
        _addons = (addons['addons'] as List).cast<Map<String, dynamic>>();
        _graph = graph;
        if (_selected == selected) _agentInfo = info;
        _strings = strings;
        _locale = Locale(language);
        _busy = false;
        _failed = false;
      });
      if (firstSnapshot) {
        unawaited(_detectSetup());
        unawaited(_loadJobs());
        unawaited(_checkHealth());
        unawaited(_checkUpdates());
        if (!_welcome) _quietCatalog = _quietAddonCatalog();
        unawaited(_lookForNewApps());
        // Settings › Costs: a desktop notification when a plan limit turns red.
        _limitsTimer ??= Timer.periodic(const Duration(minutes: 1), (_) {
          if (_backend?.isConnected == true) {
            unawaited(
              _backend!.call('limits.notify').then((_) {}, onError: (_) {}),
            );
          }
        });
      }
      unawaited(_loadAddonHints());
      unawaited(_loadFoundHints());
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failed = true;
        });
      }
    }
  }

  String get _themePreference =>
      _snapshot?['settings']['flutter_theme_mode'] as String? ?? 'system';
  Map get _desktopTheme => _snapshot?['theme'] as Map? ?? const {};
  ThemeData _theme(Brightness brightness) =>
      appTheme(brightness, mode: _themePreference, desktop: _desktopTheme);

  Future<void> _projectAction(
    String method,
    String command,
    String? path,
  ) async {
    setState(() => _busy = true);
    try {
      await _backend!.call(method, {'command': command, 'path': path});
      await _refresh();
    } catch (_) {
      _actionFailed();
    }
  }

  @override
  void dispose() {
    _limitsTimer?.cancel();
    windowManager.removeListener(this);
    _liveTimer?.cancel();
    _mapLayoutTimer?.cancel();
    _startMenu.dispose();
    _aiTransform.dispose();
    _systemTransform.dispose();
    for (final terminal in _terminals) {
      terminal.dispose();
    }
    _backend?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Asterism',
    navigatorKey: _navigator,
    // F1 opens Help, as in the GTK app.
    shortcuts: {
      ...WidgetsApp.defaultShortcuts,
      const SingleActivator(LogicalKeyboardKey.f1): const _HelpIntent(),
    },
    actions: {
      ...WidgetsApp.defaultActions,
      _HelpIntent: CallbackAction<_HelpIntent>(
        onInvoke: (_) {
          if (!_navigationBlocked && _snapshot != null) _openHelp();
          return null;
        },
      ),
    },
    debugShowCheckedModeBanner: false,
    locale: _locale,
    supportedLocales: const [
      Locale('en'),
      Locale('de'),
      Locale('es'),
      Locale('fr'),
      Locale('it'),
      Locale('nl'),
      Locale('pl'),
      Locale('pt'),
    ],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: appThemeMode(_themePreference, _desktopTheme),
    home: Scaffold(
      appBar: AppBar(
        title: const Text('Asterism'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: false,
                  label: DragTarget<Map<String, dynamic>>(
                    onWillAcceptWithDetails: (details) {
                      if (details.data['found'] != null) {
                        setState(() {
                          _card = null;
                          _browser = null;
                          _showSystemMap = false;
                          _showMap = true;
                        });
                        if (_graph == null) _refresh();
                        return true;
                      }
                      return false;
                    },
                    builder: (context, candidates, rejected) =>
                        Text(tr('AI Map')),
                  ),
                ),
                ButtonSegment(value: true, label: Text(tr('System Map'))),
              ],
              selected: {_showSystemMap},
              onSelectionChanged: _navigationBlocked
                  ? null
                  : (choice) {
                      if (choice.single) {
                        _openSystem();
                      } else {
                        setState(() {
                          _card = null;
                          _browser = null;
                          _showSystemMap = false;
                          _showMap = true;
                          _showGuide = false;
                          _showSettings = false;
                          _showProviders = false;
                          _showConnections = false;
                          _visibleTerminal = null;
                        });
                        _refresh();
                      }
                    },
            ),
          ),
          if (!_showSystemMap)
            IconButton(
              tooltip: tr('Usage'),
              onPressed: _navigationBlocked ? null : _openUsage,
              icon: const Icon(Icons.bar_chart_outlined),
            ),
          if (_healthCount > 0)
            IconButton(
              key: const ValueKey('problems-open'),
              tooltip: '${_healthReport?['summary'] ?? ''}',
              icon: Icon(
                Icons.priority_high,
                color: (_healthReport?['warn'] as int? ?? 0) > 0
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
              onPressed: _navigationBlocked ? null : _openProblems,
            ),
          IconButton(
            key: const ValueKey('help-open'),
            tooltip: tr('Help (F1)'),
            icon: const Icon(Icons.help_outline),
            onPressed: _navigationBlocked || _snapshot == null
                ? null
                : _openHelp,
          ),
          IconButton(
            tooltip: tr('Your first agent'),
            icon: const Icon(Icons.rocket_launch_outlined),
            onPressed: _navigationBlocked ? null : _openGuide,
          ),
          IconButton(
            tooltip: tr('Connections'),
            icon: const Icon(Icons.account_tree_outlined),
            onPressed: _navigationBlocked
                ? null
                : () {
                    setState(() {
                      _card = null;
                      _browser = null;
                      _connectionCommand = null;
                      _guideReturn = false; // chosen from the menu
                      _showConnections = !_showConnections;
                      _showSystemMap = false;
                      _showProviders = false;
                      _showGuide = false;
                      _showSettings = false;
                      _visibleTerminal = null;
                    });
                    _refresh();
                  },
          ),
          IconButton(
            tooltip: tr('Providers and models'),
            icon: const Icon(Icons.memory_outlined),
            onPressed: _navigationBlocked
                ? null
                : () {
                    setState(() {
                      _card = null;
                      _browser = null;
                      _guideReturn = false; // chosen from the menu
                      _showProviders = !_showProviders;
                      _showSystemMap = false;
                      _showConnections = false;
                      _showGuide = false;
                      _showSettings = false;
                      _visibleTerminal = null;
                    });
                    _refresh();
                  },
          ),
          IconButton(
            tooltip: tr('Settings'),
            icon: const Icon(Icons.settings_outlined),
            onPressed: _navigationBlocked || _snapshot == null
                ? null
                : () => setState(() {
                    _card = null;
                    _browser = null;
                    _guideReturn = false; // chosen from the menu
                    _showSettings = !_showSettings;
                    if (_showSettings && _shortName == null) _loadShortName();
                    _showSystemMap = false;
                    _showConnections = false;
                    _showProviders = false;
                    _showGuide = false;
                    _visibleTerminal = null;
                  }),
          ),
          IconButton(
            tooltip: tr(_showMap ? 'Agents' : 'Map'),
            icon: Icon(_showMap ? Icons.list : Icons.hub_outlined),
            onPressed: _navigationBlocked
                ? null
                : () {
                    setState(() {
                      _card = null;
                      _browser = null;
                      _guideReturn = false; // chosen from the menu
                      _showMap = !_showMap;
                      _showSystemMap = false;
                      _showConnections = false;
                      _showSettings = false;
                      _showGuide = false;
                      _showProviders = false;
                      _visibleTerminal = null;
                    });
                    if (_showMap) _refresh();
                  },
          ),
          IconButton(
            tooltip: tr('Refresh'),
            onPressed: _navigationBlocked ? null : _retry,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_busy && _taskActive && _card == null && _reviewDepth == 0)
            const LinearProgressIndicator(),
          if (_snapshot?['migration_error'] != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(
                      'Your AI Agents Map settings could not be imported. Asterism will use its current or default settings.',
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(_snapshot!['migration_error'] as String),
                ],
              ),
            ),
          if (_failed)
            MaterialBanner(
              content: Text(
                tr('The application service could not be reached.'),
              ),
              actions: [
                TextButton(
                  onPressed: _busy ? null : _retry,
                  child: Text(tr('Refresh')),
                ),
              ],
            ),
          if (_welcome)
            MapWelcome(
              tr: tr,
              busy: _busy,
              skipSearch: _skipWelcomeSearch,
              searched: _system['search_done'] == true,
              onLook: _openExisting,
              onSkip: () => setState(() => _skipWelcomeSearch = true),
              onSystem: () => _openSystem(),
              onAgents: () => _openGroups(),
            ),
          if (_terminals.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final terminal in _terminals)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ActionChip(
                        avatar: const Icon(Icons.terminal),
                        label: Text(terminal.command),
                        onPressed: () => setState(() {
                          _visibleTerminal = terminal;
                          _showSystemMap = false;
                        }),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                _mapAreaWidth = constraints.maxWidth;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_backend != null)
                      Offstage(
                        key: const ValueKey('system-slot'),
                        offstage:
                            !_showSystemMap ||
                            _card != null ||
                            _browser != null,
                        child: SystemMapView(
                          key: const ValueKey("system-state"),
                          suspended:
                              !_showSystemMap ||
                              _card != null ||
                              _browser != null,
                          data: _system,
                          backend: _backend!,
                          tr: tr,
                          busy: _busy || _systemRefreshing,
                          controller: _systemTransform,
                          onRefresh: (search) => _refreshSystem(search),
                          onOperation: (method, params, title) =>
                              _addonOperation(method, params),
                          onSaved: _systemSaved,
                          onSession: _systemSession,
                          onShowAI: _showAI,
                          onHealthAction: (action) {
                            if (action.first == 'install') {
                              _openGuide();
                            } else if ([
                              'runtime',
                              'models',
                            ].contains(action.first)) {
                              _guideAction('', 'providers');
                            } else {
                              setState(() => _systemSelection = 'pc');
                            }
                          },
                          onGroups: _openGroups,
                          requestedNode: _systemSelection,
                          onUndo: _connectionUndo == null && _moveUndo == null
                              ? null
                              : () async {
                                  if (_moveUndo != null) {
                                    final result = await _addonOperation(
                                      'system.move_undo',
                                      {'undo': _moveUndo},
                                    );
                                    if (result?['ok'] == true) _moveUndo = null;
                                  } else {
                                    await _undoConnection();
                                  }
                                  await _reloadSystem();
                                  await _refreshSystem(false, quiet: true);
                                },
                        ),
                      ),
                    if (_browser != null)
                      Offstage(
                        key: const ValueKey('browser-slot'),
                        offstage: _card != null,
                        child: _viewHost(
                          'Download model',
                          ModelBrowser(
                            hosted: true,
                            runtime: _browser!,
                            tr: tr,
                            onOperation: _providerOperation,
                            onClose: () => setState(() => _browser = null),
                          ),
                          () => setState(() => _browser = null),
                        ),
                      ),
                    if (_hasTaskView ||
                        (_card == null && _browser == null && !_showSystemMap))
                      RetainedTaskView(
                        key: const ValueKey('view-slot'),
                        visible:
                            _card == null &&
                            _browser == null &&
                            !_showSystemMap,
                        child: _showGuide
                            ? _viewHost(
                                'Your first agent',
                                FirstAgentView(
                                  hosted: true,
                                  data: _guide,
                                  busy: _busy,
                                  tr: tr,
                                  onChoose: _chooseGuide,
                                  onAction: _guideAction,
                                  onBack: () =>
                                      setState(() => _showGuide = false),
                                  onRefresh: _openGuide,
                                ),
                                () => setState(() => _showGuide = false),
                              )
                            : _visibleTerminal != null
                            ? AgentTerminalView(
                                session: _visibleTerminal!,
                                tr: tr,
                                onBack: () {
                                  final fromGuide = _guideTerminals.remove(
                                    _visibleTerminal,
                                  );
                                  setState(() => _visibleTerminal = null);
                                  if (fromGuide) {
                                    _guideReturn = true;
                                    _backToGuideIfFromIt();
                                  }
                                },
                                onStop: () => _stopTerminal(_visibleTerminal!),
                              )
                            : _showConnections
                            ? _viewHost(
                                'Connections',
                                ConnectionsView(
                                  hosted: true,
                                  data: _connections,
                                  busy: _busy,
                                  tr: tr,
                                  onPreview: _connectionPreview,
                                  onAuthorPreview: (params) =>
                                      _connectionPreview(params, author: true),
                                  onCatalogTask: _quietTask,
                                  onCall: (method, params) =>
                                      _backend!.call(method, params),
                                  onSkillPreview: (params) =>
                                      _connectionPreview(
                                        params,
                                        method: 'skills.web_preview',
                                      ),
                                  onCatalogPreview: (params) =>
                                      _connectionPreview(
                                        params,
                                        method: 'mcp.option_preview',
                                      ),
                                  showFound: _showFound,
                                  onBack: () {
                                    setState(() {
                                      _showConnections = false;
                                      _showFound = false;
                                    });
                                    _backToGuideIfFromIt();
                                  },
                                  onUndo: _connectionUndo == null
                                      ? null
                                      : _undoConnection,
                                ),
                                () {
                                  setState(() {
                                    _showConnections = false;
                                    _showFound = false;
                                  });
                                  _backToGuideIfFromIt();
                                },
                                width: TaskCardWidth.half,
                                focus: _focusOf(_connections),
                              )
                            : _showProviders
                            ? _viewHost(
                                'Providers and models',
                                ProvidersView(
                                  hosted: true,
                                  data: _providers,
                                  busy: _busy,
                                  tr: tr,
                                  onInstall: (key) =>
                                      _installProgram('runtime', key),
                                  onOperation: _providerOperation,
                                  onConfirm: (title, runtime) => _cardReview(
                                    title,
                                    runtime,
                                    (yes, no) => TaskReview(
                                      content: Text(
                                        tr(
                                          'This can interrupt agents using this provider.',
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: no,
                                          child: Text(tr('Cancel')),
                                        ),
                                        FilledButton(
                                          onPressed: yes,
                                          child: Text(tr('Continue')),
                                        ),
                                      ],
                                    ),
                                  ),
                                  onRemove: _removeModel,
                                  onPerformance: _performance,
                                  onCall: (method, params) =>
                                      _backend!.call(method, params),
                                  onBrowse: (runtime) =>
                                      setState(() => _browser = runtime),
                                  onDiscover: _openExisting,
                                  onBack: () {
                                    setState(() => _showProviders = false);
                                    _backToGuideIfFromIt();
                                  },
                                ),
                                () {
                                  setState(() => _showProviders = false);
                                  _backToGuideIfFromIt();
                                },
                                width: TaskCardWidth.full,
                              )
                            : _showSettings && _snapshot != null
                            ? SettingsView(
                                settings:
                                    _snapshot!['settings']
                                        as Map<String, dynamic>,
                                busy: _busy,
                                tr: tr,
                                onUpdate: _updateSettings,
                                desktopTheme: _desktopTheme,
                                checkers: [
                                  for (final h
                                      in (_system['helpers'] as List? ?? []))
                                    if (h is Map && h['check'] == true) h,
                                ],
                                unitName: _shortName == null
                                    ? ''
                                    : '$_shortName-providers.service',
                                onBack: () =>
                                    setState(() => _showSettings = false),
                              )
                            : _showMap && _graph != null
                            ? AnimatedSwitcher(
                                duration: const Duration(milliseconds: 200),
                                child: _focusCategory == null
                                    ? AgentMap(
                                        key: const ValueKey('ai-map'),
                                        graph: _mapGraph,
                                        onEdit: _mapEdit,
                                        lightFps:
                                            _snapshot!['settings']['map_light_fps']
                                                as int? ??
                                            20,
                                        selection: _mapSelection,
                                        controls: _mapControls,
                                        staticState: (
                                          _snapshot,
                                          _busy,
                                          _strings,
                                          _terminals
                                              .map((t) => '${t.id}:${t.ended}')
                                              .join(','),
                                        ),
                                        savedLayout:
                                            _mapLayoutOverride ??
                                            (_snapshot!['settings']['flutter_map_layout']
                                                    as Map<String, dynamic>? ??
                                                {}),
                                        onLayout: _saveMapLayout,
                                        animate: _windowFocused
                                            ? (_snapshot!['settings']['map_animations']
                                                      as String? ??
                                                  'all')
                                            : 'off',
                                        onAnimationChanged: (mode) =>
                                            _updateSettings({
                                              'map_animations': mode,
                                            }),
                                        controller: _aiTransform,
                                        focusedNode: _aiFocus,
                                        onNode: _aiNode,
                                        tr: tr,
                                        onAgent: _selectAgent,
                                        onSubagents: _openSubagents,
                                        onNodeDrop: _systemFolderOnAI,
                                        onNodeMenu: _nodeMenu,
                                        groups: MapGroup.fromGraph(
                                          _mapGraph,
                                          const [
                                            'MCP servers and skills',
                                            'Agents',
                                            'Providers',
                                            'Models',
                                          ],
                                          found: _groupFound,
                                          available: _groupAvailable,
                                        ),
                                        onExpandGroup: (col) => setState(
                                          () => _focusCategory = col,
                                        ),
                                      )
                                    : _viewHost(
                                        const [
                                          'MCP servers and skills',
                                          'Agents',
                                          'Providers',
                                          'Models',
                                        ][_focusCategory!],
                                        _groupFocus(),
                                        () => setState(
                                          () => _focusCategory = null,
                                        ),
                                      ),
                              )
                            : LayoutBuilder(
                                builder: (context, constraints) {
                                  if (constraints.maxWidth < 800) {
                                    return _selected == null
                                        ? _agents()
                                        : _details();
                                  }
                                  return Row(
                                    children: [
                                      SizedBox(width: 310, child: _agents()),
                                      const VerticalDivider(width: 1),
                                      Expanded(child: _details()),
                                    ],
                                  );
                                },
                              ),
                      ),
                    if (_card != null) _host(_card!, _closeCard),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    ),
  );

  List<Map<String, dynamic>> get _catalog =>
      (_snapshot?['agents'] as List? ?? []).cast<Map<String, dynamic>>();

  Widget _agents() => AgentListView(
    catalog: _catalog,
    search: _search,
    selected: _selected,
    busy: _busy,
    tr: tr,
    onSearch: (value) => setState(() => _search = value),
    onSelected: _selectAgent,
  );

  Widget _details() => AgentDetailsView(
    catalog: _catalog,
    selected: _selected,
    projectsByAgent: _snapshot?['projects'] as Map? ?? {},
    busy: _busy,
    info: _agentInfo,
    tr: tr,
    onBack: () => setState(() => _selected = null),
    onStart: _start,
    startMenu: _startMenu,
    onProjectAction: _projectAction,
    onSubagents: _openSubagents,
    onAction: _agentAction,
    onConnections: () => _guideAction(_selected ?? '', 'connections'),
    onCall: (method, params) => _backend!.call(method, params),
  );
}

class _HelpIntent extends Intent {
  const _HelpIntent();
}
