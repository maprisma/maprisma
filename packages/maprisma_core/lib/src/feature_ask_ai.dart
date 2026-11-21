part of 'core.dart';

/// The largest host context sent to the Ask AI backend with a request.
const maxAskAiContext = 16 * 1024;

/// Ask AI owns its proposals independently of the other feature modules.
final class _AskAiFeatureState {
  final proposals = SmartProposals(newHandle);
}

/// Ask AI feature entry points, helper selection and proposal validation.
extension AskAiFeatureRoutes on CoreService {
  SmartProposals get smartProposals => _askAiFeature.proposals;

  /// The agents that can answer a smart card (docs/plan-smart-helpers.md): the
  /// confirmed local helper first, then the agent for AI checks, then the
  /// others, each with a guarded start that has no tools.
  List<Map<String, dynamic>> smartHelpers() {
    final local = localHelpers().$3;
    final (checkers, _) = _aiHelpers();
    final chosen = '${settings.load()['ai_checks_agent'] ?? ''}';
    bool ready(String command) {
      final a = addons.adapters.where((a) => a.command == command).firstOrNull;
      return a != null &&
          a.facts.containsKey('closed') &&
          a.table('rewrite').containsKey('argv');
    }

    return [
      if (local != null)
        {'command': 'local-helper', 'name': helperName(local), 'local': true},
      for (final c in [
        if (checkers.contains(chosen)) chosen,
        ...checkers.where((c) => c != chosen),
      ])
        if (ready(c))
          {
            'command': c,
            'name': _nameOf(c),
            'local': false,
            'web_search': addons.adapters.any(
              (a) => a.command == c && smartHasResearch(a),
            ),
          },
    ];
  }

  bool? _signInObserved(AgentRecord agent) {
    final access = agent.adapter.table('access');
    if ((access['env'] as List? ?? const []).isEmpty &&
        (access['files'] as List? ?? const []).isEmpty) {
      return null;
    }
    return reads.graph.signedIn(agent);
  }

  bool get _mcpUpdatesFresh =>
      (settings.load()['ai_checks'] == true || mcpCheckForced) &&
      mcp_updates.readCache(mcpUpdatesCache)['ok'] == true &&
      !mcp_updates.due(
        DateTime.now().millisecondsSinceEpoch / 1000,
        mcpUpdatesCache,
      );

  List<mcp_updates.McpFound> _openMcpUpdates() => mcp_updates.stillOpen(
    mcp_updates.cached(mcpUpdatesCache),
    mcp_updates.installedServers(mcp.library(), identity.home),
  );

  String? _diagnosticAnswer(String request) {
    bool asks(String prompt) => [
      prompt,
      i18n.text(prompt),
    ].any((text) => text.toLowerCase() == request.trim().toLowerCase());
    final lines = <String>[];
    if (asks('Which agents need sign-in?')) {
      for (final agent in reads.catalog.scan().where(
        (a) =>
            a.installed &&
            (_signInObserved(a) != null ||
                reads.details.actions(a)['login'] == true),
      )) {
        final signed = _signInObserved(agent);
        if (signed != true) {
          lines.add(
            signed == false
                ? agent.name
                : '${agent.name} · ${i18n.text('Unknown')}',
          );
        }
      }
    } else if (asks('Which agents have updates?')) {
      if (!_updatesFresh) {
        return i18n.text('No recent update check is available.');
      }
      lines.addAll(
        lastUpdates
            .where((u) => u['kind'] == 'agent')
            .map((u) => "${u['name']} · ${u['current']} → ${u['available']}"),
      );
    } else if (asks('Which MCP servers have updates?')) {
      if (!_mcpUpdatesFresh) {
        return i18n.text('No recent update check is available.');
      }
      lines.addAll(
        _openMcpUpdates().map((u) => '${u.name} · ${u.current} → ${u.latest}'),
      );
    } else {
      return null;
    }
    return lines.isEmpty ? i18n.text('None') : lines.join('\n');
  }

