import 'provider_scans.dart' show RuntimeRecord;
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'adapter_assets.g.dart';
import 'agent_catalog.dart';
import 'connect_apply.dart';
import 'core_tasks.dart';
import 'inventory.dart' show chatModels;
import 'llm_plans.dart';
import 'map_graph.dart' show splitModel;
import 'mcp_plans.dart';
import 'online_models.dart';
import 'py_values.dart';
import 'read_service.dart';
import 'skill_plans.dart';
import 'provider_facts.dart';

/// connect.chain and connect.merge: several plans, one preview, one backup,
/// one Undo; each builder reads what the ones before it planned.
Plan chainPlans(ConfigFiles config, List<Plan Function()> builders) {
  final plans = <Plan>[], first = <String, String>{};
  config.staged = {};
  final Map<String, String> texts;
  try {
    for (final build in builders) {
      final item = build();
      for (final change in item.changes) {
        first.putIfAbsent(change.path, () => change.old);
        config.staged![change.path] = change.next;
      }
      item.changes.clear();
      plans.add(item);
    }
    texts = Map.of(config.staged!);
  } finally {
    config.staged = null;
  }
  if (plans.isEmpty) throw const FormatException('nothing to do');
  plans.first.changes.addAll([
    for (final e in texts.entries)
      if (e.value != first[e.key]) Change(e.key, first[e.key]!, e.value),
  ]);
  return mergePlans(plans);
}

Plan mergePlans(List<Plan> plans) {
  if (plans.isEmpty) throw const FormatException('nothing to do');
  final result = Plan(
    plans.map((p) => p.agent).join(','),
    '',
    plans.first.provider,
  );
  for (final item in plans) {
    for (final change in item.changes) {
      if (result.changes.any((c) => c.path == change.path)) {
        throw FormatException('${change.path} twice');
      }
      result.changes.add(change);
    }
    result.linksAdd.addAll(item.linksAdd);
    result.linksRemove.addAll(item.linksRemove);
    result.filesStaged.addAll(item.filesStaged);
    for (final path in item.retire) {
      if (!result.retire.contains(path)) result.retire.add(path);
    }
    // Python compares these by value.
    bool seen(List<Map<String, dynamic>> list, Map v) =>
        list.any((x) => jsonEncode(x) == jsonEncode(v));
    for (final c in item.contexts) {
      if (!seen(result.contexts, c)) result.contexts.add(c);
    }
    for (final a in item.modelActions) {
      if (!seen(result.modelActions, a)) result.modelActions.add(a);
    }
  }
  return result;
}

final class MapEdits {
  MapEdits(
    this.reads,
    this.config,
    this.llm,
    this.mcp,
    this.skills,
    this.connections,
    this.configDir,
  ) : online = OnlineModels(
        reads.files,
        config,
        reads.files.identity.home,
        reads.graph.ownFolder,
      );
  final OnlineModels online;
  final ReadService reads;
  final ConfigFiles config;
  final LlmPlans llm;
  final McpPlans mcp;
  final SkillPlans skills;
  final CoreConnections connections;
  final String configDir;
  final _clock = Stopwatch()..start();
  int _built = -1 << 40;

  /// flutter_backend.current_map: the last map, built again after 5 s.
  Map<String, dynamic> currentMap() {
    final nodes = reads.map['nodes'] as List? ?? const [];
    if (nodes.isEmpty || _clock.elapsedMilliseconds - _built >= 5000) {
      reads.map = reads.buildMap();
      _built = _clock.elapsedMilliseconds;
    }
    return reads.map;
  }

  String get failurePath => '$configDir/failed-links.json';

  /// link_hints.load for the failed-lines file (a link in its place: none).
  Map<String, dynamic> _failures() =>
      FileSystemEntity.typeSync(failurePath, followLinks: false) ==
          FileSystemEntityType.link
      ? {}
      : reads.graph.failures();

