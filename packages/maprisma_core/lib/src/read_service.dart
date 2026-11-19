import 'provider_ops.dart' show ProviderOps;
import 'provider_scans.dart' show ProviderScans, RuntimeRecord;
import 'model_guard.dart' show GpuUsage;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'activity_readers.dart';
import 'ai_activity_log.dart';
import 'agent_catalog.dart';
import 'agent_progress.dart';
import 'agent_halt.dart' show agentInstancePids, cwdOf;
import 'pty_sessions.dart' show processIdentity;
import 'session_readers.dart' show SessionReaders;
import 'agent_details.dart';
import 'desktop.dart';
import 'identity.dart';
import 'inventory.dart';
import 'map_graph.dart';
import 'scan_files.dart';
import 'service_i18n.dart';
import 'settings.dart';
import 'adapter_assets.g.dart';
import 'core_tasks.dart' show taskFocus;
import 'system_reads.dart';
import 'provider_facts.dart';

// Each route here has passed its differential fixtures (normal and hostile) and
// a read-only comparison with the Python reference on a real HOME.
const readOnlyRoutes = <String>{
  'app.snapshot',
  'map.snapshot',
  'agents.details',
  'agents.activity',
  'connections.snapshot',
  'usage.snapshot',
  'existing.mounts',
  'system.mount_signature',
  'providers.snapshot',
};

final class ReadService {
  ReadService(this.identity, this.settings, this.desktop, this.i18n) {
    files = ScanFiles(identity);
    catalog = AgentCatalog(files, desktop);
    details = DetailReaders(files, desktop, i18n);
    inventory = InventoryReader(files, catalog, details);
    activity = ActivityReaders(files, details);
    graph = MapGraph(files, i18n)..programSignIn = details.limitsSignedIn;
  }
  final AppIdentity identity;
  final SettingsStore settings;

  /// Why Asterism's folders could not be copied (legacy_move.dart), if so.
  String? migrationError;
  final Desktop desktop;
  final ServiceI18n i18n;
  late final ScanFiles files;
  late final AgentCatalog catalog;
  late final DetailReaders details;
  late final InventoryReader inventory;
  late final ActivityReaders activity;
  late final activityLog = AiActivityLog(files, settings);
  bool _samplingActivityLog = false;

  ActivityUsage? _activityUsage(String source) {
    if (!source.startsWith('agent:')) return null;
    final command = source.substring(6);
    final sessions = catalog.adapter(command)?.table('sessions');
    final reader = sessions?['reader'];
    final folder = sessions?['activity_dir'];
    if (reader is! String ||
        !{'pi-files', 'codex-files'}.contains(reader) ||
        folder is! String ||
        !folder.startsWith('~/')) {
      return null;
    }
    final root = p.normalize(files.expand(folder));
    if (!p.isWithin(files.identity.home, root)) return null;
    final pids = agentInstancePids(ProviderScans(files), {command})[command];
    if (pids == null || pids.length != 1) return null;
    final pid = pids.single;
    final identity = processIdentity(pid);
    if (identity == null) return null;
    final logs = <String>{};
    for (final fd in files.list('/proc/$pid/fd', limit: 512)) {
      try {
        final target = Link(fd).targetSync();
        if (target.endsWith('.jsonl') &&
            p.isWithin(root, target) &&
            (reader != 'codex-files' ||
                p.basename(target).startsWith('rollout-'))) {
          logs.add(target);
        }
      } on FileSystemException {
        // The descriptor may have closed while the process was sampled.
      }
    }
    if (logs.length != 1) return null;
    final log = logs.single;
    final bytes = files.bytes(log, limit: 4 * 1024 * 1024);
    if (bytes == null) return null;
    final numeric = SessionReaders(files).parse(reader, bytes);
    if (numeric == null ||
        numeric.tokens.isEmpty ||
        processIdentity(pid) != identity) {
      return null;
    }
    return (
      session: '$pid:${identity.$3}:$log',
      model: numeric.tokens.length == 1 ? numeric.tokens.keys.single : null,
      input: numeric.tokens.values.fold(0, (n, counts) => n + counts[0]),
      output: numeric.tokens.values.fold(0, (n, counts) => n + counts[1]),
    );
  }

