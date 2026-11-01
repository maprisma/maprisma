/// What may be done (task 019). The most specific rule wins: an item counts 8,
/// an agent 4, a category 2, an action 1. Only rules naming the same fields can
/// tie, and then allow wins. No match is deny: the defaults are written out.
library;

const ruleActions = [
  'install',
  'update',
  'remove',
  'connect',
  'disconnect',
  'move',
  'start',
  'stop',
];
const ruleCategories = ['mcp', 'skills', 'agents', 'providers', 'models'];
const maxActionRules = 200;

/// Allow all, one rule per action, so each default can be read and removed.
final defaultActionRules = <Map<String, dynamic>>[
  for (final action in ruleActions)
    {
      'effect': 'allow',
      'action': action,
      'category': '*',
      'item': '*',
      'agent': '*',
    },
];

/// One thing a request does.
final class ActionCheck {
  const ActionCheck(this.action, this.category, this.item, [this.agent = '']);
  final String action, category, item, agent;
}

/// Refused by the rules; the message is the core's own text.
final class RuleRefused implements Exception {
  const RuleRefused(this.message);
  final String message;
}

bool validActionRules(Object? value) =>
    value is List &&
    value.length <= maxActionRules &&
    value.every((r) {
      if (r is! Map || r.length != 5) return false;
      final fields = ['action', 'category', 'item', 'agent'];
      if (!fields.every((k) => r[k] is String && (r[k] as String).isNotEmpty)) {
        return false;
      }
      return const ['allow', 'deny'].contains(r['effect']) &&
          (r['action'] == '*' || ruleActions.contains(r['action'])) &&
          (r['category'] == '*' || ruleCategories.contains(r['category'])) &&
          (r['item'] == '*' || r['category'] != '*');
    });

int ruleScore(Map rule) =>
    (rule['item'] != '*' ? 8 : 0) +
    (rule['agent'] != '*' ? 4 : 0) +
    (rule['category'] != '*' ? 2 : 0) +
    (rule['action'] != '*' ? 1 : 0);

bool _matches(Map rule, ActionCheck check) {
  bool same(String key, String value) => rule[key] == '*' || rule[key] == value;
  // "Everything for Pi" also covers what is done to Pi itself.
  final agent =
      same('agent', check.agent) ||
      check.category == 'agents' && rule['agent'] == check.item;
  return same('action', check.action) &&
      same('category', check.category) &&
      same('item', check.item) &&
      agent;
}

/// The rule that decides, or null when none matches (refused).
Map? decidingRule(List rules, ActionCheck check) {
  Map? best;
  for (final rule in rules.cast<Map>()) {
    if (!_matches(rule, check)) continue;
    final score = ruleScore(rule), top = best == null ? -1 : ruleScore(best);
    if (score > top || score == top && rule['effect'] == 'allow') best = rule;
  }
  return best;
}

bool ruleAllows(List rules, ActionCheck check) =>
    decidingRule(rules, check)?['effect'] == 'allow';

/// `mcp:x`, `skills:/p`, `runtime:k`, `cloud:k`, `agent:c`, `model:runtime:k:m`.
(String, String)? _node(Object? id) {
  if (id is! String) return null;
  final parts = id.split(':');
  return switch (parts.first) {
    'mcp' => ('mcp', id.substring(4)),
    'skills' => ('skills', id.substring(7)),
    'runtime' => ('providers', id.substring(8)),
    'cloud' => ('providers', id.substring(6)),
    'agent' => ('agents', id.substring(6)),
    'model' when parts.length > 3 => ('models', parts.skip(3).join(':')),
    _ => null,
  };
}

String _agent(Object? id) =>
    id is String && id.startsWith('agent:') ? id.substring(6) : '$id';

/// Moving a line is two things: leaving one end and reaching the other.
List<ActionCheck> _line(Object? old, Object? next, String agent) => [
  if (_node(old) case (final c, final i))
    ActionCheck('disconnect', c, i, agent),
  if (_node(next) case (final c, final i)) ActionCheck('connect', c, i, agent),
];

List<ActionCheck> _forAgents(
  String action,
  String category,
  String item,
  Object? agents,
) => [
  for (final a in agents is List ? agents : const [])
    ActionCheck(action, category, item, '$a'),
];

const _operations = {
  'models.download': ('install', 'models'),
  'models.pull': ('install', 'models'),
  'model.import': ('install', 'models'),
  'model.load': ('start', 'models'),
  'model.unload': ('stop', 'models'),
  'runtime.start': ('start', 'providers'),
  'runtime.stop': ('stop', 'providers'),
};

