part of 'core.dart';

extension ProviderConfigurationRoutes on CoreService {
  List<Map<String, dynamic>> configHelpers() => [
    for (final h in smartHelpers())
      {
        ...h,
        'web_search':
            h['local'] != true &&
            addons.adapters.any(
              (a) => a.command == h['command'] && smartHasResearch(a),
            ),
      },
  ];
  Map<String, dynamic> configRoute(String method, Map<String, dynamic> params) {
    final allowed = switch (method) {
      'models.config' => const {'key', 'model', 'profile'},
      'models.config_check' => const {'key', 'model', 'values'},
      'models.config_preview' => const {
        'key',
        'model',
        'values',
        'config_proposal',
      },
      _ => const {'key', 'model', 'profile', 'command', 'focus', 'web_search'},
    };
    if (params.keys.any((k) => !allowed.contains(k)) ||
        params['key'] is! String ||
        params['model'] != null && params['model'] is! String ||
        params['profile'] != null &&
            !configProfiles.contains(params['profile']) ||
        params['web_search'] != null && params['web_search'] is! bool) {
      throw const FormatException('Invalid configuration request');
    }
    final key = params['key'] as String,
        profile = params['profile'] as String? ?? 'balanced';
    if (!configurable(key)) {
      throw const FormatException('Unknown local provider');
    }
    RuntimeRecord runtime() {
      final rt = ProviderScans(
        reads.files,
      ).scan().where((r) => r.key == key && r.installed).firstOrNull;
      if (rt == null) throw const FormatException('Unknown local provider');
      return rt;
    }

    final store = ProviderConfigFiles(reads.files, config);
    if (method == 'models.config') {
      runtime();
      return tasks.start(method, params, (facts) {
        configCache.keep(key, facts);
        final model = store.select(facts, params['model'] as String?);
        return {
          ...store.view(facts, model, profile),
          'helpers': configHelpers(),
          'focus': taskFocus(reads.map, {'runtime': key}),
        };
      });
    }
    final facts = configCache.get(key);
    if (facts == null) return {'error': 'stale'};
    final model = store.select(facts, params['model'] as String?);
    if (method == 'models.config_ask') {
      final command = params['command'], focus = params['focus'] ?? '';
      if (command is! String ||
          focus is! String ||
          focus.runes.length > 500 ||
          !configHelpers().any(
            (h) =>
                h['command'] == command &&
                (params['web_search'] != true || h['web_search'] == true),
          )) {
        throw const FormatException('This helper is not ready');
      }
      final helper = command == 'local-helper' ? localHelpers().$3 : null;
      if (command == 'local-helper' && helper == null) {
        throw const FormatException('This helper is not ready');
      }
      return tasks.startPrivate(
        method,
        utf8.encode(
          jsonEncode({
            'command': helper?.agent ?? command,
            'facts': {...facts, 'writable': store.canWrite(facts, model)},
            'model': model,
            'profile': profile,
            'focus': focus,
            'web_search': params['web_search'] == true,
            'language': i18n.language,
            'settings_path': identity.settingsPath,
            if (helper != null)
              'helper': {
                'provider': helper.provider,
                'runtime': helper.runtime,
                'model': helper.model,
              },
          }),
        ),
        (answer) {
          if (answer['error'] != null) return answer;
          final values = Map<String, dynamic>.from(answer['values'] as Map);
          return {
            ...answer,
            'config_proposal': configCache.propose(key, model, values),
          };
        },
      );
    }
    final values = params['values'];
    if (values is! Map ||
        values.length > 32 ||
        values.keys.any((k) => k is! String) ||
        values.values.any(
          (v) => v != null && v is! String && v is! num && v is! bool,
        )) {
      throw const FormatException('Invalid configuration values');
    }
    final check = ConfigMath(facts, model).validate(values);
    if (method == 'models.config_check') {
      final snippet =
          facts['writable'] != true && (check['errors'] as List).isEmpty
          ? store.snippet(
              facts,
              model,
              ConfigMath(facts, model).effective(values),
            )
          : null;
      return {...check, 'snippet': ?snippet};
    }
    final proposal = params['config_proposal'];
    if (proposal != null) {
      if (proposal is! String) {
        throw const FormatException('Invalid configuration proposal');
      }
      configCache.check(proposal, key, model, values);
    }
    if ((check['errors'] as List).isNotEmpty) return {'ok': false, ...check};
    if (!store.canWrite(facts, model)) {
      throw const FormatException('This provider offers configuration advice');
    }
    final rt = runtime();
    final changes = store.changes(rt, model, values);
    _configAgentContexts(rt, facts, model, values, changes);
    return {
      'ok': true,
      ...connections.keep(Plan(rt.name, rt.key, '', changes: changes)),
      'warnings': check['warnings'],
      'restart': facts['restart'],
      'item': rt.name,
      'focus': taskFocus(reads.map, {'runtime': key}),
    };
  }

  void _configAgentContexts(
    RuntimeRecord rt,
    Map facts,
    String model,
    Map values,
    List<Change> changes,
  ) {
    final schema = (facts['schema'] as List).cast<Map>();
    final contextId = schema.where((s) => s['role'] == 'context').first['id'];
    final parallelId = schema
        .where((s) => s['role'] == 'parallel')
        .firstOrNull?['id'];
    final total =
        configWriter(facts) == 'ini_defaults' ||
        configWriter(facts) == 'jan_pair';
    if (!values.containsKey(contextId) &&
        (!total || parallelId == null || !values.containsKey(parallelId))) {
      return;
    }
    final contexts = <String, int>{};
    var changed =
        total && values.containsKey(parallelId) && facts['configured'] is Map;
    for (final m in (facts['models'] as List).cast<Map>()) {
      final name = '${m['name']}', math = ConfigMath(facts, name);
      final before = math.effective(const {});
      final affected =
          schema.first['scope'] == 'global' || model == '*' || model == name;
      // Defaults apply only to keys without an explicit per-model override.
      final overrides =
          (facts['overrides'] as Map?)?[name] as List? ?? const [];
      final next = math.effective({
        if (affected)
          for (final e in values.entries)
            if (model != '*' || !overrides.contains(e.key)) e.key: e.value,
      });
      int tokens(Map v) =>
          configInt(v[contextId]) ~/
          (total ? configInt(v[parallelId], 1).clamp(1, 256) : 1);
      if (tokens(before) != tokens(next)) changed = true;
      if (tokens(next) > 0) contexts[name] = tokens(next);
    }
    if (!changed) return;
    final local = LocalLlm(reads.files);
    for (final adapter in addons.adapters) {
      if (!llm.supported(adapter.command) ||
          !local.connected(adapter, rt.key)) {
        continue;
      }
      final paths = llm.files(adapter.command),
          old = [
            for (final path in llm.files(adapter.command)) config.read(path),
          ];
      final next = llm.transform(
        adapter.command,
        old,
        rt,
        '',
        false,
        false,
        contexts,
      );
      for (var i = 0; i < paths.length; i++) {
        if (next[i] != old[i]) changes.add(Change(paths[i], old[i], next[i]));
      }
    }
  }

  Map<String, dynamic> providerConfigControl(
    String method,
    Map<String, dynamic> params,
  ) {
    final model = params['model'];
    if (params['key'] is! String ||
        params.length != (method == 'providers.restart' ? 1 : 2) ||
        method == 'providers.reload_model' &&
            (model is! String || !modelKey.hasMatch(model))) {
      throw const FormatException('Invalid provider operation');
    }
    return tasks.start(method, params);
  }
}