  void _observeActivity(Map<String, dynamic> options) {
    final enabled = settings.value(options, 'ai_activity_log') == true;
    final agents = <String>{
      if (enabled)
        for (final e in _activity!.entries)
          if (e.value is Map && e.value['working'] == true) 'agent:${e.key}',
    };
    final activeAgents = agents.map((source) => source.substring(6)).toSet();
    final paths = <String, String>{
      if (activeAgents.isNotEmpty)
        for (final e in agentInstancePids(
          ProviderScans(files),
          activeAgents,
        ).entries)
          if (e.value.length == 1)
            'agent:${e.key}': cwdOf(e.value.single, files.posix),
    };
    final runtimes = _inventory!.runtimes.where((rt) => rt.running).toList();
    if (!enabled || runtimes.length != 1) {
      activityLog.observe(
        agents,
        workingDirectories: paths,
        usageFor: _activityUsage,
      );
    } else if (!_samplingActivityLog) {
      _samplingActivityLog = true;
      unawaited(() async {
        try {
          if (await GpuUsage(
            files,
            ProviderScans(files),
          ).generating(runtimes)) {
            agents.add('runtime:${runtimes.single.key}');
          }
          activityLog.observe(
            agents,
            workingDirectories: paths,
            usageFor: _activityUsage,
          );
        } on Exception {
          activityLog.observe(
            agents,
            workingDirectories: paths,
            usageFor: _activityUsage,
          );
        } finally {
          _samplingActivityLog = false;
        }
      }());
    }
  }

  late final MapGraph graph;

  /// Called after each inventory scan (the provider watcher's config).
  void Function(InventorySnapshot inventory, List<AgentRecord> agents)?
  onInventory;
  Map<String, dynamic> map = {
    'activity': <String, dynamic>{},
    'nodes': <dynamic>[],
    'edges': <dynamic>[],
  };
  bool _pending = false, _forced = false, _forcePending = false;
  final _clock = Stopwatch()..start();
  int _lastScan = -1000000;
  String? _inputs;
  List<AgentRecord>? _agents;
  Map<String, AgentInfo>? _details;
  InventorySnapshot? _inventory;

  /// Inventory from the most recent map refresh, including user model folders.
  InventorySnapshot get mapInventory => _inventory!;
  Map<String, List<String>>? _running;
  Map<String, dynamic>? _activity;
  Map<String, dynamic> dispatch(String method, Map<String, dynamic> params) {
    if (method == 'map.snapshot') return mapSnapshot(params);
    if (method == 'agents.details' || method == 'agents.activity') {
      if (params.length != 1 || params['command'] is! String) {
        throw const FormatException('Expected an agent');
      }
      final agents = catalog.scan();
      final known = agents
          .where((a) => a.command == params['command'])
          .toList();
      if (known.isEmpty) throw const FormatException('Unknown agent');
      final agent = known.first;
      if (method == 'agents.activity') {
        return activity
                    .snapshot(
                      [agent],
                      recent:
                          (settings.value(settings.load(), 'subagents_minutes')
                              as num) *
                          60.0,
                      kept:
                          (settings.value(settings.load(), 'subagents_kept')
                                  as num)
                              .toInt(),
                    )
                    .$2[agent.command]
                as Map<String, dynamic>? ??
            {'instances': 0, 'subagents_supported': false, 'children': []};
      }
      return {
        'command': agent.command,
        ...details.read(agent.adapter).toJson(),
        'extra_usage': details.extraUsage(agent.adapter),
        'actions': details.actions(agent),
      };
    }
    if (method == 'connections.snapshot') {
      if (params.keys.any((k) => k != 'command') ||
          params.containsKey('command') && params['command'] is! String) {
        throw const FormatException('Unexpected parameters');
      }
      final result = inventory.snapshot(catalog.scan());
      final focus = [
        for (final n in map['nodes'] as List)
          if (n['id'] == 'agent:${params['command']}') n['id'],
      ];
      return {...result, 'focus': focus};
    }
    if (params.isNotEmpty) throw const FormatException('Unexpected parameters');
    if (method == 'providers.snapshot') return providersSnapshot();
    if (method == 'usage.snapshot') {
      // Fixtures pin the clock (MAPRISMA_SCAN_NOW), as the session readers do.
      final pinned = double.tryParse(
        identity.environment['MAPRISMA_SCAN_NOW'] ?? '',
      );
      return UsageReader(files).snapshot(
        now: pinned == null
            ? null
            : DateTime.fromMicrosecondsSinceEpoch((pinned * 1e6).round()),
      );
    }
    if (method == 'existing.mounts' || method == 'system.mount_signature') {
      final text =
          files.text(
            '/proc/self/mountinfo',
            limit: 4 << 20,
            allowRootOwned: true,
          ) ??
          '';
      final mounts = localMounts(text);
      return method == 'existing.mounts'
          ? {'mounts': mounts}
          : {'signature': mountSignature(mounts)};
    }
    if (method == 'app.snapshot') {
      final saved = settings.load(), agents = catalog.scan();
      final defaultPath = settings.value(saved, 'agent_folder');
      String folder(dynamic path) {
        if (path is! String || path.isEmpty || path.contains('\x00')) return '';
        final candidate = files.expand(path);
        if (!p.isAbsolute(candidate)) return '';
        try {
          return Directory(candidate).existsSync()
              ? Directory(candidate).resolveSymbolicLinksSync()
              : '';
        } on FileSystemException {
          return '';
        }
      }

      final fallback = folder(defaultPath).isEmpty
          ? identity.home
          : folder(defaultPath);
      final pinned = mapOf(saved['agent_projects']),
          history = mapOf(saved['agent_project_history']);
      return {
        'protocol': 2,
        'migration_error': migrationError,
        'language': settings.value(saved, 'language'),
        'settings': settings.snapshot(),
        'theme':
            desktop.name != 'omarchy' ||
                settings.value(saved, 'look') == 'omarchy'
            ? desktop.themeColors()
            : {},
        'fonts': desktop.fonts(),
        'setup_needed': settings.value(saved, 'setup_done') != true,
        'agents': agents.map((a) => a.toJson()).toList(),
        'projects': {
          for (final a in agents)
            a.command: {
              'default': folder(pinned[a.command]).isEmpty
                  ? fallback
                  : folder(pinned[a.command]),
              'pinned': pinned[a.command] is String ? pinned[a.command] : null,
              'history': [
                for (final path
                    in (history[a.command] is List
                            ? history[a.command] as List
                            : [])
                        .whereType<String>()
                        .where(
                          (s) =>
                              s.isNotEmpty &&
                              !s.contains('\x00') &&
                              p.isAbsolute(s),
                        )
                        .toSet())
                  {'path': path, 'available': Directory(path).existsSync()},
              ],
            },
        },
      };
    }
    throw const FormatException('Unknown read route');
  }

