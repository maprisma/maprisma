import 'dart:io';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'adapters.dart';
import 'dsh_profile.dart';
import 'agent_catalog.dart';
import 'agent_details.dart';
import 'first_agent.dart' show credentialsPresent;
import 'inventory.dart';
import 'provider_scans.dart';
import 'scan_files.dart';
import 'service_i18n.dart';
import 'provider_facts.dart';

(String, String) splitModel(String model) {
  model = model.trim();
  if (model.endsWith(')') && model.contains(' (')) {
    final at = model.lastIndexOf(' (');
    return (model.substring(0, at), model.substring(at + 2, model.length - 1));
  }
  if (model.contains('/') && !model.startsWith('/')) {
    final at = model.indexOf('/');
    return (model.substring(at + 1), model.substring(0, at));
  }
  return (model, '');
}

String graphModelKey(String model) {
  var key = model.trim().toLowerCase().split('/').last;
  for (final suffix in ['.gguf', '-gguf', '_gguf']) {
    if (key.endsWith(suffix)) {
      key = key.substring(0, key.length - suffix.length);
    }
  }
  return key.replaceFirst(
    RegExp(r'[-_.](?:i?q\d(?:_[0-9a-z]+)*|f16|bf16|f32|fp16)$'),
    '',
  );
}

final class MapGraph {
  MapGraph(this.files, this.i18n);

  /// A sign-in that only the agent's own program can tell (a keyring store,
  /// a moved home: DetailReaders.limitsSignedIn), beside [signedIn]'s files
  /// and keys.
  bool Function(Adapter adapter)? programSignIn;

  /// Why an agent keeps a skill folder that nothing here can take away.
  String Function(String command, String path)? skillWay;
  Object? _waysOf;
  String? _waysIn;
  final _ways = <String, String>{};
  final ScanFiles files;
  final ServiceI18n i18n;
  final nodes = <Map<String, dynamic>>[], edges = <Map<String, dynamic>>[];
  Map<String, dynamic> node(
    String id,
    int column,
    String label, {
    String detail = '',
    String kind = '',
    String icon = '',
    String font = '',
    bool dim = false,
    String status = '',
    String group = '',
    String ownProvider = '',
    bool ownLogin = false,
  }) {
    final existing = nodes.firstWhereOrNull((n) => n['id'] == id);
    if (existing != null) return existing;
    final value = {
      'id': id,
      'column': column,
      'label': label,
      'detail': detail,
      'kind': kind,
      'icon': icon,
      'icon_font': font,
      'dim': dim,
      'status': status,
      'group': group,
      'active': false,
      // Agents: the id of their own online provider (provider facts), the
      // one dragging the agent onto signs in to; "" for none.
      'own_provider': ownProvider,
      // Agents: the app can start their sign-in there (access.logins, as
      // Ask AI's own_clouds login); dropping one onto it is refused without.
      'own_login': ownLogin,
    };
    nodes.add(value);
    return value;
  }

  void link(
    String source,
    String target,
    String kind, {
    String failed = '',
    String dangling = '',
    String fixed = '',
  }) {
    if (edges.any((e) => e['source'] == source && e['target'] == target)) {
      return;
    }
    edges.add({
      'source': source,
      'target': target,
      'kind': kind,
      'failed': failed,
      'fixed': fixed,
      'dangling': dangling,
    });
  }

  /// An agent's sign-in to its own online provider is there: a key in the
  /// environment or a sign-in file (a stat, never a read). An adapter that
  /// names neither sign-in files nor keys cannot tell: signed in.
  bool signedIn(AgentRecord agent) {
    final access = agent.adapter.table('access');
    if ((access['files'] as List? ?? const []).isEmpty &&
        (access['env'] as List? ?? const []).isEmpty) {
      return true;
    }
    return credentialsPresent(
          access,
          files.identity.home,
          files.identity.environment,
        ) ||
        programSignIn?.call(agent.adapter) == true;
  }

  String providerName(String raw) =>
      mapOf(visibleProviderFacts['names'])[raw.trim().toLowerCase()]
          as String? ??
      raw.trim();