/// Everything a request does, for the rules. A route that changes the setup
/// needs an entry here or in [rulesExempt]: action_rules_test fails otherwise.
List<ActionCheck> actionChecks(String method, Map<String, dynamic> p) {
  String text(String key) => '${p[key] ?? ''}';
  // An add-on's id starts with its kind: agent-goose, provider-…
  String addon(String id) => id.startsWith('agent') ? 'agents' : 'providers';
  switch (method) {
    case 'connections.preview':
      final kind = text('kind');
      return [
        ActionCheck(
          p['remove'] == true ? 'disconnect' : 'connect',
          kind == 'provider' ? 'providers' : kind,
          text('item'),
          text('command'),
        ),
      ];
    case 'connections.move_preview':
      return _line(p['old'], p['new'], _agent(p['agent']));
    case 'connections.repair_preview':
      return _line(null, p['target'], _agent(p['agent']));
    case 'connections.author_preview':
      final skill = text('kind') == 'skills';
      return _forAgents(
        'connect',
        skill ? 'skills' : 'mcp',
        text(skill ? 'folder' : 'name'),
        p['agents'],
      );
    case 'connections.forget_preview':
      return [ActionCheck('remove', 'mcp', text('name'))];
    case 'mcp.option_preview':
      return [
        ActionCheck('install', 'mcp', text('name')),
        ..._forAgents('connect', 'mcp', text('name'), p['agents']),
      ];
    case 'skills.web_preview':
      return [
        ActionCheck('install', 'skills', text('folder')),
        ..._forAgents('connect', 'skills', text('folder'), p['agents']),
      ];
    case 'found.update_preview':
      return [ActionCheck('update', 'mcp', text('name'))];
    case 'models.switch_preview':
      return _line(p['old'], p['new'], '');
    case 'models.attach_preview':
      final model = _node(p['model'])?.$2 ?? text('model');
      return _forAgents('connect', 'models', model, p['agents']);
    case 'models.remove_preview':
      return [ActionCheck('remove', 'models', text('model'))];
    case 'models.tuning_preview':
      return [ActionCheck('update', 'providers', text('key'))];
    case 'system.move_preview':
      return const [ActionCheck('move', 'models', '')];
    case 'existing.preview':
    case 'system.folder_preview':
      return const [ActionCheck('connect', 'models', '')];
    case 'system.stack_preview':
      return [ActionCheck('install', 'providers', text('part'))];
    case 'providers.run':
      final known = _operations[p['operation']];
      if (known == null) return const [];
      final inner = p['params'] is Map ? p['params'] as Map : const {};
      final item = known.$2 == 'models'
          ? inner['model'] ?? inner['name'] ?? ''
          : inner['runtime'] ?? inner['key'] ?? '';
      return [ActionCheck(known.$1, known.$2, '$item')];
    case 'jobs.continue':
      return const [ActionCheck('install', 'models', '')];
    case 'agents.action_preview':
      final action = text('action');
      final name = const {'install', 'update', 'remove'}.contains(action)
          ? action
          : action == 'logout'
          ? 'disconnect'
          : 'connect';
      return [ActionCheck(name, 'agents', text('command'))];
    case 'agents.key_preview':
      return [ActionCheck('connect', 'agents', text('command'))];
    case 'agents.halt_preview':
    case 'sessions.stop':
      return [ActionCheck('stop', 'agents', text('command'))];
    case 'sessions.start':
    case 'system.help_preview':
    case 'system.fix_preview':
      return [ActionCheck('start', 'agents', text('command'))];
    case 'updates.run':
      return [ActionCheck('update', 'agents', text('key'))];
    case 'installers.preview':
      return [
        ActionCheck(
          'install',
          text('kind') == 'runtime' ? 'providers' : 'agents',
          text('key'),
        ),
      ];
    case 'found.unpack':
      return [ActionCheck('install', 'agents', text('program'))];
    case 'addons.remove_preview':
      return [ActionCheck('remove', addon(text('id')), text('id'))];
    case 'addons.set_enabled':
      return [
        ActionCheck(
          p['enabled'] == true ? 'install' : 'remove',
          addon(text('id')),
          text('id'),
        ),
      ];
    case 'addons.install':
    case 'addons.file_preview':
      return const [ActionCheck('install', 'agents', '')];
    case 'setup.apply':
      return const [ActionCheck('update', 'agents', '')];
  }
  return const [];
}

/// Routes of kind preview or change that need no rule: reading a plan's own
/// follow-up, undoing, settings (the rules live there), and small app state.
const rulesExempt = {
  'addons.file_install', // the preview before it is checked
  'addons.remove_apply', 'addons.remove_undo',
  'agents.action_apply', 'agents.halt_apply', 'agents.key_apply',
  'agents.security_preview', 'agents.usage_refresh',
  'app.settings_changed', 'changes.undo', 'checks.mcp_release',
  'connections.apply', 'connections.undo', 'existing.apply',
  'found.seen', 'guide.choose', 'help.open_manual',
  'installers.install', 'jobs.discard', 'limits.notify',
  'map.smart_connect', 'map.smart_plan', 'map.smart_run',
  'models.remove_apply', 'models.slots_preview', 'models.slots_reload',
  'projects.forget', 'projects.pin',
  'sessions.read', 'sessions.resize', 'sessions.write', 'settings.update',
  'setup.later', 'system.forget_disk', 'system.help_apply',
  'system.move_apply', 'system.move_undo', 'system.refresh',
  'system.stack_apply', 'tasks.cancel', 'tasks.status', 'window.popup',
};