  /// The failure entry removed, in the same backup and Undo; null if unchanged.
  Change _failureRemoved(String key) {
    final String raw;
    try {
      raw = utf8.decode(
        File(failurePath).readAsBytesSync(),
        allowMalformed: true,
      );
    } on FileSystemException {
      throw const FormatException('Failure metadata changed');
    }
    if (utf8.encode(raw).length > 1024 * 1024) {
      throw const FormatException('Failure metadata changed');
    }
    final content = jsonDecode(raw);
    if (content is! Map) {
      throw const FormatException('Invalid failure metadata');
    }
    content.remove(key);
    return Change(
      failurePath,
      raw,
      '${pyJsonDumps(content, indent: 2, ensureAscii: false)}\n',
    );
  }

  static void _ids(Map<String, dynamic> params, Set<String> fields) {
    if (params.length != fields.length || !params.keys.every(fields.contains)) {
      throw const FormatException('Unexpected map edit fields');
    }
    for (final e in params.entries) {
      final v = e.value;
      if (e.key == 'agents') {
        if (v is! List ||
            v.length > 32 ||
            v.any((x) => x is! String || x.length > 128) ||
            v.toSet().length != v.length) {
          throw const FormatException('Invalid agent selection');
        }
      } else if (v != null && (v is! String || v.length > 8192)) {
        throw const FormatException('Invalid map identity');
      }
    }
  }

  /// flutter_map_editor.preview for connections.move_preview (the model
  /// switch/attach previews need the provider engines and stay with Python).
  Map<String, dynamic> movePreview(Map<String, dynamic> params) {
    _ids(params, {'agent', 'old', 'new'});
    final graph = currentMap();
    final nodes = {
      for (final n in graph['nodes'] as List) n['id'] as String: n as Map,
    };
    final edges = [for (final e in graph['edges'] as List) e as Map];
    final agents = reads.catalog.scan();
    final catalog = {
      for (final a in agents.where((a) => a.installed)) a.command: a,
    };
    final inv = reads.inventory.collect(catalog.values.toList());
    final runtimes = {
      for (final r in inv.runtimes)
        if (r.installed &&
            (visibleProviderFacts['connect_keys'] as Map).containsKey(r.key))
          'runtime:${r.key}': r,
    };
    Map node(String ident, Set<String> kinds) {
      final n = nodes[ident];
      if (n == null || !kinds.contains(n['kind'])) {
        throw const FormatException('Map item unavailable; refresh');
      }
      return n;
    }

    String agent(String ident) {
      node(ident, {'agent'});
      final command = ident.substring('agent:'.length);
      if (!catalog.containsKey(command)) {
        throw const FormatException('Agent unavailable');
      }
      return command;
    }

    runtime(String ident) {
      node(ident, {'runtime'});
      final rt = runtimes[ident];
      if (rt == null) throw const FormatException('Runtime unavailable');
      return rt;
    }

    bool linked(String source, String target, Set<String> kinds) => edges.any(
      (e) =>
          e['source'] == source &&
          e['target'] == target &&
          kinds.contains(e['kind']),
    );
    final aid = params['agent'] as String?,
        old = params['old'] as String?,
        next = params['new'] as String?;
    if (aid == null || old == null) {
      throw const FormatException('Map item unavailable; refresh');
    }
    final command = agent(aid);
    final target = node(old, {'runtime', 'mcp', 'skills'});
    final failures = _failures();
    final failureKey = '$aid|$old';
    final failed = failures[failureKey] as Map?;
    final failureChange = failed != null ? _failureRemoved(failureKey) : null;
    final unapplied = failed != null && failed['applied'] != true;
    final dangling =
        edges
                .where(
                  (e) =>
                      e['source'] == aid &&
                      e['target'] == old &&
                      pyTruthy(e['dangling']),
                )
                .firstOrNull?['dangling']
            as String? ??
        '';
    final adapter = catalog[command]!.adapter;
    if (dangling.isNotEmpty) {
      final (configured, provider) = splitModel(
        reads.details.read(adapter).model,
      );
      final key = old.contains(':') ? old.substring(old.indexOf(':') + 1) : '';
      if (configured != dangling ||
          provider != (visibleProviderFacts['connect_keys'] as Map)[key]) {
        throw const FormatException('Model changed; refresh');
      }
    }
    if (!linked(aid, old, {'uses', 'available', 'mcp', 'skills', 'failed'})) {
      throw const FormatException('Connection changed; refresh');
    }
    final focus = <String>{aid, old};
    final builders = <Plan Function()>[];
    if (next != null) {
      final before = runtime(old), after = runtime(next);
      if (before.key == after.key ||
          !unapplied &&
              dangling.isEmpty &&
              !reads.inventory.llm.connected(adapter, before.key)) {
        throw const FormatException('Connection unavailable');
      }
      builders.add(
        () => llm.plan(
          command,
          after,
          '',
          false,
          replaces: unapplied ? null : before,
        ),
      );
      focus.add(next);
    } else if (unapplied) {
      // only the recorded failure goes
    } else if (target['kind'] == 'runtime') {
      final before = runtime(old);
      if (dangling.isEmpty &&
          !reads.inventory.llm.connected(adapter, before.key)) {
        throw const FormatException('Connection unavailable');
      }
      builders.add(() => llm.plan(command, before, '', false, remove: true));
    } else if (target['kind'] == 'mcp') {
      // mcp:<name>, or mcp:<name>~2 for another server of that name.
      final name = old
          .substring('mcp:'.length)
          .replaceFirst(RegExp(r'~\d+$'), '');
      if (!mcp.rawEntries(command).containsKey(name)) {
        throw const FormatException('Connection unavailable');
      }
      builders.add(() => mcp.plan(command, name, const [], remove: true));
    } else {
      final folder = old.substring('skills:'.length);
      final (through, listed, links) = skills.reach(
        command,
        skills.expand(folder),
      );
      if (through.isEmpty && !listed && links.isEmpty) {
        throw const FormatException('Connection unavailable');
      }
      builders.add(() => skills.plan(command, folder, remove: true));
    }
    if (builders.isEmpty && failureChange == null) {
      throw const FormatException('No editable model users');
    }
    final plan = builders.isNotEmpty
        ? chainPlans(config, builders)
        : Plan('', '', '');
    if (failureChange != null) plan.changes.add(failureChange);
    return {
      ...connections.keep(plan),
      'focus': [
        for (final n in nodes.keys)
          if (focus.contains(n)) n,
      ],
      'agents': [catalog[command]!.name],
      'notes': <String>[],
      'model_actions': <dynamic>[],
    };
  }

