part of 'core.dart';

extension FeatureRoutes on CoreService {
  List<Map<String, dynamic>> projectAgentProfiles() {
    addons.reload(enabledAddons());
    reads.catalog.adapters = addons.adapters;
    return [
      for (final agent in reads.catalog.scan())
        if (agent.adapter.table('project').isEmpty)
          // Known, but without a managed profile: never a candidate, yet a
          // request naming it must be answered with an explained exclusion.
          <String, dynamic>{
            'id': agent.command,
            'name': agent.name,
            'aliases': [agent.adapter.label],
            'installed': agent.installed,
            'project_supported': false,
          }
        else
          (() {
            final localProviders = agent.installed
                ? [
                    for (final provider
                        in reads.details.read(agent.adapter).providers)
                      if (provider['local'] == true)
                        '${provider['id'] ?? provider['name']}',
                  ]
                : <String>[];
            return <String, dynamic>{
              'id': agent.command,
              'name': agent.name,
              'aliases': [agent.adapter.label],
              'installed': agent.installed,
              'plan_argv': agent.adapter.table('project')['plan'],
              'run_argv': agent.adapter.table('project')['run'],
              'setup_argv': agent.adapter.table('project')['setup'],
              'access_modes':
                  agent.adapter.table('project')['access_modes'] ??
                  ['read-only', 'project-edit'],
              'models': agent.installed
                  ? edits.online
                        .choices(agent.adapter)
                        .where(
                          (model) => !localProviders.any(
                            (provider) => model.startsWith('$provider/'),
                          ),
                        )
                        .toList()
                  : [],
              'local_providers': localProviders,
              'permissions': agent.adapter.table('project')['permissions'],
              'native_subagents':
                  agent.adapter.table('project')['native_subagents'] == true,
              'model_option': agent.adapter.table('project')['model_option'],
              'provider_option': agent.adapter.table(
                'project',
              )['provider_option'],
              'subagent_option': agent.adapter.table(
                'project',
              )['subagent_option'],
              'subagent_definitions':
                  agent.adapter.table('project')['subagent_definitions'] ?? {},
            };
          })(),
    ];
  }

  /// Reuse the map's detected connections and model catalog. No endpoint or
  /// credential data crosses the feature boundary, and no defaults are written.
  List<Map<String, dynamic>> projectRuntimeProfiles() {
    addons.reload(enabledAddons());
    reads.catalog.adapters = addons.adapters;
    final runtimes = reads.inventory.providers.scan();
    final agents = <Map<String, dynamic>>[];
    for (final agent in reads.catalog.scan()) {
      if (!agent.installed ||
          agent.adapter.table('project')['provider_option'] is! String) {
        continue;
      }
      agents.add({
        'id': agent.command,
        'models': edits.online.choices(agent.adapter),
        'providers': reads.details.read(agent.adapter).providers,
      });
    }
    return projectRuntimeFacts(runtimes, agents);
  }

  Future<Map<String, dynamic>> featureCall(Map<String, dynamic> params) async {
    final refresh = params['refresh'];
    if (params.length != (params.containsKey('refresh') ? 4 : 3) ||
        params['plugin'] is! String ||
        params['operation'] is! String ||
        params['params'] is! Map<String, dynamic> ||
        (params.containsKey('refresh') && refresh is! bool)) {
      throw const FormatException('Invalid feature request');
    }

    final id = params['plugin'] as String;
    final operation = params['operation'] as String;
    final arguments = params['params'] as Map<String, dynamic>;
    if (!featureIds.contains(id)) throw ServiceError('feature_unknown');
    final method = switch (id) {
      'reports'
          when const {
            'helpers',
            'generate',
            'save',
            'list',
            'get',
            'update',
            'delete',
            'move_aside',
          }.contains(operation) =>
        'reports.$operation',
      'ask-ai'
          when const {
            'helpers',
            'ask',
            'review',
            'run',
            'connect',
            'plan',
          }.contains(operation) =>
        'map.smart_$operation',
      'ai-project-center'
          when const {
            'profiles',
            'setup',
            'setup_apply',
            'summary',
            'list',
            'get',
            'save',
            'move',
            'set_importance',
            'delete',
            'plan',
            'review',
            'run',
            'pause',
            'continue',
            'message',
            'message_drop',
          }.contains(operation) =>
        operation,
      _ => throw ServiceError('feature_operation_unknown'),
    };
    // Consumed here, never forwarded (and only for a valid call): the user
    // asked for fresh data, so the call carries the grown generation.
    if (refresh == true) growDiscovery();
    final result = await featurePlugins.call(
      id,
      method,
      arguments,
      () {
        if (id == 'ai-project-center') {
          return projectCenterCall(method, arguments);
        }
        return dispatch(method, arguments);
      },
      context: id == 'ask-ai'
          ? askAiHostContext
          : id == 'ai-project-center'
          ? projectCenterHostContext
          : null,
    );
    // An Ask AI action that changes the map's facts (run directly).
    if (id == 'ask-ai' && CoreService.discoveryRoutes.contains(method)) {
      growDiscovery();
    }
    // The first answer the Projects tab reads says which backend it is.
    return id == 'ai-project-center' && method == 'list'
        ? {...result, ..._projectCenterMeta()}
        : result;
  }

  Future<Map<String, dynamic>> projectCenterCall(
    String operation,
    Map<String, dynamic> params,
  ) {
    projectCenter.discoveryGeneration = discoveryGeneration;
    return projectCenter.call(operation, params);
  }

  /// What the Project Center backend needs from the host with each request.
  Map<String, dynamic> projectCenterHostContext() => {
    'generation': discoveryGeneration,
  };

  /// The negotiated API and capabilities of the Project Center backend,
  /// added by the host (an api-1 backend sends neither).
  Map<String, dynamic> _projectCenterMeta() => {
    'api': featurePlugins.negotiatedApi('ai-project-center'),
    'capabilities': featurePlugins.capabilities('ai-project-center'),
  };

  /// The indicator's counts. While the AI Project Center has stored nothing
  /// yet and is not running, there is nothing to count: its backend is not
  /// started just for the 2-second poll.
  Future<Map<String, dynamic>> featureSummary() async {
    if (_projectCenter == null &&
        !featurePlugins.closing &&
        !featurePlugins.tracked('ai-project-center') &&
        FileSystemEntity.typeSync(
              p.join(identity.dataDir, 'ai-project-center', 'projects.json'),
              followLinks: false,
            ) ==
            FileSystemEntityType.notFound) {
      return Future.value({
        'running': 0,
        'pausing': 0,
        'waiting': 0,
        'attention': 0,
        'attention_projects': 0,
        'needs_you': 0,
        'ready': 0,
        'drafts': 0,
        'finished': 0,
        'total': 0,
        'by_agent': <String, int>{},
        'connected': true,
        'api': null,
        'capabilities': null,
      });
    }
    final summary = await featurePlugins.call(
      'ai-project-center',
      '@summary',
      {},
      () {
        projectCenter.discoveryGeneration = discoveryGeneration;
        return {...projectCenter.summary(), 'connected': true};
      },
      context: projectCenterHostContext,
    );
    return {...summary, ..._projectCenterMeta()};
  }

  /// Grows the discovery generation: features rebuild their cached profile
  /// and runtime snapshots on their next request.
  void growDiscovery() => discoveryGeneration++;

  Future<void> shutdownFeatures() async {
    final center = _projectCenter;
    if (center != null) {
      await center.shutdown();
      // Released: should closing be aborted later, the next call reopens it.
      if (_projectCenter == center) _projectCenter = null;
    }
    await featurePlugins.shutdown();
  }
}
