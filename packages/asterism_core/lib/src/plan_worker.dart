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
import 'system_help.dart' show analyzeMap;
import 'agent_keys.dart' show storeKey;
import 'model_moves.dart' show SystemMoves, ScanFilesLike;
import 'dart:math' show Random;
import 'first_agent.dart';
import 'agent_catalog.dart';
import 'desktop.dart' show detectDesktop;
import 'model_guard.dart';
import 'provider_ops.dart';
import 'provider_scans.dart';
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
  if (actions is! List || actions.length > 2) {
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
  final contexts = [...plan.contexts];
  plan.contexts.clear();
  final backup = ConfigFiles(posix, home).apply(plan, root);
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
  // The map editor's model guard (asterism-core worker --guard JSON), asked
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
    // A provider operation: no private plan, its parameters checked again here.
    if (args.isEmpty && ProviderOps.shapes.containsKey(request['operation'])) {
      final identity = AppIdentity();
      final files = ScanFiles(identity);
      final ops = ProviderOps(files, ProviderScans(files));
      final i18n = ServiceI18n(identity, SettingsStore(identity));
      send({
        'type': 'result',
        'result': await ops.execute(
          request['operation'] as String,
          request['params'] as Map,
          // flutter_worker's progress line: the fraction clamped, the text cut.
          progress: (fraction, text) => send({
            'type': 'progress',
            'fraction': fraction.isFinite ? fraction.clamp(0.0, 1.0) : 0.0,
            'text': text.length > 300 ? text.substring(0, 300) : text,
          }),
          translate: i18n.text,
        ),
      });
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
          'agents.key',
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
  final user = p.join(
    identity.root('XDG_DATA_HOME', '.local/share'),
    'asterism/addons',
  );
  return (
    AddonStore(posix, user, identity.home, AddonVerifier(posix)),
    [user, p.join(p.dirname(Platform.resolvedExecutable), 'addons')],
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
