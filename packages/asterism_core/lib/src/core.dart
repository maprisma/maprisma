import 'dart:convert';
import 'dart:io';
import 'desktop.dart';
import 'identity.dart';
import 'posix_ffi.dart';
import 'protocol.dart';
import 'provider_scans.dart' show ProviderScans;
import 'provider_watch.dart';
import 'read_service.dart';
import 'connect_apply.dart';
import 'addon_store.dart';
import 'addons.dart';
import 'py_values.dart';
import 'package:path/path.dart' as p;
import 'adapter_assets.g.dart';
import 'agent_actions.dart';
import 'agent_halt.dart';
import 'agent_start.dart';
import 'core_tasks.dart';
import 'skill_plans.dart';
import 'mcp_plans.dart';
import 'llm_plans.dart';
import 'context.dart';
import 'map_edits.dart';
import 'provider_ops.dart';
import 'inventory.dart' show chatModels;
import 'settings.dart';
import 'service_i18n.dart';
import 'provider_facts.dart';

const portedRoutes = {
  'settings.get',
  'settings.update',
  'app.theme',
  'app.identity',
  'desktop.snapshot',
  'i18n.lookup',
  'addons.list',
  'addons.set_enabled',
  'addons.catalog',
  'addons.install',
  'addons.remove_preview',
  'addons.remove_apply',
  'addons.remove_undo',
  'sessions.start',
  'projects.pin',
  'projects.forget',
  'agents.action_preview',
  'agents.action_apply',
  'agents.halt_preview',
  'agents.halt_apply',
  ...readOnlyRoutes,
};
// Phase 7 removes this blocker only after every route has differential coverage.
const dartCoreComplete = false;

final class CoreService {
  CoreService({Map<String, String>? environment}) {
    identity = AppIdentity(environment: environment);
    settings = SettingsStore(identity);
    settings.migrate();
    desktop = detectDesktop(identity, Posix());
    i18n = ServiceI18n(identity, settings);
    // The add-ons first (initialize): their agents and providers replace the
    // built-in ones the way the reference does.
    addons.reload(enabledAddons());
    reads.catalog.adapters = addons.adapters;
    // Inventory scans remember the MCP servers in use, as the reference does.
    reads.inventory.knownServers = mcp.knownServers;
    // After each scan the provider watcher's config, and its service on or off.
    reads.onInventory = watch.sync;
  }
  late final reads = ReadService(identity, settings, desktop, i18n);
  late final tasks = CoreTasks(defaultWorkerCommand(identity.environment));
  late final config = ConfigFiles(Posix(), identity.home);
  late final connections = CoreConnections(
    config,
    tasks,
    '${identity.configDir}/connection-backups',
  );
  late final mcp = McpPlans(
    reads.files,
    config,
    reads.catalog,
    AgentProfiles(reads.files, identity.configDir),
    '${identity.configDir}/mcp-servers.json',
  );
  late final llm = LlmPlans(
    config,
    reads.catalog,
    identity.home,
    ContextReader(reads.files, config),
  );
  late final addons = AddonRegistry(AddonVerifier(Posix()), [
    addonUserDir,
    p.join(p.dirname(Platform.resolvedExecutable), 'addons'),
  ]);
  String get addonUserDir =>
      p.join(identity.root('XDG_DATA_HOME', '.local/share'), 'asterism/addons');
  Set<String> enabledAddons() => {
    for (final x in settings.value(settings.load(), 'addons_enabled') as List)
      x as String,
  };

  /// flutter_addons.snapshot's sign-ins: installed agents of a provider
  /// add-on's online providers that can sign in.
  List<Map<String, dynamic>> addonSignIns(Addon item) {
    if (item.kind != 'provider') return [];
    final commands = {
      for (final x in (providerFacts['online_providers'] as List).cast<Map>())
        if (item.provides.contains(x['key'])) ...(x['agents'] as List),
    };
    return [
      for (final a in reads.catalog.scan())
        if (a.installed &&
            commands.contains(a.command) &&
            a.adapter.table('access').isNotEmpty)
          {'command': a.command, 'name': a.name},
    ];
  }

