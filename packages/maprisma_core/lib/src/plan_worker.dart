import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'addon_store.dart';
import 'addons.dart';
import 'agent_halt.dart';
import 'connect_apply.dart';
import 'posix_ffi.dart';
import 'identity.dart';
import 'installers.dart';
import 'model_removals.dart';
import 'existing_ai.dart' as existing_ai;
import 'system_map.dart' show SystemMapReader;
import 'system_actions.dart' show checkTool;
import 'smart_card.dart';
import 'system_help.dart' show analyzeMap;
import 'mcp_updates.dart' as mcp_updates;
import 'agent_details.dart' show refreshUsage;
import 'adapters.dart' show Adapter;
import 'agent_keys.dart' show storeKey;
import 'model_moves.dart' show SystemMoves, ScanFilesLike;
import 'dart:math' show Random;
import 'first_agent.dart';
import 'agent_catalog.dart';
import 'desktop.dart' show detectDesktop, GenericDesktop;
import 'model_guard.dart';
import 'mcp_catalog.dart';
import 'mcp_tools.dart';
import 'mcp_plans.dart' show mcpIdentityHash;
import 'skills_web.dart' as skills_web;
import 'llm_tuning.dart';
import 'health_report.dart' show pcInfo;
import 'agent_updates.dart' show AgentUpdates;
import 'context.dart' show ContextReader;
import 'llama_tune.dart' show LlamaTuner, readTuningRecord, untunedModels;
import 'model_hub.dart' show netFetch;
import 'model_downloads.dart' show DownloadError;
import 'provider_ops.dart';
import 'provider_scans.dart';
import 'costs.dart';
import 'found_scan.dart';
import 'scan_files.dart';
import 'service_i18n.dart';
import 'settings.dart';
import 'py_values.dart';

/// Python flutter_plan_wire: the private plan between backend and worker.
const planMaxBytes = 24 * 1024 * 1024;

(Plan, String) decodePlan(List<int> body) {
  if (body.length > planMaxBytes) {
    throw const FormatException('Private plan too large');
  }
  final data = jsonDecode(utf8.decode(body));
  if (data is! Map || data['version'] is! int) {
    throw const FormatException('Invalid private plan');
  }
  final version = data['version'] as int;
  final fields = {
    'version', 'backup_root', 'agent', 'runtime', 'provider', 'changes', //
    'contexts',
    if (version == 2 || version == 3) ...['links_add', 'links_remove'],
    if (version == 3) 'model_actions',
    // Only this core's own plans (a skill from the web) carry it.
    if (version == 3 && data.containsKey('files_staged')) 'files_staged',
    // Only an app update (mcp_update) moves old folders into the backup.
    if (version == 3 && data.containsKey('retire')) 'retire',
  };
  if (![1, 2, 3].contains(version) ||
      data.keys.toSet().length != fields.length ||
      !data.keys.every(fields.contains)) {
    throw const FormatException('Invalid private plan');
  }
  final root = data['backup_root'];
  if (root is! String || !p.isAbsolute(root)) {
    throw const FormatException('Expected an absolute backup root');
  }
  final changes = <Change>[];
  for (final change in data['changes'] as List) {
    final path = change['path'], old = change['old'], next = change['new'];
    if (path is! String ||
        !p.isAbsolute(path) ||
        old is! String ||
        next is! String) {
      throw const FormatException('Invalid configuration change');
    }
    changes.add(Change(path, old, next));
  }
  final contexts = <Map<String, dynamic>>[];
  for (final entry in data['contexts'] as List) {
    final tokens = entry['tokens'];
    final rt = entry['runtime'];
    if (tokens is! int ||
        tokens <= 0 ||
        entry['model'] is! String ||
        rt is! Map ||
        rt['key'] is! String ||
        !rt.keys.every(_runtimeFields.contains)) {
      throw const FormatException('Invalid model context');
    }
    contexts.add(Map<String, dynamic>.from(entry as Map));
  }
  List<(String, String)> links(String key) {
    final entries = data[key] ?? [];
    if (entries is! List || entries.length > 200) {
      throw const FormatException('Too many skill links');
    }
    return [
      for (final entry in entries)
        () {
          if (entry is! List ||
              entry.length != 2 ||
              entry.any(
                (v) =>
                    v is! String ||
                    v.isEmpty ||
                    v.length > 4096 ||
                    v.contains('\x00'),
              )) {
            throw const FormatException('Invalid skill link');
          }
          final link = entry[0] as String, target = entry[1] as String;
          if (!p.isAbsolute(link) ||
              key == 'links_add' && !p.isAbsolute(target)) {
            throw const FormatException('Expected absolute skill paths');
          }
          return (link, target);
        }(),
    ];
  }

  final actions = data['model_actions'] ?? [];
  if (actions is! List || actions.length > maxModelActions) {
    throw const FormatException('Invalid model actions');
  }
  for (final action in actions) {
    if (action is! Map ||
        action.keys.toSet().length != 4 ||
        !const {
          'operation',
          'key',
          'model',
          'agents',
        }.containsAll(action.keys) ||
        !const {'model.load', 'model.unload'}.contains(action['operation']) ||
        ['key', 'model'].any(
          (k) =>
              action[k] is! String ||
              (action[k] as String).isEmpty ||
              (action[k] as String).length > 4096,
        ) ||
        action['agents'] is! List ||
        (action['agents'] as List).length > 32 ||
        (action['agents'] as List).any(
          (c) => c is! String || c.isEmpty || c.length > 128,
        ) ||
        (action['agents'] as List).toSet().length !=
            (action['agents'] as List).length) {
      throw const FormatException('Invalid model action');
    }
  }
  for (final key in ['agent', 'runtime', 'provider']) {
    if (data[key] is! String) {
      throw const FormatException('Invalid private plan');
    }
  }
  final staged = data['files_staged'] ?? [];
  if (staged is! List || staged.length > skills_web.maxFiles) {
    throw const FormatException('Invalid fetched files');
  }
  final filesStaged = <(String, String, String, bool)>[];
  for (final entry in staged) {
    if (entry is! List ||
        entry.length != 4 ||
        entry[0] is! String ||
        !p.isAbsolute(entry[0] as String) ||
        (entry[0] as String).length > 4096 ||
        entry[1] is! String ||
        !p.isAbsolute(entry[1] as String) ||
        entry[2] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(entry[2] as String) ||
        entry[3] is! bool) {
      throw const FormatException('Invalid fetched file');
    }
    filesStaged.add((
      entry[0] as String,
      entry[1] as String,
      entry[2] as String,
      entry[3] as bool,
    ));
  }
  // An app's old version: only a real folder right in ~/Applications.
  final retire = data['retire'] ?? [];
  final apps = p.join(AppIdentity().home, 'Applications');
  if (retire is! List || retire.length > 20) {
    throw const FormatException('Invalid retired folders');
  }
  for (final path in retire) {
    if (path is! String ||
        !p.isAbsolute(path) ||
        p.normalize(path) != path ||
        p.dirname(path) != apps ||
        p.basename(path).startsWith('.') ||
        FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw const FormatException('Invalid retired folder');
    }
  }
  return (
    Plan(
      pyStr(data['agent']),
      pyStr(data['runtime']),
      pyStr(data['provider']),
      changes: changes,
      linksAdd: links('links_add'),
      linksRemove: links('links_remove'),
      contexts: contexts,
      modelActions: [
        for (final a in actions) Map<String, dynamic>.from(a as Map),
      ],
      filesStaged: filesStaged,
      retire: retire.cast<String>(),
    ),
    root,
  );
}

