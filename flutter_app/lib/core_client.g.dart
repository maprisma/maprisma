// Generated from packages/maprisma_core/protocol/routes.json by tools/protocol.py client.
// Do not edit by hand.

import 'service_transport.dart';

class _CallTransport implements ServiceTransport {
  const _CallTransport(this._call);

  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
  _call;

  @override
  bool get isConnected => true;

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) => _call(method, params);

  @override
  void dispose() {}

  @override
  Future<void> shutdown() async {}
}

class CoreClient {
  const CoreClient(this.transport);

  CoreClient.fromCall(
    Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) call,
  ) : transport = _CallTransport(call);

  final ServiceTransport transport;

  Future<Map<String, dynamic>> addonsCatalog([
    Map<String, dynamic> params = const {},
  ]) => transport.call('addons.catalog', params);

  Future<Map<String, dynamic>> addonsEnableFound({required Object? ids}) =>
      transport.call('addons.enable_found', {'ids': ids});

  Future<Map<String, dynamic>> addonsFileInstall([
    Map<String, dynamic> params = const {},
  ]) => transport.call('addons.file_install', params);

  Future<Map<String, dynamic>> addonsFilePreview({required Object? path}) =>
      transport.call('addons.file_preview', {'path': path});

  Future<Map<String, dynamic>> addonsHints([
    Map<String, dynamic> params = const {},
  ]) => transport.call('addons.hints', params);

  Future<Map<String, dynamic>> addonsInstall([
    Map<String, dynamic> params = const {},
  ]) => transport.call('addons.install', params);

  Future<Map<String, dynamic>> addonsList([
    Map<String, dynamic> params = const {},
  ]) => transport.call('addons.list', params);

  Future<Map<String, dynamic>> addonsRemoveApply({required Object? preview}) =>
      transport.call('addons.remove_apply', {'preview': preview});

  Future<Map<String, dynamic>> addonsRemovePreview({required Object? id}) =>
      transport.call('addons.remove_preview', {'id': id});

  Future<Map<String, dynamic>> addonsRemoveUndo({required Object? undo}) =>
      transport.call('addons.remove_undo', {'undo': undo});

  Future<Map<String, dynamic>> addonsSetEnabled({
    required Object? enabled,
    required Object? id,
  }) => transport.call('addons.set_enabled', {'enabled': enabled, 'id': id});

  Future<Map<String, dynamic>> agentsActionApply({required Object? preview}) =>
      transport.call('agents.action_apply', {'preview': preview});

  Future<Map<String, dynamic>> agentsActionPreview({
    required Object? action,
    required Object? command,
    Object? kind,
    Object? login,
  }) => transport.call('agents.action_preview', {
    'action': action,
    'command': command,
    'kind': ?kind,
    'login': ?login,
  });

  Future<Map<String, dynamic>> agentsActivity({required Object? command}) =>
      transport.call('agents.activity', {'command': command});

  Future<Map<String, dynamic>> agentsCosts({required String command}) =>
      transport.call('agents.costs', {'command': command});

  Future<Map<String, dynamic>> agentsDetails({required Object? command}) =>
      transport.call('agents.details', {'command': command});

  Future<Map<String, dynamic>> agentsHaltApply({required Object? preview}) =>
      transport.call('agents.halt_apply', {'preview': preview});

  Future<Map<String, dynamic>> agentsHaltPreview({required Object? command}) =>
      transport.call('agents.halt_preview', {'command': command});

  Future<Map<String, dynamic>> agentsHealth([
    Map<String, dynamic> params = const {},
  ]) => transport.call('agents.health', params);

  Future<Map<String, dynamic>> agentsKeyApply({
    required Object? key,
    required Object? preview,
  }) => transport.call('agents.key_apply', {'key': key, 'preview': preview});

  Future<Map<String, dynamic>> agentsKeyPreview({required Object? command}) =>
      transport.call('agents.key_preview', {'command': command});

  Future<Map<String, dynamic>> agentsProjects({required String command}) =>
      transport.call('agents.projects', {'command': command});

  Future<Map<String, dynamic>> agentsSecurity({required Object? command}) =>
      transport.call('agents.security', {'command': command});

  Future<Map<String, dynamic>> agentsSecurityPreview([
    Map<String, dynamic> params = const {},
  ]) => transport.call('agents.security_preview', params);

  Future<Map<String, dynamic>> agentsTraffic([
    Map<String, dynamic> params = const {},
  ]) => transport.call('agents.traffic', params);

  Future<Map<String, dynamic>> agentsUsageRefresh({required Object? command}) =>
      transport.call('agents.usage_refresh', {'command': command});

  Future<Map<String, dynamic>> appIdentity([
    Map<String, dynamic> params = const {},
  ]) => transport.call('app.identity', params);

  Future<Map<String, dynamic>> appSettingsChanged([
    Map<String, dynamic> params = const {},
  ]) => transport.call('app.settings_changed', params);

  Future<Map<String, dynamic>> appSnapshot([
    Map<String, dynamic> params = const {},
  ]) => transport.call('app.snapshot', params);

  Future<Map<String, dynamic>> appTheme([
    Map<String, dynamic> params = const {},
  ]) => transport.call('app.theme', params);

  Future<Map<String, dynamic>> changesHistory([
    Map<String, dynamic> params = const {},
  ]) => transport.call('changes.history', params);

  Future<Map<String, dynamic>> changesUndo({required Object? id}) =>
      transport.call('changes.undo', {'id': id});

  Future<Map<String, dynamic>> checksMcpCheck({required Object? force}) =>
      transport.call('checks.mcp_check', {'force': force});

  Future<Map<String, dynamic>> checksMcpRelease({required Object? name}) =>
      transport.call('checks.mcp_release', {'name': name});

  Future<Map<String, dynamic>> checksMcpTask({required Object? name}) =>
      transport.call('checks.mcp_task', {'name': name});

  Future<Map<String, dynamic>> checksMcpUpdates([
    Map<String, dynamic> params = const {},
  ]) => transport.call('checks.mcp_updates', params);

  Future<Map<String, dynamic>> connectionsApply({required String plan}) =>
      transport.call('connections.apply', {'plan': plan});

  Future<Map<String, dynamic>> connectionsAuthorPreview({
    required Object? agents,
    Object? entry,
    String? folder,
    required String kind,
    String? name,
  }) => transport.call('connections.author_preview', {
    'agents': agents,
    'entry': ?entry,
    'folder': ?folder,
    'kind': kind,
    'name': ?name,
  });

  Future<Map<String, dynamic>> connectionsForgetPreview({
    required String name,
  }) => transport.call('connections.forget_preview', {'name': name});

  Future<Map<String, dynamic>> connectionsMovePreview({
    required String agent,
    required Object? newValue,
    required String old,
  }) => transport.call('connections.move_preview', {
    'agent': agent,
    'new': newValue,
    'old': old,
  });

  Future<Map<String, dynamic>> connectionsPreview({
    required String command,
    required String item,
    required String kind,
    String? model,
    required bool remove,
    bool? useNow,
  }) => transport.call('connections.preview', {
    'command': command,
    'item': item,
    'kind': kind,
    'model': ?model,
    'remove': remove,
    'use_now': ?useNow,
  });

  Future<Map<String, dynamic>> connectionsRepairPreview({
    required String agent,
    required String target,
  }) => transport.call('connections.repair_preview', {
    'agent': agent,
    'target': target,
  });

  Future<Map<String, dynamic>> connectionsSnapshot({Object? command}) =>
      transport.call('connections.snapshot', {'command': ?command});

  Future<Map<String, dynamic>> connectionsUndo({required String undo}) =>
      transport.call('connections.undo', {'undo': undo});

  Future<Map<String, dynamic>> costsRate([
    Map<String, dynamic> params = const {},
  ]) => transport.call('costs.rate', params);

  Future<Map<String, dynamic>> desktopSnapshot([
    Map<String, dynamic> params = const {},
  ]) => transport.call('desktop.snapshot', params);

  Future<Map<String, dynamic>> detailsMcp({required String name}) =>
      transport.call('details.mcp', {'name': name});

  Future<Map<String, dynamic>> detailsSkills({required String path}) =>
      transport.call('details.skills', {'path': path});

  Future<Map<String, dynamic>> dictationRun({
    required String action,
    String? target,
  }) => transport.call('dictation.run', {'action': action, 'target': ?target});

  Future<Map<String, dynamic>> dictationSnapshot([
    Map<String, dynamic> params = const {},
  ]) => transport.call('dictation.snapshot', params);

  Future<Map<String, dynamic>> dictationStart([
    Map<String, dynamic> params = const {},
  ]) => transport.call('dictation.start', params);

  Future<Map<String, dynamic>> dictationStop({
    bool? cancel,
    String? recording,
  }) => transport.call('dictation.stop', {
    'cancel': ?cancel,
    'recording': ?recording,
  });

  Future<Map<String, dynamic>> existingApply([
    Map<String, dynamic> params = const {},
  ]) => transport.call('existing.apply', params);

  Future<Map<String, dynamic>> existingCheck([
    Map<String, dynamic> params = const {},
  ]) => transport.call('existing.check', params);

  Future<Map<String, dynamic>> existingMounts([
    Map<String, dynamic> params = const {},
  ]) => transport.call('existing.mounts', params);

  Future<Map<String, dynamic>> existingPreview({
    required Object? found,
    required Object? models,
  }) => transport.call('existing.preview', {'found': found, 'models': models});

  Future<Map<String, dynamic>> existingScan([
    Map<String, dynamic> params = const {},
  ]) => transport.call('existing.scan', params);

  Future<Map<String, dynamic>> foundHints([
    Map<String, dynamic> params = const {},
  ]) => transport.call('found.hints', params);

  Future<Map<String, dynamic>> foundList({required String kind}) =>
      transport.call('found.list', {'kind': kind});

  Future<Map<String, dynamic>> foundLookInside([
    Map<String, dynamic> params = const {},
  ]) => transport.call('found.look_inside', params);

  Future<Map<String, dynamic>> foundScan([
    Map<String, dynamic> params = const {},
  ]) => transport.call('found.scan', params);

  Future<Map<String, dynamic>> foundSeen({required String kind}) =>
      transport.call('found.seen', {'kind': kind});

  Future<Map<String, dynamic>> foundUnpack({required String program}) =>
      transport.call('found.unpack', {'program': program});

  Future<Map<String, dynamic>> foundUpdatePreview([
    Map<String, dynamic> params = const {},
  ]) => transport.call('found.update_preview', params);

  Future<Map<String, dynamic>> gpuSnapshot([
    Map<String, dynamic> params = const {},
  ]) => transport.call('gpu.snapshot', params);

  Future<Map<String, dynamic>> guideChoose({required Object? route}) =>
      transport.call('guide.choose', {'route': route});

  Future<Map<String, dynamic>> guideSnapshot([
    Map<String, dynamic> params = const {},
  ]) => transport.call('guide.snapshot', params);

  Future<Map<String, dynamic>> healthReport([
    Map<String, dynamic> params = const {},
  ]) => transport.call('health.report', params);

  Future<Map<String, dynamic>> helpOpenManual([
    Map<String, dynamic> params = const {},
  ]) => transport.call('help.open_manual', params);

  Future<Map<String, dynamic>> helpSnapshot([
    Map<String, dynamic> params = const {},
  ]) => transport.call('help.snapshot', params);

  Future<Map<String, dynamic>> helperSnapshot([
    Map<String, dynamic> params = const {},
  ]) => transport.call('helper.snapshot', params);

  Future<Map<String, dynamic>> i18nLookup({
    int? n,
    String? other,
    required String text,
  }) => transport.call('i18n.lookup', {'n': ?n, 'other': ?other, 'text': text});

  Future<Map<String, dynamic>> installersInstall([
    Map<String, dynamic> params = const {},
  ]) => transport.call('installers.install', params);

  Future<Map<String, dynamic>> installersPreview([
    Map<String, dynamic> params = const {},
  ]) => transport.call('installers.preview', params);

  Future<Map<String, dynamic>> jobsContinue({required Object? id}) =>
      transport.call('jobs.continue', {'id': id});

  Future<Map<String, dynamic>> jobsDiscard({required Object? id}) =>
      transport.call('jobs.discard', {'id': id});

  Future<Map<String, dynamic>> jobsList([
    Map<String, dynamic> params = const {},
  ]) => transport.call('jobs.list', params);

  Future<Map<String, dynamic>> limitsNotify([
    Map<String, dynamic> params = const {},
  ]) => transport.call('limits.notify', params);

  Future<Map<String, dynamic>> mapBadges([
    Map<String, dynamic> params = const {},
  ]) => transport.call('map.badges', params);

  Future<Map<String, dynamic>> mapSmartAsk({
    String? answer,
    required String column,
    required String command,
    required String request,
  }) => transport.call('map.smart_ask', {
    'answer': ?answer,
    'column': column,
    'command': command,
    'request': request,
  });

  Future<Map<String, dynamic>> mapSmartConnect({
    required String agent,
    required String candidate,
    required String proposal,
  }) => transport.call('map.smart_connect', {
    'agent': agent,
    'candidate': candidate,
    'proposal': proposal,
  });

  Future<Map<String, dynamic>> mapSmartHelpers([
    Map<String, dynamic> params = const {},
  ]) => transport.call('map.smart_helpers', params);

  Future<Map<String, dynamic>> mapSmartPlan({
    required Object? agents,
    required String candidate,
    required String proposal,
    required Object? values,
  }) => transport.call('map.smart_plan', {
    'agents': agents,
    'candidate': candidate,
    'proposal': proposal,
    'values': values,
  });

  Future<Map<String, dynamic>> mapSmartReview({
    required String candidate,
    required String proposal,
  }) => transport.call('map.smart_review', {
    'candidate': candidate,
    'proposal': proposal,
  });

  Future<Map<String, dynamic>> mapSmartRun({
    required String candidate,
    required String proposal,
  }) => transport.call('map.smart_run', {
    'candidate': candidate,
    'proposal': proposal,
  });

  Future<Map<String, dynamic>> mapSnapshot({Object? force, Object? poll}) =>
      transport.call('map.snapshot', {'force': ?force, 'poll': ?poll});

  Future<Map<String, dynamic>> mapUsage({required Object? commands}) =>
      transport.call('map.usage', {'commands': commands});

  Future<Map<String, dynamic>> mcpCatalog([
    Map<String, dynamic> params = const {},
  ]) => transport.call('mcp.catalog', params);

  Future<Map<String, dynamic>> mcpOptionPreview([
    Map<String, dynamic> params = const {},
  ]) => transport.call('mcp.option_preview', params);

  Future<Map<String, dynamic>> mcpOptionTest([
    Map<String, dynamic> params = const {},
  ]) => transport.call('mcp.option_test', params);

  Future<Map<String, dynamic>> mcpSearch([
    Map<String, dynamic> params = const {},
  ]) => transport.call('mcp.search', params);

  Future<Map<String, dynamic>> mcpTools([
    Map<String, dynamic> params = const {},
  ]) => transport.call('mcp.tools', params);

  Future<Map<String, dynamic>> mcpToolsCached({required Object? name}) =>
      transport.call('mcp.tools_cached', {'name': name});

  Future<Map<String, dynamic>> modelsAttachPreview({
    required Object? agents,
    required String model,
    required String provider,
  }) => transport.call('models.attach_preview', {
    'agents': agents,
    'model': model,
    'provider': provider,
  });

  Future<Map<String, dynamic>> modelsChooseApply({required String preview}) =>
      transport.call('models.choose_apply', {'preview': preview});

  Future<Map<String, dynamic>> modelsChoosePreview({
    required Object? model,
    required String provider,
  }) => transport.call('models.choose_preview', {
    'model': model,
    'provider': provider,
  });

  Future<Map<String, dynamic>> modelsChooseUndo({required String undo}) =>
      transport.call('models.choose_undo', {'undo': undo});

  Future<Map<String, dynamic>> modelsRemoveApply({required Object? removal}) =>
      transport.call('models.remove_apply', {'removal': removal});

  Future<Map<String, dynamic>> modelsRemovePreview({
    required Object? key,
    required Object? model,
  }) => transport.call('models.remove_preview', {'key': key, 'model': model});

  Future<Map<String, dynamic>> modelsSlotsPreview([
    Map<String, dynamic> params = const {},
  ]) => transport.call('models.slots_preview', params);

  Future<Map<String, dynamic>> modelsSlotsReload([
    Map<String, dynamic> params = const {},
  ]) => transport.call('models.slots_reload', params);

  Future<Map<String, dynamic>> modelsSwitchPreview({
    required Object? newValue,
    required String old,
    required String provider,
  }) => transport.call('models.switch_preview', {
    'new': newValue,
    'old': old,
    'provider': provider,
  });

  Future<Map<String, dynamic>> modelsTune({
    required String key,
    required Object? models,
  }) => transport.call('models.tune', {'key': key, 'models': models});

  Future<Map<String, dynamic>> modelsTuning({required String key}) =>
      transport.call('models.tuning', {'key': key});

  Future<Map<String, dynamic>> modelsTuningAsk([
    Map<String, dynamic> params = const {},
  ]) => transport.call('models.tuning_ask', params);

  Future<Map<String, dynamic>> modelsTuningPreview([
    Map<String, dynamic> params = const {},
  ]) => transport.call('models.tuning_preview', params);

  Future<Map<String, dynamic>> projectsForget([
    Map<String, dynamic> params = const {},
  ]) => transport.call('projects.forget', params);

  Future<Map<String, dynamic>> projectsPin([
    Map<String, dynamic> params = const {},
  ]) => transport.call('projects.pin', params);

  Future<Map<String, dynamic>> providersDetails({required String key}) =>
      transport.call('providers.details', {'key': key});

  Future<Map<String, dynamic>> providersHealth([
    Map<String, dynamic> params = const {},
  ]) => transport.call('providers.health', params);

  Future<Map<String, dynamic>> providersRun({
    required Object? operation,
    required Object? params,
  }) => transport.call('providers.run', {
    'operation': operation,
    'params': params,
  });

  Future<Map<String, dynamic>> providersSnapshot([
    Map<String, dynamic> params = const {},
  ]) => transport.call('providers.snapshot', params);

  Future<Map<String, dynamic>> rulesTest({
    required String action,
    required String agent,
    required String category,
    required String item,
  }) => transport.call('rules.test', {
    'action': action,
    'agent': agent,
    'category': category,
    'item': item,
  });

  Future<Map<String, dynamic>> sessionsRead({required String session}) =>
      transport.call('sessions.read', {'session': session});

  Future<Map<String, dynamic>> sessionsResize({
    required Object? cols,
    required Object? rows,
    required String session,
  }) => transport.call('sessions.resize', {
    'cols': cols,
    'rows': rows,
    'session': session,
  });

  Future<Map<String, dynamic>> sessionsStart({
    required String command,
    required bool outside,
    required Object? path,
  }) => transport.call('sessions.start', {
    'command': command,
    'outside': outside,
    'path': path,
  });

  Future<Map<String, dynamic>> sessionsStop({required String session}) =>
      transport.call('sessions.stop', {'session': session});

  Future<Map<String, dynamic>> sessionsWrite({
    required Object? data,
    required String session,
  }) => transport.call('sessions.write', {'data': data, 'session': session});

  Future<Map<String, dynamic>> settingsGet([
    Map<String, dynamic> params = const {},
  ]) => transport.call('settings.get', params);

  Future<Map<String, dynamic>> settingsUpdate({required Object? values}) =>
      transport.call('settings.update', {'values': values});

  Future<Map<String, dynamic>> setupApply({
    Object? declined,
    required Object? enabled,
  }) => transport.call('setup.apply', {
    'declined': ?declined,
    'enabled': enabled,
  });

  Future<Map<String, dynamic>> setupDetect([
    Map<String, dynamic> params = const {},
  ]) => transport.call('setup.detect', params);

  Future<Map<String, dynamic>> setupLater([
    Map<String, dynamic> params = const {},
  ]) => transport.call('setup.later', params);

  Future<Map<String, dynamic>> skillsWebFetch([
    Map<String, dynamic> params = const {},
  ]) => transport.call('skills.web_fetch', params);

  Future<Map<String, dynamic>> skillsWebPreview([
    Map<String, dynamic> params = const {},
  ]) => transport.call('skills.web_preview', params);

  Future<Map<String, dynamic>> skillsWebSearch([
    Map<String, dynamic> params = const {},
  ]) => transport.call('skills.web_search', params);

  Future<Map<String, dynamic>> systemCached([
    Map<String, dynamic> params = const {},
  ]) => transport.call('system.cached', params);

  Future<Map<String, dynamic>> systemFixPreview({
    required String command,
    required String finding,
  }) => transport.call('system.fix_preview', {
    'command': command,
    'finding': finding,
  });

  Future<Map<String, dynamic>> systemFolderPreview({
    required Object? found,
    required Object? runtime,
  }) => transport.call('system.folder_preview', {
    'found': found,
    'runtime': runtime,
  });

  Future<Map<String, dynamic>> systemForgetDisk({required Object? node}) =>
      transport.call('system.forget_disk', {'node': node});

  Future<Map<String, dynamic>> systemHelpApply({required Object? preview}) =>
      transport.call('system.help_apply', {'preview': preview});

  Future<Map<String, dynamic>> systemHelpPreview({
    required String command,
    required String topic,
  }) => transport.call('system.help_preview', {
    'command': command,
    'topic': topic,
  });

  Future<Map<String, dynamic>> systemMountSignature([
    Map<String, dynamic> params = const {},
  ]) => transport.call('system.mount_signature', params);

  Future<Map<String, dynamic>> systemMoveApply([
    Map<String, dynamic> params = const {},
  ]) => transport.call('system.move_apply', params);

  Future<Map<String, dynamic>> systemMovePreview([
    Map<String, dynamic> params = const {},
  ]) => transport.call('system.move_preview', params);

  Future<Map<String, dynamic>> systemMoveUndo({required Object? undo}) =>
      transport.call('system.move_undo', {'undo': undo});

  Future<Map<String, dynamic>> systemRefresh({required Object? search}) =>
      transport.call('system.refresh', {'search': search});

  Future<Map<String, dynamic>> systemStackApply({required Object? preview}) =>
      transport.call('system.stack_apply', {'preview': preview});

  Future<Map<String, dynamic>> systemStackPreview({required Object? part}) =>
      transport.call('system.stack_preview', {'part': part});

  Future<Map<String, dynamic>> systemToolCheck([
    Map<String, dynamic> params = const {},
  ]) => transport.call('system.tool_check', params);

  Future<Map<String, dynamic>> systemView({
    required Object? selected,
    required Object? transform,
  }) => transport.call('system.view', {
    'selected': selected,
    'transform': transform,
  });

  Future<Map<String, dynamic>> tasksCancel({required String task}) =>
      transport.call('tasks.cancel', {'task': task});

  Future<Map<String, dynamic>> tasksStatus({required String task}) =>
      transport.call('tasks.status', {'task': task});

  Future<Map<String, dynamic>> updatesCheck([
    Map<String, dynamic> params = const {},
  ]) => transport.call('updates.check', params);

  Future<Map<String, dynamic>> updatesRun({
    required String key,
    Object? runningOk,
  }) => transport.call('updates.run', {'key': key, 'running_ok': ?runningOk});

  Future<Map<String, dynamic>> usageSnapshot([
    Map<String, dynamic> params = const {},
  ]) => transport.call('usage.snapshot', params);

  Future<Map<String, dynamic>> windowPopup({
    required Object? height,
    required Object? width,
  }) => transport.call('window.popup', {'height': height, 'width': width});

  Future<Map<String, dynamic>> windowRounding([
    Map<String, dynamic> params = const {},
  ]) => transport.call('window.rounding', params);
}
