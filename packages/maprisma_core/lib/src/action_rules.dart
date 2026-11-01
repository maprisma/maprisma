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
const ruleActionNames = {
  'install': 'Install',
  'update': 'Update',
  'remove': 'Remove',
  'connect': 'Connect',
  'disconnect': 'Disconnect',
  'move': 'Move',
  'start': 'Start',
  'stop': 'Stop',
};
const ruleCategoryNames = {
  'mcp': 'MCP servers',
  'skills': 'Skills',
  'agents': 'Agents',
  'providers': 'Providers',
  'models': 'Models',
};

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

bool _matches(
  Map rule,
  ActionCheck check,
  String Function(String, String) normal,
) {
  bool same(String key, String value) => rule[key] == '*' || rule[key] == value;
  // "Everything for Pi" also covers what is done to Pi itself.
  final agent =
      same('agent', check.agent) ||
      check.category == 'agents' && rule['agent'] == check.item;
  final item =
      rule['item'] == '*' ||
      normal(check.category, '${rule['item']}') ==
          normal(check.category, check.item);
  return same('action', check.action) &&
      same('category', check.category) &&
      item &&
      agent;
}

String _asIs(String category, String item) => item;

/// The rule that decides, or null when none matches (refused). [normal] gives
/// an item its one spelling: models ignore case, skill folders are `~/…`.
Map? decidingRule(
  List rules,
  ActionCheck check, {
  String Function(String, String) normal = _asIs,
}) {
  Map? best;
  for (final rule in rules.cast<Map>()) {
    if (!_matches(rule, check, normal)) continue;
    final score = ruleScore(rule), top = best == null ? -1 : ruleScore(best);
    if (score > top || score == top && rule['effect'] == 'allow') best = rule;
  }
  return best;
}

bool ruleAllows(
  List rules,
  ActionCheck check, {
  String Function(String, String) normal = _asIs,
}) => decidingRule(rules, check, normal: normal)?['effect'] == 'allow';

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

/// `agent-pi` is the agent pi, `llm-ollama` the local LLM ollama.
String ruleAddonCategory(String id) =>
    id.startsWith('agent-') ? 'agents' : 'providers';
String ruleAddonItem(String id) => id.startsWith('agent-')
    ? id.substring(6)
    : id.startsWith('llm-')
    ? id.substring(4)
    : id;

/// What only the core knows about a request.
final class RuleFacts {
  const RuleFacts({this.installed, this.updateColumn, this.modelUsers});

  /// Whether a program of an installer is already here: then it is an update.
  final bool Function(String kind, String key)? installed;

  /// The category of an entry of updates.run.
  final String Function(String key)? updateColumn;

  /// The agents on a model's line.
  final List<String> Function(String node)? modelUsers;
}

/// Everything a request does, for the rules. A route that changes the setup
/// needs an entry here or in [rulesExempt]; action_rules_test names what each
/// entry must give for parameters the handlers really take.
List<ActionCheck> actionChecks(
  String method,
  Map<String, dynamic> p, [
  RuleFacts facts = const RuleFacts(),
]) {
  String text(String key) => '${p[key] ?? ''}';
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
      final item = text(skill ? 'folder' : 'name');
      return [
        if (!skill) ActionCheck('install', 'mcp', item),
        ..._forAgents('connect', skill ? 'skills' : 'mcp', item, p['agents']),
      ];
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
    case 'models.switch_preview':
      final users = facts.modelUsers?.call(text('old')) ?? const <String>[];
      return [
        for (final agent in users.isEmpty ? const [''] : users)
          ..._line(p['old'], p['new'], agent),
      ];
    case 'models.attach_preview':
      final model = _node(p['model'])?.$2 ?? text('model');
      return _forAgents('connect', 'models', model, p['agents']);
    case 'models.remove_preview':
      return [ActionCheck('remove', 'models', text('model'))];
    case 'models.tuning_preview':
      return [ActionCheck('update', 'providers', text('key'))];
    case 'models.slots_preview':
      return const [ActionCheck('update', 'providers', '')];
    case 'agents.security_preview':
      return [ActionCheck('update', 'agents', text('command'))];
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
      final item = known.$2 == 'providers'
          ? inner['key']
          : inner['model'] ?? inner['name'] ?? inner['repo'] ?? inner['path'];
      return [ActionCheck(known.$1, known.$2, '${item ?? ''}')];
    case 'jobs.continue':
      return const [ActionCheck('install', 'models', '')];
    case 'agents.action_preview':
      final name = switch (text('action')) {
        'install' => 'install',
        'update' => 'update',
        'uninstall' => 'remove',
        'verify' => 'start',
        'logout' => 'disconnect',
        _ => 'connect',
      };
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
      return [
        ActionCheck(
          'update',
          facts.updateColumn?.call(text('key')) ?? 'agents',
          text('key'),
        ),
      ];
    case 'installers.preview':
      final kind = text('kind');
      return [
        ActionCheck(
          facts.installed?.call(kind, text('key')) == true
              ? 'update'
              : 'install',
          kind == 'runtime' ? 'providers' : 'agents',
          text('key'),
        ),
      ];
    case 'addons.remove_preview':
      return [
        ActionCheck(
          'remove',
          ruleAddonCategory(text('id')),
          ruleAddonItem(text('id')),
        ),
      ];
    case 'addons.set_enabled':
      return [
        ActionCheck(
          p['enabled'] == true ? 'install' : 'remove',
          ruleAddonCategory(text('id')),
          ruleAddonItem(text('id')),
        ),
      ];
    // Which kind a file holds shows later: both must be allowed.
    case 'addons.file_preview':
      return const [
        ActionCheck('install', 'agents', ''),
        ActionCheck('install', 'providers', ''),
      ];
    case 'setup.apply':
      return const [
        ActionCheck('update', 'agents', ''),
        ActionCheck('update', 'providers', ''),
      ];
  }
  return const [];
}

/// Routes that need no rule of their own.
const rulesExempt = {
  // Their handler knows what they touch and checks that itself.
  'addons.install', 'found.unpack', 'found.update_preview',
  // Second steps: their preview was checked, and a review is modal, so the
  // rules cannot change in between. The rules button waits in Ask AI too.
  'addons.file_install', 'addons.remove_apply', 'agents.action_apply',
  'agents.halt_apply', 'agents.key_apply', 'connections.apply',
  'existing.apply', 'installers.install', 'models.remove_apply',
  'system.help_apply', 'system.move_apply', 'system.stack_apply',
  // Ask AI: each dispatches a checked route, or checks its own candidate.
  'map.smart_connect', 'map.smart_plan', 'map.smart_run',
  // Putting back what was changed; Settings lists these.
  'addons.remove_undo', 'changes.undo', 'connections.undo', 'system.move_undo',
  // The rules live in the settings, so these can never lock their editor.
  'app.settings_changed', 'settings.update',
  // A running session's input and size, tasks, and the app's own state.
  'sessions.read', 'sessions.resize', 'sessions.write',
  'tasks.cancel', 'tasks.status',
  'agents.usage_refresh', 'checks.mcp_release', 'found.seen', 'guide.choose',
  'help.open_manual', 'jobs.discard', 'limits.notify', 'models.slots_reload',
  'projects.forget', 'projects.pin', 'setup.later', 'system.forget_disk',
  'system.refresh', 'window.popup',
};
