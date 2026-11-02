import 'package:flutter/material.dart';

import 'overlay_window.dart';

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
const _actionNames = {
  'install': 'Install',
  'update': 'Update',
  'remove': 'Remove',
  'connect': 'Connect',
  'disconnect': 'Disconnect',
  'move': 'Move',
  'start': 'Start',
  'stop': 'Stop',
};
const _categoryNames = {
  'mcp': 'MCP servers',
  'skills': 'Skills',
  'agents': 'Agents',
  'providers': 'Providers',
  'models': 'Models',
};

Map<String, dynamic> _rule(String effect, [String action = '*']) => {
  'effect': effect,
  'action': action,
  'category': '*',
  'item': '*',
  'agent': '*',
};

/// The defaults: one allow per action, as the core has them.
List<Map<String, dynamic>> defaultRules() => [
  for (final action in ruleActions) _rule('allow', action),
];

/// Allow and deny rules, each list with its +; a bar tries a request.
class ActionRulesWindow extends StatefulWidget {
  const ActionRulesWindow({
    super.key,
    required this.rules,
    required this.hints,
    required this.items,
    required this.agents,
    required this.tr,
    required this.onSave,
    required this.onTest,
  });
  final List<Map<String, dynamic>> rules;
  final bool hints;

  /// Per category, what can be named: id -> what the user reads.
  final Map<String, Map<String, String>> items;
  final Map<String, String> agents;
  final String Function(String) tr;
  final Future<void> Function(List<Map<String, dynamic>>, bool) onSave;
  final Future<Map<String, dynamic>> Function(Map<String, String>) onTest;

  @override
  State<ActionRulesWindow> createState() => _ActionRulesWindowState();
}

class _ActionRulesWindowState extends State<ActionRulesWindow> {
  late var _rules = [
    for (final r in widget.rules) {...r},
  ];
  late var _hints = widget.hints;
  var _try = <String, String>{
    'action': 'disconnect',
    'category': 'skills',
    'item': '*',
    'agent': '*',
  };
  String? _answer;
  List<Map<String, dynamic>>? _before;
  bool _failed = false;

  String tr(String key) => widget.tr(key);

  bool get _tryHasAgent =>
      const ['connect', 'disconnect'].contains(_try['action']) &&
      _try['category'] != 'agents';

  String _words(Map rule) => [
    tr(rule['effect'] == 'allow' ? 'Allow' : 'Deny'),
    rule['action'] == '*' ? tr('All') : tr(_actionNames[rule['action']]!),
    rule['category'] == '*' ? tr('All') : tr(_categoryNames[rule['category']]!),
    if (rule['item'] != '*') '${rule['item']}',
    if (rule['agent'] != '*') '${rule['agent']}',
  ].join(' · ');

