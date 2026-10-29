import 'dart:io';
import 'dart:convert';
import 'agent_catalog.dart';
import 'agent_projects.dart';
import 'desktop.dart';
import 'identity.dart';
import 'pty_sessions.dart';
import 'settings.dart';

/// ai_core: the variables an agent sets for what it starts itself.
const agentSessionExact = {
  'CLAUDECODE',
  'CLAUDE_PID',
  'CLAUDE_EFFORT',
  'AI_AGENTS_MAP_NO_PROVIDERS',
  'AI_AGENT',
  'CODEX_THREAD_ID',
  'CODEX_SANDBOX',
  'CODEX_CI',
  'OPENCODE',
  'OPENCODE_PID',
  'OPENCODE_CLIENT',
  'OPENCODE_SERVER',
  'PI_CODING_AGENT',
  'GEMINI_CLI',
  'QWEN_CODE',
  'CRUSH',
  'GOOSE_TERMINAL',
  'AMP_CURRENT_THREAD_ID',
  'COPILOT_CLI',
  'CURSOR_AGENT',
};
bool isAgentSessionVar(String name) =>
    agentSessionExact.contains(name) || name.startsWith('CLAUDE_CODE_');

/// flutter_backend's agent start, terminal sessions and project folders.
final class AgentStart {
  AgentStart(this.identity, this.settings, this.catalog, this.desktop)
    : projects = AgentProjects(identity.home);
  final AppIdentity identity;
  final SettingsStore settings;
  final AgentCatalog catalog;
  final Desktop desktop;
  final AgentProjects projects;
  final sessions = PtySessions();

  /// ai_core.add_user_program_dirs: mise's shims and ~/.local/bin at the end
  /// of PATH (what is already on it still wins).
  Map<String, String> withUserPrograms(Map<String, String> env) {
    var mise = env['MISE_DATA_DIR'] ?? '';
    if (mise.isEmpty || !mise.startsWith('/')) {
      mise = '${identity.home}/.local/share/mise';
    }
    final current = env['PATH'] ?? '';
    final path = current.split(':');
    final added = [
      for (final dir in ['$mise/shims', '${identity.home}/.local/bin'])
        if (!path.contains(dir) && _isDir(dir)) dir,
    ];
    if (added.isNotEmpty) {
      env['PATH'] = [if (current.isNotEmpty) current, ...added].join(':');
    }
    return env;
  }

  static bool _isDir(String path) {
    try {
      return Directory(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  Map<String, dynamic> start(Map<String, dynamic> params) {
    if (params.length != 3 ||
        !const {'command', 'path', 'outside'}.every(params.containsKey) ||
        params['outside'] is! bool) {
      throw const FormatException('Invalid start request');
    }
    final command = params['command'];
    if (command is! String) throw const FormatException('Invalid agent');
    final agent = catalog
        .scan()
        .where((a) => a.command == command && a.installed)
        .firstOrNull;
    final facts = agent?.adapter.facts ?? const {};
    if (agent == null || facts['chat_app'] == true) {
      throw const FormatException('No terminal program for this agent');
    }
    final saved = settings.load();
    final chosen =
        params['path'] ?? projects.projects(command, saved)['default'];
    final folder = projects.folder(chosen);
    if (folder == null) {
      throw const FormatException('Project folder unavailable');
    }
    final env = Map<String, String>.from(identity.environment)
      ..removeWhere((k, _) => isAgentSessionVar(k));
    withUserPrograms(env);
    env['TERM'] = 'xterm-256color';
    env['COLORTERM'] = 'truecolor';
    env.remove('AI_AGENTS_MAP_PAGE');
    env.remove('AI_AGENTS_MAP_VIEW');
    final program = whichIn(command, env['PATH']);
    if (program == null) throw const FormatException('Program unavailable');
    final argv = [
      program,
      for (final a in facts['start'] as List? ?? const []) '$a',
    ];
    String? ident;
    if (params['outside'] == true) {
      // env removes inherited session markers without a shell command.
      final unset = [
        for (final name in identity.environment.keys)
          if (isAgentSessionVar(name) ||
              name == 'AI_AGENTS_MAP_PAGE' ||
              name == 'AI_AGENTS_MAP_VIEW') ...[
            '-u',
            name,
          ],
      ];
      final launcher = whichIn('env', identity.environment['PATH']);
      if (launcher == null ||
          !desktop.openTerminal([
            launcher,
            ...unset,
            'PATH=${env['PATH']}',
            'TERM=xterm-256color',
            'COLORTERM=truecolor',
            ...argv,
          ], folder)) {
        throw const FileSystemException('Terminal could not be opened');
      }
    } else {
      ident = sessions.start(command, argv, folder, env);
    }
    try {
      settings.saveOwn({
        'agent_project_history': projects.used(
          command,
          folder,
          settings.load()['agent_project_history'] ?? {},
        ),
      });
    } catch (_) {
      if (ident != null) sessions.stop(ident);
      rethrow;
    }
    return {'session': ident, 'command': command, 'path': folder};
  }

  static const _sessionFields = {
    'sessions.read': {'session'},
    'sessions.write': {'session', 'data'},
    'sessions.resize': {'session', 'cols', 'rows'},
    'sessions.stop': {'session'},
  };

  Map<String, dynamic> session(String method, Map<String, dynamic> params) {
    final expected = _sessionFields[method]!;
    if (params.length != expected.length ||
        !expected.every(params.containsKey) ||
        params['session'] is! String) {
      throw const FormatException('Invalid session request');
    }
    final ident = params['session'] as String;
    if (!sessions.items.containsKey(ident)) {
      throw const FormatException('Unknown session');
    }
    switch (method) {
      case 'sessions.read':
        return sessions.read(ident);
      case 'sessions.stop':
        return sessions.stop(ident);
      case 'sessions.resize':
        return sessions.resize(ident, params['cols'], params['rows']);
    }
    final data = params['data'];
    if (data is! String || data.length > 24 * 1024) {
      throw const FormatException('Invalid terminal input');
    }
    final List<int> bytes;
    try {
      bytes = base64.decode(data);
    } on FormatException {
      throw const FormatException('Invalid terminal input');
    }
    return sessions.write(ident, bytes);
  }

  Map<String, dynamic> project(String method, Map<String, dynamic> params) {
    if (params.length != 2 ||
        !params.containsKey('command') ||
        !params.containsKey('path')) {
      throw const FormatException('Expected command and path');
    }
    final command = params['command'], path = params['path'];
    if (command is! String ||
        !catalog.scan().any((a) => a.command == command)) {
      throw const FormatException('Unknown agent');
    }
    if (path != null && (path is! String || path.length > 4096)) {
      throw const FormatException('Invalid path');
    }
    final saved = settings.load();
    final pinned = saved['agent_projects'] ?? {};
    if (method == 'projects.pin') {
      settings.saveOwn({
        'agent_projects': projects.pin(command, path as String?, pinned),
      });
    } else {
      if (path is! String) {
        throw const FormatException('Expected a history path');
      }
      final (history, pins) = projects.forget(
        command,
        path,
        saved['agent_project_history'] ?? {},
        pinned,
      );
      settings.saveOwn({
        'agent_project_history': history,
        'agent_projects': pins,
      });
    }
    return projects.projects(command, settings.load());
  }
}