  /// flutter_map_editor.preview for models.switch_preview and
  /// models.attach_preview on a local LLM: the model's users move to another
  /// of its models (or lose it), or chosen agents get it; the runtime unloads
  /// and loads the models after the files (the guard refuses a model in use).
  /// Online models follow in part 2b (the reference builds them meanwhile).
  Map<String, dynamic> modelPreview(
    String method,
    Map<String, dynamic> params,
    void Function(String key, List<String> commands) guard,
  ) {
    final switching = method == 'models.switch_preview';
    _ids(
      params,
      switching ? {'provider', 'old', 'new'} : {'provider', 'model', 'agents'},
    );
    final graph = currentMap();
    final nodes = {
      for (final n in graph['nodes'] as List) n['id'] as String: n as Map,
    };
    final edges = [for (final e in graph['edges'] as List) e as Map];
    final catalog = {
      for (final a in reads.catalog.scan().where((a) => a.installed))
        a.command: a,
    };
    final inv = reads.inventory.collect(catalog.values.toList());
    final runtimes = {
      for (final r in inv.runtimes)
        if (r.installed &&
            (visibleProviderFacts['connect_keys'] as Map).containsKey(r.key))
          'runtime:${r.key}': r,
    };
    Map node(String? ident, Set<String> kinds) {
      final n = nodes[ident];
      if (n == null || !kinds.contains(n['kind'])) {
        throw const FormatException('Map item unavailable; refresh');
      }
      return n;
    }

    String agent(String ident) {
      node(ident, {'agent'});
      final command = ident.substring('agent:'.length);
      if (!catalog.containsKey(command)) {
        throw const FormatException('Agent unavailable');
      }
      return command;
    }

    bool linked(String source, String target, Set<String> kinds) => edges.any(
      (e) =>
          e['source'] == source &&
          e['target'] == target &&
          kinds.contains(e['kind']),
    );
    final pid = params['provider'] as String?;
    final provider = node(pid, {'runtime', 'cloud'});
    final old = (switching ? params['old'] : params['model']) as String?;
    final modelNode = node(old, {'model'});
    if (!linked(pid!, old!, {'serves'})) {
      throw const FormatException('Model/provider mismatch');
    }
    final next = switching ? params['new'] as String? : old;
    if (next != null) {
      node(next, {'model'});
      if (!linked(pid, next, {'serves'}) || switching && next == old) {
        throw const FormatException('Choose another model of this provider');
      }
    }
    List<String> selected;
    if (!switching) {
      selected = [for (final c in params['agents'] as List) agent('agent:$c')];
    } else {
      Set<String> users(List edges) => {
        for (final e in edges)
          if (e['kind'] == 'default' && e['target'] == old)
            e['source'] as String,
      };
      // As the reference: the users on the shown map, against a fresh build.
      final expected = users(edges),
          actual = users(reads.buildMap()['edges'] as List);
      if (expected.length != actual.length || !expected.containsAll(actual)) {
        throw const FormatException('Model users changed; refresh');
      }
      selected = {
        for (final e in edges)
          if (e['target'] == old && e['kind'] == 'default')
            agent(e['source'] as String),
      }.toList();
    }
    final focus = <String>{
      pid,
      old,
      ?next,
      for (final c in selected) 'agent:$c',
    };
    final builders = <Plan Function()>[];
    final actions = <Map<String, dynamic>>[], notes = <String>[];
    if (provider['kind'] == 'cloud') {
      if (next == null || selected.isEmpty) {
        throw const FormatException(
          'Online models require agents and another model',
        );
      }
      for (final command in selected) {
        if (!linked('agent:$command', pid, {'uses', 'available', 'offer'})) {
          throw const FormatException('Agent/provider mismatch');
        }
        final adapter = catalog[command]!.adapter;
        final chosen = online.target(
          adapter,
          provider['label'] as String,
          nodes[next]!['label'] as String,
        );
        if (chosen == null) {
          throw const FormatException('Unsupported online model');
        }
        builders.add(() => online.plan(adapter, chosen));
      }
      return _modelResult(
        builders,
        actions,
        notes,
        nodes,
        focus,
        selected,
        catalog,
      );
    }
    final rt = runtimes[pid];
    node(pid, {'runtime'});
    if (rt == null) throw const FormatException('Runtime unavailable');
    final name = next != null ? nodes[next]!['label'] as String : '';
    if (!rt.models.contains(modelNode['label']) ||
        name.isNotEmpty && !chatModels(rt.models).contains(name)) {
      throw const FormatException('Model unavailable');
    }
    for (final command in selected) {
      final adapter = catalog[command]!.adapter;
      final fixed = adapter.facts['fixed_provider'];
      if (!llm.supported(command) || fixed is String && fixed.isNotEmpty) {
        throw const FormatException('Agent cannot switch provider');
      }
      if (switching) _canLeave(command, rt, catalog);
      builders.add(
        () =>
            llm.plan(command, rt, name, name.isNotEmpty, remove: name.isEmpty),
      );
    }
    if ((providerFacts['engines'] as Map)[rt.key]?['can_load'] == true) {
      // The worker checks these again before it writes any configuration.
      if (switching) {
        guard(rt.key, selected);
        actions.add({
          'operation': 'model.unload',
          'key': rt.key,
          'model': modelNode['label'],
          'agents': selected,
        });
      }
      if (next != null) {
        actions.add({
          'operation': 'model.load',
          'key': rt.key,
          'model': name,
          'agents': <String>[],
        });
      }
      notes.add(
        'Undo restores configuration files; runtime load and unload actions are not undone.',
      );
    }
    return _modelResult(
      builders,
      actions,
      notes,
      nodes,
      focus,
      selected,
      catalog,
    );
  }

