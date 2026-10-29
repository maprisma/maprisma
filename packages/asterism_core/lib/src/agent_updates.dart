import 'dart:convert';
import 'dart:io';
import 'adapters.dart' show Adapter;
import 'desktop.dart' show whichIn;
import 'installers.dart' show Gpu, Installer;
import 'model_hub.dart' show boundedOutput, netFetch;

/// agent_updates: updates for the installed agents and local LLMs, each
/// checked the way it was installed, so Update installs what was found:
/// mise (`mise outdated --json`, Update runs `mise upgrade TOOL` in a
/// terminal), an agent's own updater and release channel (Claude Code: npm's
/// dist-tags), and the app's own installs (the installer's latest release;
/// Update opens the install review). Asked at most every [checkEvery]
/// seconds (the answers are cached owner-only). Nothing is installed or run
/// here except `mise outdated`.

const tagsUrl =
    'https://registry.npmjs.org/-/package/@anthropic-ai/claude-code/dist-tags';
const checkEvery = 6 * 3600;
const channels = ['latest', 'stable'];
const _maxOutput = 256 * 1024;
final _version = RegExp(r'^\d{1,6}(\.\d{1,6}){1,3}$');
final toolRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,99}$');
final _shown = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$');

Map<String, dynamic> update(
  String kind,
  String key,
  String name,
  String current,
  String available, {
  List<String> command = const [],
  bool page = false,
}) => {
  'kind': kind,
  'key': key,
  'name': name,
  'current': current,
  'available': available,
  'command': command,
  'page': page,
};

/// agent_updates.parse.
List<int>? parseVersion(dynamic version) {
  var text = '${version ?? ''}'.trim();
  text = text.replaceFirst(RegExp(r'^v+'), '').split('-').first;
  return _version.hasMatch(text)
      ? [for (final p in text.split('.')) int.parse(p)]
      : null;
}

/// agent_updates.newer: available > installed, both readable.
bool newer(String available, String installed) {
  final a = parseVersion(available), b = parseVersion(installed);
  if (a == null || b == null) return false;
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return a.length > b.length;
}

/// agent_updates.channel: Claude Code's release channel.
String claudeChannel(String home) {
  try {
    final data = jsonDecode(
      File('$home/.claude/settings.json').readAsStringSync(),
    );
    final value = data is Map ? data['autoUpdatesChannel'] : null;
    return channels.contains(value) ? value as String : 'latest';
  } on Object {
    return 'latest';
  }
}

/// agent_updates.claude_channel_latest.
Future<String?> claudeChannelLatest(
  String channel, {
  Future<dynamic> Function(String)? fetch,
}) async {
  dynamic tags;
  try {
    tags =
        await (fetch ??
            (url) async => jsonDecode(
              utf8.decode(
                await netFetch(
                  url,
                  maxBytes: 16 * 1024,
                  timeout: 10,
                  redirects: 0,
                ),
              ),
            ))(tagsUrl);
  } on Object {
    return null;
  }
  final version = tags is Map ? tags[channel] : null;
  return version is String && parseVersion(version) != null ? version : null;
}

/// agent_updates.mise_outdated: tool → (current, latest).
Future<Map<String, (String, String)>> miseOutdated(String? path) async {
  final mise = whichIn('mise', path);
  if (mise == null) return {};
  final (out, ok) = await boundedOutput(
    [mise, 'outdated', '--json'],
    maxBytes: _maxOutput,
    timeout: const Duration(seconds: 60),
  );
  if (!ok) return {};
  dynamic data;
  try {
    final text = utf8.decode(out, allowMalformed: true);
    data = jsonDecode(text.isEmpty ? '{}' : text);
  } on FormatException {
    return {};
  }
  return parseOutdated(data);
}

Map<String, (String, String)> parseOutdated(dynamic data) {
  final found = <String, (String, String)>{};
  for (final e in (data is Map ? data.entries : const <MapEntry>[])) {
    final item = e.value;
    if (item is! Map || !toolRe.hasMatch('${e.key}')) continue;
    String text(dynamic v) =>
        v == null || v == '' || v == false || v == 0 ? '' : '$v';
    final current = text(item['current']), latest = text(item['latest']);
    if (_shown.hasMatch(current) &&
        _shown.hasMatch(latest) &&
        current != latest) {
      found['${e.key}'] = (current, latest);
    }
  }
  return found;
}

