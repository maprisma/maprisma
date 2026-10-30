import 'dart:convert';
import 'dart:io';
import 'agent_catalog.dart';
import 'agent_start.dart' show isAgentSessionVar;
import 'core_tasks.dart' show newHandle, coreHandle;
import 'desktop.dart';
import 'identity.dart';
import 'pty_sessions.dart';
import 'settings.dart';

/// install_recipes: an agent's ways to install, update or remove it, as the
/// step for this PC. Only plain words are started (in a terminal the user
/// watches); anything else is only shown, to copy.
const _managers = {
  'pacman': (['pacman', '-S', '--needed'], ['pacman', '-R']),
  'apt': (['apt', 'install'], ['apt', 'remove']),
  'dnf': (['dnf', 'install'], ['dnf', 'remove']),
  'zypper': (['zypper', 'install'], ['zypper', 'remove']),
};
const _tools = {
  'npm': (['npm', 'install', '-g'], ['npm', 'uninstall', '-g']),
  'pipx': (['pipx', 'install'], ['pipx', 'uninstall']),
  'uv': (['uv', 'tool', 'install'], ['uv', 'tool', 'uninstall']),
};
const _updates = {
  'npm': ['npm', 'update', '-g'],
  'pipx': ['pipx', 'upgrade'],
  'uv': ['uv', 'tool', 'upgrade'],
};
final _word = RegExp(r'^[A-Za-z0-9@:/._=+,-]{1,300}$');
final _program = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$');
final _package = RegExp(r'^[a-z0-9@][a-z0-9@._+-]{0,99}$');
const testPrompt = 'Reply with one short sentence: are you ready?';

final class Step {
  Step(
    this.kind, {
    this.commands = const [],
    this.run,
    this.sudo = false,
    this.installer = false,
    this.url = '',
    this.note = '',
  });
  final String kind, url, note;
  final List<String> commands;
  final List<List<String>>? run;
  final bool sudo, installer;
}

final class Recipes {
  Recipes(this.path);
  final String? path; // the PATH programs are looked up on
  bool has(String program) => whichIn(program, path) != null;

  String manager() => _managers.keys.firstWhere(has, orElse: () => '');

  static List<String>? _plain(List words) {
    final text = [for (final w in words) '$w'];
    if (text.isEmpty) return null;
    final first = text.first != 'sudo'
        ? text.first
        : (text.length > 1 ? text[1] : '-');
    if (!_program.hasMatch(first)) return null;
    return text.every(_word.hasMatch) ? text : null;
  }

  static List<List<String>>? runnable(List<List> commands) {
    final found = [for (final c in commands) _plain(c)];
    return found.every((c) => c != null) ? found.cast<List<String>>() : null;
  }

  List<String> _list(dynamic v) => v is List ? [for (final x in v) '$x'] : [];

  Step? _update(Map way) {
    final kind = way['kind'], spec = '${way['spec'] ?? ''}';
    final tool = '${way['tool'] ?? ''}', update = _list(way['update']);
    if (kind == 'installer') return Step('installer', installer: true);
    if (kind == 'mise' && spec.isNotEmpty && has('mise')) {
      final argv = ['mise', '--yes', 'upgrade', spec];
      return Step('mise', commands: [shellJoin(argv)], run: runnable([argv]));
    }
    if (kind == 'tool' &&
        _updates.containsKey(tool) &&
        spec.isNotEmpty &&
        has(tool)) {
      final argv = [..._updates[tool]!, spec];
      return Step('tool', commands: [shellJoin(argv)], run: runnable([argv]));
    }
    if (kind == 'command' && update.isNotEmpty && has(update.first)) {
      return Step(
        'command',
        commands: [shellJoin(update)],
        run: runnable([update]),
        sudo: way['sudo'] == true || update.first == 'sudo',
      );
    }
    if (kind == 'package' && _packages(way)[manager()] != null) {
      return Step('manual', note: "It comes with the system's updates.");
    }
    return null;
  }