  Map<String, dynamic> smartRoute(String method, Map<String, dynamic> params) {
    if (method == 'map.smart_helpers') {
      if (params.isNotEmpty) throw const FormatException('Invalid request');
      return {'helpers': smartHelpers()};
    }
    if (method == 'map.smart_ask') {
      final column = params['column'], command = params['command'];
      final request = params['request'], answer = params['answer'];
      final context = params['context'];
      final auto = column == 'auto';
      if (params.keys.any(
            (k) => !const {
              'column',
              'command',
              'request',
              'answer',
              'context',
              'web_search',
            }.contains(k),
          ) ||
          params['web_search'] != null && params['web_search'] is! bool ||
          (!auto && !smartColumns.contains(column)) ||
          context != null &&
              (!auto || context is! String || context.length > 3000) ||
          command is! String ||
          request is! String ||
          request.trim().isEmpty ||
          request.length > 2000 ||
          answer != null && (answer is! String || answer.length > 200)) {
        throw const FormatException('Invalid request');
      }
      if (params['web_search'] == true &&
          !smartHelpers().any(
            (h) => h['command'] == command && h['web_search'] == true,
          )) {
        throw const FormatException('This helper is not ready');
      }
      if (auto && context == null && answer == null) {
        final diagnostic = _diagnosticAnswer(request);
        if (diagnostic != null) {
          return tasks.completed(method, {
            'status': 'answer',
            'summary': diagnostic,
            'helper': command,
            'local': true,
          });
        }
      }
      if (!smartHelpers().any((h) => h['command'] == command)) {
        throw const FormatException('This helper is not ready');
      }
      final helper = command == 'local-helper' ? localHelpers().$3 : null;
      final agents = reads.catalog.scan();
      final mapGraph = reads.buildMap(const {
        'activity',
        'agents',
        'inventory',
      }, true);
      final inventory = reads.mapInventory;
      late final providers = (reads.providersSnapshot()['local'] as List)
          .cast<Map>();
      final engines = providerFacts['engines'] as Map;
      final running = {
        for (final n in (mapGraph['nodes'] as List).cast<Map>())
          if (n['status'] == 'running') '${n['id']}',
      };
      final clouds = visibleProviderFacts['cloud'] as Map? ?? const {};
      final body = utf8.encode(
        pyJsonDumps({
          'column': column,
          'command': helper?.agent ?? command,
          'shown': command,
          'request': request.trim(),
          'answer': ?answer,
          'context': ?context,
          'web_search': params['web_search'] == true,
          'language': i18n.language,
          'action_rules': _rulesForHelper(column),
          'rule_hints': settings.value(settings.load(), 'action_rule_hints'),
          'settings_path': identity.settingsPath,
          'map_nodes': smartMapNodes(mapGraph),
          'map_edges': [
            for (final edge in (mapGraph['edges'] as List).cast<Map>())
              if (edge['kind'] != 'serves' && edge['kind'] != 'skills')
                {
                  'source': edge['source'],
                  'target': edge['target'],
                  'kind': edge['kind'],
                },
          ],
          // Each agent's own online provider: Ask AI signs it in there, as
          // dropping it onto that provider does (F14).
          'own_clouds': {
            for (final a in agents)
              if (a.installed && clouds[a.command] is String)
                a.command: {
                  'cloud': 'cloud:${'${clouds[a.command]}'.toLowerCase()}',
                  'name': a.name,
                  'login': reads.details.actions(a)['login'] == true,
                  'logout':
                      (a.adapter.table('access')['logout'] as List? ?? const [])
                          .isNotEmpty,
                },
          },
          if (auto)
            'addons': [..._smartAddonFacts(true), ..._smartAddonFacts(false)]
          else if (column == 'agents' || column == 'providers')
            'addons': _smartAddonFacts(column == 'agents'),
          if (auto || column == 'models') ...{
            'runtime_actions': [
              for (final rt in providers)
                if (rt['installed'] == true &&
                    (rt['can_import'] == true || rt['can_load'] == true))
                  {
                    'key': rt['key'],
                    'name': rt['name'],
                    'import': rt['can_import'] == true,
                    'load': rt['can_load'] == true,
                    'models': chatModels([
                      for (final m in rt['models'] as List? ?? const []) '$m',
                    ]).take(40).toList(),
                  },
            ],
            'provider_models': _providerModels(),
            // The agents the manual Connect offers for a local LLM (F12).
            'connect_agents': [
              for (final a in agents)
                if (a.installed && llm.supported(a.command))
                  {'command': a.command, 'name': a.name},
            ],
          },
          if (auto || column == 'providers')
            'providers': [
              for (final rt in providers)
                {
                  'key': rt['key'],
                  'name': rt['name'],
                  'installed': rt['installed'],
                  'running': rt['running'],
                  'install': rt['installable'] == true,
                  'update': lastUpdates.any((u) => u['key'] == rt['key']),
                  'start': rt['can_control'] == true && rt['running'] != true,
                  'stop': rt['can_control'] == true && rt['running'] == true,
                  'configurable': rt['configurable'] == true,
                  'models': chatModels([
                    for (final m in rt['models'] as List? ?? const []) '$m',
                  ]).take(40).toList(),
                  'config_scope': configSchema(
                    '${rt['key']}',
                  ).firstOrNull?['scope'],
                },
            ],
          if (auto || column == 'agents')
            'agents': [
              for (final a in agents)
                () {
                  final can = reads.details.actions(a);
                  return {
                    'command': a.command,
                    'name': a.name,
                    'installed': a.installed,
                    'version': a.version,
                    if (auto && a.installed) ...{
                      'signed_in': _signInObserved(a),
                      'update_available': _updatesFresh
                          ? lastUpdates.any(
                              (u) =>
                                  u['kind'] == 'agent' && u['key'] == a.command,
                            )
                          : null,
                    },
                    'install': !a.installed && can['install'] == true,
                    'update': can['update'] == true,
                    'remove': can['uninstall'] == true,
                    'login': can['login'] == true,
                    'logout':
                        a.installed &&
                        (a.adapter.table('access')['logout'] as List? ??
                                const [])
                            .isNotEmpty,
                    'verify': can['verify'] == true,
                    'key': can['key'] == true,
                    'security': a.installed,
                    'start': a.installed,
                    'halt': running.contains('agent:${a.command}'),
                    'configure': a.installed,
                    'details': true,
                  };
                }(),
            ],
          if (auto || column == 'models') ..._moveFacts(),
          if (column == 'mcp') ...smartMcpFacts(agents, inventory),
          if (auto) 'mcp_facts': smartMcpFacts(agents, inventory),
          if (auto && _mcpUpdatesFresh)
            'mcp_updates': [
              for (final u in _openMcpUpdates())
                {'name': u.name, 'current': u.current, 'latest': u.latest},
            ],
          'runtimes': [
            for (final rt in inventory.runtimes)
              if (rt.installed && _takesDownloads(rt, engines))
                {
                  'key': rt.key,
                  'name': rt.name,
                  'download': '${(engines[rt.key] as Map?)?['download'] ?? ''}',
                  'models_dir': rt.modelsDir,
                  'models': rt.models.take(40).toList(),
                },
          ],
          'model_users': () {
            return [
              for (final rt in inventory.runtimes)
                if (rt.installed && rt.models.isNotEmpty)
                  {
                    'key': rt.key,
                    'name': rt.name,
                    'used_by': reads.modelUsers(rt, fresh: false)
                      ..removeWhere((_, users) => users.isEmpty),
                  },
            ];
          }(),
          if (helper != null)
            'helper': {
              'provider': helper.provider,
              'runtime': helper.runtime,
              'model': helper.model,
            },
        }),
      );
      if (body.length > 256 * 1024) {
        throw const FormatException('Request too large');
      }
      return tasks.startPrivate('map.smart_ask', body, finalizeSmartAsk);
    }
    if (method == 'map.smart_plan') return _smartPlan(params);
    final fields = {
      'proposal',
      'candidate',
      if (method == 'map.smart_connect') 'agent',
    };
    if (params.length != fields.length ||
        !params.keys.every(fields.contains) ||
        params.values.any((v) => v is! String)) {
      throw const FormatException('Invalid request');
    }
    final candidate = smartProposals.candidate(params);
    // Rules can have changed since it was proposed.
    if ((candidate['action'] as Map?)?['kind'] == 'map_edit') {
      final edit = candidate['action'] as Map;
      _enforce(
        actionChecks(
          edit['method'] as String,
          Map<String, dynamic>.from(edit['params'] as Map),
          _ruleFacts,
        ),
      );
    } else {
      _enforce(smartCandidateChecks(candidate));
    }
    final action = candidate['action'] as Map;
    if (action['kind'] == 'agent_task') {
      final task = action['command'] as String;
      _enforce([ActionCheck('start', 'agents', task)]);
      final argv = taskArgv(
        addons.adapters.where((a) => a.command == task).firstOrNull,
        task,
        action['prompt'] as String,
        identity.environment,
        identity.home,
      );
      if (method != 'map.smart_review' || argv == null || argv.isEmpty) {
        throw const FormatException('Guarded helper unavailable');
      }
      return helpPreviews.keep(
        task,
        _nameOf(task),
        action['prompt'] as String,
        argv,
        'smart-card',
      );
    }
    if (action['kind'] == 'agent_action') {
      if (method == 'map.smart_review') {
        final review = dispatch('agents.action_preview', {
          'command': action['command'],
          'action': action['step'],
        });
        candidate['preview'] = review['preview'];
        return review;
      }
      final preview = candidate.remove('preview');
      if (method != 'map.smart_run' || preview == null) {
        throw const FormatException('Review it first');
      }
      return dispatch('agents.action_apply', {'preview': preview});
    }
    if (action['kind'] == 'model_remove') {
      if (method == 'map.smart_review') {
        final review = dispatch('models.remove_preview', {
          'key': action['key'],
          'model': action['model'],
        });
        candidate['removal'] = review['removal'];
        return review;
      }
      if (method != 'map.smart_run' || candidate['removal'] == null) {
        throw const FormatException('Review it first');
      }
      final removal = candidate.remove('removal');
      return dispatch('models.remove_apply', {'removal': removal});
    }
    if (action['kind'] == 'model_move') {
      if (method == 'map.smart_review') {
        final started = dispatch('system.move_preview', {
          'source': action['source'],
          'target': action['target'],
        });
        candidate['move_task'] = started['task'];
        return started;
      }
      final preview = tasks.items[candidate['move_task']]?.result['preview'];
      if (method != 'map.smart_run' || preview == null) {
        throw const FormatException('Review it first');
      }
      candidate.remove('move_task');
      return dispatch('system.move_apply', {'preview': preview});
    }
    if (action['kind'] != null) throw const FormatException('Invalid request');
    if (method == 'map.smart_review') {
      return {
        'title': candidate['title'],
        'subtitle': candidate['subtitle'],
        'size': candidate['size'],
        'fit': candidate['fit'],
        'runtime': action['runtime_name'],
      };
    }
    if (method == 'map.smart_run') {
      if (candidate['fit'] == 'too_large') {
        throw const FormatException('This model is too large for this PC');
      }
      // Once: while it runs or when it worked. A failed or cancelled download
      // can start again, without a new request and its tokens.
      final last = tasks.items[candidate['task']]?.state;
      if (last == 'running' || last == 'done') {
        throw const FormatException('This one has already been started');
      }
      final started = dispatch('providers.run', {
        'operation': action['operation'],
        'params': action['params'],
      });
      candidate['task'] = started['task'];
      return started;
    }
    final rt = reads.inventory
        .collect(reads.catalog.scan())
        .runtimes
        .where((r) => r.key == action['runtime'])
        .firstOrNull;
    final model = rt == null ? null : smartInstalled(rt.models, action);
    if (model == null) {
      throw const FormatException('This model is not on this PC yet');
    }
    // Only an agent the manual Connect offers for a local LLM (F12).
    final connect = candidate['connect'] as List? ?? const [];
    if (!connect.any((a) => a is Map && a['command'] == params['agent'])) {
      throw const FormatException('This agent cannot use a local LLM');
    }
    // As a drawn connection with the provider's model: the agent uses it now.
    return dispatch('connections.preview', {
      'kind': 'provider',
      'command': params['agent'],
      'item': action['runtime'],
      'remove': false,
      'model': model,
      'use_now': true,
    });
  }