  /// An agent can leave a local LLM: both ways out ask the same.
  void _canLeave(
    String command,
    RuntimeRecord rt,
    Map<String, AgentRecord> catalog,
  ) {
    final adapter = catalog[command]?.adapter;
    if (adapter == null) throw const FormatException('Agent unavailable');
    final fixed = adapter.facts['fixed_provider'];
    if (!llm.supported(command) || fixed is String && fixed.isNotEmpty) {
      throw const FormatException('Agent cannot switch provider');
    }
    if (!reads.inventory.llm.active(adapter, rt.key)) {
      throw const FormatException('Model users changed; refresh');
    }
  }

  /// Ask AI: agents leave a local LLM in one preview, one backup and one Undo.
  /// The files stay. [pairs] says who leaves. As the map's own disconnect of
  /// an agent → provider line it only changes configuration: nothing is
  /// unloaded, so Undo puts back all it did; afterwards the app offers the
  /// local LLM's loaded models as after any line change (models.slots_preview).
  Map<String, dynamic> modelsDisconnect(String key, List<Map> pairs) {
    final catalog = {
      for (final a in reads.catalog.scan().where((a) => a.installed))
        a.command: a,
    };
    final rt = reads.inventory
        .collect(catalog.values.toList())
        .runtimes
        .where((r) => r.key == key && r.installed)
        .firstOrNull;
    if (rt == null) throw const FormatException('Runtime unavailable');
    final users = reads.modelUsers(rt);
    final selected = {for (final p in pairs) '${p['agent']}'}.toList();
    if (selected.isEmpty) {
      throw const FormatException('No editable model users');
    }
    final leaving = {for (final p in pairs) '${p['model']}'};
    for (final p in pairs) {
      if (users[p['model']]?.contains(p['agent']) != true) {
        throw const FormatException('Model users changed; refresh');
      }
    }
    // Leaving means the whole LLM: every model an agent has must be asked for.
    for (final e in users.entries) {
      if (e.value.any(selected.contains) && !leaving.contains(e.key)) {
        throw const FormatException('Model users changed; refresh');
      }
    }
    final builders = <Plan Function()>[];
    for (final command in selected) {
      _canLeave(command, rt, catalog);
      builders.add(() => llm.plan(command, rt, '', false, remove: true));
    }
    final actions = <Map<String, dynamic>>[], notes = <String>[];
    final pid = 'runtime:$key';
    final nodes = {
      for (final n in currentMap()['nodes'] as List)
        n['id'] as String: n as Map,
    };
    return {
      ..._modelResult(
        builders,
        actions,
        notes,
        nodes,
        {
          pid,
          for (final m in leaving) 'model:$pid:${m.toLowerCase()}',
          for (final c in selected) 'agent:$c',
        },
        selected,
        catalog,
      ),
      'disconnects': [for (final p in pairs) '${p['model']} → ${p['agent']}'],
    };
  }

