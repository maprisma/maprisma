import 'dart:io';
import 'provider_facts.dart' show visibleProviderFacts;
import 'py_values.dart' show pyStr, pyTruthy;

/// agent_status.agent_checks / runtime_checks / summary_line: is an agent, or
/// a local LLM, ready to use? Each check with what to do next when it is not.
/// Only whether a credential file is there is looked at (a stat, never a
/// read). The texts are the reference's, translated by [tr].

const waitingForAuth = 'Waiting for auth';
const signInExpiredText = 'Sign-in expired';
const limitsPaused = 'Limits paused';
const issueKinds = ['vte4', 'terminal'];

Map<String, dynamic> check(
  String state,
  String title, [
  String detail = '',
  String step = '',
  String command = '',
  String signIn = '',
]) => {
  'state': state,
  'title': title,
  'detail': detail,
  'step': step,
  'command': command,
  'sign_in': signIn,
};

/// graph.split_model: "qwen (llama-local)" → (qwen, llama-local);
/// "anthropic/claude" → (claude, anthropic).
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

final class SetupChecks {
  SetupChecks({
    required this.tr,
    required this.home,
    required this.environment,
    required this.desktop,
    required this.installCommand,
  });
  final String Function(String) tr;
  final String home;
  final Map<String, String> environment;

  /// "omarchy" or "generic": how things are done on this desktop.
  final String desktop;
  final String Function(String package) installCommand;

  String f(String text, List<Object?> args) {
    var out = tr(text);
    for (var i = 0; i < args.length; i++) {
      out = out.replaceAll('{$i}', '${args[i]}');
    }
    return out;
  }

  /// desktop.text.
  String desktopText(String key) => tr(
    desktop == 'omarchy'
        ? const {
            'install_agent':
                "Install it from Omarchy's menu: Setup → Defaults → Agent.",
            'install_agent_first':
                "Install one from Omarchy's menu: Setup → Defaults → Agent (Claude Code, Codex or OpenCode to start with).",
            'install_agent_short': "Omarchy's menu: Setup → Defaults → Agent.",
            'install_coding_agent':
                "Claude Code, Codex or OpenCode: Omarchy's menu → Setup → Defaults → Agent.",
            'install_terminal': 'Install the terminal launcher Omarchy uses:',
          }[key]!
        : const {
            'install_agent':
                "Install it with its own installer (see the agent's website).",
            'install_agent_first':
                'Install one with its own installer (Claude Code, Codex or OpenCode to start with).',
            'install_agent_short':
                'Each agent has its own installer (see its website).',
            'install_coding_agent':
                'Claude Code, Codex or OpenCode, each with its own installer.',
            'install_terminal': 'Install a terminal app (Console, Konsole, …):',
          }[key]!,
  );

  /// agent_status.issue_text.
  (String, String, String) issueText(String kind) => kind == 'vte4'
      ? (
          tr(
            'The terminal inside the map needs the vte4 package, so it started in a separate terminal.',
          ),
          tr(
            'Install it (it needs your password); the next Start then runs inside the map:',
          ),
          installCommand('vte4'),
        )
      : (
          tr('No terminal was found to start it in.'),
          desktopText('install_terminal'),
          installCommand('xdg-terminal-exec'),
        );

  /// agent_status.credentials_present: an API-key variable set, or a
  /// credential file there (only whether it is).
  bool credentialsPresent(Map access) {
    for (final name in access['env'] as List? ?? const []) {
      if ((environment['$name'] ?? '').isNotEmpty) return true;
    }
    for (final name in access['files'] as List? ?? const []) {
      try {
        if (FileSystemEntity.typeSync('$home/$name') ==
            FileSystemEntityType.file) {
          return true;
        }
      } on FileSystemException {
        continue;
      }
    }
    return false;
  }

  /// agent_status.sign_in_expired.
  bool signInExpired(Map record, Map? access) {
    final status = pyTruthy(record['usageStatusText'])
        ? pyStr(record['usageStatusText'])
        : '';
    if (status == signInExpiredText) return true;
    if (status != waitingForAuth) return false;
    return pyTruthy(record['ready']) ||
        (access != null && credentialsPresent(access));
  }

  static String _cut(String text, int limit) {
    final runes = text.runes;
    return runes.length <= limit
        ? text
        : String.fromCharCodes(runes.take(limit));
  }