  /// The add-ons Ask AI may name in the Agents (agent add-ons) or Providers
  /// column, with the steps their menus offer now: the add-on sheet's (details,
  /// on, off, remove) and the catalog's (install, update) when it was read.
  List<Map<String, dynamic>> _smartAddonFacts(bool agentsColumn) {
    final listed =
        (addons.snapshot(enabledAddons(), addonSignIns, addonUserDir)['addons']
                as List)
            .cast<Map>();
    final rows = {for (final r in catalogRows) '${r['id']}': r};
    bool mine(Object? kind) => (kind == 'agent') == agentsColumn;
    bool offered(Map? row, String action) =>
        row?['action'] == action && row?['preview'] != null;
    return [
      for (final a in listed)
        if (mine(a['kind']))
          {
            'id': a['id'],
            'name': a['name'],
            'enabled': a['enabled'] == true,
            'details': true,
            'on':
                a['enabled'] != true &&
                a['supported'] == true &&
                a['verified'] == true,
            'off': a['enabled'] == true && a['supported'] == true,
            'remove': a['removable'] == true,
            'install': false,
            'update': offered(rows[a['id']], 'update'),
          },
      for (final r in catalogRows)
        if (mine(r['kind']) &&
            offered(r, 'install') &&
            !listed.any((a) => a['id'] == r['id']))
          {
            'id': r['id'],
            'name': r['name'],
            'enabled': false,
            'details': false,
            'on': false,
            'off': false,
            'remove': false,
            'install': true,
            'update': false,
          },
    ];
  }