  Map<String, dynamic> _packages(Map way) => {
    for (final pair in way['packages'] as List? ?? const [])
      if (pair is List && pair.length == 2) '${pair[0]}': pair[1],
  };

  Step? _step(Map way, String action) {
    if (action == 'update') return _update(way);
    final remove = action == 'uninstall';
    final kind = way['kind'], spec = '${way['spec'] ?? ''}';
    final tool = '${way['tool'] ?? ''}', argv = _list(way['argv']);
    if (kind == 'installer') return Step('installer', installer: true);
    if (kind == 'mise') {
      if (spec.isEmpty || !has('mise')) return null;
      final commands = remove
          ? [
              ['mise', '--yes', 'unuse', '-g', spec],
              ['mise', '--yes', 'uninstall', '--all', spec],
            ]
          : [
              ['mise', '--yes', 'use', '-g', spec],
            ];
      return Step(
        'mise',
        commands: [for (final c in commands) shellJoin(c)],
        run: runnable(commands),
      );
    }
    if (kind == 'tool') {
      if (!_tools.containsKey(tool) || spec.isEmpty || !has(tool)) return null;
      final words = [...(remove ? _tools[tool]!.$2 : _tools[tool]!.$1), spec];
      return Step('tool', commands: [shellJoin(words)], run: runnable([words]));
    }
    if (kind == 'command') {
      if (remove || argv.isEmpty || !has(argv.first)) return null;
      return Step(
        'command',
        commands: [shellJoin(argv)],
        run: runnable([argv]),
        sudo: way['sudo'] == true,
      );
    }
    if (kind == 'package') {
      final m = manager(), name = _packages(way)[m];
      if (m.isEmpty || name is! String || !_package.hasMatch(name)) return null;
      final words = [
        'sudo',
        ...(remove ? _managers[m]!.$2 : _managers[m]!.$1),
        name,
      ];
      return Step(
        'package',
        commands: [shellJoin(words)],
        run: runnable([words]),
        sudo: true,
      );
    }
    if (kind == 'manual') {
      return Step(
        'manual',
        url: '${way['url'] ?? ''}',
        note: '${way['note'] ?? ''}',
      );
    }
    return null;
  }

  /// choose: the way to install (update, remove) on this PC.
  Step? choose(List ways, String action, String source) {
    var list = ways.whereType<Map>().toList();
    if (action == 'uninstall' || action == 'update') {
      const prefer = {
        'mise': ['mise'],
        'package': ['package', 'command'],
        'own': ['installer', 'tool', 'command'],
      };
      final kinds = prefer[source] ?? const <String>[];
      list = [
        ...list.where((w) => kinds.contains(w['kind'])),
        if (action == 'uninstall') ...list.where((w) => w['kind'] == 'manual'),
      ];
      if (action == 'update') {
        for (final way in list) {
          final step = _step(way, action);
          if (step != null) return step;
        }
        return null;
      }
    }
    for (final way in list) {
      final step = _step(way, action);
      if (step != null) return step;
    }
    final commands = <String>[];
    for (final way in list) {
      final spec = '${way['spec'] ?? ''}', tool = '${way['tool'] ?? ''}';
      if (way['kind'] == 'mise' && spec.isNotEmpty) {
        commands.add(
          shellJoin([
            'mise',
            '--yes',
            action == 'uninstall' ? 'unuse' : 'use',
            '-g',
            spec,
          ]),
        );
        if (action == 'uninstall') {
          commands.add(
            shellJoin(['mise', '--yes', 'uninstall', '--all', spec]),
          );
        }
      } else if (way['kind'] == 'tool' &&
          _tools.containsKey(tool) &&
          spec.isNotEmpty) {
        commands.add(
          shellJoin([
            ...(action == 'uninstall' ? _tools[tool]!.$2 : _tools[tool]!.$1),
            spec,
          ]),
        );
      } else if (way['kind'] == 'package') {
        for (final e in _packages(way).entries) {
          if (_managers.containsKey(e.key)) {
            commands.add(
              shellJoin([
                'sudo',
                ...(action == 'uninstall'
                    ? _managers[e.key]!.$2
                    : _managers[e.key]!.$1),
                '${e.value}',
              ]),
            );
          }
        }
      }
    }
    return commands.isEmpty ? null : Step('commands', commands: commands);
  }
}