  /// link_check.add_model_step: where a local LLM's models come from.
  String addModelStep(Map rt) => switch (rt['key']) {
    'jan' => tr(
      'add one in the Jan app (Hub), or right-click Jan on the map → Models….',
    ),
    'lmstudio' => tr(
      'download one in LM Studio (Discover), or right-click LM Studio on the map → Models….',
    ),
    'vllm' => f(
      'vLLM serves one Hugging Face model: write its id into {0} (VLLM_MODEL=…), then start vLLM.',
      ['$home/.config/vllm/server.env'],
    ),
    _ => f(
      'right-click {0} on the map → Models… and download one that fits your card.',
      [rt['name']],
    ),
  };

  /// agent_details.plan_label.
  static String planLabel(dynamic raw) {
    final text = pyTruthy(raw)
        ? _cut(
            pyStr(
              raw,
            ).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' '),
            40,
          )
        : '';
    return const {
          'free': 'Free',
          'go': 'Go',
          'plus': 'Plus',
          'pro': 'Pro',
          'prolite': 'Pro Lite',
          'team': 'Team',
          'business': 'Business',
          'enterprise': 'Enterprise',
          'edu': 'Edu',
        }[text.trim().toLowerCase()] ??
        text;
  }

  /// agent_status.agent_checks.
  List<Map<String, dynamic>> agentChecks({
    required Map agent,
    required Map info,
    required Map record,
    required List<Map> runtimes,
    required List<String> mcp,
    required List<String> skills,
    required Map hints,
    Map? access,
    bool? loggedIn,
    Map? issue,
  }) {
    final checks = <Map<String, dynamic>>[];
    if (agent['installed'] != true) {
      return [
        check('missing', tr('Not installed'), '', desktopText('install_agent')),
      ];
    }
    final version = '${agent['version'] ?? ''}';
    checks.add(check('ok', tr('Installed'), version));
    if (issue != null && issueKinds.contains(issue['kind'])) {
      final (what, step, command) = issueText(issue['kind'] as String);
      checks.add(
        check('warn', tr('Start ran into a problem'), what, step, command),
      );
    }
    final (model, provider) = splitModel('${info['model'] ?? ''}');
    final providers = (info['providers'] as List? ?? const []).cast<Map>();
    final localNames = {
      for (final p in providers)
        if (p['local'] == true) '${p['name']}',
    };
    final usesLocal = provider.isNotEmpty && localNames.contains(provider);
    final name = '${agent['name']}';
    final command = '${agent['command']}';
    final hasRecord = record.isNotEmpty;
    if (usesLocal) {
      checks.add(
        check(
          'ok',
          tr('No account needed'),
          tr('It uses a local LLM on this computer.'),
        ),
      );
    } else if (signInExpired(record, access)) {
      final login = access == null ? '' : '${access['login'] ?? ''}';
      checks.add(
        check(
          'missing',
          tr('Sign-in expired'),
          f(
            '{0} is signed in, but its service no longer accepts the sign-in (it ran out, or the plan was changed), so its plan and limits cannot be shown.',
            [name],
          ),
          login.isNotEmpty
              ? tr('Sign in again, then refresh this page:')
              : tr('Sign in again, then refresh this page.'),
          login,
          command,
        ),
      );
    } else if (hasRecord &&
        pyTruthy(record['ready']) &&
        pyTruthy(record['tierLabel'])) {
      checks.add(
        check(
          'ok',
          tr('Signed in'),
          f('Plan: {0}', [planLabel(record['tierLabel'])]),
        ),
      );
    } else if (hasRecord &&
        pyTruthy(record['authHelpText']) &&
        !pyTruthy(record['ready'])) {
      checks.add(
        check(
          'missing',
          tr('Not signed in'),
          _cut(
            pyTruthy(record['usageStatusText'])
                ? pyStr(record['usageStatusText'])
                : '',
            200,
          ),
          _cut(pyStr(record['authHelpText']), 300),
          '',
          command,
        ),
      );
    } else if (access != null &&
        access['local_ok'] == true &&
        (access['files'] as List? ?? const []).isEmpty &&
        (access['env'] as List? ?? const []).isEmpty &&
        '${access['login'] ?? ''}'.isEmpty) {
      checks.add(check('ok', tr('No account needed'), tr('${access['how']}')));
    } else if (access != null) {
      final how = tr('${access['how']}');
      final login = '${access['login'] ?? ''}';
      final signedIn = loggedIn ?? credentialsPresent(access);
      if (signedIn) {
        checks.add(
          check('ok', tr('Signed in'), tr('Its sign-in or API key is set up.')),
        );
      } else if (access['local_ok'] == true && localNames.isNotEmpty) {
        checks.add(
          check(
            'info',
            tr('No account set up'),
            tr('It can use the local LLMs it is connected to.'),
            how + (login.isNotEmpty ? ' · ${f('Sign in: {0}', [login])}' : ''),
            '',
            command,
          ),
        );
      } else {
        checks.add(
          check(
            'missing',
            tr('Not signed in'),
            how,
            login.isNotEmpty ? f('Sign in: {0}', [login]) : how,
            '',
            command,
          ),
        );
      }
    } else if (model.isEmpty &&
        providers.isEmpty &&
        !(visibleProviderFacts['cloud'] as Map).containsKey(command)) {
      checks.add(
        check(
          'missing',
          tr('No model set up'),
          tr(
            'It has no model service of its own, and none is set up in its settings.',
          ),
          tr(
            'Draw a line on the map from it to a local LLM, or set up a provider in the agent itself (OpenClaw: openclaw onboard).',
          ),
        ),
      );
    } else {
      checks.add(
        check(
          'info',
          tr('Sign-in unknown'),
          tr('Maprisma does not know how this agent signs in.'),
        ),
      );
    }
    if (hasRecord &&
        (pyTruthy(record['usageStatusText'])
                ? pyStr(record['usageStatusText'])
                : '') ==
            limitsPaused &&
        !usesLocal) {
      checks.add(
        check(
          'info',
          tr('Limits paused'),
          f(
            '{0} renews its sign-in itself the next time it runs; then its limits come back. Signing in again is not needed.',
            [name],
          ),
        ),
      );
    }
    if (model.isNotEmpty) {
      checks.add(
        check(
          'ok',
          tr('Model'),
          model + (provider.isNotEmpty ? ' · $provider' : ''),
        ),
      );
    } else if (checks.any((c) => c['title'] == tr('No model set up'))) {
      // Said above, with what to do.
    } else if (localNames.isNotEmpty) {
      checks.add(
        check(
          'warn',
          tr('No model chosen'),
          '',
          tr(
            'Draw a line on the map from the agent to a model of a local LLM it is connected to.',
          ),
        ),
      );
    } else {
      checks.add(check('info', tr('Model'), tr("the agent's own default")));
    }
    final byName = {for (final rt in runtimes) '${rt['name']}': rt};
    for (final p in providers) {
      if (p['local'] != true) continue;
      final rt = byName['${p['runtime'] ?? ''}'];
      final active = p['active'] == true;
      final problem = active ? 'missing' : 'info';
      final unused = active
          ? ''
          : tr('Not in use: it only matters when the agent is switched to it.');
      final label = '${p['runtime'] ?? ''}'.isNotEmpty
          ? '${p['runtime']}'
          : '${p['name']}';
      if (rt == null || rt['installed'] != true) {
        checks.add(
          check(
            problem,
            f('{0} is not installed', [label]),
            unused,
            tr('Install it: its card on Setup → Install.'),
          ),
        );
      } else if ((rt['models'] as List? ?? const []).isEmpty) {
        final step = addModelStep(rt);
        checks.add(
          check(
            problem,
            f('{0} has no models', [rt['name']]),
            unused,
            step.isEmpty ? step : step[0].toUpperCase() + step.substring(1),
          ),
        );
      } else if (active && rt['server_off'] == true) {
        checks.add(
          check(
            'missing',
            f("{0}'s server is off", [rt['name']]),
            tr(
              'The app is open, but the agent reaches it only through its server.',
            ),
            tr('Start server in its menu on the map (lms server start).'),
          ),
        );
      } else if (active && rt['running'] != true) {
        checks.add(
          check(
            'ok',
            '${rt['name']}',
            rt['can_control'] == true
                ? tr('starts with the agent')
                : tr('installed, not running'),
          ),
        );
      } else {
        checks.add(
          check(
            'ok',
            '${rt['name']}',
            rt['running'] == true ? tr('running') : tr('set up'),
          ),
        );
      }
    }
    final keys = [for (final k in hints.keys) '$k']..sort();
    for (final key in keys) {
      if (!key.startsWith('agent:$command|')) continue;
      final entry = hints[key] as Map;
      final list = (entry['hints'] as List? ?? const []).cast<Map>();
      final first = list.isNotEmpty ? '${list.first['text']}' : '';
      final target = key.substring(key.indexOf('|') + 1);
      final shown = target.contains(':')
          ? target.substring(target.indexOf(':') + 1)
          : '';
      final error =
          pyTruthy(entry['kind']) && list.any((h) => h['level'] == 'error');
      checks.add(
        check(
          error ? 'missing' : 'warn',
          f('A connection does not work: {0}', [shown]),
          first,
          tr('Click its dotted line on the map for all hints and Test again.'),
        ),
      );
    }
    checks.add(
      mcp.isNotEmpty
          ? check('ok', tr('MCP servers'), mcp.join(', '))
          : check(
              'info',
              tr('No MCP servers yet'),
              '',
              tr(
                'Add one: Add MCP server on Setup, then draw a line from the agent to it on the map.',
              ),
            ),
    );
    checks.add(
      skills.isNotEmpty
          ? check('ok', tr('Skills'), skills.join(', '))
          : check(
              'info',
              tr('No skills yet'),
              '',
              tr('Add some: Add skills on Setup.'),
            ),
    );
    return checks;
  }

  /// agent_status.runtime_checks.
  List<Map<String, dynamic>> runtimeChecks(
    Map rt,
    Map hints,
    Map<String, String> agentNames,
    bool? login,
  ) {
    if (rt['installed'] != true) {
      return [
        check(
          'missing',
          tr('Not installed'),
          '',
          tr('Install it: its card on Setup → Install.'),
        ),
      ];
    }
    final address = '${rt['address'] ?? ''}';
    final checks = [check('ok', tr('Installed'), address)];
    final active = (rt['active_agents'] as List? ?? const []).cast<String>();
    if (rt['running'] == true) {
      checks.add(check('ok', tr('Running'), address));
    } else if (rt['can_control'] == true) {
      checks.add(
        check(
          'info',
          tr('Not running'),
          active.isNotEmpty
              ? tr('starts with an agent that uses it')
              : tr('nothing uses it now'),
          active.isNotEmpty ? '' : tr('Right-click → Start to run it now.'),
        ),
      );
    } else {
      checks.add(
        check(
          'warn',
          tr('Not running'),
          tr('no user service starts it'),
          tr(
            'Start it yourself, or reinstall it from the map so a service starts it.',
          ),
        ),
      );
    }
    if (login != null) {
      checks.add(
        check(
          login ? 'ok' : 'info',
          tr('Start at login'),
          login ? tr('on') : tr('off'),
        ),
      );
    }
    final models = rt['models'] as List? ?? const [];
    final dir = '${rt['models_dir'] ?? ''}';
    if (models.isNotEmpty) {
      checks.add(
        check(
          'ok',
          tr('Models'),
          '${models.length}${dir.isNotEmpty ? ' · $dir' : ''}',
        ),
      );
    } else {
      checks.add(
        check(
          'missing',
          tr('No models'),
          '',
          tr(
            'Download one: Add model on Setup, or Models… in its menu on the map.',
          ),
        ),
      );
    }
    final users = [
      for (final a in rt['agents'] as List? ?? const [])
        agentNames['$a'] ?? '$a',
    ];
    if (users.isNotEmpty) {
      final now = [for (final a in active) agentNames[a] ?? a];
      checks.add(
        check(
          'ok',
          tr('Connected agents'),
          users.join(', ') +
              (now.isNotEmpty
                  ? ' · ${f('in use by {0}', [now.join(', ')])}'
                  : ''),
        ),
      );
    } else {
      checks.add(
        check(
          'missing',
          tr('No agent connected'),
          '',
          tr('Draw a line from an agent to this box on the map.'),
        ),
      );
    }
    final keys = [for (final k in hints.keys) '$k']..sort();
    for (final key in keys) {
      if (!key.endsWith('|runtime:${rt['key']}')) continue;
      final entry = hints[key] as Map;
      final list = (entry['hints'] as List? ?? const []).cast<Map>();
      final first = list.isNotEmpty ? '${list.first['text']}' : '';
      final head = key.substring(0, key.indexOf('|'));
      final source = head.contains(':')
          ? head.substring(head.indexOf(':') + 1)
          : '';
      checks.add(
        check(
          'missing',
          f('The connection from {0} does not work', [
            agentNames[source] ?? source,
          ]),
          first,
          tr('Click its dotted line on the map for all hints and Test again.'),
        ),
      );
    }
    return checks;
  }

  /// agent_status.summary_line: (ok | warn | missing, one sentence).
  (String, String) summaryLine(List<Map<String, dynamic>> checks) {
    final missing = checks.where((c) => c['state'] == 'missing').toList();
    final warn = checks.where((c) => c['state'] == 'warn').toList();
    if (missing.isNotEmpty) {
      return (
        'missing',
        f('Not ready yet: {0}', [missing.first['title']]) +
            (missing.length > 1
                ? ' ${f('(+{0} more to do)', [missing.length - 1])}'
                : ''),
      );
    }
    if (warn.isNotEmpty) {
      return (
        'warn',
        f('Works, one thing to look at: {0}', [warn.first['title']]),
      );
    }
    return ('ok', tr('Set up and ready'));
  }
}