  /// What the Models helper may move: only model folders, to known disks,
  /// the saved System Map when this run has none yet. The agent sees short
  /// names and neutral ids, never a path; `node` stays in the core.
  /// What only the host process knows and Ask AI reads, for its backend
  /// process: the add-on catalog's offers (without their preview tokens, which
  /// stay with the host and its install flow), the last program-update check
  /// and a manual MCP check.
  ///
  /// Only the fields Ask AI reads, and bounded: the private frame has the
  /// request limit, and the context must leave room for the params.
  Map<String, dynamic> askAiHostContext() {
    String? text(Object? value) =>
        value is String && value.length <= 200 ? value : null;
    final context = <String, dynamic>{
      'catalog': [
        for (final row in catalogRows)
          if (row['preview'] != null)
            {
              for (final key in const ['id', 'name', 'kind', 'action'])
                key: text(row[key]),
              'offered': true,
            },
      ],
      'updates': [
        for (final update in lastUpdates)
          {
            for (final key in const [
              'kind',
              'key',
              'name',
              'current',
              'available',
            ])
              key: text(update[key]),
            // The updater the check found; the backend checks it again
            // (allowedUpdate) before it runs it.
            if (update['command'] is List &&
                (update['command'] as List).length <= 16 &&
                (update['command'] as List).every((w) => text(w) != null))
              'command': update['command'],
          },
      ],
      'updates_checked_at': _updatesCheckedAt?.toUtc().toIso8601String(),
      'mcp_check_forced': mcpCheckForced,
    };
    for (final key in const ['catalog', 'updates']) {
      if (utf8.encode(jsonEncode(context)).length <= maxAskAiContext) break;
      context[key] = const <Object>[];
    }
    return context;
  }

