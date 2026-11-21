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
    if (params.length != 3 ||
        params['plugin'] is! String ||
        params['operation'] is! String ||
        params['params'] is! Map<String, dynamic>) {
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
            'delete',
            'plan',
            'review',
            'run',
            'pause',
            'continue',
          }.contains(operation) =>
        operation,
      _ => throw ServiceError('feature_operation_unknown'),
    };
    return featurePlugins.call(id, method, arguments, () {
      if (id == 'ai-project-center') {
        return projectCenterCall(method, arguments);
      }
      return dispatch(method, arguments);
    });
  }

  Future<Map<String, dynamic>> projectCenterCall(
    String operation,
    Map<String, dynamic> params,
  ) => projectCenter.call(operation, params);

  Future<Map<String, dynamic>> featureSummary() => featurePlugins.call(
    'ai-project-center',
    '@summary',
    {},
    () => {...projectCenter.summary(), 'connected': true},
  );

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
