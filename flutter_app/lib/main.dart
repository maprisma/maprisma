import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';

import 'backend.dart';
import 'map_benchmark.dart';
import 'map_snapshot.dart';
import 'task_card.dart';
import 'terminal_tabs.dart';
import 'agent_terminal.dart';
import 'agent_map.dart';
import 'agent_list_view.dart';
import 'agent_details_view.dart';
import 'agent_usage.dart';
import 'cost_card.dart';
import 'settings_view.dart';
import 'app_theme.dart';
import 'map_zoom.dart';
import 'test_shots.dart';
import 'window_popup.dart';
import 'project_start_menu.dart';
import 'addon_details.dart';
import 'map_legend.dart';
import 'map_groups.dart';
import 'map_welcome.dart';
import 'map_addons_focus.dart';
import 'first_agent_view.dart';
import 'installer_review.dart';
import 'agent_security_view.dart';
import 'api_key_review.dart';
import 'performance_view.dart';
import 'interrupted_jobs.dart';
import 'found_on_pc_view.dart';
import 'help_view.dart';
import 'item_details_view.dart';
import 'map_layout.dart' show withAgentLinks;
import 'map_editor.dart' show mapColumnLayers;
import 'map_smart_card.dart'
    show SmartStatusData, SmartStatusIcon, mapSmartColumns;
import 'agent_action_dialog.dart';
import 'providers_view.dart';
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
  runApp(const MaprismaApp());
}

class MaprismaApp extends StatefulWidget {
  const MaprismaApp({super.key, this.connectBackend});

  /// Allows isolated service fixtures; production always starts its bundled service.
  final Future<Backend> Function()? connectBackend;

  @override
  State<MaprismaApp> createState() => _MaprismaAppState();
}

class _MaprismaAppState extends State<MaprismaApp> with WindowListener {
  final _navigator = GlobalKey<NavigatorState>();

  /// F9: a picture of this window (test_shots.dart). In a recorded test it
  /// goes next to the protocol, with a note; that part stays in English, it is
  /// a test tool.
  final _shots = TestShots.fromEnvironment(Platform.environment);
  final _windowShots = WindowShots.fromEnvironment(Platform.environment);
  final _shotArea = GlobalKey();
  bool _shooting = false;