  /// In the Ask AI backend process: take the host's context, and reread what
  /// the host may have changed on disk since the last request.
  void applyAskAiHostContext(Map<String, dynamic> context) {
    final catalog = context['catalog'];
    if (catalog is List) {
      catalogRows = [
        for (final row in catalog)
          if (row is Map)
            {
              for (final key in const ['id', 'name', 'kind', 'action'])
                key: row[key] is String ? row[key] : null,
              // Only "offered" matters here; the real token is the host's.
              'preview': row['offered'] == true ? 'host' : null,
            },
      ];
    }
    final updates = context['updates'];
    if (updates is List) {
      lastUpdates = [
        for (final update in updates)
          if (update is Map<String, dynamic>) update,
      ];
    }
    final checked = context['updates_checked_at'];
    _updatesCheckedAt = checked is String ? DateTime.tryParse(checked) : null;
    if (context['mcp_check_forced'] is bool) {
      mcpCheckForced = context['mcp_check_forced'] as bool;
    }
    // The host saves each refreshed System Map; the last one read here may
    // be older.
    final saved = loadMapCache(systemMapPath, Posix());
    if (saved.isNotEmpty) systemMapLast = saved;
    addons.reload(enabledAddons());
    reads.catalog.adapters = addons.adapters;
  }