/// flutter_worker connections.apply: check the model actions and the skill
/// sources, back up and write; then the context sizes and the model actions
/// (each checked again; a failure is counted, the files stay).
Future<Map<String, dynamic>> applyPlan(
  List<int> body,
  Posix posix,
  String home, {
  ProviderOps? ops,
  String? stagingRoot,
}) async {
  final (plan, root) = decodePlan(body);
  ops ??= () {
    final files = ScanFiles(AppIdentity());
    return ProviderOps(files, ProviderScans(files));
  }();
  final actions = await validateActions(ops, plan.modelActions);
  for (final (_, target) in plan.linksAdd) {
    if (!Directory(target).existsSync() ||
        !File(p.join(target, 'SKILL.md')).existsSync()) {
      throw StateError('Skill source changed; review again');
    }
  }
  // Fetched files read back from staging, checked against the review.
  final staging =
      stagingRoot ?? p.join(AppIdentity().cacheDir, 'skill-staging');
  plan.filesAdd.addAll(skills_web.readStaged(plan.filesStaged, staging, posix));
  final contexts = [...plan.contexts];
  plan.contexts.clear();
  final backup = ConfigFiles(posix, home).apply(plan, root);
  for (final folder in {
    for (final (_, file, _, _) in plan.filesStaged) p.dirname(file),
  }) {
    try {
      Directory(folder).deleteSync(recursive: true);
    } on FileSystemException {
      // Swept with the next fetch.
    }
  }
  // Context sizes set through the local LLM's API (Ollama), after the files:
  // the connection stands even when one fails (counted, as the reference does).
  var failures = 0;
  for (final c in contexts) {
    if (!await setOllamaContext(c, posix.uid)) failures++;
  }
  for (final action in actions) {
    try {
      await validateActions(ops, [action]);
      await ops.execute(action['operation'] as String, {
        'key': action['key'],
        'model': action['model'],
      });
    } catch (_) {
      failures++;
    }
  }
  return {'backup': backup, 'context_failures': failures};
}