final class ActionPlan {
  ActionPlan(this.public, this.argv, [this.step]);
  final Map<String, dynamic> public;
  final List<String> argv;
  final Step? step;
  String get signature => jsonEncode([public, argv, step?.run]);
}

/// flutter_agent_actions: reviewed agent actions; no command, argv or URL
/// comes from the app.
final class AgentActions {
  AgentActions(
    this.identity,
    this.settings,
    this.catalog,
    this.desktop,
    this.sessions,
    this.translate,
  );
  final AppIdentity identity;
  final SettingsStore settings;
  final AgentCatalog catalog;
  final Desktop desktop;
  final PtySessions sessions;
  final String Function(String) translate;
  final _previews = <String, (DateTime, Map<String, dynamic>, ActionPlan)>{};
  final _verifications = <String, (String, Directory, String)>{};

  /// The environment with the user's program folders (add_user_program_dirs).
  /// The user's environment with mise's shims and ~/.local/bin on PATH
  /// (ai_core.add_user_program_dirs).
  Map<String, String> get userEnv => _env;

  Map<String, String> get _env {
    final env = Map<String, String>.from(identity.environment);
    var mise = env['MISE_DATA_DIR'] ?? '';
    if (mise.isEmpty || !mise.startsWith('/')) {
      mise = '${identity.home}/.local/share/mise';
    }
    final current = env['PATH'] ?? '';
    final added = [
      for (final dir in ['$mise/shims', '${identity.home}/.local/bin'])
        if (!current.split(':').contains(dir) && Directory(dir).existsSync())
          dir,
    ];
    if (added.isNotEmpty) {
      env['PATH'] = [if (current.isNotEmpty) current, ...added].join(':');
    }
    return env;
  }

  bool _hasTool(String name, String? path) {
    if (whichIn(name, path) != null) return true;
    final own = File('${identity.home}/.local/bin/$name');
    try {
      return own.statSync().type == FileSystemEntityType.file &&
          own.statSync().mode & 0x40 != 0;
    } on FileSystemException {
      return false;
    }
  }

  bool _nodeReady(String? path) {
    if (_hasTool('node', path)) return true;
    final installs = Directory(
      '${identity.home}/.local/share/mise/installs/node',
    );
    try {
      return installs.listSync().any(
        (d) => File('${d.path}/bin/node').existsSync(),
      );
    } on FileSystemException {
      return false;
    }
  }

