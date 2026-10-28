import 'dart:convert';
import 'dart:io';
import 'desktop.dart';
import 'identity.dart';
import 'posix_ffi.dart';
import 'protocol.dart';
import 'read_service.dart';
import 'connect_apply.dart';
import 'core_tasks.dart';
import 'skill_plans.dart';
import 'mcp_plans.dart';
import 'llm_plans.dart';
import 'context.dart';
import 'map_edits.dart';
import 'provider_ops.dart';
import 'inventory.dart' show chatModels;
import 'adapter_assets.g.dart';
import 'settings.dart';
import 'service_i18n.dart';

const portedRoutes = {
  'settings.get',
  'settings.update',
  'app.theme',
  'app.identity',
  'desktop.snapshot',
  'i18n.lookup',
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
    // Inventory scans remember the MCP servers in use, as the reference does.
    reads.inventory.knownServers = mcp.knownServers;
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
                (providerFacts['connect_keys'] as Map).containsKey(r.key),
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
      return dispatchHandle(method, params, connections, tasks);
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
    if (method == 'settings.update') return settings.update(params);
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