  Map<String, dynamic> _moveFacts() {
    if (systemMapLast == null) {
      final saved = loadMapCache(systemMapPath, Posix());
      if (saved.isNotEmpty) systemMapLast = saved;
    }
    final nodes = (systemMapLast?['nodes'] as List? ?? const []).cast<Map>();
    // A folder by its name; a disk where it is mounted, home as "~".
    String label(Map n) {
      final path = '${n['path']}';
      if (n['kind'] != 'disk') return p.basename(path);
      return path == identity.home ? '~' : p.basename(path);
    }

    List<Map> short(String prefix, bool Function(Map) wanted) => [
      for (final (i, n)
          in nodes.where((n) => n['status'] != 'missing' && wanted(n)).indexed)
        {'id': '$prefix${i + 1}', 'label': label(n), 'node': n['id']},
    ];
    return {
      'folders': short(
        'f',
        (n) =>
            n['kind'] == 'models' ||
            n['kind'] == 'folder' && n['label'] == 'Models folder',
      ),
      'disks': short('d', (n) => n['kind'] == 'disk'),
    };
  }

  /// Ask AI's facts of the MCP column: the agents, each MCP server by the
  /// map's id (another of one name is name~2) with the agents that use that
  /// very server, and the skill folders by short ids.
  Map<String, dynamic> smartMcpFacts(
    List<AgentRecord> agents, [
    InventorySnapshot? snapshot,
  ]) {
    final inventory = snapshot ?? reads.inventory.collect(agents);
    final installed = agents.where((a) => a.installed).toList();
    return {
      'agents': [
        for (final a in installed)
          if (mcp.supported(a.command) || skills.ownDir(a.command) != null)
            {
              'command': a.command,
              'name': a.name,
              'mcp': mcp.supported(a.command),
            },
      ],
      // By the map's id: another server of one name is name~2,
      // with the agents that use that very server.
      'mcp': {
        for (final server in inventory.mcp)
          server['id']: [
            for (final a in installed)
              if ((server['agents'] as List).contains(a.command)) a.command,
          ],
      },
      // Short names: a path of this PC stays here.
      'skill_paths': {
        for (final (i, set) in inventory.skillSets.indexed)
          's${i + 1}': set['path'],
      },
      'skills': {
        for (final (i, set) in inventory.skillSets.indexed)
          's${i + 1}': [
            for (final a in installed)
              if (inventory.agentSkills[a.command]?.contains(set['path']) ==
                      true &&
                  _skillWay(a.command, set['path'] as String).isEmpty)
                a.command,
          ],
      },
    };
  }