  Map<String, dynamic> addonRoute(String method, Map<String, dynamic> params) {
    if (method == 'addons.list') {
      if (params.isNotEmpty) {
        throw const FormatException('Add-on service unavailable');
      }
      return addons.snapshot(enabledAddons(), addonSignIns, addonUserDir);
    }
    if (starter.sessions.items.values.any(starter.sessions.running)) {
      throw const FormatException(
        'Finish running agents before changing add-ons',
      );
    }
    if (params.length != 2 ||
        params['id'] is! String ||
        params['enabled'] is! bool) {
      throw const FormatException('Invalid add-on request');
    }
    final on = params['enabled'] as bool;
    final item = addons.items.where((a) => a.id == params['id']).firstOrNull;
    if (item == null ||
        !supportedKinds.contains(item.kind) ||
        on && !const {'verified', 'loaded'}.contains(item.state)) {
      throw const FormatException('Add-on unavailable');
    }
    final before = enabledAddons(), enabled = {...before};
    on ? enabled.add(item.id) : enabled.remove(item.id);
    try {
      addons.reload(enabled);
      if (on &&
          !addons.items.any((a) => a.id == item.id && a.state == 'loaded')) {
        throw const FormatException('An adapter could not be loaded');
      }
      settings.saveOwn({'addons_enabled': enabled.toList()..sort()});
    } catch (_) {
      addons.reload(before);
      reads.catalog.adapters = addons.adapters;
      rethrow;
    }
    reads.catalog.adapters = addons.adapters;
    return addons.snapshot(enabled, addonSignIns, addonUserDir);
  }

  late final addonActions = AddonActions(Posix(), addonUserDir);
  final _catalogPreviews = <String, (DateTime, Map<String, dynamic>)>{};

  bool get addonInstalling => tasks.items.values.any(
    (t) => t.operation == 'addons.install' && t.state == 'running',
  );

  /// guard_addon_changes.
  void guardAddonChanges() {
    if (addonInstalling) {
      throw const FormatException('An installation is already running');
    }
    if (starter.sessions.items.values.any(starter.sessions.running)) {
      throw const FormatException(
        'Finish running agents before changing add-ons',
      );
    }
  }

  void _reloadAddons(Set<String> enabled) {
    addons.reload(enabled);
    reads.catalog.adapters = addons.adapters;
  }

  void _saveAddons(Set<String> enabled) =>
      settings.saveOwn({'addons_enabled': enabled.toList()..sort()});

  /// flutter_addon_catalog.Catalog.register + catalog_focus.
  Map<String, dynamic> _registerCatalog(Map<String, dynamic> result) {
    final records = result['records'];
    if (records is! List ||
        records.length > 200 ||
        result['online'] is! bool ||
        utf8.encode(jsonEncode(result)).length > 768 * 1024) {
      throw const FormatException('Invalid catalog result');
    }
    _catalogPreviews.clear();
    final public = <Map<String, dynamic>>[];
    for (final record in records.cast<Map>()) {
      final entry = Map<String, dynamic>.from(record['entry'] as Map);
      final old = record['installed_version'];
      if (old is! String) {
        throw const FormatException('Invalid installed version');
      }
      final supported = supportedKinds.contains(entry['kind']);
      final action = old.isEmpty
          ? 'install'
          : newerVersion(entry['version'], old)
          ? 'update'
          : '';
      final token = newHandle().substring(coreHandle.length);
      if (supported && action.isNotEmpty) {
        _catalogPreviews[token] = (
          DateTime.now(),
          Map<String, dynamic>.from(record),
        );
      }
      final row = <String, dynamic>{
        for (final key in [
          'id',
          'name',
          'version',
          'kind',
          'summary',
          'description',
          'reads',
          'sends',
          'capabilities',
          'privacy',
        ])
          key: entry[key],
        'supported': supported,
        'installed_version': old,
        'action': action,
        'preview': _catalogPreviews.containsKey(token) ? token : null,
      };
      row['focus'] = taskFocus(reads.map, row);
      public.add(row);
    }
    return {'entries': public, 'online': result['online']};
  }