  ActionPlan resolve(Map<String, dynamic> params) {
    const allowed = {'command', 'action', 'login', 'kind'};
    if (params.keys.any((k) => !allowed.contains(k)) ||
        !params.containsKey('command') ||
        !params.containsKey('action') ||
        params['command'] is! String ||
        params['action'] is! String) {
      throw const FormatException('Invalid agent action');
    }
    final env = _env, path = env['PATH'];
    final kind = params['kind'] ?? 'agent';
    if (kind != 'agent') {
      if (kind != 'tool' ||
          params['command'] != 'node' ||
          params['action'] != 'install' ||
          params.containsKey('login')) {
        throw const FormatException('Unknown prerequisite action');
      }
      if (!_hasTool('mise', path)) {
        throw const FormatException('Install the prerequisite manager first');
      }
      final mise = whichIn('mise', path) ?? '${identity.home}/.local/bin/mise';
      final argv = [mise, '--yes', 'use', '-g', 'node@lts'];
      final step = Step('command', commands: [shellJoin(argv)], run: [argv]);
      return ActionPlan(
        {
          'command': 'node',
          'name': 'Node.js',
          'action': 'install',
          'commands': step.commands,
          'note': '',
          'url': '',
          'data': <String>[],
          'installed': _nodeReady(path),
          'version': '',
          'source': '',
          'runnable': true,
          'external': true,
          'logins': <String>[],
        },
        [],
        step,
      );
    }
    final command = params['command'] as String,
        action = params['action'] as String;
    if (!const {
      'install',
      'update',
      'uninstall',
      'login',
      'logout',
      'verify',
    }.contains(action)) {
      throw const FormatException('Unknown agent action');
    }
    final agent = catalog.scan().where((a) => a.command == command).firstOrNull;
    if (agent == null) throw const FormatException('Unavailable agent');
    final facts = agent.adapter.facts;
    final public = <String, dynamic>{
      'command': command,
      'name': agent.name,
      'action': action,
      'commands': <String>[],
      'note': '',
      'url': '',
      'data': <String>[],
      'installed': agent.installed,
      'version': agent.version,
      'source': agent.source,
      'runnable': false,
      'external': false,
      'logins': <String>[],
    };
    if (const {'install', 'update', 'uninstall'}.contains(action)) {
      if (params.containsKey('login') ||
          action != 'install' && !agent.installed) {
        throw const FormatException('Invalid lifecycle action');
      }
      final step = Recipes(
        path,
      ).choose(facts['install'] as List? ?? const [], action, agent.source);
      if (step == null) throw const FormatException('No installation recipe');
      public
        ..['commands'] = step.commands
        ..['note'] = step.note
        ..['url'] = step.url
        ..['data'] = action == 'uninstall'
            ? [for (final d in facts['data'] as List? ?? const []) '$d']
            : <String>[]
        ..['runnable'] = step.run != null && !step.installer
        ..['external'] = true;
      return ActionPlan(public, [], step);
    }
    if (!agent.installed) throw const FormatException('Agent is not installed');
    final access = agent.adapter.table('access');
    List<String> argv;
    if (action == 'logout') {
      final logout = access['logout'] as List? ?? const [];
      if (params.containsKey('login') || logout.isEmpty) {
        throw const FormatException('No registered sign-out command');
      }
      argv = [for (final a in logout) '$a'];
    } else if (action == 'verify') {
      if (params.containsKey('login')) {
        throw const FormatException('Invalid test request');
      }
      final ask = [
        for (final a in agent.adapter.table('ask')['argv'] as List? ?? const [])
          '$a',
      ];
      if (ask.isEmpty || !ask.contains('{prompt}')) {
        throw const FormatException('No fixed test command');
      }
      argv = [
        whichIn(ask.first, path) ?? ask.first,
        for (final a in ask.skip(1)) a == '{prompt}' ? testPrompt : a,
      ];
      public['note'] = testPrompt;
    } else {
      final logins = [
        for (final l in access['logins'] as List? ?? const [])
          if (l is Map) l,
      ];
      final index = params['login'] ?? 0;
      if (index is! int || index < 0 || index >= logins.length) {
        throw const FormatException('No registered sign-in command');
      }
      argv = [for (final a in logins[index]['argv'] as List) '$a'];
      public['logins'] = [for (final l in logins) translate('${l['label']}')];
      final note = logins[index]['note'];
      public['note'] = note is String && note.isNotEmpty ? translate(note) : '';
    }
    final binary = argv.isEmpty ? null : whichIn(argv.first, path);
    if (binary == null) throw const FormatException('Program unavailable');
    argv[0] = binary;
    public
      ..['commands'] = [shellJoin(argv)]
      ..['runnable'] = true;
    return ActionPlan(public, argv);
  }