  /// map.smart_plan: an approved MCP candidate as the app's normal preview;
  /// the agents and values come from the user, the rest from the checked
  /// proposal.
  Map<String, dynamic> _smartPlan(Map<String, dynamic> params) {
    final agents = params['agents'], values = params['values'];
    if (params.length != 4 ||
        params['proposal'] is! String ||
        params['candidate'] is! String ||
        agents is! List ||
        agents.any((a) => a is! String) ||
        values is! Map) {
      throw const FormatException('Invalid request');
    }
    final candidate = smartProposals.candidate(params);
    final action = candidate['action'] as Map;
    final kind = action['kind'];
    if (kind == 'map_edit') {
      final method = action['method'];
      final expected = candidate['agents'] as List? ?? const [];
      if (!smartMapMethods.contains(method) ||
          values.isNotEmpty ||
          agents.length != expected.length ||
          !agents.every((agent) => expected.contains(agent))) {
        throw const FormatException('Invalid map edit');
      }
      final edit = Map<String, dynamic>.from(action['params'] as Map);
      _enforce(actionChecks(method as String, edit, _ruleFacts));
      return dispatch(method, edit);
    }
    if (agents.isEmpty) throw const FormatException('Choose an agent');
    _enforce(smartCandidateChecks(candidate));
    if (kind == 'mcp_add') {
      final server = Map<String, dynamic>.from(action['server'] as Map);
      final option = smartMcpOption(server);
      if (option == null) throw const FormatException('Show the server again');
      final shown = mcpOptions.server({
        ...server,
        'options': [option],
      });
      return dispatch('mcp.option_preview', {
        'option': (shown['options'] as List).single['option'],
        'name': smartMcpName('${server['name']}'),
        'values': values,
        'agents': agents,
      });
    }
    if (kind == 'mcp_connect') {
      if (agents.length != 1 || agents.single != action['agent']) {
        throw const FormatException('Invalid request');
      }
      return dispatch('connections.preview', {
        'kind': 'mcp',
        'command': action['agent'],
        'item': action['server'],
        'remove': false,
      });
    }
    if (kind == 'skill_connect') {
      if (agents.length != 1 || agents.single != action['agent']) {
        throw const FormatException('Invalid request');
      }
      return dispatch('connections.preview', {
        'kind': 'skills',
        'command': action['agent'],
        'item': action['folder'],
        'remove': false,
      });
    }
    if (kind == 'model_disconnect') {
      return edits.modelsDisconnect(action['key'] as String, [
        for (final p in action['pairs'] as List) p as Map,
      ]);
    }
    if (kind == 'mcp_disconnect') {
      final pairs = [for (final p in action['pairs'] as List) p as Map];
      if (agents.length != {...agents}.length ||
          !{...agents}.containsAll(candidate['agents'] as List) ||
          agents.length != (candidate['agents'] as List).length) {
        throw const FormatException('Invalid request');
      }
      return pairs.length == 1
          ? dispatch('connections.preview', {
              'kind': pairs.single['skill'] == null ? 'mcp' : 'skills',
              'command': pairs.single['agent'],
              'item': pairs.single['server'] ?? pairs.single['skill'],
              'remove': true,
            })
          : _disconnectAll(pairs);
    }
    throw const FormatException('Invalid request');
  }