  /// finish_addon_install.
  Map<String, dynamic> _finishInstall(Map<String, dynamic> result) {
    if (result.length != 3 ||
        !const {'ok', 'id', 'version'}.every(result.containsKey) ||
        result['ok'] != true) {
      throw const FormatException('Invalid add-on installation result');
    }
    final enabled = enabledAddons();
    _reloadAddons(enabled);
    final item = addons.items.where((i) => i.id == result['id']).firstOrNull;
    return {
      ...result,
      'enabled': enabled.contains(result['id']),
      'loaded': item?.state == 'loaded',
    };
  }

  Map<String, dynamic> addonStoreRoute(
    String method,
    Map<String, dynamic> params,
  ) {
    if (method == 'addons.catalog') {
      if (params.isNotEmpty) {
        throw const FormatException('Add-on service unavailable');
      }
      return tasks.start('addons.catalog', {
        'settings_path': identity.settingsPath,
      }, _registerCatalog);
    }
    guardAddonChanges();
    if (method == 'addons.install') {
      if (params.length != 1 || params['preview'] is! String) {
        throw const FormatException('Invalid add-on preview');
      }
      if (settings.value(settings.load(), 'addons_online') != true) {
        throw const FormatException('Online add-on access disabled');
      }
      final kept = _catalogPreviews[params['preview']];
      if (kept == null) throw const FormatException('Unknown add-on preview');
      if (DateTime.now().difference(kept.$1).inSeconds >= 600) {
        throw const FormatException('Add-on preview expired');
      }
      final body = utf8.encode(
        pyJsonDumps({
          'record': kept.$2,
          'settings_path': identity.settingsPath,
        }),
      );
      if (body.length > 64 * 1024) {
        throw const FormatException('Add-on plan too large');
      }
      final task = tasks.startPrivate('addons.install', body, _finishInstall);
      _catalogPreviews.remove(params['preview']);
      return task;
    }
    final field = method.endsWith('_preview')
        ? 'id'
        : method.endsWith('_apply')
        ? 'preview'
        : 'undo';
    if (params.length != 1 || params[field] is! String) {
      throw const FormatException('Invalid add-on removal');
    }
    final value = params[field] as String;
    return switch (method) {
      'addons.remove_preview' => {
        ...addonActions.preview(addons.items, value),
        'focus': taskFocus(reads.map, params),
      },
      'addons.remove_apply' => addonActions.apply(
        value,
        enabledAddons(),
        _reloadAddons,
        _saveAddons,
      ),
      'addons.remove_undo' => addonActions.undo(value, enabledAddons(), (
        enabled,
      ) {
        _reloadAddons(enabled);
        return addons.items;
      }, _saveAddons),
      _ => throw ServiceError('unported_route'),
    };
  }

  late final starter = AgentStart(identity, settings, reads.catalog, desktop);
  late final actions = () {
    final made = AgentActions(
      identity,
      settings,
      reads.catalog,
      desktop,
      starter.sessions,
      i18n.text,
    );
    starter
      ..onRead = made.observe
      ..onStop = made.forget;
    return made;
  }();
  late final halt = AgentHalt(
    reads.catalog,
    ProviderScans(reads.files),
    starter.sessions,
    tasks,
  );
  late final watch = WatchService(
    identity,
    settings,
    tasks.workerCommand,
    ProviderOps(reads.files, ProviderScans(reads.files)),
  );
  late final edits = MapEdits(
    reads,
    config,
    llm,
    mcp,
    skills,
    connections,
    identity.configDir,
  );
  late final skills = SkillPlans(
    reads.files,
    config,
    reads.catalog,
    AgentProfiles(reads.files, identity.configDir),
  );