  Map<String, dynamic> _modelResult(
    List<Plan Function()> builders,
    List<Map<String, dynamic>> actions,
    List<String> notes,
    Map<String, Map> nodes,
    Set<String> focus,
    List<String> selected,
    Map<String, AgentRecord> catalog,
  ) {
    if (builders.isEmpty && actions.isEmpty) {
      throw const FormatException('No editable model users');
    }
    final plan = builders.isNotEmpty
        ? chainPlans(config, builders)
        : Plan('', '', '');
    plan.modelActions.addAll(actions);
    final result = connections.keep(plan);
    if (actions.isNotEmpty) result['empty'] = false;
    return {
      ...result,
      'focus': [
        for (final n in nodes.keys)
          if (focus.contains(n)) n,
      ],
      'agents': [for (final c in selected) catalog[c]!.name],
      'notes': notes,
      'model_actions': [
        for (final a in actions)
          {'operation': a['operation'], 'model': a['model']},
      ],
    };
  }

  /// flutter_map_editor.repair_preview: retry a known failed edge and clear
  /// its hints in the same backup and Undo (a local LLM line with its model
  /// again).
  Map<String, dynamic> repairPreview(
    Map<String, dynamic> params,
    Map<String, dynamic> Function(Map<String, dynamic>) preview,
  ) {
    _ids(params, {'agent', 'target'});
    final aid = params['agent'] as String?,
        target = params['target'] as String?;
    final graph = currentMap();
    final nodes = {
      for (final n in graph['nodes'] as List) n['id'] as String: n as Map,
    };
    if (nodes[aid]?['kind'] != 'agent' ||
        !const {'runtime', 'mcp', 'skills'}.contains(nodes[target]?['kind'])) {
      throw const FormatException('Unknown failed connection');
    }
    final edge = [
      for (final e in graph['edges'] as List)
        if (e['source'] == aid && e['target'] == target) e as Map,
    ].firstOrNull;
    final entry = _failures()['$aid|$target'] as Map?;
    if (edge == null || entry == null && !pyTruthy(edge['dangling'])) {
      throw const FormatException('Failure changed; refresh');
    }
    final kind = nodes[target]!['kind'] as String;
    final request = <String, dynamic>{
      'kind': kind == 'runtime' ? 'provider' : kind,
      'command': aid!.substring('agent:'.length),
      'item': target!.substring(target.indexOf(':') + 1),
      'remove': false,
    };
    if (kind == 'runtime') {
      final model = pyTruthy(edge['dangling'])
          ? edge['dangling'] as String
          : '${entry?['target'] ?? ''}';
      request.addAll({'model': model, 'use_now': model.isNotEmpty});
    }
    final result = preview(request);
    final plan = connections.take(result['plan'] as String);
    if (entry != null) plan.changes.add(_failureRemoved('$aid|$target'));
    return {
      ...result,
      ...connections.keep(plan),
      'focus': [aid, target],
    };
  }