  /// The rules a helper of this column needs. A skill folder is named by the
  /// short id the helper knows it by, never by its path.
  List<Map<String, dynamic>> _rulesForHelper(Object? column) {
    final mine = switch (column) {
      'auto' => const ['mcp', 'skills', 'agents', 'providers', 'models'],
      'mcp' => const ['mcp', 'skills'],
      'agents' => const ['agents'],
      'providers' => const ['providers'],
      _ => const ['models'],
    };
    final rules = (settings.value(settings.load(), 'action_rules') as List)
        .cast<Map>();
    final ids = <String, String>{};
    if (rules.any((r) => r['category'] == 'skills' && r['item'] != '*')) {
      final sets = reads.inventory
          .collect(reads.catalog.scan(), remember: false)
          .skillSets;
      for (final (i, set) in sets.indexed) {
        ids[_ruleItem('skills', '${set['path']}')] = 's${i + 1}';
      }
    }
    return [
      for (final r in rules)
        if (r['category'] == '*' || mine.contains(r['category']))
          {
            ...Map<String, dynamic>.from(r),
            if (r['category'] == 'skills' && r['item'] != '*')
              'item': ids[_ruleItem('skills', '${r['item']}')] ?? 'none here',
          },
    ];
  }

  /// Check action rules at delivery and keep executable actions behind local handles.
  Map<String, dynamic> finalizeSmartAsk(Map<String, dynamic> result) {
    final checked = _dropRefused(result);
    for (final candidate
        in (checked['candidates'] as List? ?? const []).cast<Map>()) {
      if (candidate['kind'] != 'provider_config') continue;
      final action = candidate['action'] as Map;
      final facts = action.remove('facts');
      if (facts is! Map) {
        throw const FormatException('Invalid configuration proposal');
      }
      final key = '${candidate['key']}', model = '${candidate['model']}';
      final values = Map<String, dynamic>.from(candidate['values'] as Map);
      configCache.keep(key, Map<String, dynamic>.from(facts));
      candidate['config_proposal'] = configCache.propose(key, model, values);
    }
    return smartProposals.keep(smartWorded(checked, i18n.text));
  }

  /// Refused candidates do not reach the card: a disconnect keeps what may
  /// go, a web answer stays without its button.
  Map<String, dynamic> _dropRefused(Map<String, dynamic> result) {
    final list = result['candidates'];
    if (list is! List) return result;
    final rules = settings.value(settings.load(), 'action_rules') as List;
    bool ok(ActionCheck check) => ruleAllows(rules, check, normal: _ruleItem);
    final kept = <Map>[];
    for (final c in list.cast<Map>()) {
      final action = c['action'];
      if (action is Map &&
          const {
            'mcp_disconnect',
            'model_disconnect',
          }.contains(action['kind'])) {
        final pairs = (action['pairs'] as List).cast<Map>();
        // An agent leaves a local LLM whole: one refused model keeps it there.
        final staying = action['kind'] == 'model_disconnect'
            ? {
                for (final p in pairs)
                  if (!smartPairChecks(p).every(ok)) '${p['agent']}',
              }
            : const <String>{};
        final left = [
          for (final p in pairs)
            if (smartPairChecks(p).every(ok) &&
                !staying.contains('${p['agent']}'))
              p,
        ];
        if (left.isNotEmpty) {
          final commands = {for (final p in left) '${p['agent']}'}.toList();
          kept.add({
            ...c,
            'title': smartDisconnectTitle(left),
            'agents': commands,
            if (action['kind'] == 'mcp_disconnect')
              'subtitle': [for (final a in commands) _nameOf(a)].join(', '),
            'action': {...action, 'pairs': left},
          });
        }
      } else if (action is Map && action['kind'] == 'map_edit') {
        final checks = actionChecks(
          action['method'] as String,
          Map<String, dynamic>.from(action['params'] as Map),
          _ruleFacts,
        );
        if (checks.isNotEmpty && checks.every(ok)) kept.add(c);
      } else if (smartCandidateChecks(c).every(ok)) {
        kept.add(c);
      }
    }
    if (kept.isNotEmpty ||
        result['instead'] != null ||
        result['status'] == 'answer') {
      return {...result, 'candidates': kept};
    }
    return list.isEmpty
        ? result
        : {
            if (result['helper'] != null) 'helper': result['helper'],
            if (result['local'] != null) 'local': result['local'],
            'status': 'redirect',
            'instead': {
              'hint': smartNotAllowed,
              'column': null,
              'request': null,
            },
          };
  }
}