  /// flutter_connections.preview for the kinds this core builds.
  Map<String, dynamic> preview(Map<String, dynamic> params) {
    final fields = {
      'kind', 'command', 'item', 'remove', //
      if (params['kind'] == 'provider') ...['model', 'use_now'],
    };
    if (params.length != fields.length ||
        !params.keys.every(fields.contains) ||
        !corePreview(params) ||
        params['remove'] is! bool ||
        params['command'] is! String ||
        params['item'] is! String) {
      throw const FormatException('Invalid connection request');
    }
    final command = params['command'] as String;
    final agents = reads.catalog.scan();
    if (!agents.any((a) => a.command == command && a.installed)) {
      throw const FormatException('Agent unavailable');
    }
    final inventory = reads.inventory.collect(agents);
    final Plan plan;
    if (params['kind'] == 'provider') {
      if (!llm.supported(command) ||
          params['use_now'] is! bool ||
          params['model'] is! String) {
        throw const FormatException('Agent provider configuration unavailable');
      }
      final rt = inventory.runtimes
          .where(
            (r) =>
                r.key == params['item'] &&
                r.installed &&
                (visibleProviderFacts['connect_keys'] as Map).containsKey(
                  r.key,
                ),
          )
          .firstOrNull;
      if (rt == null) throw const FormatException('Provider unavailable');
      final remove = params['remove'] as bool,
          model = params['model'] as String;
      if (!remove &&
          (model.isNotEmpty &&
                  (!modelKey.hasMatch(model) ||
                      !chatModels(rt.models).contains(model)) ||
              params['use_now'] == true && model.isEmpty)) {
        throw const FormatException('Choose an available chat model');
      }
      plan = llm.plan(
        command,
        rt,
        remove ? '' : model,
        remove ? false : params['use_now'] as bool,
        remove: remove,
      );
    } else if (params['kind'] == 'mcp') {
      final server = inventory.mcp
          .where((s) => s['name'] == params['item'])
          .firstOrNull;
      if (server == null || !mcp.supported(command)) {
        throw const FormatException('MCP server unavailable');
      }
      plan = mcp.plan(command, server['name'] as String, [
        for (final a in server['agents'] as List) a as String,
      ], remove: params['remove'] as bool);
    } else {
      final folder = inventory.skillSets
          .where((s) => s['path'] == params['item'])
          .firstOrNull;
      if (folder == null || skills.ownDir(command) == null) {
        throw const FormatException('Skill folder unavailable');
      }
      plan = skills.plan(
        command,
        folder['path'] as String,
        remove: params['remove'] as bool,
      );
    }
    return {
      ...connections.keep(plan),
      'kind': params['kind'],
      'command': command,
      'item': params['item'],
      'remove': params['remove'],
      'focus': taskFocus(reads.map, params),
    };
  }

  /// flutter_map_editor._guard_model, asked of the worker: it reads the GPU
  /// and asks the runtime with the reference's time limits, while this
  /// synchronous service waits for its one answer line.
  void guardModel(String key, List<String> commands) {
    const inUse = 'Model is in use; stop its users first';
    final command = tasks.workerCommand;
    final ProcessResult out;
    try {
      out = Process.runSync(command.first, [
        ...command.skip(1),
        '--guard',
        jsonEncode({'key': key, 'agents': commands}),
      ]);
    } on ProcessException {
      throw const FormatException(inUse);
    }
    final lines = const LineSplitter()
        .convert('${out.stdout}')
        .where((l) => l.startsWith('{'));
    final reply = lines.isEmpty ? null : jsonDecode(lines.last);
    if (reply is Map && reply['type'] == 'result') return;
    throw FormatException(
      reply is Map && reply['message'] is String
          ? reply['message'] as String
          : inUse,
    );
  }