/// agent_updates.mise_command_of: "http:muse" → "muse".
String miseCommandOf(String tool) => tool.split(':').last.split('/').last;

/// The adapters' own updaters (update.self: plain words only).
List<List<String>> selfUpdates(List<Adapter> adapters) => [
  for (final a in adapters)
    if (_selfUpdate(a).isNotEmpty) _selfUpdate(a),
];

List<String> _selfUpdate(Adapter a) {
  final argv = [
    for (final x in (a.table('update')['self'] as List? ?? const [])) '$x',
  ];
  return _plain(argv) ?? const [];
}

/// install_recipes._plain: argv as plain words, its program a plain name.
List<String>? _plain(List<String> words) {
  final program = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$');
  final word = RegExp(r'^[A-Za-z0-9@:/._=+,-]{1,300}$');
  if (words.isEmpty) return null;
  final first = words.first != 'sudo'
      ? words.first
      : (words.length > 1 ? words[1] : '-');
  if (!program.hasMatch(first)) return null;
  return words.every(word.hasMatch) ? words : null;
}

/// agent_updates._allowed: mise's upgrade, or an agent's own updater.
bool allowedUpdate(List<String> argv, List<Adapter> adapters) {
  if (argv.length >= 2 && argv[0] == 'mise' && argv[1] == 'upgrade') {
    return true;
  }
  return selfUpdates(adapters).any(
    (u) =>
        argv.length >= u.length &&
        [for (var i = 0; i < u.length; i++) argv[i] == u[i]].every((x) => x),
  );
}

bool _usable(dynamic u, List<Adapter> adapters) {
  const fields = {
    'kind',
    'key',
    'name',
    'current',
    'available',
    'command',
    'page',
  };
  if (u is! Map ||
      u.length != fields.length ||
      !u.keys.every(fields.contains)) {
    return false;
  }
  final command = u['command'];
  return const ['agent', 'runtime'].contains(u['kind']) &&
      ['key', 'name', 'current', 'available'].every((k) => u[k] is String) &&
      u['page'] is bool &&
      command is List &&
      (command.isEmpty ||
          (command.every((x) => x is String) &&
              allowedUpdate(command.cast<String>(), adapters)));
}

final class AgentUpdates {
  AgentUpdates({
    required this.adapters,
    required this.installer,
    required this.agentInstaller,
    required this.home,
    required this.cachePath,
    this.path,
    this.writeCache,
  });
  final List<Adapter> adapters;

  /// install_ctl.installer: the app's installer of a local LLM or agent.
  final Installer? Function(String key) installer;

  /// Whether the app installs this agent itself (install_ctl.AGENT_INSTALLERS).
  final bool Function(String command) agentInstaller;
  final String home, cachePath;
  final String? path;
  final void Function(String path, List<int> bytes)? writeCache;

  Map<String, dynamic> _loadCache() {
    try {
      final data = jsonDecode(File(cachePath).readAsStringSync());
      return data is Map<String, dynamic> ? data : {};
    } on Object {
      return {};
    }
  }

  /// agent_updates.still_open: cached updates not installed since.
  List<Map<String, dynamic>> stillOpen(
    List<Map<String, dynamic>> found,
    List<Map> agents,
    List<Map> runtimes,
  ) {
    final versions = {
      for (final a in agents)
        if (a['installed'] == true) '${a['command']}': '${a['version']}',
    };
    return [
      for (final u in found)
        if (!(u['kind'] == 'agent' &&
                (u['command'] as List).isNotEmpty &&
                versions.containsKey(u['key']) &&
                versions[u['key']] != u['current']) &&
            !(u['kind'] == 'runtime' &&
                !runtimes.any(
                  (r) => r['key'] == u['key'] && r['installed'] == true,
                )) &&
            !(u['page'] == true &&
                (installer('${u['key']}') == null ||
                    installer('${u['key']}')!.currentVersion() !=
                        u['current'])))
          u,
    ];
  }

