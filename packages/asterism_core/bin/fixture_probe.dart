// Development-only component differentials. Never imported by the application.
import 'dart:convert';
import 'dart:io';
import 'package:asterism_core/asterism_core.dart';
import 'package:asterism_core/src/security_plans.dart' show securityPlan;
import 'package:asterism_core/src/mcp_catalog.dart' as mcpc;
import 'package:asterism_core/src/mcp_tools.dart' as mcpt;
import 'package:asterism_core/src/skills_web.dart' as skw;
import 'package:asterism_core/src/llm_tuning.dart' as tun;
import 'package:asterism_core/src/setup_checks.dart' as chk;
import 'package:asterism_core/src/health_report.dart' as hr;
import 'package:asterism_core/src/agent_updates.dart' as upd;
import 'package:asterism_core/src/model_slots.dart' as slots;
import 'package:asterism_core/src/found_scan.dart' as fs;
import 'package:asterism_core/src/installers.dart' as inst;
import 'package:asterism_core/src/provider_scans.dart' show RuntimeRecord;
import 'package:asterism_core/src/system_map.dart' show SystemMapReader;
import 'package:asterism_core/src/agent_catalog.dart' show AgentCatalog;
import 'package:asterism_core/src/scan_files.dart' show ScanFiles;
import 'package:asterism_core/src/tar_check.dart';
import 'package:asterism_core/src/installers.dart' show koboldSync;
import 'package:asterism_core/src/adapters.dart';
import 'package:asterism_core/src/connect_apply.dart';
import 'package:asterism_core/src/addon_store.dart';
import 'package:asterism_core/src/addons.dart';
import 'package:asterism_core/src/line_diff.dart';
import 'package:asterism_core/src/model_hub.dart';
import 'package:asterism_core/src/provider_watch.dart';
import 'package:asterism_core/src/pty_sessions.dart';
import 'package:asterism_core/src/context.dart';
import 'package:asterism_core/src/py_values.dart';
import 'package:asterism_core/src/py_yaml.dart';
import 'package:asterism_core/src/read_service.dart';
import 'package:asterism_core/src/security_reports.dart';
import 'package:asterism_core/src/session_readers.dart';
import 'package:asterism_core/src/usage_readers.dart';