  Map<String, dynamic> preview(Map<String, dynamic> params) {
    final plan = resolve(params);
    final now = DateTime.now();
    _previews.removeWhere((_, v) => now.difference(v.$1).inSeconds >= 300);
    while (_previews.length >= 16) {
      _previews.remove(_previews.keys.first);
    }
    final token = plan.public['runnable'] == true
        ? newHandle().substring(coreHandle.length)
        : null;
    if (token != null) _previews[token] = (now, Map.of(params), plan);
    return {...plan.public, 'preview': token};
  }

  Map<String, dynamic> apply(String token) {
    final kept = _previews[token];
    if (kept == null) {
      throw const FormatException('Unknown agent action preview');
    }
    final (created, params, previous) = kept;
    if (DateTime.now().difference(created).inSeconds >= 300) {
      throw const FormatException('Agent action preview expired');
    }
    final plan = resolve(params);
    if (plan.public['runnable'] != true ||
        plan.signature != previous.signature) {
      throw const FormatException('Agent action changed; preview again');
    }
    if (const {'update', 'uninstall'}.contains(params['action']) &&
        sessions.items.values.any(
          (s) => s.command == params['command'] && sessions.running(s),
        )) {
      throw const FormatException(
        'Finish the owned agent before updating or removing it',
      );
    }
    Map<String, dynamic> result;
    if (plan.public['external'] == true) {
      if (!desktop.runStepsInTerminal(
        plan.step!.run!,
        translate('Done. Press Enter to close.'),
      )) {
        throw const FormatException('No terminal available');
      }
      result = {'external': true};
    } else {
      final env = _env..removeWhere((k, _) => isAgentSessionVar(k));
      env
        ..['TERM'] = 'xterm-256color'
        ..['COLORTERM'] = 'truecolor'
        ..['MAPRISMA_NO_PROVIDERS'] = '1'
        ..remove('MAPRISMA_PAGE')
        ..remove('MAPRISMA_VIEW');
      final temporary = params['action'] == 'verify'
          ? Directory.systemTemp.createTempSync('asterism-agent-test-')
          : null;
      final cwd = temporary?.path ?? identity.home;
      String ident;
      try {
        ident = sessions.start(
          params['command'] as String,
          plan.argv,
          cwd,
          env,
        );
      } catch (_) {
        temporary?.deleteSync(recursive: true);
        rethrow;
      }
      if (temporary != null) {
        _verifications[ident] = (params['command'] as String, temporary, '');
      }
      result = {'session': ident, 'command': plan.public['name'], 'path': cwd};
    }
    _previews.remove(token);
    return result;
  }

  /// observe: the test's answer seen, the agent marked as working.
  void observe(String ident, Map<String, dynamic> result) {
    final kept = _verifications[ident];
    if (kept == null) return;
    final (command, temporary, tail) = kept;
    final text = tail + (result['text'] as String);
    final cut = text.length > 4096 ? text.substring(text.length - 4096) : text;
    _verifications[ident] = (command, temporary, cut);
    if (result['ended'] != true) return;
    try {
      final cleaned = cut
          .replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '')
          .trim();
      if (result['exit_code'] == 0 && cleaned.length >= 2) {
        final saved = settings.load()['first_agent'];
        final state = saved is Map
            ? Map<String, dynamic>.from(saved)
            : <String, dynamic>{};
        final before = state['verified'];
        final verified = before is List
            ? [
                for (final x in before)
                  if (x is String && x != command) x,
              ]
            : <String>[];
        settings.saveOwn({
          'first_agent': {
            ...state,
            'verified': [...verified, command],
          },
        });
      }
    } catch (_) {
      result['verification_failed'] = true;
    } finally {
      forget(ident);
    }
  }

  void forget(String ident) {
    final kept = _verifications.remove(ident);
    if (kept == null) return;
    try {
      kept.$2.deleteSync(recursive: true);
    } catch (_) {
      // gone already
    }
  }
}