  late final AppIdentity identity;
  late final SettingsStore settings;
  late final Desktop desktop;
  late final ServiceI18n i18n;
  Map<String, dynamic> dispatch(String method, Map<String, dynamic> params) {
    if (handleRoutes.containsKey(method)) {
      final value = params[handleRoutes[method]];
      if (value is! String || !value.startsWith(coreHandle)) {
        throw ServiceError('unported_route');
      }
      if (method.startsWith('sessions.')) {
        return starter.session(method, params);
      }
      return dispatchHandle(method, params, connections, tasks);
    }
    if (method == 'addons.list' || method == 'addons.set_enabled') {
      return addonRoute(method, params);
    }
    if (method.startsWith('addons.')) return addonStoreRoute(method, params);
    if (method == 'sessions.start') return starter.start(params);
    if (method == 'agents.action_preview') {
      return {
        ...actions.preview(params),
        'focus': taskFocus(reads.map, params),
      };
    }
    if (method == 'agents.action_apply') {
      if (params.length != 1 || params['preview'] is! String) {
        throw const FormatException('Invalid agent action preview');
      }
      if (addonInstalling) {
        throw const FormatException('Add-on installation in progress');
      }
      return actions.apply(params['preview'] as String);
    }
    if (method == 'agents.halt_preview') return halt.preview(params);
    if (method == 'agents.halt_apply') return halt.apply(params);
    if (method == 'projects.pin' || method == 'projects.forget') {
      return starter.project(method, params);
    }
    if (method == 'providers.run') {
      if (!coreProviderRun(params)) throw ServiceError('unported_route');
      if (params.length != 2 ||
          params['operation'] is! String ||
          params['params'] is! Map) {
        throw const FormatException('Invalid provider operation');
      }
      final inner = Map<String, dynamic>.from(params['params'] as Map);
      ProviderOps.validate(params['operation'] as String, inner);
      return {
        ...tasks.start(params['operation'] as String, inner),
        'focus': taskFocus(reads.map, inner),
      };
    }
    if (method == 'connections.move_preview') return edits.movePreview(params);
    if (method == 'models.switch_preview' ||
        method == 'models.attach_preview') {
      return edits.modelPreview(method, params, guardModel);
    }
    if (method == 'connections.repair_preview') {
      return edits.repairPreview(params, preview);
    }
    if (method == 'connections.author_preview') {
      return edits.authorPreview(params, reads.catalog.scan());
    }
    if (method == 'connections.preview') {
      if (!corePreview(params)) {
        throw ServiceError('unported_route');
      }
      return preview(params);
    }
    if (!portedRoutes.contains(method)) throw ServiceError('unported_route');
    if (method == 'settings.update') {
      final result = settings.update(params);
      if ((params['values'] as Map).containsKey('providers_with_agents')) {
        watch.settingChanged();
      }
      return result;
    }
    if (readOnlyRoutes.contains(method)) return reads.dispatch(method, params);
    if (method == 'i18n.lookup') {
      if (params.keys.any((k) => !['text', 'other', 'n'].contains(k)) ||
          params['text'] is! String ||
          (params.length != 1 &&
              !(params.length == 3 &&
                  params['other'] is String &&
                  params['n'] is int))) {
        throw const FormatException('Invalid translation');
      }
      return {
        'language': i18n.language,
        'text': params.length == 1
            ? i18n.text(params['text'])
            : i18n.plural(params['text'], params['other'], params['n']),
      };
    }
    if (params.isNotEmpty) throw const FormatException('Unexpected parameters');
    switch (method) {
      case 'settings.get':
        return settings.snapshot();
      case 'app.theme':
        return {
          'theme':
              settings.value(settings.load(), 'look') == 'omarchy' &&
                  desktop.name == 'omarchy'
              ? desktop.themeColors()
              : <String, String>{},
        };
      case 'app.identity':
        return {
          'name': identity.name,
          'app_id': identity.appId,
          'short_name': identity.shortName,
          'config_dir': identity.configDir,
          'cache_dir': identity.cacheDir,
        };
      case 'desktop.snapshot':
        return {'name': desktop.name, 'theme_dir': desktop.themeDir};
    }
    throw ServiceError('unported_route');
  }

  String handle(String frame) {
    int? id;
    Map<String, dynamic> response;
    try {
      // Python reports null for oversized or undecodable frames, and a parsed
      // nonnegative id for later validation failures.
      if (utf8.encode(frame).length + 1 > maxRequest) {
        throw ServiceError('request_too_large');
      }
      final raw = jsonDecode(frame);
      if (raw is Map && raw['id'] is int && raw['id'] >= 0) id = raw['id'];
      final request = Request.decode(frame);
      response = {
        'id': request.id,
        'result': dispatch(request.method, request.params),
      };
    } on ServiceError catch (e) {
      response = {
        'id': id,
        'error': {'code': e.code},
      };
    } on FormatException {
      response = {
        'id': id,
        'error': {'code': 'invalid_request'},
      };
    } on TypeError {
      response = {
        'id': id,
        'error': {'code': 'invalid_request'},
      };
    } catch (_) {
      response = {
        'id': id,
        'error': {'code': 'operation_failed'},
      };
    }
    var result = jsonEncode(response);
    if (utf8.encode(result).length > maxResponse) {
      result = jsonEncode({
        'id': id,
        'error': {'code': 'response_too_large'},
      });
    }
    return result;
  }
}