  /// flutter_providers.snapshot with the focus the backend adds per runtime.
  Map<String, dynamic> providersSnapshot() {
    final engines = providerFacts['engines'] as Map;
    bool lms() =>
        inventory.providers.which('lms') ||
        FileSystemEntity.isFileSync(files.expand('~/.lmstudio/bin/lms'));
    final local = <Map<String, dynamic>>[];
    for (final rt in inventory.providers.scan()) {
      final engine = engines[rt.key] as Map? ?? const {};
      final removable = engine['removable'] as String? ?? '';
      final download = engine['download'] as String? ?? '';
      local.add({
        'key': rt.key,
        'name': rt.name,
        'installed': rt.installed,
        'installable': !rt.installed && engine['can_install'] == true,
        'running': rt.running,
        'server_off': rt.serverOff,
        'address': rt.address,
        'models_dir': rt.modelsDir,
        'models': rt.models,
        'can_control': rt.key == 'strata'
            ? ProviderOps(files, inventory.providers).canControl(rt)
            : engine['lms_control'] == true
            ? rt.installed && (rt.service.isNotEmpty || lms())
            : rt.installed && rt.service.isNotEmpty,
        'can_load': engine['can_load'] == true,
        'removable': rt.installed && (removable == 'file' || removable == 'api')
            ? removable
            : '',
        'download': rt.installed ? download : '',
        'can_import':
            rt.installed && (download == 'file' || download == 'pull'),
        'tunable':
            rt.installed && ((engine['tuning'] as Map?)?.isNotEmpty ?? false),
        'focus': taskFocus(map, {'key': rt.key}),
      });
    }
    final folders = settings.load()['model_folders'];
    return {
      'folders': [
        for (final f in folders is List ? folders : const [])
          if (f is String)
            {'path': f, 'available': FileSystemEntity.isDirectorySync(f)},
      ],
      'local': local,
      'online': visibleProviderFacts['online'],
    };
  }