  /// flutter_connections.author_preview: a new MCP server definition or a
  /// skill-set folder for chosen agents, saved as data, never executed.
  Map<String, dynamic> authorPreview(
    Map<String, dynamic> params,
    List<AgentRecord> agents,
  ) {
    final kind = params['kind'];
    if (kind != 'mcp' && kind != 'skills') {
      throw const FormatException('Invalid authoring request');
    }
    final fields = kind == 'mcp'
        ? {'kind', 'agents', 'name', 'entry'}
        : {'kind', 'agents', 'folder'};
    if (params.length != fields.length || !params.keys.every(fields.contains)) {
      throw const FormatException('Unexpected authoring fields');
    }
    final selected = params['agents'];
    if (selected is! List ||
        selected.isEmpty ||
        selected.length > 32 ||
        selected.any((c) => c is! String || c.isEmpty || c.length > 128) ||
        selected.toSet().length != selected.length) {
      throw const FormatException('Choose installed agents');
    }
    final catalog = {
      for (final a in agents.where((a) => a.installed)) a.command: a,
    };
    final commands = [for (final c in selected) c as String];
    if (commands.any((c) => !catalog.containsKey(c))) {
      throw const FormatException('Agent unavailable');
    }
    final notes = <String>[];
    final List<Plan> plans;
    final String item;
    if (kind == 'mcp') {
      final name = params['name'], entry = params['entry'];
      if (name is! String ||
          !RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(name) ||
          entry is! Map ||
          entry.length != 6 ||
          !const {
            'transport',
            'command',
            'args',
            'url',
            'env',
            'headers',
          }.containsAll(entry.keys)) {
        throw const FormatException('Invalid server definition');
      }
      bool badText(dynamic v) =>
          v is! String || v.length > 4096 || v.contains('\x00');
      if (['transport', 'command', 'url'].any((k) => badText(entry[k])) ||
          entry['args'] is! List ||
          (entry['args'] as List).length > 128 ||
          (entry['args'] as List).any(badText)) {
        throw const FormatException('Invalid server arguments');
      }
      for (final field in ['env', 'headers']) {
        final values = entry[field];
        if (values is! Map ||
            values.length > 64 ||
            values.entries.any(
              (e) =>
                  e.key is! String ||
                  e.value is! String ||
                  (e.value as String).length > 8192 ||
                  RegExp('[\\x00\\n\\r]').hasMatch(e.value as String) ||
                  !RegExp(
                    r'^[A-Za-z_][A-Za-z0-9_-]{0,127}$',
                  ).hasMatch(e.key as String),
            )) {
          throw const FormatException('Invalid server fields');
        }
      }
      if (RegExp('[\\n\\r]').hasMatch(entry['url'] as String)) {
        throw const FormatException('Invalid server address');
      }
      final clean = checkEntry(entry);
      if (clean['transport'] == 'stdio' &&
          ((clean['command'] as String).trim().isEmpty ||
              (clean['command'] as String).contains('\r'))) {
        throw const FormatException('Invalid executable name');
      }
      if (commands.any((c) => !mcp.supported(c))) {
        throw const FormatException('MCP configuration unavailable');
      }
      if (commands.any((c) => mcp.rawEntries(c).containsKey(name))) {
        notes.add(
          'Existing definitions with this name will be replaced for the selected agents.',
        );
      }
      plans = [
        for (final c in commands)
          mcp.plan(c, name, const [], remove: false, entry: clean),
      ];
      notes.add(
        'Maprisma saves configuration only. Agents may start this server when they read it.',
      );
      item = name;
    } else {
      final folder = params['folder'];
      if (folder is! String ||
          folder.isEmpty ||
          folder.length > 4096 ||
          folder.contains('\x00')) {
        throw const FormatException('Choose a skill-set folder');
      }
      final expanded = skills.expand(folder);
      if (!p.isAbsolute(expanded)) {
        throw const FormatException('Choose an absolute skill folder');
      }
      final String source;
      try {
        source = Directory(expanded).resolveSymbolicLinksSync();
      } on FileSystemException {
        throw const FormatException('Choose a skill-set folder');
      }
      if (!FileSystemEntity.isDirectorySync(source)) {
        throw const FormatException('Choose a skill-set folder');
      }
      var count = 0;
      List<String> bounded(String directory) {
        final result = <String>[];
        for (final entry in Directory(directory).listSync(followLinks: false)) {
          count++;
          if (result.length >= 200 || count > 1000) {
            throw const FormatException('Choose a smaller skill-set folder');
          }
          result.add(entry.path);
        }
        return result;
      }

      try {
        for (final entry in bounded(source)) {
          if (!p.basename(entry).startsWith('.') &&
              FileSystemEntity.isDirectorySync(entry) &&
              !File(p.join(entry, 'SKILL.md')).existsSync()) {
            bounded(entry);
          }
        }
      } on FileSystemException {
        throw const FormatException('Choose a skill-set folder');
      }
      if (skills.skillsOf(source).isEmpty) {
        throw const FormatException('No skill folders found');
      }
      if (commands.any((c) => skills.ownDir(c) == null)) {
        throw const FormatException('Skill configuration unavailable');
      }
      plans = [for (final c in commands) skills.plan(c, source, remove: false)];
      item = config.tilde(source);
      notes.add('Skills may include scripts that agents can run.');
      notes.add(
        'The original skill files stay in place. Agents read linked skills; later edits take effect there too.',
      );
      if (commands.any((c) => skills.reach(c, source).$1.isNotEmpty)) {
        notes.add(
          'Some agents already read this folder automatically; their native access is unchanged.',
        );
      }
    }
    final result = {
      ...connections.keep(mergePlans(plans)),
      'kind': kind,
      'item': item,
      'agents': [for (final c in commands) catalog[c]!.name],
      'notes': notes,
    };
    final anchors = <String>[];
    for (final c in commands) {
      for (final a in taskFocus(reads.map, {
        'command': c,
        'kind': kind,
        'item': item,
      })) {
        if (!anchors.contains(a)) anchors.add(a);
      }
    }
    return {...result, 'focus': anchors};
  }
}