  /// The app's own program folder of an agent (install_ctl installed_folder):
  /// from the ~/.local/bin link up to `current`, when that folder is marked.
  String? ownFolder(String command) {
    final String target;
    try {
      target = Link(files.expand('~/.local/bin/$command')).targetSync();
    } on FileSystemException {
      return null;
    }
    var parent = p.dirname(target);
    while (parent != p.dirname(parent) && parent != '.') {
      if (p.basename(parent) == 'current') {
        final root = p.dirname(parent);
        return files.exists('$root/.maprisma') ||
                files.exists('$root/.ai-agents-map')
            ? root
            : null;
      }
      parent = p.dirname(parent);
    }
    return null;
  }

  List<String> choices(Adapter adapter, String current) {
    final models = adapter.table('models'), reader = models['reader'];
    final out = <String>[];
    if (reader == 'claude') out.addAll(['fable', 'opus', 'sonnet']);
    if (reader == 'codex') {
      final rows = files.json(
        '~/.codex/models_cache.json',
        limit: 4 * 1024 * 1024,
      )['models'];
      if (rows is List) {
        for (final row in rows.take(200)) {
          if (row is Map &&
              row['visibility'] == 'list' &&
              row['slug'] is String) {
            out.add(row['slug']);
          }
        }
      }
    }
    if (models['hook'] == true && adapter.command == 'dsh') {
      final text = files.text(dshProfile, limit: 2 * 1024 * 1024) ?? '';
      for (final e in dshProviders(text).entries) {
        final rows = mapOf(e.value)['models'];
        for (final row in rows is List ? rows : const []) {
          if (row is Map && row['id'] is String) {
            out.add('${e.key}/${row['id']}');
          }
        }
      }
      final folder = ownFolder('dsh');
      if (folder != null) {
        final packages = '$folder/current/node_modules/@deepseek-ai';
        out.addAll(
          dshBuiltinChoices(
            files.text('$packages/dsh-base/cordis.patch.yml', limit: 1 << 20) ??
                '',
            files.text(
                  '$packages/dsh-llm-deepseek/lib/index.js',
                  limit: 1 << 20,
                ) ??
                '',
          ),
        );
      }
    } else if (models['hook'] == true) {
      final config = adapter.command == 'hermes'
          ? yamlMap(files.text('~/.hermes/config.yaml') ?? '')
          : adapter.command == 'opencode'
          ? files.json('~/.config/opencode/opencode.json')
          : files.json('${adapter.facts['home'] ?? '~/.pi/agent'}/models.json');
      final providers = mapOf(config['providers'] ?? config['provider']);
      for (final provider in providers.entries.take(50)) {
        final names = mapOf(provider.value)['models'];
        if (names is Map) {
          out.addAll(
            names.keys.whereType<String>().map((n) => '${provider.key}/$n'),
          );
        }
        if (names is List) {
          for (final entry in names.take(200)) {
            final id = entry is Map ? entry['id'] : entry;
            if (id is String) out.add('${provider.key}/$id');
          }
        }
      }
    }
    final name = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:\-]{0,99}$'),
        qualified = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:\-/]{0,199}$');
    final valid = out
        .where((s) => name.hasMatch(s) || qualified.hasMatch(s))
        .take(800)
        .toList();
    if (current.isNotEmpty &&
        !valid.contains(current) &&
        (name.hasMatch(current) || qualified.hasMatch(current))) {
      valid.insert(0, current);
    }
    return valid;
  }

  Map<String, dynamic> failures() {
    final raw = files.json(
          '${files.identity.configDir}/failed-links.json',
          limit: 1024 * 1024,
          comments: false,
        ),
        result = <String, dynamic>{};
    final id = RegExp(r'^[a-z]+:[^|\x00-\x1f]{1,300}$');
    for (final entry in raw.entries.take(200)) {
      final pair = entry.key.split('|');
      if (pair.length != 2 || !pair.every(id.hasMatch) || entry.value is! Map) {
        continue;
      }
      final value = entry.value as Map, hints = value['hints'];
      if (!['provider', 'mcp', 'skills'].contains(value['kind']) ||
          hints is! List) {
        continue;
      }
      final clean = [
        for (final h in hints)
          if (h is Map &&
              ['error', 'warning', 'ok'].contains(h['level']) &&
              h['text'] is String)
            {'level': h['level'], 'text': boundedText(h['text'], 400)},
      ].take(12).toList();
      if (clean.isNotEmpty) {
        result[entry.key] = {
          'hints': clean,
          'applied': value['applied'] == true,
        };
      }
    }
    return result;
  }

  Map<String, dynamic> build(
    List<AgentRecord> agents,
    Map<String, AgentInfo> details,
    InventorySnapshot inv, {
    Map<String, List<String>> running = const {},
    Map<String, dynamic> activity = const {},
    List<String> layers = const [
      'agents',
      'online',
      'local',
      'models',
      'mcp',
      'skills',
    ],
    String animate = 'all',
    int modelsShown = 10,
    Map<String, String> providerModels = const {},
  }) {
    nodes.clear();
    edges.clear();
    final live = <String, List<String>>{},
        clouds = mapOf(visibleProviderFacts['cloud']),
        names = mapOf(visibleProviderFacts['connect_keys']);
    final runtimes = {for (final rt in inv.runtimes) rt.name: rt},
            // A local model an agent is set to: its name as the agent has it.
            labels =
            <String, String>{};
    String status(RuntimeRecord rt) => rt.running
        ? rt.serverOff
              ? 'noserver'
              : 'running'
        : rt.installed
        ? 'stopped'
        : 'missing';
    void runtime(RuntimeRecord rt) {
      node(
        'runtime:${rt.key}',
        2,
        rt.name,
        kind: 'runtime',
        detail: rt.serverOff
            ? '${rt.address} · ${i18n.text('server off')}'
            : rt.address,
        status: status(rt),
      );
    }

    final fail = failures();
    for (final agent in agents.where((a) => a.installed)) {
      final a = agent.toJson(),
          aid = 'agent:${agent.command}',
          instances = running[agent.command] ?? [],
          info = details[agent.command],
          own = clouds[agent.command] as String? ?? '';
      final runningText = instances.length == 1
          ? i18n.text('running')
          : i18n.text('{0} running').replaceAll('{0}', '${instances.length}');
      node(
        aid,
        1,
        a['name'],
        detail: instances.isEmpty
            ? agent.version
            : [
                agent.version,
                runningText,
              ].where((v) => v.isNotEmpty).join(' · '),
        kind: 'agent',
        icon: a['icon'],
        font: a['icon_font'],
        status: instances.isEmpty ? '' : 'running',
        // Made for a local LLM (its adapter connects one): the map's Local
        // agents card; the others are online agents.
        group: agent.adapter.table('local_llm').isEmpty ? '' : 'local',
        ownProvider: own.isEmpty ? '' : 'cloud:${own.toLowerCase()}',
        ownLogin:
            own.isNotEmpty &&
            (agent.adapter.table('access')['logins'] as List? ?? const [])
                .isNotEmpty,
      );
      var (model, modelProvider) = splitModel(info?.model ?? '');
      final local = <String, String>{};
      // A local provider set to a port its LLM no longer listens on.
      final stale = <String, RuntimeRecord>{};
      final providers = List<Map<String, dynamic>>.from(info?.providers ?? [])
        ..sort(
          (a, b) => (a['active'] == true ? 0 : 1).compareTo(
            b['active'] == true ? 0 : 1,
          ),
        );
      for (final provider in providers) {
        // Joined by its configured port to the runtime detected there.
        final rt = localRuntime(provider, inv.runtimes);
        if (rt != null) {
          local[provider['name']] = rt.name;
          runtime(rt);
          link(
            aid,
            'runtime:${rt.key}',
            provider['active'] == true ? 'uses' : 'available',
          );
        } else if (movedRuntime(provider, inv.runtimes) case final moved?) {
          stale['${provider['name']}'] = moved;
        }
      }
      // A model with no provider of its own, while the agent's one provider
      // is a local LLM (Claude Code with a local ANTHROPIC_BASE_URL): that
      // LLM's model, not one of the agent's own online provider.
      final active = providers.where((p) => p['active'] == true).toList();
      if (modelProvider.isEmpty &&
          active.length == 1 &&
          (local.containsKey(active.single['name']) ||
              stale.containsKey(active.single['name']))) {
        modelProvider = active.single['name'] as String;
      }
      // Also a provider whose LLM moved to another port: a broken line to it.
      final dangling =
          stale[modelProvider] ??
          inv.runtimes.firstWhereOrNull(
            (rt) =>
                rt.installed &&
                modelProvider.isNotEmpty &&
                names[rt.key] == modelProvider &&
                !local.containsKey(modelProvider),
          );
      // An agent with no local-LLM planner (Claude Code, Codex: the address
      // is in its own settings) cannot be repaired or disconnected here: the
      // line says where to change it instead.
      String unfixable(RuntimeRecord rt) =>
          agent.adapter.facts.containsKey('local_llm')
          ? ''
          : i18n
                .text(
                  'its address is set in its own settings: change it there to {0}',
                )
                .replaceAll('{0}', rt.address);
      if (dangling != null) {
        runtime(dangling);
        link(
          aid,
          'runtime:${dangling.key}',
          'failed',
          failed: 'error',
          dangling: model,
          fixed: unfixable(dangling),
        );
      }
      // Every other local provider whose LLM moved (an inactive one too):
      // a broken line, no default; Repair rewrites its address.
      for (final moved in stale.values) {
        if (identical(moved, dangling)) continue;
        runtime(moved);
        link(
          aid,
          'runtime:${moved.key}',
          'failed',
          failed: 'error',
          fixed: unfixable(moved),
        );
      }
      var cloud = '';
      if (modelProvider.isNotEmpty &&
          !local.containsKey(modelProvider) &&
          dangling == null) {
        cloud = providerName(modelProvider);
      } else if (modelProvider.isEmpty) {
        cloud = clouds[agent.command] as String? ?? '';
      }
      if (clouds.containsKey(agent.command) &&
          local.isEmpty &&
          stale.isEmpty &&
          cloud.isEmpty) {
        cloud = clouds[agent.command];
      }
      if (cloud.isNotEmpty) {
        final cid = 'cloud:${cloud.toLowerCase()}';
        node(cid, 2, cloud, kind: 'cloud');
        // Its own provider, while it is not signed in: one it can use
        // (drawing the agent onto it signs in), not one it uses.
        link(aid, cid, cloud == own && !signedIn(agent) ? 'available' : 'uses');
        if (model.isNotEmpty) {
          final mid = 'model:$cid:${model.toLowerCase()}';
          node(mid, 3, model, kind: 'model');
          link(cid, mid, 'serves');
          link(aid, mid, 'default');
        }
        for (final other in choices(agent.adapter, model)) {
          if (other != model && !other.contains('/')) {
            final mid = 'model:$cid:${other.toLowerCase()}';
            node(mid, 3, other, kind: 'model');
            link(cid, mid, 'serves');
          }
        }
      } else if (model.isNotEmpty && local.containsKey(modelProvider)) {
        final mid =
            'model:runtime:${runtimes[local[modelProvider]]!.key}:${model.toLowerCase()}';
        labels[mid] = model;
        link(aid, mid, 'default');
      }
      for (final choice in choices(
        agent.adapter,
        model.isNotEmpty && modelProvider.isNotEmpty
            ? '$modelProvider/$model'
            : '',
      )) {
        if (!choice.contains('/')) continue;
        final at = choice.indexOf('/'),
            provider = choice.substring(0, at),
            name = choice.substring(at + 1);
        if (names.values
                .map((v) => '$v'.toLowerCase())
                .contains(provider.toLowerCase()) ||
            [
              ...local.keys,
              ...stale.keys,
            ].map((v) => v.toLowerCase()).contains(provider.toLowerCase())) {
          continue;
        }
        final service = providerName(provider),
            cid = 'cloud:${providerName(provider).toLowerCase()}';
        node(cid, 2, service, kind: 'cloud');
        link(aid, cid, 'offer');
        final mid = 'model:$cid:${name.toLowerCase()}';
        node(mid, 3, name, kind: 'model');
        link(cid, mid, 'serves');
      }
      for (final chosen in instances) {
        var (name, provider) = chosen.isEmpty
            ? (model, modelProvider)
            : splitModel(chosen);
        if (name.isEmpty) continue;
        // `--model qwen` names no provider: the agent's configured one.
        if (provider.isEmpty) provider = modelProvider;
        String mid;
        if (local.containsKey(provider)) {
          mid =
              'model:runtime:${runtimes[local[provider]]!.key}:${name.toLowerCase()}';
        } else if (stale.containsKey(provider) ||
            dangling != null && provider == modelProvider) {
          // Its local LLM moved (or its provider is gone): only the broken
          // line, no online service.
          continue;
        } else {
          final service = provider.isEmpty ? cloud : providerName(provider);
          if (service.isEmpty) continue;
          final cid = 'cloud:${service.toLowerCase()}';
          node(cid, 2, service, kind: 'cloud');
          mid = 'model:$cid:${name.toLowerCase()}';
          node(mid, 3, name, kind: 'model');
          link(cid, mid, 'serves');
        }
        final users = live.putIfAbsent(mid, () => []);
        if (!users.contains(a['name'])) users.add(a['name']);
      }
      for (final name in inv.agentMcp[agent.command] ?? []) {
        // This agent's server of that name (another of the same name is
        // another box, name~2).
        final server =
            inv.mcp.firstWhereOrNull(
              (s) =>
                  s['name'] == name &&
                  (s['agents'] as List).contains(agent.command),
            ) ??
            inv.mcp.firstWhereOrNull((s) => s['name'] == name);
        final id = 'mcp:${server?['id'] ?? name}';
        node(
          id,
          0,
          name,
          kind: 'mcp',
          detail: server?['target'] ?? '',
          group: server?['kind'] == 'url' ? 'online' : '',
        );
        link(aid, id, 'mcp');
      }
      for (final path in inv.agentSkills[agent.command] ?? []) {
        final skills = inv.skillSets.firstWhereOrNull((s) => s['path'] == path);
        final count = (skills?['skills'] as List? ?? []).length;
        final id = 'skills:$path';
        node(
          id,
          0,
          path,
          kind: 'skills',
          detail: i18n
              .plural('1 skill', '{0} skills', count)
              .replaceAll('{0}', '$count'),
        );
        // Reading folders per line is for a new inventory, not each scan.
        if (!identical(inv, _waysOf) || i18n.language != _waysIn) {
          _waysOf = inv;
          _waysIn = i18n.language;
          _ways.clear();
        }
        link(
          aid,
          id,
          'skills',
          fixed: _ways.putIfAbsent(
            '${agent.command}\n$path',
            () => skillWay?.call(agent.command, path) ?? '',
          ),
        );
      }
    }
    // A known server without agents stays, to draw a line to it again.
    for (final server in inv.mcp) {
      node(
        'mcp:${server['id'] ?? server['name']}',
        0,
        server['name'] as String,
        kind: 'mcp',
        detail: server['target'] ?? '',
        group: server['kind'] == 'url' ? 'online' : '',
        dim: true,
      );
    }
    // What an agent is set to or runs, and each provider's chosen model:
    // drawn even past the first [modelsShown] models.
    final wanted = {
      for (final e in edges)
        if (e['kind'] == 'default') '${e['target']}',
      ...live.keys,
      ...providerModels.values,
    };
    for (final rt in inv.runtimes.where((r) => r.installed)) {
      runtime(rt);
      final rid = 'runtime:${rt.key}';
      final keys = {
        for (final id in wanted)
          if (id.startsWith('model:$rid:'))
            graphModelKey(id.substring('model:$rid:'.length)),
      };
      final shown = [
        ...rt.models.take(modelsShown),
        for (final model in rt.models.skip(modelsShown))
          if (keys.contains(graphModelKey(model))) model,
      ];
      for (final model in shown) {
        final id = 'model:$rid:${model.toLowerCase()}';
        node(
          id,
          3,
          model,
          kind: 'model',
          group: rt.modelsDir.isEmpty ? rt.name : rt.modelsDir,
        );
        link(rid, id, 'serves');
      }
      if (rt.models.length > shown.length) {
        final id = 'more:$rid';
        node(
          id,
          3,
          i18n
              .text('+{0} more')
              .replaceAll('{0}', '${rt.models.length - shown.length}'),
          kind: 'more',
          dim: true,
          group: rt.modelsDir.isEmpty ? rt.name : rt.modelsDir,
        );
        link(rid, id, 'serves');
      }
    }
    // Reused model folders no local LLM lists: a folder card of their own.
    for (final folder in inv.modelFolders) {
      final path = folder['path'] as String,
          models = (folder['models'] as List).cast<String>();
      for (final model in models.take(modelsShown)) {
        node(
          'model:folder:$path:${model.toLowerCase()}',
          3,
          model,
          kind: 'model',
          group: path,
        );
      }
      if (models.length > modelsShown) {
        node(
          'more:folder:$path',
          3,
          i18n
              .text('+{0} more')
              .replaceAll('{0}', '${models.length - modelsShown}'),
          kind: 'more',
          dim: true,
          group: path,
        );
      }
    }
    final ids = nodes.map((n) => n['id']).toSet(), byKey = <String, String>{};
    for (final n in nodes) {
      if (n['kind'] == 'model' &&
          (n['id'] as String).startsWith('model:runtime:')) {
        byKey.putIfAbsent(
          '${(n['id'] as String).split(':')[2]}|${graphModelKey(n['label'])}',
          () => n['id'],
        );
      }
    }
    String listed(String id) {
      if (ids.contains(id) || !id.startsWith('model:runtime:')) return id;
      final parts = id.split(':');
      return byKey['${parts[2]}|${graphModelKey(parts.skip(3).join(':'))}'] ??
          id;
    }

    for (final e in edges) {
      e['target'] = listed(e['target']);
    }
    // An agent set to a model its local LLM no longer has: the model stays,
    // marked missing, so its line and the way to repair it stay too.
    for (final e in edges.where((e) => e['kind'] == 'default').toList()) {
      final id = e['target'] as String;
      if (ids.contains(id) || !id.startsWith('model:runtime:')) continue;
      final rt = inv.runtimes.firstWhereOrNull(
        (r) => r.key == id.split(':')[2],
      );
      if (rt == null || !ids.contains('runtime:${rt.key}')) continue;
      node(
        id,
        3,
        labels[id] ?? id.split(':').skip(3).join(':'),
        kind: 'model',
        status: 'missing',
        detail: i18n.text('This model is no longer on this PC.'),
        group: rt.modelsDir.isEmpty ? rt.name : rt.modelsDir,
      );
      link('runtime:${rt.key}', id, 'serves');
      ids.add(id);
    }
    for (final id in live.keys.toList()) {
      final found = listed(id);
      if (found != id) {
        final names = live.remove(id)!;
        live
            .putIfAbsent(found, () => [])
            .addAll(names.where((n) => !(live[found] ?? []).contains(n)));
      }
    }
    final chosen = edges
        .where((e) => e['kind'] == 'default')
        .map((e) => e['target'])
        .toSet();
    for (final n in nodes) {
      if (live.containsKey(n['id'])) {
        n['status'] = 'running';
        n['detail'] = i18n
            .text('in use · {0}')
            .replaceAll('{0}', live[n['id']]!.join(', '));
      }
      n['active'] =
          n['kind'] == 'model' &&
          (chosen.contains(n['id']) || live.containsKey(n['id']));
    }
    edges.removeWhere(
      (e) => !ids.contains(e['source']) || !ids.contains(e['target']),
    );
    for (final entry in fail.entries) {
      final parts = entry.key.split('|');
      if (!ids.contains(parts[0]) || !ids.contains(parts[1])) continue;
      final hints = entry.value['hints'] as List;
      final level = hints.any((h) => h['level'] == 'error')
          ? 'error'
          : hints.any((h) => h['level'] == 'warning')
          ? 'warning'
          : 'ok';
      if (level == 'ok') continue;
      link(parts[0], parts[1], 'failed');
      edges.firstWhere(
        (e) => e['source'] == parts[0] && e['target'] == parts[1],
      )['failed'] = level;
    }
    void place(int column, int neighbour) {
      final index = {
        for (final n in nodes.where((n) => n['column'] == neighbour))
          n['id']: nodes
              .where((n) => n['column'] == neighbour)
              .toList()
              .indexOf(n),
      };
      final selected = nodes.where((n) => n['column'] == column).toList();
      final original = {
        for (var i = 0; i < selected.length; i++) selected[i]['id']: i,
      };
      double weight(Map n) {
        final linked = <int>[];
        for (final e in edges.where((e) => e['kind'] != 'default')) {
          if (e['target'] == n['id'] && index.containsKey(e['source'])) {
            linked.add(index[e['source']]!);
          }
          if (e['source'] == n['id'] && index.containsKey(e['target'])) {
            linked.add(index[e['target']]!);
          }
        }
        return linked.isEmpty
            ? index.length.toDouble()
            : linked.reduce((a, b) => a + b) / linked.length;
      }

      selected.sort((a, b) {
        final w = weight(a).compareTo(weight(b));
        return w != 0 ? w : original[a['id']]!.compareTo(original[b['id']]!);
      });
      nodes.removeWhere((n) => n['column'] == column);
      nodes.addAll(selected);
    }

    place(0, 1);
    final left = nodes.where((n) => n['column'] == 0).toList();
    final mcps = left.where((n) => n['kind'] == 'mcp'),
        other = left.where((n) => n['kind'] != 'mcp');
    nodes.removeWhere((n) => n['column'] == 0);
    nodes.addAll([...mcps, ...other]);
    place(2, 1);
    place(3, 2);
    final enabled = layers
        .where(
          (l) => [
            'agents',
            'online',
            'local',
            'models',
            'mcp',
            'skills',
          ].contains(l),
        )
        .toSet();
    final shown = enabled
        .where(
          (l) => l == 'models'
              ? enabled.contains('online') || enabled.contains('local')
              : ['mcp', 'skills'].contains(l)
              ? enabled.contains('agents')
              : true,
        )
        .toSet();
    const layerOf = {
      'agent': 'agents',
      'cloud': 'online',
      'runtime': 'local',
      'model': 'models',
      'more': 'models',
      'mcp': 'mcp',
      'skills': 'skills',
      'subagent': 'agents',
    };
    final hidden = nodes
        .where((n) => !shown.contains(layerOf[n['kind']]))
        .map((n) => n['id'])
        .toSet();
    for (final kind in ['models', 'mcp', 'skills']) {
      for (final n in nodes.where(
        (n) => layerOf[n['kind']] == kind && !hidden.contains(n['id']),
      )) {
        final linked = edges
            .where(
              (e) =>
                  e['target'] == n['id'] &&
                  (kind == 'models'
                      ? e['kind'] == 'serves'
                      : e['kind'] == kind),
            )
            .map((e) => e['source'])
            .toList();
        if (linked.isNotEmpty && linked.every(hidden.contains)) {
          hidden.add(n['id']);
        }
      }
    }
    final working = activity.entries
        .where((e) => e.value is Map && e.value['working'] == true)
        .map((e) => 'agent:${e.key}')
        .toSet();
    final activeModels = edges
        .where((e) => working.contains(e['source']) && e['kind'] == 'default')
        .map((e) => e['target'])
        .toSet();
    final publicEdges = <Map<String, dynamic>>[];
    for (final edge in edges) {
      if (hidden.contains(edge['source']) || hidden.contains(edge['target'])) {
        continue;
      }
      final active =
          working.contains(edge['source']) &&
              ['uses', 'mcp', 'skills', 'default'].contains(edge['kind']) ||
          edge['kind'] == 'serves' && activeModels.contains(edge['target']);
      final entry = fail['${edge['source']}|${edge['target']}'];
      final row = {
        ...edge,
        'active': animate != 'off' && active,
        'activity': active ? 'agent' : '',
      };
      if (entry != null) {
        row['hints'] = entry['hints'];
        row['applied'] = entry['applied'];
      } else if (edge['kind'] == 'failed' && edge['fixed'] == '') {
        // A broken local line of the map's own (no recorded failure).
        row['hints'] = [
          {
            'level': 'error',
            'text': edge['dangling'] != ''
                ? 'The configured model has no provider connection. Repair or remove this connection.'
                : 'This local LLM now listens on another port. Repair or remove this connection.',
          },
        ];
      }
      publicEdges.add(row);
    }
    return {
      'activity': activity,
      'nodes': nodes.where((n) => !hidden.contains(n['id'])).toList(),
      'edges': publicEdges,
    };
  }
}