  Future<void> _changed() async {
    setState(() {
      _answer = null;
      _before = null;
    });
    try {
      await widget.onSave(_rules, _hints);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (mounted) setState(() => _failed = false);
  }

  bool _deadDeny(Map rule) =>
      rule['effect'] == 'deny' &&
      _rules.any(
        (r) =>
            r['effect'] == 'allow' &&
            const [
              'action',
              'category',
              'item',
              'agent',
            ].every((k) => r[k] == rule[k]),
      );

  DropdownMenuItem<String> _entry(String value, String label) =>
      DropdownMenuItem(
        value: value,
        child: Text(label, overflow: TextOverflow.ellipsis),
      );

  Widget _picker(
    String field,
    String value,
    List<DropdownMenuItem<String>> entries,
    ValueChanged<String> changed,
  ) {
    // A rule for what is gone stays visible and can be deleted.
    final known = entries.any((e) => e.value == value);
    return Expanded(
      child: DropdownButton<String>(
        key: ValueKey('rule-$field'),
        isExpanded: true,
        value: value,
        items: [...entries, if (!known) _entry(value, value)],
        onChanged: (v) {
          if (v != null) changed(v);
        },
      ),
    );
  }

  List<DropdownMenuItem<String>> _actions() => [
    _entry('*', tr('All')),
    for (final a in ruleActions) _entry(a, tr(_actionNames[a]!)),
  ];
  List<DropdownMenuItem<String>> _categories() => [
    _entry('*', tr('All')),
    for (final c in _categoryNames.entries) _entry(c.key, tr(c.value)),
  ];
  List<DropdownMenuItem<String>> _items(String category) => [
    _entry('*', tr('All')),
    for (final i in (widget.items[category] ?? const {}).entries)
      _entry(i.key, i.value),
  ];
  List<DropdownMenuItem<String>> _agents() => [
    _entry('*', tr('All')),
    for (final a in widget.agents.entries) _entry(a.key, a.value),
  ];
  bool _hasAgent(Map rule) =>
      const ['*', 'connect', 'disconnect'].contains(rule['action']) &&
      rule['category'] != 'agents';

  Widget _row(Map<String, dynamic> rule, int index) {
    void set(Map<String, dynamic> change) {
      setState(() => rule.addAll(change));
      if (rule['category'] == '*') rule['item'] = '*';
      if (!_hasAgent(rule)) rule['agent'] = '*';
      _changed();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _picker(
              'action',
              '${rule['action']}',
              _actions(),
              (v) => set({'action': v}),
            ),
            const SizedBox(width: 8),
            _picker(
              'category',
              '${rule['category']}',
              _categories(),
              (v) => set({'category': v, 'item': '*'}),
            ),
            const SizedBox(width: 8),
            if (rule['category'] == '*')
              const Spacer()
            else
              _picker(
                'item',
                '${rule['item']}',
                _items('${rule['category']}'),
                (v) => set({'item': v}),
              ),
            const SizedBox(width: 8),
            if (_hasAgent(rule))
              _picker(
                'agent',
                '${rule['agent']}',
                _agents(),
                (v) => set({'agent': v}),
              )
            else
              const Spacer(),
            IconButton(
              key: ValueKey('rule-delete-${rule['effect']}-$index'),
              tooltip: tr('Remove'),
              icon: const Icon(Icons.close),
              onPressed: () {
                setState(() => _rules.remove(rule));
                _changed();
              },
            ),
          ],
        ),
        if (_deadDeny(rule))
          Text(
            tr('Never decides: an allow rule names the same things.'),
            style: const TextStyle(fontSize: 12),
          ),
      ],
    );
  }

  Widget _list(String effect, String title) {
    final rows = _rules.where((r) => r['effect'] == effect).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              key: ValueKey('rule-add-$effect'),
              tooltip: tr('Add'),
              icon: const Icon(Icons.add),
              onPressed: _rules.length >= 200
                  ? null
                  : () {
                      setState(() => _rules.add(_rule(effect)));
                      _changed();
                    },
            ),
          ],
        ),
        for (final (i, rule) in rows.indexed) _row(rule, i),
      ],
    );
  }

  Widget _tester() => Row(
    children: [
      Text(tr('Test a request')),
      const SizedBox(width: 12),
      _picker(
        'test-action',
        _try['action']!,
        _actions().skip(1).toList(),
        (v) => setState(() => _try = {..._try, 'action': v}),
      ),
      const SizedBox(width: 8),
      _picker(
        'test-category',
        _try['category']!,
        _categories().skip(1).toList(),
        (v) => setState(() => _try = {..._try, 'category': v, 'item': '*'}),
      ),
      const SizedBox(width: 8),
      _picker(
        'test-item',
        _try['item']!,
        _items(_try['category']!),
        (v) => setState(() => _try = {..._try, 'item': v}),
      ),
      const SizedBox(width: 8),
      if (_tryHasAgent)
        _picker(
          'test-agent',
          _try['agent']!,
          _agents(),
          (v) => setState(() => _try = {..._try, 'agent': v}),
        )
      else
        const Spacer(),
      const SizedBox(width: 8),
      OutlinedButton(
        key: const ValueKey('rule-test'),
        onPressed: () async {
          final reply = await widget.onTest({
            for (final e in _try.entries)
              e.key: e.value == '*' || e.key == 'agent' && !_tryHasAgent
                  ? ''
                  : e.value,
          });
          if (mounted) {
            final rule = reply['rule'];
            setState(
              () => _answer = [
                tr(reply['allowed'] == true ? 'Allowed' : 'Refused'),
                if (rule is Map) _words(rule),
              ].join(': '),
            );
          }
        },
        child: Text(tr('Test')),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => OverlayWindow(
    child: Material(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tr('What may be done'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                TextButton(
                  key: const ValueKey('rule-defaults'),
                  onPressed: () {
                    final before = _before ?? _rules;
                    _rules = defaultRules();
                    _changed();
                    setState(() => _before = before);
                  },
                  child: Text(tr('Restore defaults')),
                ),
                if (_before != null)
                  TextButton(
                    key: const ValueKey('rule-undo'),
                    onPressed: () {
                      setState(() {
                        _rules = _before!;
                        _before = null;
                      });
                      _changed();
                    },
                    child: Text(tr('Undo')),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(tr('Close')),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  tr(
                    'The most specific rule decides; on a tie allow wins. A request no rule matches is refused.',
                  ),
                ),
                const SizedBox(height: 12),
                _list('allow', tr('Allow')),
                const SizedBox(height: 16),
                _list('deny', tr('Deny')),
                SwitchListTile(
                  key: const ValueKey('rule-hints'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('Say which rule refused something')),
                  value: _hints,
                  onChanged: (v) {
                    setState(() => _hints = v);
                    _changed();
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(padding: const EdgeInsets.all(12), child: _tester()),
          if (_failed)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Text(tr('The action could not be completed.')),
            ),
          if (_answer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Text(_answer!),
            ),
        ],
      ),
    ),
  );
}
