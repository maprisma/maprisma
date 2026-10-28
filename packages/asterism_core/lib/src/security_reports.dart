import 'package:collection/collection.dart';
import 'adapters.dart';
import 'adapter_assets.g.dart';
import 'agent_details.dart';
import 'scan_files.dart';
import 'service_i18n.dart';

bool sameSecurityValue(dynamic a, dynamic b) {
  if (a is List && b is List) {
    final x = a.map((v) => '$v').toList()..sort(),
        y = b.map((v) => '$v').toList()..sort();
    return const ListEquality<String>().equals(x, y);
  }
  return const DeepCollectionEquality().equals(a, b);
}

final class SecurityReports {
  SecurityReports(this.files, this.i18n);
  final ScanFiles files;
  final ServiceI18n i18n;
  Map<String, dynamic> agent(Adapter adapter, {int mcpServers = 0}) {
    var spec = adapter.table('security');
    final known = spec.isNotEmpty;
    final hooked = spec['hook'] == true;
    if (hooked) {
      spec = Map<String, dynamic>.from(
        hookSecurityFacts[adapter.command] as Map? ?? {},
      );
    }
    final path = spec['file'] as String? ?? '',
        format = spec['format'] ?? 'json';
    final data = format == 'toml'
        ? files.toml(path)
        : format == 'yaml'
        ? yamlMap(files.text(path) ?? '')
        : files.json(path);
    final settings = <Map<String, dynamic>>[],
        rules = <List<dynamic>>[],
        risks = <Map<String, dynamic>>[];
    String tr(dynamic value) => i18n.text(value as String? ?? '');
    dynamic current(String key) {
      if (hooked) {
        final permission = data['permission'];
        if (permission is String) return permission;
        final name = key.startsWith('permission.') ? key.substring(11) : key;
        final value = mapOf(permission)[name];
        if (value is Map) {
          return value.length == 1 && value.containsKey('*')
              ? value['*'] ?? 'ask'
              : value;
        }
        return value ??
            (mapOf(permission)['*'] is String ? mapOf(permission)['*'] : null);
      }
      if (format == 'yaml') {
        final parts = key.split('.');
        if (parts.length != 2) return null;
        final block = RegExp(
          '^${RegExp.escape(parts[0])}:[ \t]*\n((?:[ \t]+.*\n?|[ \t]*\n)+)',
          multiLine: true,
        ).firstMatch(files.text(path) ?? '');
        if (block == null) return null;
        final match = RegExp(
          '^[ \t]+${RegExp.escape(parts[1])}:[ \t]*(.*?)[ \t]*(?:#.*)?\$',
          multiLine: true,
        ).firstMatch(block[1]!);
        if (match == null) return null;
        final raw = match[1]!.trim();
        if (!match[1]!.startsWith("'") && !match[1]!.startsWith('"')) {
          if (['true', 'yes', 'on'].contains(raw.toLowerCase())) return true;
          if (['false', 'no'].contains(raw.toLowerCase())) return false;
        }
        return raw.replaceAll(RegExp('^[\'"]+|[\'"]+\$'), '');
      }
      return dig(data, key);
    }

    for (final setting in spec['settings'] as List? ?? []) {
      if (setting is! Map) continue;
      var value = current(setting['key']);
      final condition = setting['current_if'];
      if (condition != null &&
          !(condition == 'list' && value is List ||
              condition == 'text' && value is String ||
              condition == 'bool' && value is bool)) {
        value = null;
      }
      final choices = <Map<String, dynamic>>[];
      for (final choice in setting['choices'] as List? ?? []) {
        choices.add({
          'value': choice['unset'] == true ? null : choice['value'],
          'label': tr(choice['label']),
          'explain': tr(choice['explain']),
          'risk': choice['risk'] ?? 1,
        });
      }
      final warn = setting['warn'];
      settings.add({
        'key': setting['key'],
        'title': tr(setting['title']),
        'explain': tr(setting['explain']),
        'choices': choices,
        'current': value,
        'default': setting['default'],
        'path': files.expand(path),
        'fmt': format,
        'terms': setting['terms'] ?? [],
        'editable': setting['editable'] ?? true,
        'recommended': setting['recommended'],
        'warn': warn is Map
            ? [tr(warn['title']), tr(warn['explain']), tr(warn['fix'])]
            : warn is List
            ? warn
            : [],
      });
    }
    List<String> strings(dynamic value) => value is List
        ? value
              .whereType<String>()
              .take(200)
              .map((s) => boundedText(s, 300))
              .toList()
        : [];
    for (final rule in spec['rules'] as List? ?? []) {
      if (rule is! Map) continue;
      var value = current(rule['key']);
      if (rule['keys_where'] is Map) {
        final wanted = rule['keys_where'] as Map;
        value = mapOf(value).entries
            .where(
              (e) =>
                  e.value is Map &&
                  wanted.entries.every(
                    (w) => sameSecurityValue(e.value[w.key], w.value),
                  ),
            )
            .map((e) => e.key)
            .toList();
      }
      var entries = strings(value);
      if (entries.isEmpty && rule['also'] is String) {
        entries = strings(dig(files.json(rule['also']), rule['key']));
      }
      if (entries.isNotEmpty) {
        rules.add([tr(rule['title']), rule['key'], entries]);
      }
    }
    final sandboxKey = adapter.table('security')['sandbox'] ?? '',
        asksKey = adapter.table('security')['asks'] ?? '';
    final sandbox = settings.firstWhereOrNull((s) => s['key'] == sandboxKey),
        asks = settings.firstWhereOrNull((s) => s['key'] == asksKey);
    dynamic effective(Map setting) => setting['current'] ?? setting['default'];
    Map<String, dynamic> choice(Map setting) {
      final value = effective(setting), choices = setting['choices'] as List;
      final found = choices.whereType<Map<String, dynamic>>().firstWhereOrNull(
        (c) => sameSecurityValue(c['value'], value),
      );
      if (found != null) return found;
      if (setting['current'] == null) {
        final unset = choices
            .whereType<Map<String, dynamic>>()
            .firstWhereOrNull((c) => c['value'] == null);
        if (unset != null) return unset;
      }
      final label = value is List
          ? value.join(', ')
          : value == null
          ? 'None'
          : '$value';
      return {
        'value': value,
        'label': tr('Custom: {0}').replaceAll('{0}', boundedText(label, 80)),
        'explain': tr('Set by hand; AI Agents Map leaves it as it is.'),
        'risk': 1,
      };
    }

    void risk(
      String level,
      String title,
      String why,
      String lower, {
      String key = '',
      dynamic value,
    }) {
      risks.add({
        'level': level,
        'title': title,
        'why': why,
        'lower': lower,
        'fix_key': key,
        'fix_value': value,
      });
    }

    final sandboxed =
        sandbox != null &&
        [
          true,
          'enabled',
          'read-only',
          'workspace-write',
        ].contains(effective(sandbox));
    if (asks != null && (choice(asks)['risk'] as int) >= 3) {
      risk(
        'high',
        tr('Runs commands without asking'),
        tr(
          '{0}: a wrong command or a prompt injection is carried out at once, with your rights.',
        ).replaceAll('{0}', choice(asks)['label']),
        tr(
          'Let it ask first, or use this only in a container or virtual machine.',
        ),
        key: asks['key'],
        value: asks['recommended'],
      );
    }
    if (sandbox != null && (choice(sandbox)['risk'] as int) >= 3) {
      risk(
        'high',
        tr('No sandbox'),
        tr('Commands may change anything in your home folder.'),
        tr('Use the project-folder sandbox.'),
        key: sandboxKey,
        value: sandbox['recommended'],
      );
    } else if (sandboxKey != '' &&
        !sandboxed &&
        asks != null &&
        (choice(asks)['risk'] as int) >= 2) {
      risk(
        'medium',
        tr('Acts on its own without a sandbox'),
        tr(
          'It may do things without asking, and nothing fences in what the commands touch.',
        ),
        tr('Switch the sandbox on, or let it ask first.'),
        key: sandboxKey,
        value: sandbox?['recommended'],
      );
    }
    for (final setting in settings) {
      if ([asksKey, sandboxKey].contains(setting['key'])) continue;
      final selected = choice(setting), warn = setting['warn'] as List;
      if (warn.isNotEmpty && selected['risk'] == 1) continue;
      if ((selected['risk'] as int) >= 2 && setting['editable'] == true) {
        final preferred = (setting['choices'] as List)
            .whereType<Map>()
            .firstWhereOrNull(
              (c) => sameSecurityValue(c['value'], setting['recommended']),
            );
        risk(
          'medium',
          setting['title'],
          selected['explain'],
          tr('Choose “{0}”.').replaceAll('{0}', preferred?['label'] ?? ''),
          key: setting['key'],
          value: setting['recommended'],
        );
      }
    }
    for (final rule in rules) {
      if ((rule[1] as String).endsWith('allow') &&
          (rule[2] as List).any(
            (s) =>
                RegExp(r'^(Bash|Shell)(\(\*?\)|\(\*\*?\))?$|^\*$').hasMatch(s),
          )) {
        risk(
          'high',
          tr('Every shell command allowed'),
          tr('An allow rule lets any command run without asking.'),
          tr('Allow single commands such as Bash(git status) instead.'),
        );
      }
    }
    for (final setting in settings) {
      final warn = setting['warn'] as List;
      if (warn.length == 3 && choice(setting)['risk'] == 1) {
        risk(
          'low',
          warn[0],
          warn[1],
          warn[2],
          key: setting['key'],
          value: setting['recommended'],
        );
      }
    }
    if (mcpServers > 0) {
      risk(
        'low',
        i18n
            .plural('1 MCP server', '{0} MCP servers', mcpServers)
            .replaceAll('{0}', '$mcpServers'),
        tr(
          'Each runs as you and gives the agent more tools; one that is compromised can read or change your files.',
        ),
        tr(
          'Keep only servers you use and trust; remove the others on the map.',
        ),
      );
    }
    if (!sandboxed && known) {
      risk(
        'low',
        tr('Works with your rights'),
        tr(
          'Without a sandbox, what the agent runs can read everything you can: SSH keys, browser profiles, documents.',
        ),
        tr(
          'Start it in the project folder, keep secrets out of it, review what it wants to run.',
        ),
      );
    }
    for (final setting in settings) {
      final selected = choice(setting);
      if (selected['risk'] == 0) {
        risk(
          'ok',
          '${setting['title']}: ${selected['label']}',
          selected['explain'],
          '',
        );
      }
    }
    if (sandboxed && choice(sandbox)['risk'] != 0) {
      risk(
        'ok',
        '${sandbox['title']}: ${choice(sandbox)['label']}',
        choice(sandbox)['explain'],
        '',
      );
    }
    final order = {'high': 0, 'medium': 1, 'low': 2, 'ok': 3},
        original = {for (var i = 0; i < risks.length; i++) risks[i]: i};
    risks.sort((a, b) {
      final priority = order[a['level']]!.compareTo(order[b['level']]!);
      return priority != 0 ? priority : original[a]!.compareTo(original[b]!);
    });
    final levels = [
      for (final setting in settings)
        ['low', 'low', 'medium', 'high'][choice(setting)['risk'] as int],
      for (final risk in risks)
        if (['low', 'medium', 'high'].contains(risk['level']))
          risk['level'] as String,
    ];
    final level = levels.isEmpty
        ? 'medium'
        : levels.contains('high')
        ? 'high'
        : levels.contains('medium')
        ? 'medium'
        : 'low';
    final note = known
        ? tr(spec['note'])
        : tr(
            'AI Agents Map does not know this agent\'s security settings yet. Look in its own settings or documentation for “permissions”, “approval” and “sandbox”.',
          );
    return {
      'agent': adapter.command,
      'known': known,
      'settings': settings,
      'rules': rules,
      'risks': risks,
      'files': path.isEmpty ? [] : [files.expand(path)],
      'note': note,
      'glossary': ['sandbox', 'approval', 'rules', 'mcp'],
      'level': level,
    };
  }
}