/// The worker process: one request line, the plan from an inherited private
/// file (--plan-fd N, as the Python backend passes it) or length-prefixed on
/// stdin (--plan-stdin, as the Dart core passes it). One result line.
Future<int> runWorker(List<String> args) async {
  void send(Map<String, dynamic> message) =>
      stdout.writeln(pyJsonDumps(message));
  // The map editor's model guard (maprisma-core worker --guard JSON), asked
  // before stdin is read: its caller waits for it and sends nothing.
  if (args.length == 2 && args[0] == '--guard') {
    try {
      final request = jsonDecode(args[1]);
      if (request is! Map ||
          request.length != 2 ||
          request['key'] is! String ||
          request['agents'] is! List ||
          (request['agents'] as List).any((a) => a is! String)) {
        throw const FormatException('Invalid guard request');
      }
      final files = ScanFiles(AppIdentity());
      final ops = ProviderOps(files, ProviderScans(files));
      await guardModel(
        files,
        ops.providers,
        ops.runtime(request['key'] as String),
        [for (final a in request['agents'] as List) a as String],
      );
      send({
        'type': 'result',
        'result': {'ok': true},
      });
    } on FormatException catch (error) {
      send({
        'type': 'error',
        'code': 'operation_failed',
        'message': error.message,
      });
    } catch (_) {
      send({'type': 'error', 'code': 'operation_failed'});
    }
    return 0;
  }
  try {
    final input = BytesBuilder(copy: false);
    await for (final chunk in stdin) {
      input.add(chunk);
      if (input.length > planMaxBytes + 128 * 1024) {
        throw const FormatException('Request too large');
      }
    }
    final bytes = input.takeBytes();
    final newline = bytes.indexOf(10);
    if (newline < 0 || newline > 64 * 1024) {
      throw const FormatException('Invalid worker request');
    }
    final request = jsonDecode(utf8.decode(bytes.sublist(0, newline)));
    if (request is! Map ||
        request.keys.toSet().length != 2 ||
        !request.containsKey('operation') ||
        !request.containsKey('params') ||
        request['params'] is! Map) {
      throw const FormatException('Invalid worker request');
    }
    // The add-on catalog: no private plan (flutter_addon_catalog.catalog_records).
    if (args.isEmpty && request['operation'] == 'addons.catalog') {
      final store = _addonStore();
      final online = _addonsOnline((request['params'] as Map)['settings_path']);
      send({
        'type': 'result',
        'result': await catalogRecords(store.$1, online, store.$2),
      });
      return 0;
    }
    // The setup page's look (setup.detect) and the first-agent guide
    // (guide.snapshot), with the add-ons of the chosen settings.
    if (args.isEmpty &&
        const {
          'setup.detect',
          'guide.snapshot',
        }.contains(request['operation'])) {
      final params = request['params'] as Map;
      if (params.length != 1 ||
          !params.containsKey('settings_path') ||
          (params['settings_path'] != null &&
              params['settings_path'] is! String)) {
        throw const FormatException('Invalid worker request');
      }
      final chosen = params['settings_path'] as String?;
      final identity = AppIdentity();
      final files = ScanFiles(identity);
      final desktop = detectDesktop(identity, Posix());
      final path = chosen != null && chosen.isNotEmpty
          ? chosen
          : identity.settingsPath;
      final enabled = _enabledIn(path);
      final registry = _registryFor(enabled);
      if (request['operation'] == 'setup.detect') {
        send({
          'type': 'result',
          'result': {
            'installed': setupInstalled(
              registry,
              enabled,
              files,
              (adapters) => AgentCatalog(files, desktop, adapters: adapters),
            ),
          },
        });
        return 0;
      }
      final settings = SettingsStore(identity);
      send({
        'type': 'result',
        'result': guideSnapshot(
          registry,
          files,
          AgentCatalog(files, desktop, adapters: registry.adapters),
          settings.value(settings.load(), 'first_agent') as Map,
          ServiceI18n(identity, settings).text,
          // The starter models' fit: the card with the most video memory.
          vram: loadRoutes(registry.items).any((r) => r.kind == 'local')
              ? (await detectGpu()).vram
              : 0,
        ),
      });
      return 0;
    }
    // The System Map's refresh (flutter_system_map.refresh): files only, no
    // program started, nothing sent, no credential file opened.
    if (args.isEmpty && request['operation'] == 'system.refresh') {
      final params = request['params'] as Map;
      if (params.length != 3 ||
          params['search'] is! bool ||
          params['cache'] is! String ||
          (params['settings_path'] != null &&
              params['settings_path'] is! String)) {
        throw const FormatException('Invalid worker request');
      }
      final identity = AppIdentity();
      final files = ScanFiles(identity);
      final chosen = params['settings_path'] as String?;
      final registry = _reloadAddons(chosen);
      final settings = SettingsStore(identity);
      final i18n = ServiceI18n(identity, settings);
      final reader = SystemMapReader(
        files,
        registry,
        AgentCatalog(
          files,
          detectDesktop(identity, Posix()),
          adapters: registry.adapters,
        ),
        i18n.text,
        i18n.plural,
        settingsPath: chosen,
        checksAgent: '${settings.load()['ai_checks_agent'] ?? ''}',
      );
      send({
        'type': 'result',
        'result': reader.refresh(
          params['cache'] as String,
          search: params['search'] as bool,
          progress: (fraction, text) => send({
            'type': 'progress',
            'fraction': fraction.isFinite ? fraction.clamp(0.0, 1.0) : 0.0,
            'text': text.length > 300 ? text.substring(0, 300) : text,
          }),
        ),
      });
      return 0;
    }
    // A disk scan for existing AI installs (existing_ai.scan): nothing found runs.
    if (args.isEmpty && request['operation'] == 'existing.scan') {
      final params = request['params'] as Map;
      if (params.length != 1 || params['path'] is! String) {
        throw const FormatException('Invalid worker request');
      }
      send({
        'type': 'result',
        'result': existing_ai.scan(
          params['path'] as String,
          (fraction, text) => send({
            'type': 'progress',
            'fraction': fraction.isFinite ? fraction.clamp(0.0, 1.0) : 0.0,
            'text': text.length > 300 ? text.substring(0, 300) : text,
          }),
        ),
      });
      return 0;
    }
    // An installer preview: the release looked up with the add-ons switched
    // on in the chosen settings (flutter_installers.prepare).
    if (args.isEmpty && request['operation'] == 'installers.preview') {
      final params = request['params'] as Map;
      if (params.length != 2 ||
          params['selection'] is! Map ||
          (params['settings_path'] != null &&
              params['settings_path'] is! String)) {
        throw const FormatException('Invalid installer preview');
      }
      final chosen = params['settings_path'] as String?;
      _reloadAddons(chosen);
      send({
        'type': 'result',
        'result': await Installers(
          ScanFiles(AppIdentity()),
          settingsPath: chosen,
        ).prepare(params['selection'] as Map),
      });
      return 0;
    }
    // MCP servers to start with, pinned to their newest versions; a registry
    // search; the registry's list saved for searching (mcp_catalog,
    // mcp_registry). Nothing found here runs.
    if (args.isEmpty &&
        const {
          'mcp.catalog',
          'mcp.search',
          'mcp.registry_refresh',
        }.contains(request['operation'])) {
      final params = request['params'] as Map;
      final identity = AppIdentity();
      final path = identity.environment['PATH'];
      final listPath = '${identity.home}/.cache/maprisma/mcp-registry.json';
      final dynamic result;
      switch (request['operation']) {
        case 'mcp.catalog':
          if (params.isNotEmpty) {
            throw const FormatException('Invalid worker request');
          }
          result = {
            'servers': await Future.wait([
              for (final pick in catalogPicks) resolvePick(pick, path),
            ]),
          };
        case 'mcp.search':
          if (params.length != 2 ||
              params['query'] is! String ||
              params['cursor'] is! String) {
            throw const FormatException('Invalid worker request');
          }
          result = await searchPage(
            params['query'] as String,
            listPath,
            path,
            cursor: params['cursor'] as String,
          );
        default:
          if (params.isNotEmpty) {
            throw const FormatException('Invalid worker request');
          }
          final posix = Posix();
          result = {
            'ok': await refreshList(
              listPath,
              now: DateTime.now().millisecondsSinceEpoch / 1000,
              fetch: (url) async => jsonDecode(
                utf8.decode(
                  await netFetch(
                    url,
                    maxBytes: registryMaxBytes,
                    timeout: listPageTimeout,
                    redirects: 0,
                    headers: const {'Accept': 'application/json'},
                  ),
                ),
              ),
              write: posix.atomicWrite,
            ),
          };
      }
      send({'type': 'result', 'result': result});
      return 0;
    }
    // skills_web: a search on skills.sh, or one skill's files fetched into
    // the private staging folder. Nothing fetched runs.
    if (args.isEmpty &&
        const {
          'skills.web_search',
          'skills.web_fetch',
        }.contains(request['operation'])) {
      final params = request['params'] as Map;
      final Map<String, dynamic> result;
      if (request['operation'] == 'skills.web_search') {
        if (params.length != 1 || params['query'] is! String) {
          throw const FormatException('Invalid worker request');
        }
        result = {
          'skills': (await skills_web.searchSkills(
            params['query'] as String,
          )).take(25).toList(),
        };
      } else {
        if (params.length != 2 ||
            params['repo'] is! String ||
            params['skill_id'] is! String) {
          throw const FormatException('Invalid worker request');
        }
        result = await skills_web.fetchSkill(
          params['repo'] as String,
          params['skill_id'] as String,
          p.join(AppIdentity().cacheDir, 'skill-staging'),
          Posix(),
        );
      }
      send({'type': 'result', 'result': result});
      return 0;
    }
    // llm_tuning.collect: a local LLM's performance facts (its devices are
    // asked of llama-server, bounded; GGUF headers read).
    if (args.isEmpty && request['operation'] == 'models.tuning') {
      final params = request['params'] as Map;
      if (params.length != 1 || params['key'] is! String) {
        throw const FormatException('Invalid worker request');
      }
      final identity = AppIdentity();
      final files = ScanFiles(identity);
      final rt = ProviderScans(
        files,
      ).scan().where((r) => r.key == params['key'] && r.installed).firstOrNull;
      if (rt == null) throw const FormatException('Unknown local provider');
      final posix = Posix();
      final installer = LlamaCppInstaller(InstallHost(identity.home, posix));
      // Task 029: the build the service runs (its program and environment).
      final built = rt.key == 'llamacpp'
          ? await LlamaTuner(
              home: identity.home,
              environment: identity.environment,
            ).build()
          : null;
      final facts =
          await LlmTuning(
            ContextReader(files, ConfigFiles(posix, identity.home)),
            identity.home,
            path: identity.environment['PATH'],
          ).collect(
            rt,
            await detectGpu(),
            llamaVersion: () async => installer.currentVersion(),
            llamaBuild: built == null || built.script
                ? null
                : (built.kind, built.devices),
          );
      // The binary the service runs, and the models with no measurement for
      // it (llm-tuning.json; the app tunes those when the card is idle). A
      // wrapper script read while the service is stopped: not known yet.
      if (rt.key == 'llamacpp') {
        facts['build_path'] = built?.binary ?? '';
        facts['untuned'] = built == null || built.script
            ? <String>[]
            : untunedModels(
                readTuningRecord(p.join(identity.stateDir, 'llm-tuning.json')),
                rt.models,
                built.mark,
              );
      }
      send({'type': 'result', 'result': facts});
      return 0;
    }
    // llama_tune (task 029): llama.cpp models measured on this card with the
    // build the service runs; numbers only, the core makes the preview.
    if (args.isEmpty && request['operation'] == 'models.tune') {
      final params = request['params'] as Map;
      if (params.length != 3 ||
          params['models'] is! List ||
          params['models_dir'] is! String ||
          params['address'] is! String) {
        throw const FormatException('Invalid worker request');
      }
      final identity = AppIdentity();
      final reader = ContextReader(
        ScanFiles(identity),
        ConfigFiles(Posix(), identity.home),
      );
      String ini;
      try {
        ini = File(reader.modelsIni).readAsStringSync();
      } on FileSystemException {
        ini = '';
      }
      Map<String, dynamic> result;
      try {
        result =
            await LlamaTuner(
              home: identity.home,
              environment: identity.environment,
            ).measure(
              [for (final m in params['models'] as List) '$m'],
              ScanFiles(identity).expand(params['models_dir'] as String),
              params['address'] as String,
              ini,
              reader.llamaModelFile,
            );
      } on FormatException catch (refused) {
        // The card is in use, no llama-bench, …: the answer says why (rule 3).
        result = {'refused': refused.message};
      }
      send({'type': 'result', 'result': result});
      return 0;
    }
    // agent_updates.check: mise outdated, an agent's own channel, the app's
    // own installs' latest releases; cached six hours (owner-only).
    if (args.isEmpty && request['operation'] == 'updates.check') {
      final params = request['params'] as Map;
      if (params.length != 1 || params['settings_path'] is! String) {
        throw const FormatException('Invalid worker request');
      }
      final identity = AppIdentity();
      final registry = _reloadAddons(params['settings_path'] as String);
      final files = ScanFiles(identity);
      final catalog = AgentCatalog(
        files,
        detectDesktop(identity, Posix()),
        adapters: registry.adapters,
      );
      final installers = Installers(
        files,
        settingsPath: params['settings_path'] as String,
      );
      final posix = Posix();
      final updates = AgentUpdates(
        adapters: registry.adapters,
        installer: (key) =>
            installers.find('runtime', key) ?? installers.find('agent', key),
        agentInstaller: (c) => installers.find('agent', c) != null,
        home: identity.home,
        cachePath: p.join(identity.cacheDir, 'updates.json'),
        path: identity.environment['PATH'],
        writeCache: posix.atomicWrite,
      );
      send({
        'type': 'result',
        'result': {
          'updates': await updates.check(
            [
              for (final a in catalog.scan())
                {
                  'command': a.command,
                  'name': a.name,
                  'installed': a.installed,
                  'version': a.version,
                  'source': a.source,
                },
            ],
            [for (final r in ProviderScans(files).scan()) r.toJson()],
            now: DateTime.now().millisecondsSinceEpoch / 1000,
            gpu: detectGpu,
          ),
        },
      });
      return 0;
    }
    // mcp_scan and skills_scan: programs with an MCP server and skill sets
    // on this PC, read only (big programs read once, kept in the cache).
    if (args.isEmpty && request['operation'] == 'found.scan') {
      final params = request['params'] as Map;
      bool strings(dynamic v) =>
          v is List && v.length <= 2000 && v.every((x) => x is String);
      final configured = params['configured'];
      final backups = params['backup_root'];
      if (params.length != 6 ||
          backups is! String ||
          !p.isAbsolute(backups) ||
          configured is! Map ||
          configured.length > 2000 ||
          !configured.values.every(strings) ||
          !strings(params['skip']) ||
          !strings(params['known']) ||
          !strings(params['mcp_folders']) ||
          !strings(params['skill_folders'])) {
        throw const FormatException('Invalid worker request');
      }
      // connect.prune_retired: old app versions kept with a backup go.
      pruneRetired(backups);
      final identity = AppIdentity();
      final scan = FoundScan(
        identity.home,
        cacheFile: p.join(identity.cacheDir, 'mcp-scan-3.json'),
        searchPath: identity.environment['PATH'],
        mcpFolders: (params['mcp_folders'] as List).cast<String>(),
        skillFolders: (params['skill_folders'] as List).cast<String>(),
      );
      final mcp = scan.scan({
        for (final e in configured.entries)
          '${e.key}': (e.value as List).cast<String>(),
      }, (params['skip'] as List).cast<String>().toSet());
      send({
        'type': 'result',
        'result': {
          'mcp': [for (final c in mcp) c.toJson()],
          'versions': scan.newVersionsFound(),
          'not_looked': scan.notLookedInto(),
          'skills': [
            for (final s in scan.skillSets(
              (params['known'] as List).cast<String>(),
            ))
              {'path': s.path, 'skills': s.skills, 'origin': s.origin},
          ],
        },
      });
      return 0;
    }
    // gpu_usage.snapshot: the GPU's totals and each local LLM's share,
    // its loaded models asked of it on loopback (read only).
    if (args.isEmpty && request['operation'] == 'gpu.snapshot') {
      final params = request['params'] as Map;
      final list = params['runtimes'];
      if (params.length != 1 ||
          list is! List ||
          list.length > 32 ||
          !list.every(
            (r) =>
                r is Map &&
                r['key'] is String &&
                r['name'] is String &&
                r['address'] is String &&
                r['models_dir'] is String,
          )) {
        throw const FormatException('Invalid worker request');
      }
      final files = ScanFiles(AppIdentity());
      final runtimes = [
        for (final r in list.cast<Map>())
          RuntimeRecord('${r['key']}', '${r['name']}')
            ..installed = true
            ..address = '${r['address']}'
            ..modelsDir = '${r['models_dir']}',
      ];
      send({
        'type': 'result',
        'result': await GpuUsage(
          files,
          ProviderScans(files),
        ).snapshot(runtimes),
      });
      return 0;
    }
    // desktop_omarchy.refresh_usage: Omarchy asked for an agent's usage.
    if (args.isEmpty && request['operation'] == 'agents.usage_refresh') {
      final params = request['params'] as Map;
      final command = params['command'];
      final rpc = params['rpc'], argv = params['argv'];
      final program = params['program'];
      final env = AppIdentity().environment;
      // The installed program the core found (AgentCatalog.realProgram),
      // checked again here: never a launcher that installs or updates it.
      if (command is! String ||
          !(params.length == 1 ||
              params.length == 4 &&
                  rpc is String &&
                  argv is List &&
                  Adapter.configureOk(argv, command) &&
                  program is String &&
                  p.isAbsolute(program) &&
                  p.basename(program) == command &&
                  !AgentCatalog(
                    ScanFiles(AppIdentity(environment: env)),
                    GenericDesktop(env),
                  ).lazyLauncher(program))) {
        throw const FormatException('Invalid worker request');
      }
      send({
        'type': 'result',
        'result': {
          'ok': await refreshUsage(
            command,
            env,
            rpc: rpc as String?,
            argv: argv == null ? null : [for (final a in argv as List) '$a'],
            program: program as String?,
          ),
        },
      });
      return 0;
    }
    // plugin_costs.usd_per_eur: the ECB's daily euro rate, kept a day.
    if (args.isEmpty && request['operation'] == 'costs.rate') {
      final params = request['params'] as Map;
      final path = params['path'];
      if (params.length != 1 ||
          path is! String ||
          p.basename(path) != 'exchange-rate.json' ||
          p.basename(p.dirname(path)) != 'omarchy-plugin-ai') {
        throw const FormatException('Invalid worker request');
      }
      final found = await usdPerEur(
        (url) =>
            netFetch(url, maxBytes: rateMaxBytes, timeout: 10, redirects: 0),
        path,
      );
      send({
        'type': 'result',
        'result': {'usd_per_eur': found?.$1, 'day': found?.$2},
      });
      return 0;
    }
    // The user's "Look inside" (look_inside) and an AppImage unpacked for a
    // server in it (unpack): only AppImages the scan itself lists.
    if (args.isEmpty &&
        const {
          'found.look_inside',
          'found.unpack',
        }.contains(request['operation'])) {
      final params = Map<String, dynamic>.from(request['params'] as Map);
      final folders = params.remove('mcp_folders');
      if (folders is! List ||
          folders.length > 50 ||
          !folders.every((x) => x is String)) {
        throw const FormatException('Invalid worker request');
      }
      final identity = AppIdentity();
      final scan = FoundScan(
        identity.home,
        cacheFile: p.join(identity.cacheDir, 'mcp-scan-3.json'),
        tempDir: p.join(identity.cacheDir, 'tmp'),
        searchPath: identity.environment['PATH'],
        mcpFolders: folders.cast<String>(),
      );
      Map<String, dynamic> result;
      if (request['operation'] == 'found.look_inside') {
        final paths = params['paths'];
        final allowed = scan.notLookedInto().toSet();
        if (params.length != 1 ||
            paths is! List ||
            paths.length > 100 ||
            !paths.every((x) => x is String && allowed.contains(x))) {
          throw const FormatException('Invalid worker request');
        }
        final found = await scan.lookInside(paths.cast<String>());
        result = {'looked': paths.length, 'found': found.length};
      } else {
        final image = params['appimage'];
        if (params.length != 1 ||
            image is! String ||
            !scan.appimages().contains(image)) {
          throw const FormatException('Invalid worker request');
        }
        result = {'folder': await scan.unpack(image)};
      }
      send({'type': 'result', 'result': result});
      return 0;
    }
    // health.pc_info: the card (lspci), the memory, the free space in the
    // model folders. Read only.
    if (args.isEmpty && request['operation'] == 'health.pc') {
      final params = request['params'] as Map;
      final dirs = params['dirs'];
      if (params.length != 1 ||
          dirs is! List ||
          dirs.length > 64 ||
          dirs.any((d) => d is! String || d.length > 4096)) {
        throw const FormatException('Invalid worker request');
      }
      send({
        'type': 'result',
        'result': await pcInfo(dirs.cast<String>(), AppIdentity().home),
      });
      return 0;
    }
    // A provider operation: no private plan, its parameters checked again here.
    if (args.isEmpty && ProviderOps.shapes.containsKey(request['operation'])) {
      final identity = AppIdentity();
      final files = ScanFiles(identity);
      final ops = ProviderOps(files, ProviderScans(files));
      final i18n = ServiceI18n(identity, SettingsStore(identity));
      final operation = request['operation'] as String;
      var last = 0.0;
      void progress(double fraction, String text) {
        // flutter_worker's progress line: the fraction clamped, the text cut.
        last = fraction.isFinite ? fraction.clamp(0.0, 1.0) : 0.0;
        send({
          'type': 'progress',
          'fraction': last,
          'text': text.length > 300 ? text.substring(0, 300) : text,
        });
      }

      Future<dynamic> run() => ops.execute(
        operation,
        request['params'] as Map,
        progress: progress,
        translate: i18n.text,
      );
      final result = await withRetries(
        operation,
        run,
        (left) => progress(
          last,
          i18n
              .text(
                'Connection lost · trying again in {0} s (it goes on where it stopped)',
              )
              .replaceAll('{0}', '$left'),
        ),
      );
      send({'type': 'result', 'result': result});
      return 0;
    }
    final operation = request['operation'];
    if (!const {
          'connections.apply',
          'agents.halt',
          'addons.install',
          'installers.install',
          'models.remove',
          'existing.check',
          'existing.apply',
          'system.tool_check',
          'system.move_preview',
          'system.move_apply',
          'system.move_undo',
          'system.analyze',
          'checks.mcp',
          'agents.key',
          'addons.install_file',
          'mcp.tools',
          'mcp.tools_test',
          'models.tuning_ask',
          'map.smart_ask',
        }.contains(operation) ||
        (request['params'] as Map).isNotEmpty) {
      throw const FormatException('Invalid private operation');
    }
    final posix = Posix();
    List<int> body;
    if (args.length == 2 && args[0] == '--plan-fd') {
      final fd = int.parse(args[1]);
      final info = posix.stat(fd);
      if (info.mode & 0xf000 != 0x8000 ||
          info.uid != posix.uid ||
          info.mode & 0x3f != 0) {
        throw const FormatException('Expected a private plan file');
      }
      body = posix.readAt(fd, 0, planMaxBytes + 1);
    } else if (args.length == 1 && args[0] == '--plan-stdin') {
      final rest = bytes.sublist(newline + 1);
      final space = rest.indexOf(10);
      final length = space < 0
          ? -1
          : int.tryParse(utf8.decode(rest.sublist(0, space))) ?? -1;
      if (length < 0 ||
          length > planMaxBytes ||
          rest.length - space - 1 != length) {
        throw const FormatException('Invalid private plan');
      }
      body = rest.sublist(space + 1);
    } else {
      throw const FormatException('Invalid worker arguments');
    }
    if (operation == 'addons.install') {
      if (body.length > 64 * 1024) {
        throw const FormatException('Add-on plan too large');
      }
      final plan = jsonDecode(utf8.decode(body));
      if (plan is! Map ||
          plan.length != 2 ||
          !plan.containsKey('record') ||
          !plan.containsKey('settings_path')) {
        throw const FormatException('Invalid private add-on plan');
      }
      final store = _addonStore();
      send({
        'type': 'result',
        'result': await store.$1.locked(
          () => installReviewed(
            store.$1,
            plan,
            _addonsOnline(plan['settings_path']),
            store.$2,
          ),
        ),
      });
      return 0;
    }
    if (operation.startsWith('system.move_')) {
      if (body.length > 700 * 1024) {
        throw const FormatException('Move plan too large');
      }
      final record = jsonDecode(utf8.decode(body));
      if (record is! Map || record['settings_path'] is! String) {
        throw const FormatException('Invalid move record');
      }
      final identity = AppIdentity();
      final files = ScanFiles(identity);
      _reloadAddons(record['settings_path'] as String);
      final moves = SystemMoves(
        ScanFilesLike(ProviderScans(files)),
        identity.home,
        record['settings_path'] as String,
        p.join(identity.cacheDir, 'system-map.json'),
      );
      void progress(double fraction, String text) => send({
        'type': 'progress',
        'fraction': fraction.isFinite ? fraction.clamp(0.0, 1.0) : 0.0,
        'text': text.length > 300 ? text.substring(0, 300) : text,
      });
      if (operation == 'system.move_preview') {
        send({'type': 'result', 'result': moves.prepare(record)});
        return 0;
      }
      // The installers' lock: one installation or move at a time.
      final store = _addonStore();
      final result = await store.$1.locked(() async {
        if (operation == 'system.move_undo') {
          return moves.undo('${record['undo']}', progress);
        }
        final random = Random.secure();
        final token = [
          for (var i = 0; i < 16; i++)
            random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ].join();
        return moves.execute(body, token, progress);
      });
      send({'type': 'result', 'result': result});
      return 0;
    }
    if (operation == 'addons.install_file') {
      if (body.length > 8192) {
        throw const FormatException('Invalid add-on request');
      }
      final request = jsonDecode(utf8.decode(body));
      if (request is! Map) {
        throw const FormatException('Invalid add-on request');
      }
      final store = _addonStore();
      send({
        'type': 'result',
        'result': await store.$1.locked(
          () async => installAddonFile(request, store.$1),
        ),
      });
      return 0;
    }
    // mcp_tools.ask (and ask_and_keep for a set-up server): its program
    // started once in a session of its own, or its address asked.
    if (operation == 'mcp.tools' || operation == 'mcp.tools_test') {
      if (body.length > 1024 * 1024) {
        throw const FormatException('Invalid MCP request');
      }
      final request = jsonDecode(utf8.decode(body));
      final keep = operation == 'mcp.tools';
      if (request is! Map ||
          request.length != (keep ? 2 : 1) ||
          request['entry'] is! Map ||
          (keep && request['name'] is! String)) {
        throw const FormatException('Invalid MCP request');
      }
      final identity = AppIdentity();
      final entry = request['entry'] as Map;
      final posix = Posix();
      Map<String, dynamic> result;
      if (keep) {
        result = await askAndKeep(
          request['name'] as String,
          entry,
          identity: mcpIdentityHash(entry),
          home: identity.home,
          environment: identity.environment,
          write: posix.atomicWrite,
        );
      } else {
        try {
          result = {
            'status': 'ok',
            ...await askTools(
              entry,
              home: identity.home,
              environment: identity.environment,
            ),
          };
        } on Object catch (error) {
          final text = askErrorText(error);
          result = {
            'status': 'failed',
            'error': text.length > 300 ? text.substring(0, 300) : text,
          };
        }
      }
      send({'type': 'result', 'result': result});
      return 0;
    }
    if (operation == 'agents.key') {
      if (body.length > 4096) {
        throw const FormatException('Invalid API-key request');
      }
      final request = jsonDecode(utf8.decode(body));
      if (request is! Map ||
          request['command'] is! String ||
          request['key'] is! String) {
        throw const FormatException('Invalid API-key request');
      }
      final identity = AppIdentity();
      final registry = _reloadAddons(identity.settingsPath);
      final catalog = AgentCatalog(
        ScanFiles(identity),
        detectDesktop(identity, Posix()),
        adapters: registry.adapters,
      );
      send({
        'type': 'result',
        'result': await storeKey(
          request,
          catalog.adapter(request['command'] as String),
          identity.home,
          identity.environment,
        ),
      });
      return 0;
    }
    if (operation == 'models.tuning_ask') {
      if (body.length > 256 * 1024) {
        throw const FormatException('Performance facts too large');
      }
      final data = jsonDecode(utf8.decode(body));
      final helper = data is Map ? data['helper'] : null;
      if (data is! Map ||
          data['command'] is! String ||
          data['facts'] is! Map ||
          data['settings_path'] is! String ||
          helper != null &&
              (helper is! Map ||
                  ['provider', 'runtime', 'model'].any(
                    (k) =>
                        helper[k] is! String ||
                        (helper[k] as String).isEmpty ||
                        (helper[k] as String).length > 200 ||
                        (helper[k] as String).codeUnits.any((c) => c < 32),
                  ))) {
        throw const FormatException('Invalid tuning request');
      }
      final identity = AppIdentity();
      final registry = _reloadAddons(data['settings_path'] as String);
      final adapter = registry.adapters
          .where((a) => a.command == data['command'])
          .firstOrNull;
      if (adapter == null) {
        throw const FormatException('AI checker unavailable');
      }
      send({
        'type': 'result',
        'result': await askTuning(
          data,
          adapter,
          identity.environment,
          identity.home,
          identity.shortName,
        ),
      });
      return 0;
    }
    if (operation == 'map.smart_ask') {
      if (body.length > 256 * 1024) {
        throw const FormatException('Request too large');
      }
      final data = jsonDecode(utf8.decode(body));
      final helper = data is Map ? data['helper'] : null;
      if (data is! Map ||
          data['command'] is! String ||
          data['settings_path'] is! String ||
          helper != null &&
              (helper is! Map ||
                  ['provider', 'runtime', 'model'].any(
                    (k) =>
                        helper[k] is! String ||
                        (helper[k] as String).isEmpty ||
                        (helper[k] as String).length > 200 ||
                        (helper[k] as String).codeUnits.any((c) => c < 32),
                  ))) {
        throw const FormatException('Invalid request');
      }
      final identity = AppIdentity();
      final registry = _reloadAddons(data['settings_path'] as String);
      send({
        'type': 'result',
        'result': await smartAsk(
          data,
          registry.adapters
              .where((a) => a.command == data['command'])
              .firstOrNull,
          identity.environment,
          identity.home,
          identity.shortName,
          mcpSearch: (query) async {
            final found = await searchPage(
              query,
              '${identity.home}/.cache/maprisma/mcp-registry.json',
              identity.environment['PATH'],
            );
            return (found['servers'] as List).cast<Map<String, dynamic>>();
          },
        ),
      });
      return 0;
    }
    if (operation == 'system.analyze') {
      if (body.length > 128 * 1024) {
        throw const FormatException('System analysis request too large');
      }
      final data = jsonDecode(utf8.decode(body));
      if (data is! Map ||
          data['command'] is! String ||
          data['settings_path'] is! String) {
        throw const FormatException('Invalid system analysis');
      }
      final identity = AppIdentity();
      final files = ScanFiles(identity);
      final registry = _reloadAddons(data['settings_path'] as String);
      final settings = SettingsStore(identity);
      final i18n = ServiceI18n(identity, settings);
      final catalog = AgentCatalog(
        files,
        detectDesktop(identity, Posix()),
        adapters: registry.adapters,
      );
      final installed = {
        for (final a in catalog.scan())
          if (a.installed) a.command,
      };
      final helpers = SystemMapReader(
        files,
        registry,
        catalog,
        i18n.text,
        i18n.plural,
        checksAgent: '${settings.load()['ai_checks_agent'] ?? ''}',
      ).helpers(installed);
      final command = data['command'] as String;
      final adapter = registry.adapters
          .where((a) => a.command == command)
          .firstOrNull;
      if (adapter == null ||
          !helpers.any((h) => h['command'] == command && h['check'] == true)) {
        throw const FormatException('AI checker unavailable');
      }
      send({
        'type': 'result',
        'result': await analyzeMap(
          data,
          adapter,
          identity.environment,
          identity.home,
          identity.shortName,
        ),
      });
      return 0;
    }
    if (operation == 'checks.mcp') {
      if (body.length > 64 * 1024) {
        throw const FormatException('MCP update check too large');
      }
      final data = jsonDecode(utf8.decode(body));
      final servers = data is Map ? data['servers'] : null;
      if (data is! Map ||
          data['command'] is! String ||
          data['cache'] is! String ||
          data['now'] is! num ||
          data['settings_path'] is! String ||
          servers is! List ||
          servers.isEmpty ||
          servers.length > mcp_updates.maxServers ||
          !servers.every(
            (s) =>
                s is Map &&
                const {'app', 'npm', 'pypi'}.contains(s['source']) &&
                ['name', 'app', 'version', 'program'].every(
                  (k) => s[k] is String && (s[k] as String).length <= 300,
                ),
          )) {
        throw const FormatException('Invalid MCP update check');
      }
      final identity = AppIdentity();
      if (data['cache'] != p.join(identity.cacheDir, 'mcp-updates.json')) {
        throw const FormatException('Invalid MCP update cache');
      }
      final files = ScanFiles(identity);
      final registry = _reloadAddons(data['settings_path'] as String);
      final settings = SettingsStore(identity);
      final i18n = ServiceI18n(identity, settings);
      final catalog = AgentCatalog(
        files,
        detectDesktop(identity, Posix()),
        adapters: registry.adapters,
      );
      final installed = {
        for (final a in catalog.scan())
          if (a.installed) a.command,
      };
      final helpers = SystemMapReader(
        files,
        registry,
        catalog,
        i18n.text,
        i18n.plural,
        checksAgent: '${settings.load()['ai_checks_agent'] ?? ''}',
      ).helpers(installed);
      final command = data['command'] as String;
      final adapter = registry.adapters
          .where((a) => a.command == command)
          .firstOrNull;
      if (adapter == null ||
          !helpers.any((h) => h['command'] == command && h['check'] == true)) {
        throw const FormatException('AI checker unavailable');
      }
      final found = await mcp_updates.checkNow(
        adapter,
        command,
        [for (final s in servers) mcp_updates.serverOf(s as Map)],
        data['cache'] as String,
        (data['now'] as num).toDouble(),
        identity.environment,
        identity.home,
        identity.shortName,
      );
      send({
        'type': 'result',
        'result': {
          'updates': [for (final f in found) mcp_updates.foundJson(f)],
        },
      });
      return 0;
    }
    if (operation == 'system.tool_check') {
      final identity = AppIdentity();
      final files = ScanFiles(identity);
      send({
        'type': 'result',
        'result': await checkTool(
          body,
          identity.environment,
          AgentCatalog(files, detectDesktop(identity, Posix())),
        ),
      });
      return 0;
    }
    if (operation == 'existing.check') {
      final record = jsonDecode(utf8.decode(body));
      if (record is! Map) throw const FormatException('Invalid program check');
      send({
        'type': 'result',
        'result': await existing_ai.checkProgram(record),
      });
      return 0;
    }
    if (operation == 'existing.apply') {
      // The installers' lock also keeps a detached install from these writes.
      final store = _addonStore();
      final home = Platform.environment['HOME'] ?? '';
      send({
        'type': 'result',
        'result': await store.$1.locked(
          () async => {
            'backup': existing_ai.executeReconnect(
              body,
              home,
              ConfigFiles(posix, home),
            ),
          },
        ),
      });
      return 0;
    }
    if (operation == 'models.remove') {
      if (body.length > maxRemovalBytes) {
        throw const FormatException('Removal preview too large');
      }
      final record = jsonDecode(utf8.decode(body));
      if (record is! Map) {
        throw const FormatException('Invalid private removal');
      }
      send({
        'type': 'result',
        'result': await ModelRemovals(ScanFiles(AppIdentity())).execute(record),
      });
      return 0;
    }
    if (operation == 'installers.install') {
      if (body.length > maxPlan) {
        throw const FormatException('Installer plan too large');
      }
      final plan = jsonDecode(utf8.decode(body));
      final record = plan is Map ? plan['record'] : null;
      if (record is! Map ||
          (record['settings_path'] != null &&
              record['settings_path'] is! String)) {
        throw const FormatException('Invalid private installer plan');
      }
      // The add-on installers' lock: one installation at a time, also across
      // a worker left running by an earlier window.
      final store = _addonStore();
      final chosen = record['settings_path'] as String?;
      send({
        'type': 'result',
        'result': await store.$1.locked(() {
          _reloadAddons(chosen);
          return Installers(
            ScanFiles(AppIdentity()),
            settingsPath: chosen,
          ).execute(
            body,
            (fraction, text) => send({
              'type': 'progress',
              'fraction': fraction.isFinite ? fraction.clamp(0.0, 1.0) : 0.0,
              'text': text.length > 300 ? text.substring(0, 300) : text,
            }),
          );
        }),
      });
      return 0;
    }
    if (operation == 'agents.halt') {
      if (body.length > 4096) throw const FormatException('Invalid halt plan');
      final files = ScanFiles(AppIdentity());
      send({
        'type': 'result',
        'result': await haltInstance(body, ProviderScans(files)),
      });
      return 0;
    }
    send({
      'type': 'result',
      'result': await applyPlan(
        body,
        posix,
        Platform.environment['HOME'] ?? '',
      ),
    });
    return 0;
  } catch (_) {
    send({'type': 'error', 'code': 'operation_failed'});
    return 0;
  }
}