  /// agent_updates.check: what can be updated now; the web is asked at most
  /// every [checkEvery] seconds.
  Future<List<Map<String, dynamic>>> check(
    List<Map> agents,
    List<Map> runtimes, {
    required double now,
    Future<Map<String, (String, String)>> Function()? mise,
    Future<String?> Function(String command, String channel)? latest,
    Future<Gpu> Function()? gpu,
    Future<String?> Function(Installer inst, Gpu gpu)? installerLatest,
  }) async {
    final saved = _loadCache();
    final checked = saved['checked'];
    if (checked is num &&
        now - checked >= 0 &&
        now - checked < checkEvery &&
        saved['updates'] is List) {
      final found = [
        for (final u in saved['updates'] as List)
          if (_usable(u, adapters)) Map<String, dynamic>.from(u as Map),
      ];
      return stillOpen(found, agents, runtimes);
    }
    final found = <Map<String, dynamic>>[];
    final installed = {
      for (final a in agents)
        if (a['installed'] == true) '${a['command']}': a,
    };
    final miseAgents = {
      for (final a in installed.values)
        if (a['source'] == 'mise') '${a['command']}',
    };
    if (miseAgents.isNotEmpty) {
      for (final e in (await (mise ?? () => miseOutdated(path))()).entries) {
        final agent = installed[miseCommandOf(e.key)];
        if (agent != null && miseAgents.contains(agent['command'])) {
          found.add(
            update(
              'agent',
              '${agent['command']}',
              '${agent['name']}',
              e.value.$1,
              e.value.$2,
              command: ['mise', 'upgrade', e.key],
            ),
          );
        }
      }
    }
    for (final a in adapters) {
      final self = _selfUpdate(a);
      final ref = a.table('update')['latest'];
      final agent = installed[a.command];
      if (self.isEmpty || ref is! String || ref.isEmpty || agent == null) {
        continue;
      }
      final List<String>? command =
          agent['source'] == 'own' && whichIn(self.first, path) != null
          ? self
          : agent['source'] == 'mise'
          ? ['mise', 'upgrade', a.command]
          : null;
      if (command != null && !found.any((u) => u['key'] == a.command)) {
        final channel = claudeChannel(home);
        final newest = latest != null
            ? await latest(a.command, channel)
            : ref == 'claude-channel'
            ? await claudeChannelLatest(channel)
            : null;
        if (newest != null && newer(newest, '${agent['version']}')) {
          found.add(
            update(
              'agent',
              a.command,
              '${agent['name']}',
              '${agent['version']}',
              newest,
              command: command,
            ),
          );
        }
      }
    }
    final ours = [
      for (final e in installed.entries)
        if (agentInstaller(e.key)) (e.key, '${e.value['name']}', 'agent'),
      for (final rt in runtimes)
        if (rt['installed'] == true)
          ('${rt['key']}', '${rt['name']}', 'runtime'),
    ];
    Gpu? card;
    for (final (key, name, kind) in ours) {
      final inst = installer(key);
      if (inst == null || !inst.canInstall || inst.installedFolder() == null) {
        continue;
      }
      card ??= await (gpu ?? () async => Gpu())();
      final newest = await (installerLatest ?? _installerLatest)(inst, card);
      final current = inst.currentVersion();
      if (newest != null &&
          current.isNotEmpty &&
          newest != current &&
          !newer(current, newest)) {
        found.add(update(kind, key, name, current, newest, page: true));
      }
    }
    try {
      writeCache?.call(
        cachePath,
        utf8.encode(jsonEncode({'checked': now, 'updates': found})),
      );
    } on Object {
      // Not kept: asked again next time.
    }
    return found;
  }

  static Future<String?> _installerLatest(Installer inst, Gpu gpu) async {
    final current = inst.currentVersion();
    final build =
        inst.builds.where((b) => current.endsWith(b.$1)).firstOrNull?.$1 ?? '';
    try {
      final release = await inst.latest(gpu, build);
      return _shown.hasMatch(release.version) ? release.version : null;
    } on Object {
      return null;
    }
  }
}