Future<void> main() async {
  final identity = AppIdentity(),
      settings = SettingsStore(identity),
      i18n = ServiceI18n(identity, settings);
  // Write routes go to a full core; scans use its read service (one map).
  final core = CoreService();
  final reads = core.reads;
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    int? id;
    Map<String, dynamic> response;
    try {
      final request = Request.decode(line);
      id = request.id;
      final params = request.params;
      Map<String, dynamic> result;
      if (request.method == 'adapter.validate') {
        if (params.keys.toSet().difference({'file', 'facts'}).isNotEmpty ||
            params.length != 1) {
          throw const FormatException('Invalid adapter fixture');
        }
        Adapter adapter;
        if (params['file'] is String) {
          final path = params['file'] as String;
          if (path.startsWith('/') || path.split('/').contains('..')) {
            throw const FormatException('Fixture path escapes HOME');
          }
          adapter = Adapter.load('${Platform.environment['HOME']}/$path');
        } else {
          adapter = Adapter(Map<String, dynamic>.from(params['facts'] as Map));
        }
        result = {'command': adapter.command, 'name': adapter.name};
      } else if (request.method == 'dev.linechanges') {
        final (added, removed) = lineChanges(
          params['old'] as String,
          params['new'] as String,
        );
        result = {'added': added, 'removed': removed};
      } else if (request.method == 'dev.jsondumps') {
        final value = jsonDecode(params['text'] as String);
        result = {
          'flat': pyJsonDumps(value),
          'indented': pyJsonDumps(value, indent: 2, ensureAscii: false),
        };
      } else if (request.method == 'dev.mcpplan') {
        // The planned texts themselves (development probe only).
        final plan = core.mcp.plan(
          params['agent'] as String,
          params['name'] as String,
          [for (final a in params['sources'] as List) a as String],
          remove: params['remove'] as bool,
        );
        result = {
          'changes': [
            for (final c in plan.changes) {'path': c.path, 'new': c.next},
          ],
        };
      } else if (request.method == 'dev.yamldump') {
        result = {'text': pyYamlDump(jsonDecode(params['json'] as String))};
      } else if (request.method == 'dev.yamlload') {
        try {
          result = {'json': pyJsonDumps(pyYamlLoad(params['text'] as String))};
        } on UnsupportedError {
          result = {'unsupported': true};
        }
      } else if (request.method == 'dev.llmplan') {
        final rt = core.reads.inventory
            .collect(core.reads.catalog.scan(), remember: false)
            .runtimes
            .firstWhere((r) => r.key == params['runtime']);
        final plan = core.llm.plan(
          params['agent'] as String,
          rt,
          params['model'] as String? ?? '',
          params['use_now'] as bool? ?? false,
          remove: params['remove'] as bool,
        );
        result = {
          'changes': [
            for (final c in plan.changes) {'path': c.path, 'new': c.next},
          ],
          'contexts': [
            for (final c in plan.contexts) [c['model'], c['tokens']],
          ],
        };
      } else if (request.method == 'dev.hfparse') {
        // models_ctl.search/files on given API answers (the URL asked is returned).
        final urls = <String>[];
        final hub = ModelHub(
          jsonList: (url) async {
            urls.add(url);
            return params['items'] as List;
          },
        );
        try {
          result = {
            'found': params['kind'] == 'search'
                ? await hub.search(
                    params['query'] as String,
                    limit: params['limit'] as int,
                  )
                : await hub.files(params['repo'] as String),
            'urls': urls,
          };
        } on FormatException catch (e) {
          result = {'error': 'FormatException', 'message': e.message};
        }
      } else if (request.method == 'dev.watch') {
        // A scripted provider_watch.Watcher run: what it runs, unloads and saves.
        final dir = Directory.systemTemp.createTempSync('asterism-watch-');
        final config = '${dir.path}/c.json', state = '${dir.path}/state.json';
        File(config).writeAsStringSync(jsonEncode(params['config']));
        var now = 0.0, running = <String>{}, busy = <int>{};
        final calls = <dynamic>[], states = <dynamic>[];
        Watcher make() => Watcher(
          config,
          run: (argv) async {
            calls.add(['run', ...argv]);
            return params['fail'] != true;
          },
          clock: () => now,
          agentsNow: (names) => (running.intersection(names), <int>{}),
          busy: (port, _) => busy.contains(port),
          lmsUp: () {
            calls.add(['lms_up']);
            return params['lms_up'] == true;
          },
          stopLms: (argv0) async => calls.add(['stop_lms', argv0]),
          sockets: (_) => <String>{},
          unload: (entry, port) async {
            calls.add(['unload', port, entry['unload']]);
            return true;
          },
          lmsBinary: () => params['lms'] as String?,
          state: state,
        );
        var watcher = make();
        for (final step in params['steps'] as List) {
          now += (step['advance'] as num?)?.toDouble() ?? 0;
          if (step['running'] != null) {
            running = {for (final a in step['running'] as List) a as String};
          }
          if (step['busy'] != null) {
            busy = {for (final b in step['busy'] as List) b as int};
          }
          if (step['config'] != null) {
            File(config).writeAsStringSync(jsonEncode(step['config']));
            // a new mtime even within the same second
            File(config).setLastModifiedSync(
              DateTime.now().add(Duration(seconds: states.length + 1)),
            );
          }
          switch (step['op']) {
            case 'new':
              watcher = make();
            case 'shutdown':
              await watcher.shutdown();
            default:
              await watcher.tick();
          }
          states.add([
            File(state).existsSync() ? File(state).readAsStringSync() : null,
            watcher.needed.toList()..sort(),
          ]);
        }
        dir.deleteSync(recursive: true);
        result = {'calls': calls, 'states': states};
      } else if (request.method == 'dev.pty') {
        // A scripted terminal session: start, read until a word, write, resize.
        final sessions = PtySessions();
        final ident = sessions.start(
          'probe',
          [for (final a in params['argv'] as List) a as String],
          params['cwd'] as String,
          {
            for (final e in (params['env'] as Map).entries)
              e.key as String: e.value as String,
          },
        );
        final out = StringBuffer();
        Map<String, dynamic> last = {};
        for (final step in params['steps'] as List) {
          if (step['write'] != null) {
            sessions.write(ident, utf8.encode(step['write'] as String));
          } else if (step['resize'] != null) {
            final size = step['resize'] as List;
            sessions.resize(ident, size[0], size[1]);
          } else {
            final until = DateTime.now().add(const Duration(seconds: 10));
            while (DateTime.now().isBefore(until)) {
              last = sessions.read(ident);
              out.write(last['text']);
              if (step['until'] == 'ended'
                  ? last['ended'] == true
                  : out.toString().contains(step['until'] as String)) {
                break;
              }
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }
        }
        sessions.stop(ident);
        result = {
          'text': out.toString(),
          'exit_code': last['exit_code'],
          'ended': last['ended'],
        };
      } else if (request.method == 'dev.addonstore') {
        // addon_store.parse_catalog / install_bytes on given bytes.
        if (params['op'] == 'parse') {
          result = {
            'entries': parseCatalog(
              File(params['text'] as String).readAsBytesSync(),
              File(params['sig'] as String).readAsBytesSync(),
            ),
          };
        } else {
          final posix = Posix();
          final user = params['user_dir'] as String;
          final store = AddonStore(
            posix,
            user,
            '/nonexistent',
            AddonVerifier(posix),
          );
          try {
            final item = store.installBytes(
              base64.decode(params['zip'] as String),
              expect: params['expect'] as String?,
            );
            result = {
              'id': item.id,
              'version': item.version,
              'state': item.state,
            };
          } catch (error) {
            result = {'error': '$error'};
          }
        }
      } else if (request.method == 'dev.watchconfig') {
        final agents = core.reads.catalog.scan();
        final inv = core.reads.inventory.collect(agents, remember: false);
        result = {
          'text': watchConfigText(inv.runtimes, {
            for (final a in agents)
              if (a.adapter.facts['self_served'] == true) a.command,
          }),
        };
      } else if (request.method == 'dev.systemrefresh') {
        // The System Map's refresh against a given cache file (read only).
        final files = ScanFiles(identity);
        final saved = settings.load();
        final reader = SystemMapReader(
          files,
          core.addons,
          AgentCatalog(files, core.desktop, adapters: core.addons.adapters),
          i18n.text,
          i18n.plural,
          checksAgent: '${saved['ai_checks_agent'] ?? ''}',
        );
        result = reader.refresh(
          params['cache'] as String,
          search: params['search'] == true,
        );
      } else if (request.method == 'dev.foundlook') {
        // mcp_scan.look_inside, scan, unpack and scan again.
        final scan = fs.FoundScan(
          identity.home,
          cacheFile: params['cache'] as String,
          tempDir: params['temp'] as String,
          searchPath: identity.environment['PATH'],
          opt: params['opt'] as String,
        );
        final image = params['image'] as String;
        final looked = await scan.lookInside([image]);
        final before = [for (final c in scan.scan({}, {})) c.toJson()];
        final folder = await scan.unpack(image);
        final after = [for (final c in scan.scan({}, {})) c.toJson()];
        result = {
          'looked': looked,
          'before': before,
          'folder': folder,
          'after': after,
          'not_looked': scan.notLookedInto(),
          'temp_left': Directory(params['temp'] as String).existsSync()
              ? Directory(params['temp'] as String).listSync().length
              : 0,
        };
      } else if (request.method == 'dev.foundscan') {
        // mcp_scan.scan (with fold_versions), new_versions_found,
        // not_looked_into and skills_scan.scan.
        final scan = fs.FoundScan(
          identity.home,
          cacheFile: params['cache'] as String,
          searchPath: identity.environment['PATH'],
          opt: params['opt'] as String,
          mcpFolders: (params['mcp_folders'] as List).cast<String>(),
          skillFolders: (params['skill_folders'] as List).cast<String>(),
          skillRoots: [
            for (final r in params['skill_roots'] as List)
              ('${r[0]}', r[1] as int),
          ],
        );
        final configured = {
          for (final e in (params['configured'] as Map).entries)
            '${e.key}': (e.value as List).cast<String>(),
        };
        result = {
          'mcp': [
            for (final c in scan.scan(
              configured,
              (params['skip'] as List).cast<String>().toSet(),
            ))
              c.toJson(),
          ],
          'versions': scan.newVersionsFound(),
          'not_looked': scan.notLookedInto(),
          'skills': [
            for (final s in scan.skillSets(
              (params['known'] as List).cast<String>(),
            ))
              {'path': s.path, 'skills': s.skills, 'origin': s.origin},
          ],
        };
      } else if (request.method == 'dev.modelslots') {
        // model_slots.models_in_use, plan, hints and the engines' slot changes.
        final engines = slots.EngineSlots(
          home: identity.home,
          processes: () => const [],
          parentOf: (_) => 0,
        );
        final tuning = tun.LlmTuning(
          ContextReader(ScanFiles(identity), core.config),
          identity.home,
        );
        final inUse = slots.modelsInUse(params['graph'] as Map?);
        final needs = slots.slotPlan(
          (params['runtimes'] as List).cast<Map>(),
          inUse,
          engines,
          (rt, m) => tuning.modelSize('${rt['key']}', '${rt['models_dir']}', m),
        );
        result = {
          'in_use': inUse,
          'needs': [
            for (final n in needs)
              {
                ...n,
                'change': slots.needChange(n),
                'swaps': slots.needSwaps(n),
                'hints': slots.slotHints(n, params['vram'] as int, i18n.text),
                'changes': [
                  for (final c in engines.slotChanges(
                    (params['runtimes'] as List).cast<Map>().firstWhere(
                      (r) => r['key'] == n['key'],
                    ),
                    slots.needCount(n),
                  ))
                    [c.path, c.next],
                ],
              },
          ],
        };
      } else if (request.method == 'dev.agentupdates') {
        // agent_updates.check with the web and mise given.
        final installers = inst.Installers(ScanFiles(identity));
        final mise = (params['mise'] as Map).map(
          (k, v) => MapEntry('$k', ('${(v as List)[0]}', '${v[1]}')),
        );
        final latest = (params['latest'] as Map).cast<String, String?>();
        final updates = upd.AgentUpdates(
          adapters: core.addons.adapters,
          installer: (key) =>
              installers.find('runtime', key) ?? installers.find('agent', key),
          agentInstaller: (c) => installers.find('agent', c) != null,
          home: identity.home,
          cachePath: params['cache'] as String,
          path: Platform.environment['PATH'],
          writeCache: (path, bytes) => File(path).writeAsBytesSync(bytes),
        );
        result = {
          'updates': await updates.check(
            (params['agents'] as List).cast<Map>(),
            (params['runtimes'] as List).cast<Map>(),
            now: (params['now'] as num).toDouble(),
            mise: () async => mise,
            latest: (command, channel) async => latest['$command:$channel'],
            gpu: () async => inst.Gpu(),
            installerLatest: (i, g) async =>
                params['installer_latest'] as String?,
          ),
        };
      } else if (request.method == 'dev.healthreport') {
        // health.check over given checks, inventory, graph and PC facts.
        final setup = chk.SetupChecks(
          tr: i18n.text,
          home: identity.home,
          environment: Platform.environment,
          desktop: params['desktop'] as String,
          installCommand: (_) => '',
        );
        Map<String, List<Map>> lists(dynamic m) => {
          for (final e in (m as Map).entries)
            '${e.key}': (e.value as List).cast<Map>(),
        };
        result =
            hr.HealthReport(
              tr: i18n.text,
              plural: i18n.plural,
              desktopText: setup.desktopText,
              home: identity.home,
              searchPath: Platform.environment['PATH'],
            ).check(
              agents: (params['agents'] as List).cast<Map>(),
              agentChecks: lists(params['agent_checks']),
              runtimeChecks: lists(params['runtime_checks']),
              runtimes: (params['runtimes'] as List).cast<Map>(),
              mcp: (params['mcp'] as List).cast<Map>(),
              skillSets: (params['skill_sets'] as List).cast<Map>(),
              providers: lists(params['providers']),
              facts: (params['facts'] as Map).cast<String, Map>(),
              graph: params['graph'] as Map?,
              pc: params['pc'] as Map,
              failedLinks: params['failed_links'] as Map,
            );
      } else if (request.method == 'dev.setupchecks') {
        // agent_status.agent_checks / runtime_checks / summary_line.
        final checks = chk.SetupChecks(
          tr: i18n.text,
          home: identity.home,
          environment: Platform.environment,
          desktop: params['desktop'] as String,
          installCommand: (pkg) => installCommand(
            params['desktop'] as String,
            pkg,
            Platform.environment['PATH'],
          ),
        );
        final runtimes = (params['runtimes'] as List).cast<Map>();
        final agent = params['agent'] as Map?;
        final List<Map<String, dynamic>> found;
        if (agent != null) {
          found = checks.agentChecks(
            agent: agent,
            info: params['info'] as Map,
            record: params['record'] as Map,
            runtimes: runtimes,
            mcp: (params['mcp'] as List).cast<String>(),
            skills: (params['skills'] as List).cast<String>(),
            hints: params['hints'] as Map,
            access: params['access'] as Map?,
            loggedIn: params['logged_in'] as bool?,
            issue: params['issue'] as Map?,
          );
        } else {
          found = checks.runtimeChecks(
            params['runtime'] as Map,
            params['hints'] as Map,
            (params['names'] as Map).cast<String, String>(),
            params['login'] as bool?,
          );
        }
        final (state, line) = checks.summaryLine(found);
        result = {
          'checks': found,
          'summary': [state, line],
        };
      } else if (request.method == 'dev.tuningtips') {
        // llm_tuning.facts_text, prompt and validate.
        final facts = params['facts'] as Map;
        dynamic validated;
        try {
          final (summary, found) = tun.validateTuning(params['answer'], facts);
          validated = [summary, found];
        } on FormatException catch (e) {
          validated = {'error': e.message};
        }
        result = {
          'text': tun.tuningFactsText(facts),
          'prompt': tun.tuningPrompt(facts),
          'validated': validated,
        };
      } else if (request.method == 'dev.llmtuning') {
        // llm_tuning.collect and tuning_changes for one runtime.
        final r = params['rt'] as Map;
        final rt = RuntimeRecord(r['key'] as String, r['name'] as String)
          ..installed = true
          ..modelsDir = r['models_dir'] as String
          ..models = (r['models'] as List).cast<String>();
        final g = params['gpu'] as Map;
        final tuning = tun.LlmTuning(
          ContextReader(ScanFiles(identity), core.config),
          identity.home,
          path: Platform.environment['PATH'],
        );
        final installer = inst.LlamaCppInstaller(
          inst.InstallHost(identity.home, Posix()),
        );
        final facts = await tuning.collect(
          rt,
          inst.Gpu(
            vendor: g['vendor'] as String,
            name: g['name'] as String,
            vram: g['vram'] as int,
          ),
          llamaVersion: () async => installer.currentVersion(),
        );
        final changes = [];
        for (final c in params['changes'] as List) {
          try {
            changes.add([
              for (final x in tuning.tuningChanges(
                rt.key,
                c[0] as String,
                c[1] as String,
                c[2] as String,
              ))
                [x.path, x.next],
            ]);
          } on FormatException {
            changes.add('refused');
          }
        }
        result = {'facts': facts, 'changes': changes};
      } else if (request.method == 'dev.skillsweb') {
        // skills_web.parse_search, files_of and the SKILL.md description.
        dynamic files;
        try {
          final (folder, found) = skw.skillFiles(
            params['tree'],
            params['skill_id'] as String,
          );
          files = [
            folder,
            [
              for (final f in found) [f.$1, f.$2, f.$3, f.$4],
            ],
          ];
        } on FormatException catch (e) {
          files = {'error': e.message};
        }
        result = {
          'search': skw.parseSkillSearch(params['search']),
          'files': files,
          'description': skw.skillDescription(params['text'] as String),
        };
      } else if (request.method == 'dev.mcptools') {
        // mcp_tools.ask against a fixture server.
        try {
          result = await mcpt.askTools(
            params['entry'] as Map,
            home: identity.home,
            environment: Platform.environment,
          );
        } on Object catch (e) {
          result = {'error': '$e'};
        }
      } else if (request.method == 'dev.mcpparse') {
        // mcp_registry.parse and _kept for one registry answer.
        final path = Platform.environment['PATH'];
        result = {
          'servers': mcpc.parseServers(params['data'], path),
          'kept': [
            for (final item
                in (params['data'] as Map)['servers'] as List? ?? [])
              mcpc.keptItem(item),
          ],
        };
      } else if (request.method == 'dev.mcpfill') {
        final entry = params['entry'] as Map;
        final filled = mcpc.fillEntry(
          entry,
          (params['values'] as Map).cast<String, String>(),
        );
        final dropped = mcpc.dropUnfilled(
          filled,
          (params['optional'] as List).cast<String>(),
        );
        result = {
          'filled': filled,
          'dropped': dropped,
          'unfilled': mcpc.unfilled(dropped),
          'secret': mcpc.secretInArgs(
            entry,
            (params['secrets'] as List).cast<String>(),
          ),
        };
      } else if (request.method == 'dev.mcpsearch') {
        final found = mcpc.searchList(
          params['query'] as String,
          params['list'] as String,
          Platform.environment['PATH'],
          offset: params['offset'] as int,
        );
        result = {
          'found': found == null ? null : [found.$1, found.$2, found.$3],
        };
      } else if (request.method == 'dev.mcppicks') {
        final versions = (params['versions'] as Map).cast<String, String>();
        result = {
          'servers': [
            for (final pick in mcpc.catalogPicks)
              await mcpc.resolvePick(
                pick,
                Platform.environment['PATH'],
                ask: (kind, name) async => versions['$kind:$name'] ?? '',
              ),
          ],
        };
      } else if (request.method == 'dev.mcprefresh') {
        final pages = params['pages'] as Map;
        final asked = <String>[];
        final ok = await mcpc.refreshList(
          params['list'] as String,
          now: (params['now'] as num).toDouble(),
          fetch: (url) async {
            asked.add(url);
            final page = pages[url];
            if (page == null) throw StateError('offline');
            return page;
          },
          write: (path, bytes) => File(path).writeAsBytesSync(bytes),
        );
        result = {'ok': ok, 'asked': asked};
      } else if (request.method == 'dev.securityplan') {
        // agent_security.plan's new text for one setting and value.
        final adapter = core.addons.adapters
            .where((a) => a.command == params['command'])
            .first;
        final report = SecurityReports(
          ScanFiles(identity),
          i18n,
        ).agent(adapter);
        try {
          final plan = securityPlan(
            report,
            params['command'] as String,
            params['key'] as String,
            params['value'],
            core.config,
          );
          result = {
            'changes': [
              for (final c in plan.changes) [c.path, c.next],
            ],
          };
        } on FormatException catch (e) {
          result = {'error': e.message};
        }
      } else if (request.method == 'dev.tarcheck') {
        // install_ctl.check_archive on a crafted archive.
        try {
          await checkArchive(
            params['path'] as String,
            limit: params['limit'] as int,
            maxEntries: params['max_entries'] as int,
          );
          result = {'ok': true};
        } on StateError catch (e) {
          result = {'error': e.message};
        }
      } else if (request.method == 'dev.koboldsync') {
        // kobold_ctl.sync with a fixed video memory size.
        result = {
          'written': await koboldSync(
            params['models'] as String,
            params['build'] as String,
            () async => params['vram'] as int,
            params['configs'] as String,
          ),
        };
      } else if (request.method == 'dev.fit') {
        final path = params['path'] as String;
        try {
          final meta = readGguf(path);
          result = {
            'layout': kvLayout(meta, params['cache'] as String).toString(),
            'best': [
              for (final v in params['vram'] as List)
                bestContext(path, v as int, params['cache'] as String),
            ],
          };
        } on FormatException catch (e) {
          result = {'error': e.message};
        }
      } else if (request.method == 'dev.undo') {
        // Undo of a backup folder either side made (development probe only).
        result = {
          'restored': ConfigFiles(
            Posix(),
            identity.home,
          ).undo(params['folder'] as String),
        };
      } else if (request.method == 'scan.catalog') {
        if (params.isNotEmpty) throw const FormatException('Unexpected params');
        result = {
          'agents': reads.catalog.scan().map((a) => a.toJson()).toList(),
        };
      } else if (request.method == 'scan.inventory') {
        if (params.isNotEmpty) throw const FormatException('Unexpected params');
        result = reads.inventory
            .collect(reads.catalog.scan(), remember: false)
            .toJson();
      } else if ([
        'scan.sessions',
        'scan.security',
        'scan.costs',
        'scan.usage',
      ].contains(request.method)) {
        if (params.length != 1 || params['command'] is! String) {
          throw const FormatException('Expected command');
        }
        final adapter = reads.catalog.adapter(params['command']);
        if (adapter == null) throw const FormatException('Unknown agent');
        if (request.method == 'scan.security') {
          result = SecurityReports(reads.files, i18n).agent(adapter);
        } else {
          final sessions = SessionReaders(reads.files).read(adapter);
          if (request.method == 'scan.sessions') {
            result = {
              'sessions': {
                for (final e in sessions.entries) e.key: e.value.toJson(),
              },
            };
          } else {
            final usage = UsageReaders(reads.files);
            result = {
              'value': request.method == 'scan.costs'
                  ? usage.costs(adapter, collected: sessions)
                  : usage.fromSessions(sessions, 'fixture'),
            };
          }
        }
      } else {
        result = readOnlyRoutes.contains(request.method)
            ? reads.dispatch(request.method, params)
            : core.dispatch(request.method, params);
      }
      response = {'id': id, 'result': result};
    } catch (_) {
      response = {
        'id': id,
        'error': {'code': 'invalid_request'},
      };
    }
    stdout.writeln(jsonEncode(response));
    await Future<void>.delayed(Duration.zero);
  }
}