/// inventory.Runtime's fields (Runtime(**record) refuses any other).
/// jobs.RETRY_DELAYS: seconds before each new try of a broken-off download.
const retryDelays = [5, 15, 30, 60, 120];

/// jobs.Jobs._run: a download or pull whose connection broke off is tried
/// again after a pause (counted down through [waiting]) and goes on where it
/// stopped (.part, Ollama's own pulls); a refusal or any other error is not.
Future<T> withRetries<T>(
  String operation,
  Future<T> Function() run,
  void Function(int secondsLeft) waiting, {
  Future<void> Function(Duration)? sleep,
}) async {
  for (var attempt = 0; ; attempt++) {
    try {
      return await run();
    } on Object catch (error) {
      final retryable =
          const {'models.download', 'models.pull'}.contains(operation) &&
          (error is DownloadError ||
              error is SocketException ||
              error is TimeoutException ||
              error is HttpException);
      if (!retryable || attempt >= retryDelays.length) rethrow;
      for (var left = retryDelays[attempt]; left > 0; left--) {
        waiting(left);
        await (sleep ?? Future<void>.delayed)(const Duration(seconds: 1));
      }
    }
  }
}

final _runtimeFields = RuntimeRecord('', '').toJson().keys.toSet();

/// context_ctl.ollama_set_context: num_ctx given to the model through
/// /api/create, only on this account's own Ollama.
Future<bool> setOllamaContext(Map<String, dynamic> c, int uid) async {
  final rt = c['runtime'];
  if (rt is! Map || rt['key'] != 'ollama') return false;
  final address = '${rt['address'] ?? ''}';
  final port =
      int.tryParse(address.substring(address.lastIndexOf(':') + 1)) ?? 0;
  if (port == 0 || !ownPort(port, uid)) return false;
  final answer = await httpJson(
    port,
    '/api/create',
    uid,
    method: 'POST',
    body: {
      'model': c['model'],
      'from': c['model'],
      'parameters': {'num_ctx': c['tokens']},
      'stream': false,
    },
    timeout: const Duration(seconds: 120),
  );
  return answer is Map && answer['error'] == null;
}