  Map<String, dynamic> mapSnapshot(Map<String, dynamic> params) {
    if (params.keys.any((k) => !['force', 'poll'].contains(k)) ||
        params.values.any((v) => v is! bool) ||
        params['force'] == true && params['poll'] == true) {
      throw const FormatException('Invalid map scan request');
    }
    Map<String, dynamic> reply() => {
      ...map,
      'pending': _pending || _forcePending,
    };
    if (_pending) {
      if (params['force'] == true && !_forced) _forcePending = true;
      return reply();
    }
    if (params['poll'] == true && !_forcePending) return reply();
    final saved = settings.load(),
        interval = settings.value(saved, 'map_scan_interval') as int,
        targets = (settings.value(saved, 'map_scan_targets') as List)
            .cast<String>();
    final force = params['force'] == true || _forcePending;
    if (!force && (interval == 0 || targets.isEmpty)) return reply();
    final inputs = jsonEncode({
      for (final key in [
        'addons_enabled',
        'map_layers',
        'map_scan_interval',
        'map_scan_pause_unfocused',
        'map_scan_targets',
        'subagents_minutes',
        'subagents_kept',
        'language',
        'models_root',
        'model_folders',
        'provider_models',
        'mcp_folders',
        'skill_folders',
      ])
        key: settings.value(saved, key),
    });
    if (!force &&
        inputs == _inputs &&
        _clock.elapsedMilliseconds - _lastScan < interval * 1000) {
      return reply();
    }
    _pending = true;
    _forced = force;
    _forcePending = false;
    _lastScan = _clock.elapsedMilliseconds;
    _inputs = inputs;
    scheduleMicrotask(() {
      try {
        map = buildMap(
          force ? {'activity', 'agents', 'inventory'} : targets.toSet(),
        );
      } catch (_) {
        // A failed read keeps the last bounded map, like the reference worker.
      } finally {
        _pending = false;
      }
    });
    return reply();
  }

  Map<String, dynamic> buildMap([
    Set<String> targets = const {'activity', 'agents', 'inventory'},
    bool allLayers = false,
  ]) {
    if (_agents == null || targets.contains('agents')) {
      _agents = catalog.scan();
      _details = {
        for (final a in _agents!)
          if (a.installed) a.command: details.read(a.adapter),
      };
    }
    if (_inventory == null ||
        targets.contains('inventory') ||
        targets.contains('agents')) {
      final folders = settings.load()['model_folders'];
      _inventory = inventory.collect(
        _agents!,
        modelFolders: [
          for (final f in folders is List ? folders : const [])
            if (f is String) f,
        ],
      );
      onInventory?.call(_inventory!, _agents!);
    }
    final saved = settings.load();
    final chosen = settings.value(saved, 'provider_models') as Map;
    if (_activity == null ||
        targets.contains('activity') ||
        targets.contains('agents')) {
      final state = activity.snapshot(
        _agents!,
        recent: (settings.value(saved, 'subagents_minutes') as num) * 60,
        kept: (settings.value(saved, 'subagents_kept') as num).toInt(),
      );
      _running = state.$1;
      _activity = state.$2;
      _observeActivity(saved);
    }
    final graphData = graph.build(
      _agents!,
      _details!,
      _inventory!,
      running: _running!,
      activity: _activity!,
      layers: allLayers
          ? const ['agents', 'online', 'local', 'models', 'mcp', 'skills']
          : (settings.value(saved, 'map_layers') as List).cast<String>(),
      modelsShown: allLayers ? 40 : 10,
      animate: settings.value(saved, 'map_animations') as String,
      providerModels: {
        for (final e in chosen.entries) '${e.key}': '${e.value}',
      },
    );
    final instances = AgentProgress(
      ProviderScans(files),
    ).snapshot(_running!.keys.toSet());
    for (final node in (graphData['nodes'] as List).cast<Map>()) {
      final id = node['id'];
      if (id is! String || !id.startsWith('agent:')) continue;
      final live = instances[id.substring(6)];
      if (live == null) continue;
      node['activity_instances'] = live;
      Map<String, dynamic>? latest;
      for (final instance in live) {
        final report = instance['progress'] as Map<String, dynamic>?;
        if (report != null &&
            (latest == null ||
                DateTime.parse(
                  report['at'] as String,
                ).isAfter(DateTime.parse(latest['at'] as String)))) {
          latest = {...report, 'instance': instance['id']};
        }
      }
      if (latest == null) continue;
      node['activity_progress'] = latest;
      node['detail'] =
          "${latest['done']}/${latest['total']} · ${latest['step']}";
    }
    return graphData;
  }

  /// Who is set to which model of a local LLM: fresh, with no layer hidden and
  /// no model left out, unlike the map.
  Map<String, List<String>> modelUsers(RuntimeRecord rt, {bool fresh = true}) {
    if (fresh || _inventory == null) buildMap();
    final built = graph.build(
      _agents!,
      _details!,
      _inventory!,
      running: _running!,
      activity: _activity!,
      modelsShown: 1 << 30,
    );
    return {
      for (final model in rt.models)
        model: [
          for (final e in (built['edges'] as List).cast<Map>())
            if (e['kind'] == 'default' &&
                e['target'] == 'model:runtime:${rt.key}:${model.toLowerCase()}')
              '${e['source']}'.substring('agent:'.length),
        ],
    };
  }
}