  bool _shotKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.f9) {
      return false;
    }
    if (_shots == null) {
      final on = (_snapshot?['settings'] as Map?)?['screenshot_key'] != false;
      // A program in a terminal may use F9 itself.
      if (!on || _visibleTerminal != null) return false;
    }
    unawaited(_takeShot());
    return true;
  }

  Future<void> _takeShot() async {
    final shots = _shots, context = _navigator.currentContext;
    final area = _shotArea.currentContext?.findRenderObject();
    if (context == null || _shooting) return;
    if (area is! RenderRepaintBoundary) return;
    _shooting = true;
    try {
      final time = DateTime.now();
      final ratio = MediaQuery.devicePixelRatioOf(context);
      final image = await area.toImage(pixelRatio: ratio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      final png = data.buffer.asUint8List();
      if (shots == null) {
        final path = await _windowShots.save(png, time);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Screenshot saved: {0}').replaceAll('{0}', path)),
          ),
        );
        return;
      }
      final path = await shots.save(png, time);
      if (!context.mounted) return;
      final field = TextEditingController();
      final note = await showDialog<String>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Screenshot saved'),
          content: TextField(
            controller: field,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'What is wrong? (optional)',
            ),
            onSubmitted: (text) => Navigator.pop(dialog, text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, field.text),
              child: const Text('Done'),
            ),
          ],
        ),
      );
      field.dispose();
      await shots.record(path, note ?? '', time);
    } catch (_) {
      // A picture must never disturb the app.
    } finally {
      _shooting = false;
    }
  }

  final _terminals = <AgentTerminal>[];
  final _startMenu = ProjectStartMenuController();
  AgentTerminal? _visibleTerminal;
  bool _closing = false;
  int _reviewDepth = 0;
  Backend? _backend;
  CoreClient get _client => CoreClient(_backend!);
  CoreClient? get _maybeClient =>
      _backend == null ? null : CoreClient(_backend!);
  Map<String, dynamic>? _snapshot;
  Map<String, String> _strings = {};
  String? _selected;
  bool _busy = true;
  bool _failed = false;
  Locale? _locale;
  String _search = '';
  bool _showMap = true;
  bool _systemRefreshing = false;
  Map<String, dynamic> _system = {
    'nodes': [],
    'edges': [],
    'notes': [],
    'helpers': [],
    'limited': false,
  };
  final _aiTransform = TransformationController();
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
  List<Map<String, dynamic>> _smartHelpers = const [];
  bool _taskActive = false;
  Map<String, dynamic> _providers = {'local': [], 'online': []};
  Map<String, dynamic> _connections = {'agents': [], 'mcp': [], 'skills': []};
  String? _connectionUndo;
  String? _moveUndo;
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
        await _maybeClient?.settingsUpdate(
          values: {'flutter_map_layout': value},
        );
      } catch (_) {
        if (mounted) _actionFailed();
      }
    });
  }

  bool _livePending = false;
  bool _windowFocused = true;
  DateTime? _nextMapScan;

  double _mapAreaWidth = 0;
  TaskCardSpec? _card;
  final _viewBodyKeys = <String, GlobalKey>{};
  VoidCallback? _cancelReview;
  bool _reconnecting = false;
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
          'system.move_undo',
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
                          final started = await _client.systemMoveUndo(
                            undo: value!['move_undo'],
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
    HardwareKeyboard.instance.addHandler(_shotKey);
    windowChannel.setMethodCallHandler((call) async {
      if (call.method == 'shown') _placePopup();
    });
    _liveTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _refreshTheme();
      _refreshLive();
    });
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
      final backend = await (widget.connectBackend?.call() ?? Backend.start());
      if (!mounted) {
        backend.dispose();
        return;
      }
      _backend?.dispose();
      _backend = backend;
      await _refresh();
      unawaited(_loadDesktop());
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
                  ? 'Close Maprisma? Running agents will stop; committed changes will finish.'
                  : 'Close Maprisma and stop its running agents?',
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
        await _maybeClient?.settingsUpdate(
          values: {'flutter_map_layout': _mapLayoutOverride},
        );
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
      final result = await _client.sessionsStart(
        command: command,
        outside: choice['outside'] as bool,
        path: choice['path'],
      );
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
    if (_card != null) {
      return _refresh(
        refreshMap: _halfTaskMapVisible(_card!.width, _card!.focus),
      );
    }
    return _refresh();
  }

  @override
  void onWindowFocus() {
    _blurHide?.cancel();
    setState(() => _windowFocused = true);
  }

  @override
  void onWindowBlur() {
    setState(() => _windowFocused = false);
    // Popup mode: a click elsewhere closes it (not while a file chooser of
    // ours runs; a moment's grace for focus that comes straight back).
    if (_popup && !PopupGuard.busy) {
      _blurHide?.cancel();
      _blurHide = Timer(const Duration(milliseconds: 250), () {
        if (!_windowFocused && !PopupGuard.busy) windowManager.hide();
      });
    }
  }

  /// Popup mode (window_popup.dart): the desktop (desktop.snapshot) and the
  /// window_mode setting decide; the core floats the window at the top right
  /// under the bar each time it is shown.
  String _desktopName = '';
  Timer? _blurHide;
  bool get _popup => popupWanted(
    (_snapshot?['settings'] as Map?)?['window_mode'] as String?,
    _desktopName,
  );

  Future<void> _loadDesktop() async {
    try {
      final found = await _client.desktopSnapshot();
      if (!mounted) return;
      _desktopName = '${found['name']}';
      // Omarchy names the window itself; Maprisma's header is enough.
      if (_desktopName == 'omarchy') unawaited(_hideTitleBar());
      if (_popup) unawaited(_placePopup());
    } catch (_) {
      // A normal window.
    }
  }

  Future<void> _hideTitleBar() async {
    try {
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    } catch (_) {
      // The window plugin is missing (tests): the bar stays.
    }
  }

  Future<void> _placePopup() async {
    if (!_popup || !(_backend?.isConnected ?? false)) return;
    // No GTK title bar on the popup: Hyprland draws its border.
    await _hideTitleBar();
    // Just shown: Hyprland may not list the window for a moment.
    for (var i = 0; i < 10; i++) {
      try {
        final done = await _client.windowPopup(
          width: popupSize.width,
          height: popupSize.height,
        );
        if (done['placed'] == true || done['reason'] != 'no window yet') {
          return;
        }
      } catch (_) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  Future<Map<String, dynamic>> _freshMap() async {
    var result = await _client.mapSnapshot(force: true);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (mounted &&
        result['pending'] == true &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      result = await _client.mapSnapshot(poll: true);
    }
    return result;
  }

  /// The desktop's theme, every two seconds also while the app is busy (a
  /// download, an install, a change): app.theme only reads the theme files.
  /// The settings too: a change made by another process (another build of
  /// the app, the core's own saves) shows here without a refresh.
  bool _themePending = false;

  Future<void> _refreshTheme() async {
    if (_themePending || !(_backend?.isConnected ?? false)) return;
    _themePending = true;
    try {
      final appearance = await _client.appTheme();
      if (mounted &&
          _snapshot != null &&
          !mapEquals(
            _snapshot!['theme'] as Map?,
            appearance['theme'] as Map?,
          )) {
        setState(() => _snapshot!['theme'] = appearance['theme']);
      }
      final rounding = (await _client.windowRounding())['rounding'];
      if (mounted &&
          rounding != _windowRounding &&
          (rounding is int || rounding == null)) {
        setState(() => _windowRounding = rounding as int?);
      }
      if (_busy) return; // a change of our own is being written
      final settings = await _client.settingsGet();
      if (mounted &&
          !_busy &&
          _snapshot != null &&
          settings['language'] is String &&
          jsonEncode(_snapshot!['settings']) != jsonEncode(settings)) {
        setState(() => _snapshot!['settings'] = settings);
      }
    } catch (_) {
      // The next tick asks again.
    } finally {
      _themePending = false;
    }
  }

  Future<void> _refreshLive() async {
    if (_busy || _livePending || !(_backend?.isConnected ?? false)) return;
    _livePending = true;
    try {
      if (_taskActive || _reviewDepth > 0 || _card?.closable == false) return;
      final idleTaskSurface = _card != null || _browser != null;
      if (!idleTaskSurface &&
          (!_showMap ||
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
      final graph = await _client.mapSnapshot(poll: pending ? true : null);
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
      final initial = await _client.agentsActivity(command: command);
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
      _showSettings = false;
      _showProviders = false;
      _showConnections = false;
    });
    _refresh();
  }

  int _settingsRevision = 0;

  Future<void> _updateSettings(Map<String, dynamic> values) async {
    final revision = ++_settingsRevision;
    setState(() => _busy = true);
    try {
      await _client.settingsUpdate(values: values);
      if (!mounted || revision != _settingsRevision) return;
      setState(() => (_snapshot?['settings'] as Map?)?.addAll(values));
      await _refresh();
      if (values.containsKey('ai_checks')) unawaited(_checkMcp());
    } catch (_) {
      if (revision == _settingsRevision) _actionFailed();
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
      : {
          ...withAgentLinks(_graph!),
          'agent_badges': {..._agentBadges, ..._gpuBadges},
          'usage_boxes': _usageBoxes,
          'usage_box_size': _usageBoxSize,
          'traffic': _agentTraffic,
        };

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
      final plan = await _client.addonsRemovePreview(id: item['id']);
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
      final result = await _client.addonsRemoveApply(preview: plan['preview']);
      _addonEntries = null;
      _taskResult(
        tr('Remove'),
        result,
        _focusOf(plan),
        undo: () async {
          await _client.addonsRemoveUndo(undo: result['undo']);
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
      await _client.addonsSetEnabled(id: id, enabled: on);
      if (!mounted) return;
      setState(() {
        _selected = null;
        _agentInfo = null;
      });
      await _refresh();
      _offerAddonUndo(() async {
        await _client.addonsSetEnabled(id: id, enabled: before);
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
              ? 'Find existing AI'
              : method == 'system.move_undo'
              ? 'Undo'
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
      data = await _client.systemCached();
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
    final data = await _client.systemCached();
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
  /// needs fixing or there are tips; the smart cards list them.
  Map<String, dynamic>? _healthReport;
  int get _healthCount =>
      (_healthReport?['warn'] as int? ?? 0) +
      (_healthReport?['hint'] as int? ?? 0) +
      _updates.length +
      _mcpUpdates.length +
      _addonHints.length +
      _foundHints.length;

  Timer? _limitsTimer;

  /// Newer versions of agents and local LLMs (updates.check, cached 6 h).
  List<Map<String, dynamic>> _updates = [];

  /// Settings › Daily AI checks (checks.mcp_*): the MCP server updates the
  /// agent for AI checks found on the web; asked at most once a day (the
  /// core decides), looked at every hour.
  Map<String, dynamic>? _mcpChecks;
  bool _mcpChecking = false;
  Timer? _mcpTimer;
  List<Map<String, dynamic>> get _mcpUpdates =>
      (_mcpChecks?['updates'] as List? ?? const [])
          .cast<Map<String, dynamic>>();

  /// The batteries of plan limits and today's costs in the agents' boxes
  /// (map.badges, every minute as the reference's COST_EVERY); in euros the
  /// day's rate is fetched once (costs.rate).
  Map<String, dynamic> _agentBadges = {};
  bool _rateAsked = false;

  /// The usage statistics box of working agents (map.usage, every two
  /// seconds while one works, as the reference's checks).
  Map<String, dynamic> _usageBoxes = {};
  int _usageBoxSize = 7;
  Timer? _usageTimer;
  bool _usageAsking = false;

  /// Network traffic of agents on the map (agents.traffic, polled while the
  /// map is shown; the core samples at most every 3 s).
  Map<String, dynamic> _agentTraffic = {};
  bool _trafficAsking = false;

  Future<void> _loadTraffic() async {
    if (_backend?.isConnected != true || _trafficAsking) return;
    if (!_showMap ||
        _showSettings ||
        _showGuide ||
        _showProviders ||
        _showConnections ||
        _visibleTerminal != null) {
      return;
    }
    _trafficAsking = true;
    try {
      final found = await _client.agentsTraffic();
      if (mounted) {
        final next =
            (found['agents'] as Map?)?.cast<String, dynamic>() ?? const {};
        if (!sameMapJson(_agentTraffic, next)) {
          setState(() => _agentTraffic = next);
        }
      }
    } catch (_) {
      // Shown at the next check.
    } finally {
      _trafficAsking = false;
    }
  }

  Future<void> _openAgentUsage(String command, String label) async {
    if (_busy) return;
    setState(() => _busy = true);
    Map<String, dynamic>? info;
    try {
      info = await _client.agentsDetails(command: command);
    } catch (_) {
      _actionFailed();
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    unawaited(_refreshUsage(command));
    await showDialog<void>(
      context: _navigator.currentContext!,
      builder: (context) => AlertDialog(
        title: Text('${tr('Usage')} · $label'),
        content: SizedBox(
          width: 680,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_backend != null)
                  CostCard(
                    command: command,
                    call: (method, params) => _backend!.call(method, params),
                    tr: tr,
                  ),
                AgentUsage(info: info!, tr: tr),
              ],
            ),
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
  }

  Future<void> _loadUsageBoxes() async {
    if (_backend?.isConnected != true || _usageAsking) return;
    final activity = _graph?['activity'] as Map? ?? const {};
    final working = [
      for (final e in activity.entries)
        if ((e.value as Map?)?['working'] == true) '${e.key}',
    ];
    if (working.isEmpty) {
      if (_usageBoxes.isNotEmpty && mounted) setState(() => _usageBoxes = {});
      return;
    }
    _usageAsking = true;
    try {
      final found = await _client.mapUsage(commands: working);
      if (mounted) {
        setState(() {
          _usageBoxes = found['boxes'] as Map<String, dynamic>? ?? {};
          _usageBoxSize = found['size'] as int? ?? 7;
        });
      }
    } catch (_) {
      // Shown at the next check.
    } finally {
      _usageAsking = false;
    }
  }

  /// Running local LLMs: the GPU memory still free as a battery in their
  /// box (gpu.snapshot, read only: sysfs, their processes, their own APIs).
  Map<String, dynamic> _gpuBadges = {};

  Future<void> _loadGpu({bool retry = true}) async {
    if (_backend?.isConnected != true) return;
    try {
      final found = await _quietTask('gpu.snapshot', {});
      if (mounted) {
        setState(
          () => _gpuBadges = found['badges'] as Map<String, dynamic>? ?? {},
        );
      }
    } catch (_) {
      // The core is often busy right after the start: once more soon, not
      // only at the next minute.
      if (retry) {
        await Future<void>.delayed(const Duration(seconds: 8));
        if (mounted) await _loadGpu(retry: false);
      }
    }
  }

  /// The batteries on the cards read the agents' usage records, which are old
  /// until refreshed: once at the start, one agent after the other. This asks
  /// each provider for its limits; no model runs, so no tokens are used.
  Future<void> _refreshAllUsage() async {
    await Future<void>.delayed(const Duration(seconds: 3));
    for (final agent in _catalog.where((a) => a['installed'] == true)) {
      if (!mounted) return;
      await _refreshUsage(agent['command'] as String);
    }
    if (mounted) await _loadBadges();
  }

  Future<void> _loadBadges() async {
    if (_backend?.isConnected != true) return;
    try {
      final found = await _client.mapBadges();
      if (!mounted) return;
      final badges = found['badges'] as Map<String, dynamic>;
      if (!sameMapJson(_agentBadges, badges)) {
        setState(() => _agentBadges = badges);
      }
      if (found['rate_due'] == true && !_rateAsked) {
        _rateAsked = true;
        await _quietTask('costs.rate', {});
        await _loadBadges();
      }
    } catch (_) {
      // Shown next time.
    }
  }

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
      final found = await _client.foundHints();
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
      final found = await _client.addonsHints();
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

  /// A task from Ask AI: the prompt to read, then the agent in a terminal.
  Future<void> _smartTask(Map<String, dynamic> plan) async {
    final yes = await showDialog<bool>(
      context: _navigator.currentContext!,
      builder: (context) => AlertDialog(
        title: Text(tr('Do it with {0}…').replaceAll('{0}', '${plan['name']}')),
        content: SizedBox(
          width: 760,
          child: SingleChildScrollView(
            child: SelectableText(plan['prompt'] as String),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Start')),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      _systemSession(await _client.systemHelpApply(preview: plan['preview']));
    } catch (_) {
      _actionFailed();
    }
  }

  /// A provider step from Ask AI: the app's own page, with its own review.
  void _smartProvider(String step, String key, String name) {
    final found = _updates.where((u) => u['key'] == key).firstOrNull;
    switch (step) {
      case 'install':
        unawaited(_installProgram('runtime', key));
      case 'update' when found != null:
        unawaited(_runUpdate(found));
      case 'start' || 'stop':
        unawaited(
          _mapRuntimeControl({
            'id': 'runtime:$key',
            'label': name,
            'status': step == 'stop' ? 'running' : 'stopped',
          }),
        );
      default:
        _actionFailed();
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
      var done = await _client.updatesRun(key: update['key'] as String);
      if (done['started'] == false && done['running'] != null) {
        // The agent runs now: its program would be replaced under its feet.
        final yes = await showDialog<bool>(
          context: _navigator.currentContext!,
          builder: (context) => AlertDialog(
            title: Text(
              tr(
                '{0} is running right now.',
              ).replaceAll('{0}', '${update['name']}'),
            ),
            content: Text(
              tr(
                'An update replaces its program while it works: its sessions may stop or behave oddly, and some updaters refuse. Finish its work first, or update anyway.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(tr('Cancel')),
              ),
              FilledButton(
                key: const ValueKey('update-anyway'),
                onPressed: () => Navigator.pop(context, true),
                child: Text(tr('Update anyway')),
              ),
            ],
          ),
        );
        if (yes != true) return;
        done = await _client.updatesRun(
          key: update['key'] as String,
          runningOk: true,
        );
      }
      if (done['started'] != true) return;
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

  /// The daily check (force: Settings' Check now, also while it is off):
  /// minutes in the background when the agent is asked, else the kept answer.
  Future<void> _checkMcp({bool force = false}) async {
    if (_mcpChecking || _backend == null) return;
    setState(() => _mcpChecking = true);
    try {
      final started = await _client.checksMcpCheck(force: force);
      final snapshot = started['snapshot'] is Map
          ? started['snapshot'] as Map<String, dynamic>
          : await _awaitTask('checks.mcp_check', started);
      if (mounted) setState(() => _mcpChecks = snapshot);
    } catch (_) {
      if (force) _actionFailed();
    } finally {
      if (mounted) setState(() => _mcpChecking = false);
    }
  }

  /// An MCP server update's buttons: its release page, "Do it with …" (the
  /// task reviewed first, then in a terminal tab here), or Use it… when the
  /// newer version is already on this PC (the map's own update).
  Future<void> _mcpUpdateAction(
    Map<String, dynamic> update,
    String action,
  ) async {
    try {
      if (action == 'release') {
        final done = await _client.checksMcpRelease(
          name: update['name'] as String,
        );
        if (done['opened'] != true) _actionFailed();
        return;
      }
      if (action == 'use') {
        setState(() {
          _showConnections = true;
          _showFound = true;
          _showProviders = false;
        });
        return;
      }
      final plan = await _client.checksMcpTask(name: update['name'] as String);
      if (!mounted) return;
      final yes = await showDialog<bool>(
        context: _navigator.currentContext!,
        builder: (context) => AlertDialog(
          title: Text(
            '${tr('Update {0}').replaceAll('{0}', '${update['name']}')} · ${plan['name']}',
          ),
          content: SizedBox(
            width: 760,
            child: SingleChildScrollView(
              child: SelectableText(plan['prompt'] as String),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('Continue')),
            ),
          ],
        ),
      );
      if (yes != true || !mounted) return;
      _systemSession(await _client.systemHelpApply(preview: plan['preview']));
    } catch (_) {
      _actionFailed();
    }
  }

  /// Settings › Recent changes (changes.history / changes.undo).
  List<Map<String, dynamic>>? _changes;

  Future<void> _loadChanges() async {
    try {
      final found = await _client.changesHistory();
      if (mounted) {
        setState(
          () => _changes = (found['changes'] as List)
              .cast<Map<String, dynamic>>(),
        );
      }
    } catch (_) {
      // The section stays away.
    }
  }

  Future<void> _undoChange(String id) async {
    setState(() => _busy = true);
    try {
      final done = await _client.changesUndo(id: id);
      final restored = (done['restored'] as List).cast<String>();
      ScaffoldMessenger.of(_navigator.currentContext!).showSnackBar(
        SnackBar(
          content: Text(
            restored.isEmpty
                ? tr(
                    'Nothing was put back: the files were changed again since.',
                  )
                : tr('Put back: {0}').replaceAll('{0}', restored.join(', ')),
          ),
        ),
      );
      await _loadChanges();
      await _refresh();
    } catch (_) {
      _actionFailed();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Omarchy's usage records (agents.usage_refresh): when an agent's details
  /// show and its record is stale, Omarchy is asked in the background (at
  /// most every ten minutes per agent), then the details read again.
  final _usageAsked = <String, DateTime>{};

  Future<void> _refreshUsage(String command) async {
    final last = _usageAsked[command];
    if (last != null && DateTime.now().difference(last).inMinutes < 10) return;
    _usageAsked[command] = DateTime.now();
    try {
      final started = await _client.agentsUsageRefresh(command: command);
      if (started['task'] is! String) return;
      final done = await _awaitTask('agents.usage_refresh', started);
      if (done['ok'] != true || !mounted || _selected != command) return;
      final info = await _client.agentsDetails(command: command);
      if (mounted && _selected == command) setState(() => _agentInfo = info);
    } catch (_) {
      // The record stays as it was.
    }
  }

  void _toggleSettings() => setState(() {
    _card = null;
    _browser = null;
    _guideReturn = false; // chosen from the menu
    _showSettings = !_showSettings;
    if (_showSettings && _shortName == null) _loadShortName();
    if (_showSettings && _helpers == null) _loadHelpers();
    if (_showSettings) _loadChanges();
    _showConnections = false;
    _showProviders = false;
    _showGuide = false;
    _visibleTerminal = null;
  });

  /// Esc / Backspace (the manual's keyboard shortcuts): back from a page to
  /// the map. Text fields, dialogs, cards and terminals keep these keys:
  /// they handle them before they reach the app.
  bool get _canGoBack =>
      !_navigationBlocked &&
      _card == null &&
      _browser == null &&
      _visibleTerminal == null &&
      (_pageOpen || !_showMap);

  bool get _pageOpen =>
      _showSettings || _showProviders || _showConnections || _showGuide;

  /// Esc on the main page in popup mode closes the popup (Backspace never).
  bool get _canCloseTopLevel =>
      _popup &&
      !_navigationBlocked &&
      _card == null &&
      _browser == null &&
      _visibleTerminal == null;

  void _backOrClose() =>
      _canGoBack ? _goBack() : unawaited(windowManager.hide());

  /// A page back to what lay under it; an agent's details or the list back
  /// to the map, the main page.
  void _goBack() => setState(() {
    if (!_pageOpen) {
      _selected = null;
      _showMap = true;
    }
    _showSettings = false;
    _showProviders = false;
    _showConnections = false;
    _showGuide = false;
  });

  /// Ctrl+Plus / Ctrl+Minus / Ctrl+0: the map in view zoomed in, out, or fit
  /// to the window (within the map's own 30–200 %).
  void _zoom(double factor) => zoomMap(_aiTransform, factor);

  Future<void> _checkHealth() async {
    try {
      final report = await _quietTask('health.report', {});
      if (mounted) setState(() => _healthReport = report);
    } catch (_) {
      // No "!": the rest of the app is unaffected.
    }
  }

  int _smartStatusSeq = 0;
  (int, String)? _smartStatusTarget;

  SmartStatusData get _smartStatusData => SmartStatusData(
    report: _healthReport,
    updates: _updates,
    addonHints: [..._foundHints, ..._addonHints],
    mcpUpdates: _mcpUpdates,
    mcpTaskAgent: _mcpChecks?['task_agent'] as String?,
    onAction: _healthAction,
    onUpdate: _runUpdate,
    onAddonHint: (line, action) {
      switch (action) {
        case 'update_all':
          _updateAllAddons(line);
        case 'mcp' || 'skills':
          setState(() {
            _showConnections = true;
            _showFound = true;
            _showProviders = false;
          });
        default:
          final cat = mapSmartColumns.indexWhere((c) => c.$1 == line['column']);
          setState(() => _focusCategory = cat < 0 ? 1 : cat);
      }
    },
    onMcpUpdate: _mcpUpdateAction,
    onCheckAgain: () async {
      await Future.wait([_checkHealth(), _checkUpdates(), _checkMcp()]);
    },
  );

  Future<void> _openProblems() async {
    if (_busy) return;
    final targetCol = _smartStatusData.firstConcernedColumn;
    final colIndex = mapSmartColumns.indexWhere((c) => c.$1 == targetCol);
    final rawLayers = (_snapshot?['settings'] as Map?)?['map_layers'] as List?;
    List<String>? updatedLayers;
    if (colIndex >= 0 && rawLayers != null) {
      const needs = {0: 1, 3: 2};
      final current = rawLayers.cast<String>();
      final needed = <String>[
        ...mapColumnLayers[colIndex],
        if (needs[colIndex] case final other?) ...mapColumnLayers[other],
      ];
      if (needed.any((l) => !current.contains(l))) {
        updatedLayers = {...current, ...needed}.toList();
      }
    }
    setState(() {
      _card = null;
      _browser = null;
      _focusCategory = null;
      _showMap = true;
      _showGuide = false;
      _showSettings = false;
      _showProviders = false;
      _showConnections = false;
      _visibleTerminal = null;
      if (updatedLayers != null && _snapshot?['settings'] is Map) {
        (_snapshot!['settings'] as Map)['map_layers'] = updatedLayers;
      }
      _smartStatusTarget = (++_smartStatusSeq, targetCol);
    });
    if (updatedLayers != null) {
      unawaited(_updateSettings({'map_layers': updatedLayers}));
    }
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
        });
        unawaited(_refresh());
      case 'addmcp' || 'addskills':
        setState(() {
          _showConnections = true;
          _showFound = true;
          _showProviders = false;
        });
        unawaited(_refresh());
      default:
        setState(() {
          _showMap = true;
          _showConnections = false;
          _showProviders = false;
        });
    }
  }

  List<Map<String, dynamic>> get _uses =>
      (_healthReport?['uses'] as List? ?? const [])
          .cast<Map<String, dynamic>>();

  /// Help's use cases: the welcome page's, also after it has gone.
  Future<void> _openUses() async {
    await _cardReview(
      tr('What you can do with it'),
      const {},
      (yes, no) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: UseCaseCards(
                uses: _uses,
                tr: tr,
                onAction: (action) {
                  _cancelReview?.call();
                  // Help can open over these; they would hide the way there.
                  setState(() {
                    _browser = null;
                    _showGuide = false;
                    _visibleTerminal = null;
                  });
                  _healthAction(action);
                },
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: no, child: Text(tr('Close'))),
          ),
        ],
      ),
    );
  }

  /// Help (F1): the user manual and where to start.
  Future<void> _openHelp() async {
    if (_busy) return;
    var manual = false;
    try {
      manual = (await _client.helpSnapshot())['manual'] == true;
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
            (await _client.helpOpenManual())['opened'] == true,
        tabs: [
          ('Your first agent', Icons.rocket_launch_outlined, after(_openGuide)),
          if (_uses.isNotEmpty)
            (
              'What you can do with it',
              Icons.lightbulb_outline,
              after(_openUses),
            ),
          (
            'Agents',
            Icons.list,
            after(
              () => setState(() {
                _guideReturn = false;
                _showMap = false;
                _showConnections = false;
                _showSettings = false;
                _showGuide = false;
                _showProviders = false;
                _visibleTerminal = null;
              }),
            ),
          ),
          (
            'Providers and models',
            Icons.memory_outlined,
            after(() {
              setState(() {
                _guideReturn = false;
                _showProviders = true;
                _showConnections = false;
                _showGuide = false;
                _showSettings = false;
                _visibleTerminal = null;
              });
              _refresh();
            }),
          ),
          (
            'Connections',
            Icons.account_tree_outlined,
            after(() {
              setState(() {
                _connectionCommand = null;
                _guideReturn = false;
                _showConnections = true;
                _showProviders = false;
                _showGuide = false;
                _showSettings = false;
                _visibleTerminal = null;
              });
              _refresh();
            }),
          ),
        ],
        onUsage: () => _client.usageSnapshot(),
        starts: [
          ('Find existing AI', Icons.manage_search, after(_openExisting)),
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
      final reply = await _client.jobsList();
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
      await _client.jobsDiscard(id: job['id']);
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
      final started = await _client.jobsContinue(id: job['id']);
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
  ) async => _awaitTask(method, await _backend!.call(method, params));

  Future<Map<String, dynamic>> _awaitTask(
    String method,
    Map<String, dynamic> started,
  ) async {
    if (started['task'] is! String) throw StateError('$method started no task');
    while (true) {
      final status = await _client.tasksStatus(task: started['task'] as String);
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
        final started = await _client.systemRefresh(search: search);
        while (mounted) {
          final status = await _client.tasksStatus(
            task: started['task'] as String,
          );
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

  /// Looks through this PC for AI programs and folders; what it finds comes
  /// to the map.
  Future<void> _openExisting() async {
    if (!mounted) return;
    setState(() {
      _card = null;
      _browser = null;
      _showMap = true;
      _showGuide = false;
      _showConnections = false;
      _showProviders = false;
      _showSettings = false;
      _visibleTerminal = null;
    });
    await _refreshSystem(true);
    if (!mounted) return;
    await _refresh();
    if (mounted && _system['search_done'] == true) await _openFound();
  }

  Future<void> _openFound() async {
    await _cardReview(
      tr('What we found'),
      const {},
      (yes, no) => FoundOnPcView(
        nodes: (_system['nodes'] as List? ?? const [])
            .cast<Map<String, dynamic>>(),
        tr: tr,
        onReconnect: (source, target) => unawaited(_reconnect(source, target)),
        onClose: no,
      ),
    );
  }

  /// A found local LLM or model folder comes to the map, after its preview.
  /// What we found stays open until the preview is applied.
  Future<void> _reconnect(
    Map<String, dynamic> source,
    Map<String, dynamic>? target,
  ) async {
    if (_reconnecting) return;
    _reconnecting = true;
    try {
      final plan = await _client.existingPreview(
        found: source['found'],
        models: target?['found'],
      );
      if (!mounted ||
          !await confirmExisting(_navigator.currentContext!, plan, tr)) {
        return;
      }
      _cancelReview?.call();
      final result = await _addonOperation('existing.apply', {
        'plan': plan['plan'],
      });
      if (result == null || !mounted) return;
      await _reloadSystem();
      await _refreshSystem(false, quiet: true);
    } catch (_) {
      if (mounted) _actionFailed();
    } finally {
      _reconnecting = false;
    }
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
    });
  }

  void _aiNode(Map<String, dynamic> node) {
    if (node['kind'] == 'agent') {
      _selectAgent((node['id'] as String).substring(6));
      return;
    }
    final id = node['id'] as String;
    if (!_busy && (id.startsWith('mcp:') || id.startsWith('skills:'))) {
      unawaited(_itemDetails(node));
      return;
    }
    if (node['kind'] != 'cloud') _healthAction(const ['runtime']);
  }

  /// An MCP server's or a skill set's box: its details (details.mcp /
  /// details.skills).
  Future<void> _itemDetails(Map<String, dynamic> node) async {
    final id = node['id'] as String;
    final mcp = id.startsWith('mcp:');
    Map<String, dynamic> details;
    try {
      details = mcp
          ? await _client.detailsMcp(name: id.substring(4))
          : await _client.detailsSkills(path: id.substring(7));
    } catch (_) {
      return;
    }
    if (!mounted) return;
    await _cardReview('${details['title']}', {
      'focus': [id],
    }, (yes, no) => ItemDetailsView(details: details, tr: tr, onClose: no));
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
      final started = await _client.addonsCatalog();
      while (mounted) {
        final status = await _client.tasksStatus(
          task: started['task'] as String,
        );
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
    final file = await PopupGuard.around(
      () => openFile(
        acceptedTypeGroups: [
          XTypeGroup(label: tr('Add-on (.zip)'), extensions: const ['zip']),
        ],
      ),
    );
    if (file == null || !mounted) return;
    Map<String, dynamic> preview;
    try {
      preview = await _client.addonsFilePreview(path: file.path);
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

  /// The local helper's choices for Settings (helper.snapshot).
  Map<String, dynamic>? _helpers;

  Future<void> _loadHelpers() async {
    _helpers = const {};
    try {
      final found = await _client.helperSnapshot();
      if (mounted) setState(() => _helpers = found);
    } catch (_) {
      // Settings show no helper choice.
    }
  }

  Future<void> _loadShortName() async {
    try {
      final identity = await _client.appIdentity();
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
      await _client.guideChoose(route: route);
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

  /// The guide's starter model, as the Models page downloads one: a GGUF
  /// file into the local LLM's folder, or Ollama's pull of it (a durable
  /// job, continued after an interruption).
  Future<void> _downloadStarter(
    String key,
    Map<String, dynamic> starter,
  ) async {
    if (_busy) return;
    final runtime = (_providers['local'] as List? ?? const [])
        .cast<Map>()
        .where((r) => r['key'] == key)
        .firstOrNull;
    final pull = runtime?['download'] == 'pull';
    final result = await _providerOperation(
      pull ? 'models.pull' : 'models.download',
      pull
          ? {'key': key, 'name': 'hf.co/${starter['repo']}'}
          : {
              'key': key,
              'repo': starter['repo'],
              'file': starter['file'],
              'size': starter['size'],
            },
      tr('Download model'),
    );
    if (result != null && mounted) await _openGuide();
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
      report = await _client.agentsSecurity(command: command);
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
      preview = await _client.agentsKeyPreview(command: command);
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
      final started = await _client.agentsKeyApply(
        preview: preview['preview'],
        key: key,
      );
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
      var plan = await _client.agentsActionPreview(
        command: command,
        action: action,
        kind: kind,
      );
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
        plan = await _client.agentsActionPreview(
          command: command,
          action: action,
          login: index,
        );
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
      final result = await _client.agentsActionApply(preview: plan['preview']);
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
    final activity = (_graph?['activity'] as Map?)?[command] as Map?;
    final agentRunning =
        terminals.isNotEmpty ||
        node['status'] == 'running' ||
        activity?['working'] == true ||
        ((activity?['instances'] as num?)?.toInt() ?? 0) > 0;
    const compact = BoxConstraints(minWidth: 26, minHeight: 24);
    return SizedBox(
      height: 26,
      child: Row(
        children: [
          IconButton(
            key: ValueKey('details-${node['id']}'),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: compact,
            tooltip: tr('Details'),
            onPressed: () => _aiNode(node),
            icon: const Icon(Icons.info_outline, size: 16),
          ),
          if (node['kind'] == 'runtime')
            IconButton(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: compact,
              tooltip: tr(node['status'] == 'running' ? 'Stop' : 'Start'),
              onPressed: () => _mapRuntimeControl(node),
              icon: Icon(
                node['status'] == 'running' ? Icons.stop : Icons.play_arrow,
                size: 16,
              ),
            ),
          if (node['kind'] == 'agent') ...[
            IconButton(
              key: ValueKey('usage-agent-$command'),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: compact,
              tooltip: tr('Usage'),
              onPressed: () =>
                  _openAgentUsage(command, tr(node['label'] as String)),
              icon: const Icon(Icons.bar_chart_outlined, size: 16),
            ),
            IconButton(
              key: ValueKey('start-agent-$command'),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: compact,
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
              icon: const Icon(Icons.play_arrow, size: 16),
            ),
            if (terminals.isNotEmpty)
              IconButton(
                key: ValueKey('console-agent-$command'),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: compact,
                tooltip: tr('Console'),
                onPressed: () =>
                    setState(() => _visibleTerminal = terminals.first),
                icon: const Icon(Icons.terminal, size: 15),
              ),
            if (agentRunning)
              IconButton(
                key: ValueKey('stop-agent-$command'),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: compact,
                tooltip: tr('Stop'),
                onPressed: () => terminals.isNotEmpty
                    ? _stopTerminal(terminals.first)
                    : _haltMapAgent(command),
                icon: Icon(
                  Icons.stop,
                  size: 16,
                  color: Theme.of(context).colorScheme.error,
                ),
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
      final reply = await _client.agentsHaltPreview(command: command);
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
      final result = await _client.agentsHaltApply(preview: token);
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
      final plan = method != null
          ? await _backend!.call(method, params)
          : author
          ? await _client.connectionsAuthorPreview(
              agents: params['agents'],
              entry: params['entry'],
              folder: params['folder'] as String?,
              kind: params['kind'] as String,
              name: params['name'] as String?,
            )
          : await _client.connectionsPreview(
              command: params['command'] as String,
              item: params['item'] as String,
              kind: params['kind'] as String,
              model: params['model'] as String?,
              remove: params['remove'] as bool,
              useNow: params['use_now'] as bool?,
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
        var result = await _client.connectionsApply(
          plan: plan['plan'] as String,
        );
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
      plan = await _client.modelsSlotsPreview();
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
      var result = await _client.connectionsApply(plan: plan['plan'] as String);
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
      if (plan['reload'] == true) await _client.modelsSlotsReload();
      await _refresh();
    } catch (_) {
      _actionFailed();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Undo of a model folder move made from Ask AI.
  Future<void> _undoMove() async {
    final token = _moveUndo;
    if (token == null || _busy) return;
    final result = await _addonOperation('system.move_undo', {'undo': token});
    if (result?['ok'] == true && mounted) setState(() => _moveUndo = null);
    await _reloadSystem();
    await _refreshSystem(false, quiet: true);
  }

  Future<bool> _undoConnection({bool refresh = true}) async {
    final token = _connectionUndo;
    if (token == null) return false;
    setState(() => _busy = true);
    try {
      final result = await _client.connectionsUndo(undo: token);
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
      final preview = await _client.modelsRemovePreview(key: key, model: model);
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
      final started = await _client.modelsRemoveApply(
        removal: preview['removal'],
      );
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
      final started = await _client.setupDetect();
      while (mounted && revision == _setupRevision) {
        final status = await _client.tasksStatus(
          task: started['task'] as String,
        );
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
      if (enabled == null) {
        await _client.setupLater();
      } else {
        await _client.setupApply(enabled: enabled);
      }
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
          await _client.setupApply(enabled: before);
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
    final settingsRevision = _settingsRevision;
    setState(() => _busy = true);
    try {
      final snapshot = await _client.appSnapshot();
      final connections = _showConnections
          ? await _client.connectionsSnapshot(command: _connectionCommand)
          : null;
      final providerData = _showProviders
          ? await _client.providersSnapshot()
          : null;
      final firstSnapshot = !_startupChecked;
      final openSetup = firstSnapshot && snapshot['setup_needed'] == true;
      final addons = await _client.addonsList();
      var smartHelpers = _smartHelpers;
      try {
        final smart = await _client.mapSmartHelpers();
        smartHelpers = (smart['helpers'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
      } catch (_) {
        // Smart cards stay hidden when no helper route is available.
      }
      final mapVisible =
          _showMap &&
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
          : await _client.agentsDetails(command: selected);
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
      if (!mounted || settingsRevision != _settingsRevision) return;
      setState(() {
        _snapshot = snapshot;
        if (connections != null) _connections = connections;
        if (providerData != null) _providers = providerData;
        _startupChecked = true;
        if (openSetup) {
          _welcome = true;
          _focusCategory = 1;
          _showMap = true;
          _setupRevision++;
        }
        _addons = (addons['addons'] as List).cast<Map<String, dynamic>>();
        _smartHelpers = smartHelpers;
        _graph = graph;
        if (_selected == selected) _agentInfo = info;
        _strings = strings;
        if (selected != null && info != null) {
          unawaited(_refreshUsage(selected));
        }
        _locale = Locale(language);
        _busy = false;
        _failed = false;
      });
      if (firstSnapshot) {
        unawaited(_detectSetup());
        unawaited(_loadJobs());
        unawaited(_checkHealth());
        unawaited(_checkUpdates());
        unawaited(_checkMcp());
        _mcpTimer ??= Timer.periodic(
          const Duration(hours: 1),
          (_) => unawaited(_checkMcp()),
        );
        if (!_welcome) _quietCatalog = _quietAddonCatalog();
        unawaited(_lookForNewApps());
        // Settings › Costs: a desktop notification when a plan limit turns red.
        _usageTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
          unawaited(_loadUsageBoxes());
          unawaited(_loadTraffic());
        });
        _limitsTimer ??= Timer.periodic(const Duration(minutes: 1), (_) {
          if (_backend?.isConnected == true) {
            unawaited(_loadBadges());
            unawaited(_loadGpu());
            unawaited(_client.limitsNotify().then((_) {}, onError: (_) {}));
          }
        });
        unawaited(_loadBadges());
        unawaited(_loadGpu());
        unawaited(_refreshAllUsage());
      }
      unawaited(_loadTraffic());
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
  ThemeData _theme(Brightness brightness) => appTheme(
    brightness,
    mode: _themePreference,
    desktop: _desktopTheme,
    radius: cornerRadius(
      (_snapshot?['settings'] as Map?)?['corners'] as String?,
      _windowRounding,
    ),
  );

  /// The window's title bar is GTK's, not Flutter's: it takes the app's
  /// light or dark (COSMIC gives GTK apps no dark theme of their own).
  bool? _titleBarDark;
  void _followTitleBar(bool dark) {
    if (_titleBarDark == dark) return;
    _titleBarDark = dark;
    windowChannel.invokeMethod('titlebar', dark).catchError((_) => null);
  }

  /// Hyprland's window rounding (window.rounding; the core reads it at most
  /// every 30 s), for Settings › Corners "Like windows".
  int? _windowRounding;

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
    _usageTimer?.cancel();
    _mcpTimer?.cancel();
    _blurHide?.cancel();
    windowManager.removeListener(this);
    _liveTimer?.cancel();
    _mapLayoutTimer?.cancel();
    _startMenu.dispose();
    _aiTransform.dispose();
    HardwareKeyboard.instance.removeHandler(_shotKey);
    for (final terminal in _terminals) {
      terminal.dispose();
    }
    _backend?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Maprisma',
    navigatorKey: _navigator,
    // F1 opens Help, as in the GTK app.
    shortcuts: {
      ...WidgetsApp.defaultShortcuts,
      const SingleActivator(LogicalKeyboardKey.f1): const _HelpIntent(),
      const SingleActivator(LogicalKeyboardKey.comma, control: true):
          const _SettingsIntent(),
      const SingleActivator(LogicalKeyboardKey.f5): const _RefreshIntent(),
      const SingleActivator(LogicalKeyboardKey.equal, control: true):
          const _ZoomIntent(1.25),
      const SingleActivator(LogicalKeyboardKey.add, control: true):
          const _ZoomIntent(1.25),
      const SingleActivator(LogicalKeyboardKey.numpadAdd, control: true):
          const _ZoomIntent(1.25),
      const SingleActivator(LogicalKeyboardKey.minus, control: true):
          const _ZoomIntent(0.8),
      const SingleActivator(LogicalKeyboardKey.numpadSubtract, control: true):
          const _ZoomIntent(0.8),
      const SingleActivator(LogicalKeyboardKey.digit0, control: true):
          const _ZoomIntent(0),
      const SingleActivator(LogicalKeyboardKey.numpad0, control: true):
          const _ZoomIntent(0),
      const SingleActivator(LogicalKeyboardKey.backspace): const _BackIntent(),
    },
    actions: {
      ...WidgetsApp.defaultActions,
      _HelpIntent: CallbackAction<_HelpIntent>(
        onInvoke: (_) {
          if (!_navigationBlocked && _snapshot != null) _openHelp();
          return null;
        },
      ),
      _SettingsIntent: CallbackAction<_SettingsIntent>(
        onInvoke: (_) {
          if (!_navigationBlocked && _snapshot != null && !_showSettings) {
            _toggleSettings();
          }
          return null;
        },
      ),
      _RefreshIntent: CallbackAction<_RefreshIntent>(
        onInvoke: (_) {
          if (!_navigationBlocked) _retry();
          return null;
        },
      ),
      _ZoomIntent: CallbackAction<_ZoomIntent>(
        onInvoke: (intent) {
          if (_showMap) _zoom(intent.factor);
          return null;
        },
      ),
      // Esc (Flutter's dismiss key) and Backspace: back from a page; only
      // when nothing nearer took the key.
      DismissIntent: _BackAction<DismissIntent>(
        () => (_card?.closable ?? false) || _canGoBack || _canCloseTopLevel,
        () => (_card?.closable ?? false) ? _closeCard() : _backOrClose(),
      ),
      _EscIntent: _BackAction<_EscIntent>(
        () => (_card?.closable ?? false) || _canGoBack || _canCloseTopLevel,
        () => (_card?.closable ?? false) ? _closeCard() : _backOrClose(),
      ),
      _BackIntent: _BackAction<_BackIntent>(() => _canGoBack, _goBack),
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
    builder: (context, child) {
      _followTitleBar(Theme.of(context).brightness == Brightness.dark);
      return RepaintBoundary(key: _shotArea, child: child);
    },
    // Esc on the window's page: back from a page (the route's own dismiss
    // action would take it first); dialogs are routes of their own and keep
    // Esc as dismiss.
    home: Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): _EscIntent(),
      },
      // The page holds the focus when nothing in it does, so its keys
      // pass through here (not part of Tab's order).
      child: Focus(
        autofocus: true,
        skipTraversal: true,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Maprisma'),
            actions: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: TextButton(
                  key: const ValueKey('ai-map-open'),
                  // From a page or the agent list, back to the map.
                  onPressed: _navigationBlocked
                      ? null
                      : () {
                          setState(() {
                            _card = null;
                            _browser = null;
                            _showMap = true;
                            _showGuide = false;
                            _showSettings = false;
                            _showProviders = false;
                            _showConnections = false;
                            _visibleTerminal = null;
                          });
                          _refresh();
                        },
                  child: Text(tr('AI Map')),
                ),
              ),
              if (_moveUndo != null)
                IconButton(
                  key: const ValueKey('move-undo'),
                  tooltip: tr('Undo'),
                  icon: const Icon(Icons.undo),
                  onPressed: _navigationBlocked || _card != null
                      ? null
                      : _undoMove,
                ),
              if (_healthReport != null || _healthCount > 0)
                IconButton(
                  key: const ValueKey('problems-open'),
                  tooltip: switch ('${_healthReport?['summary'] ?? ''}'
                      .trim()) {
                    '' => tr('Everything set up and working'),
                    final s => s,
                  },
                  icon: SmartStatusIcon(
                    level: _smartStatusData.overallLevel,
                    size: 18,
                  ),
                  onPressed: _navigationBlocked ? null : _openProblems,
                ),
              MapLegendButton(tr: tr),
              IconButton(
                key: const ValueKey('help-open'),
                tooltip: tr('Help (F1)'),
                icon: const Icon(Icons.help_outline),
                onPressed: _navigationBlocked || _snapshot == null
                    ? null
                    : _openHelp,
              ),
              IconButton(
                tooltip: tr('Settings'),
                icon: const Icon(Icons.settings_outlined),
                onPressed: _navigationBlocked || _snapshot == null
                    ? null
                    : _toggleSettings,
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
                          'Your Asterism settings could not be copied. Maprisma starts with its default settings.',
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
                  onAgents: () => _openGroups(),
                  uses: _uses,
                  onAction: _healthAction,
                ),
              if (_terminals.isNotEmpty &&
                  (_snapshot?['settings'] as Map?)?['terminal_tabs'] != false)
                TerminalTabs(
                  tabs: [
                    for (final terminal in _terminals)
                      (
                        _catalog
                                    .where(
                                      (a) => a['command'] == terminal.command,
                                    )
                                    .firstOrNull?['name']
                                as String? ??
                            terminal.command,
                        terminal.ended
                            ? 'ended'
                            : ((_graph?['activity'] as Map?)?[terminal.command]
                                      as Map?)?['working'] ==
                                  true
                            ? 'working'
                            : 'running',
                      ),
                  ],
                  current: _visibleTerminal == null
                      ? null
                      : _terminals.indexOf(_visibleTerminal!),
                  tr: tr,
                  onSelect: (i) => setState(() {
                    _visibleTerminal = _terminals[i];
                  }),
                ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _mapAreaWidth = constraints.maxWidth;
                    return Stack(
                      fit: StackFit.expand,
                      children: [
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
                        if (_hasTaskView || (_card == null && _browser == null))
                          RetainedTaskView(
                            key: const ValueKey('view-slot'),
                            visible: _card == null && _browser == null,
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
                                      onStarter: _downloadStarter,
                                      onBack: () =>
                                          setState(() => _showGuide = false),
                                      onRefresh: _openGuide,
                                    ),
                                    () => setState(() => _showGuide = false),
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
                                          _connectionPreview(
                                            params,
                                            author: true,
                                          ),
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
                                      onFoundChanged: _loadFoundHints,
                                      onUpdatePreview: (params) async {
                                        await _connectionPreview(
                                          params,
                                          method: 'found.update_preview',
                                        );
                                        await _lookForNewApps();
                                      },
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
                                          in (_system['helpers'] as List? ??
                                              []))
                                        if (h is Map && h['check'] == true) h,
                                    ],
                                    helpers: _helpers,
                                    mcpChecks: _mcpChecks,
                                    mcpChecking: _mcpChecking,
                                    onCheckMcp: () => _checkMcp(force: true),
                                    changes: _changes,
                                    windowRounding: _windowRounding,
                                    onUndoChange: _undoChange,
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
                                                  .map(
                                                    (t) => '${t.id}:${t.ended}',
                                                  )
                                                  .join(','),
                                            ),
                                            savedLayout:
                                                _mapLayoutOverride ??
                                                (_snapshot!['settings']['flutter_map_layout']
                                                        as Map<
                                                          String,
                                                          dynamic
                                                        >? ??
                                                    {}),
                                            onLayout: _saveMapLayout,
                                            animate: _windowFocused
                                                ? (_snapshot!['settings']['map_animations']
                                                          as String? ??
                                                      'all')
                                                : 'off',
                                            controller: _aiTransform,
                                            layers:
                                                (_snapshot!['settings']['map_layers']
                                                        as List?)
                                                    ?.cast<String>(),
                                            onLayers: (layers) =>
                                                _updateSettings({
                                                  'map_layers': layers,
                                                }),
                                            focusedNode: _aiFocus,
                                            onNode: _aiNode,
                                            tr: tr,
                                            onAgent: _selectAgent,
                                            onSubagents: _openSubagents,
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
                                            smartAskColumns: const {
                                              'mcp',
                                              'agents',
                                              'providers',
                                              'models',
                                            },
                                            onSmartProvider: _smartProvider,
                                            onSmartTask: _smartTask,
                                            smartCards: true,
                                            smartHelpers: _smartHelpers,
                                            smartStatus: _smartStatusData,
                                            smartStatusTarget:
                                                _smartStatusTarget,
                                            client: _maybeClient,
                                            onSmartApplied: (result) {
                                              if (result['session'] != null) {
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
                                                });
                                              }
                                              if (result['move_undo']
                                                  is String) {
                                                setState(
                                                  () => _moveUndo =
                                                      result['move_undo']
                                                          as String,
                                                );
                                                unawaited(
                                                  _refreshSystem(
                                                    false,
                                                    quiet: true,
                                                  ),
                                                );
                                              }
                                              if (result['undo'] is String) {
                                                _connectionUndo =
                                                    result['undo'] as String;
                                              }
                                              unawaited(_refresh());
                                            },
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
                                          SizedBox(
                                            width: 310,
                                            child: _agents(),
                                          ),
                                          const VerticalDivider(width: 1),
                                          Expanded(child: _details()),
                                        ],
                                      );
                                    },
                                  ),
                          ),
                        if (_card != null) _host(_card!, _closeCard),
                        if (_visibleTerminal != null &&
                            _card == null &&
                            _browser == null)
                          Stack(
                            key: const ValueKey('terminal-overlay'),
                            fit: StackFit.expand,
                            children: [
                              const ModalBarrier(
                                color: Colors.black54,
                                dismissible: false,
                              ),
                              Center(
                                child: FractionallySizedBox(
                                  widthFactor: 0.8,
                                  heightFactor: 0.85,
                                  child: Card(
                                    clipBehavior: Clip.antiAlias,
                                    elevation: 8,
                                    child: AgentTerminalView(
                                      session: _visibleTerminal!,
                                      tr: tr,
                                      onBack: () {
                                        final fromGuide = _guideTerminals
                                            .remove(_visibleTerminal);
                                        setState(() => _visibleTerminal = null);
                                        if (fromGuide) {
                                          _guideReturn = true;
                                          _backToGuideIfFromIt();
                                        }
                                      },
                                      onStop: () =>
                                          _stopTerminal(_visibleTerminal!),
                                      onScreenshot:
                                          (_snapshot?['settings']
                                                  as Map?)?['screenshot_key'] ==
                                              false
                                          ? null
                                          : _takeShot,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
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
    onBack: _goBack,
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

class _SettingsIntent extends Intent {
  const _SettingsIntent();
}

class _RefreshIntent extends Intent {
  const _RefreshIntent();
}

class _ZoomIntent extends Intent {
  const _ZoomIntent(this.factor);

  /// 1.25 in, 0.8 out, 0 fit to window.
  final double factor;
}

/// Backspace: back from a page (never closes a dialog, unlike Esc).
class _BackIntent extends Intent {
  const _BackIntent();
}

/// Esc on the window's page: back from a page; on the main page in popup
/// mode it closes the popup.
class _EscIntent extends Intent {
  const _EscIntent();
}

/// Back from a page; disabled (the key passes on) when there is no page.
class _BackAction<T extends Intent> extends Action<T> {
  _BackAction(this.enabled, this.back);
  final bool Function() enabled;
  final VoidCallback back;

  @override
  bool isEnabled(T intent) => enabled();

  @override
  bool consumesKey(T intent) => enabled();

  @override
  Object? invoke(T intent) {
    back();
    return null;
  }
}