/// The add-on store and folders, as the core sees them.
(AddonStore, List<String>) _addonStore() {
  final identity = AppIdentity();
  final posix = Posix();
  final user = p.join(identity.dataDir, 'addons');
  return (
    AddonStore(posix, user, identity.home, AddonVerifier(posix)),
    [user, p.join(appFolder(), 'addons')],
  );
}

/// AdapterRegistry.reload with the add-ons switched on in the chosen
/// settings: the providers they hide and add (provider_facts).
AddonRegistry _reloadAddons(String? settingsPath) {
  final path = settingsPath != null && settingsPath.isNotEmpty
      ? settingsPath
      : p.join(AppIdentity().configDir, 'settings.json');
  return _registryFor(_enabledIn(path));
}

AddonRegistry _registryFor(Set<String> enabled) =>
    AddonRegistry(AddonVerifier(Posix()), _addonStore().$2)..reload(enabled);

/// settings_schema.value(..., 'addons_enabled') of the chosen settings.
Set<String> _enabledIn(String path) {
  var enabled = <String>{};
  try {
    final data = jsonDecode(File(path).readAsStringSync());
    final value = data is Map ? data['addons_enabled'] : null;
    if (value is List) enabled = {...value.whereType<String>()};
  } catch (_) {
    /* the default: none */
  }
  return enabled;
}

/// settings_schema.value(..., 'addons_online') is True: on unless set off.
bool _addonsOnline(dynamic settingsPath) {
  final path = settingsPath is String && settingsPath.isNotEmpty
      ? settingsPath
      : p.join(AppIdentity().configDir, 'settings.json');
  try {
    final data = jsonDecode(File(path).readAsStringSync());
    final value = data is Map ? data['addons_online'] : null;
    return value is bool ? value : true;
  } catch (_) {
    return true;
  }
}
