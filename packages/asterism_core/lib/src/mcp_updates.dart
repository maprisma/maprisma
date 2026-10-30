import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'adapters.dart';
import 'agent_updates.dart' show newer;
import 'desktop.dart' show whichIn;
import 'found_scan.dart' show FoundScan;
import 'posix_ffi.dart';
import 'py_values.dart' show pyJsonDumps;
import 'system_help.dart'
    show
        firstJson,
        guardBackground,
        oneLine,
        parseOutput,
        recordRun,
        runLogPath,
        runLookUp;

/// mcp_updates: updates for the local MCP servers, looked up on the web by an
/// installed agent once a day (Settings › Daily AI checks, off by default: it
/// uses the agent's tokens). Checked are the servers in the map's list whose
/// version can be told from how they are started: an app unpacked in
/// `~/Applications/<app>-<version>/` or anywhere as an unpacked AppImage
/// (`<folder>/<app>-<version>/usr/bin/<program>`, also through a link), an npm package
/// pinned to a version (npx -y pkg@1.2.3), a PyPI package pinned to a
/// version (uvx pkg==1.2.3). The answer is checked before it is shown: a
/// known server, a plain newer version, an https link, one short line of
/// notes. Nothing in it is ever run or downloaded.

const checkEvery = 24 * 3600;
const retryFailed = 6 * 3600;
const maxServers = 40;
final _version = RegExp(r'^\d+(?:\.\d+){1,3}$');
final _pinnedNpm = RegExp(
  r'^((?:@[a-z0-9][\w.-]*/)?[a-z0-9][\w.-]*)@(\d+(?:\.\d+){1,3})$',
  caseSensitive: false,
);
final _pinnedPypi = RegExp(
  r'^([a-z0-9][\w.-]*)(?:==|@)(\d+(?:\.\d+){1,3})$',
  caseSensitive: false,
);

const _prompt =
    '''For each of these locally installed MCP servers, find the newest released version, from the
project's official release page (GitHub releases, its homepage, npm or PyPI):
{lines}
Answer only with JSON: {"servers": [{"name": "<name as above>", "latest": "<version, digits and dots>",
"release_url": "<https link to that release or the download page>", "notes": "<one short sentence: what is new>"}]}.
Use null for latest and release_url when you cannot find them for sure. Do not guess.''';

const updatesSchema = {
  'type': 'object',
  'additionalProperties': false,
  'required': ['servers'],
  'properties': {
    'servers': {
      'type': 'array',
      'items': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['name', 'latest', 'release_url', 'notes'],
        'properties': {
          'name': {'type': 'string'},
          'latest': {
            'type': ['string', 'null'],
          },
          'release_url': {
            'type': ['string', 'null'],
          },
          'notes': {'type': 'string'},
        },
      },
    },
  },
};

/// Server: its name in the map's list, the app or package, the installed
/// version, "app"/"npm"/"pypi", the program the agents start (an app's).
typedef McpServer = ({
  String name,
  String app,
  String version,
  String source,
  String program,
});

/// Found: an update the look-up found and that held up.
typedef McpFound = ({
  String name,
  String app,
  String current,
  String latest,
  String url,
  String notes,
  String source,
  String program,
});

Map<String, dynamic> serverJson(McpServer s) => {
  'name': s.name,
  'app': s.app,
  'version': s.version,
  'source': s.source,
  'program': s.program,
};

McpServer serverOf(Map m) => (
  name: '${m['name']}',
  app: '${m['app']}',
  version: '${m['version']}',
  source: '${m['source']}',
  program: '${m['program'] ?? ''}',
);

Map<String, dynamic> foundJson(McpFound f) => {
  'name': f.name,
  'app': f.app,
  'current': f.current,
  'latest': f.latest,
  'url': f.url,
  'notes': f.notes,
  'source': f.source,
  'program': f.program,
};

/// _folder_of: the app's own folder: `~/Applications/<app>-<version>/`, or
/// `<folder>/<app>-<version>/` when the program lies in its usr/bin (an
/// unpacked AppImage anywhere); links resolved.
String? folderOf(String path, String home) {
  final apps = p.join(home, 'Applications');
  final expanded = path.startsWith('~/')
      ? p.join(home, path.substring(2))
      : path;
  String real;
  try {
    real = File(expanded).resolveSymbolicLinksSync();
  } on FileSystemException {
    real = p.normalize(p.absolute(expanded));
  }
  if (p.isWithin(apps, real)) {
    return p.join(apps, p.split(p.relative(real, from: apps))[0]);
  }
  final parts = p.split(real);
  if (parts.length >= 5 &&
      parts[parts.length - 3] == 'usr' &&
      parts[parts.length - 2] == 'bin') {
    return p.joinAll(parts.sublist(0, parts.length - 3));
  }
  return null;
}

/// _app_of: (app, version) of the app folder the program lies in.
(String, String)? _appOf(String path, String home) {
  final folder = folderOf(path, home);
  final found = folder == null
      ? null
      : FoundScan.appVersion(p.basename(folder));
  return found == null ? null : (found.$1, found.$2.join('.'));
}

/// installed_servers: the list's servers whose version is known.
List<McpServer> installedServers(Map library, String home) {
  final servers = <McpServer>[];
  for (final MapEntry(:key, :value) in library.entries.take(maxServers)) {
    if (value is! Map || value['command'] is! String) continue;
    final name = '$key', command = value['command'] as String;
    final args = [
      for (final a in value['args'] as List? ?? const [])
        if (a is String) a,
    ];
    final tool = p.basename(command);
    final first = args.where((a) => !a.startsWith('-')).firstOrNull ?? '';
    if (const {'npx', 'bunx', 'pnpx'}.contains(tool)) {
      final hit = _pinnedNpm.firstMatch(first);
      if (hit != null) {
        servers.add((
          name: name,
          app: hit[1]!,
          version: hit[2]!,
          source: 'npm',
          program: '',
        ));
      }
    } else if (tool == 'uvx' || tool == 'pipx') {
      final run = args.isEmpty
          ? -1
          : args.sublist(0, args.length - 1).indexOf('run');
      final hit = _pinnedPypi.firstMatch(
        tool == 'pipx' && run >= 0 ? args[run + 1] : first,
      );
      if (hit != null) {
        servers.add((
          name: name,
          app: hit[1]!,
          version: hit[2]!,
          source: 'pypi',
          program: '',
        ));
      }
    } else if (command.contains('/')) {
      final app = _appOf(command, home);
      if (app != null) {
        servers.add((
          name: name,
          app: app.$1,
          version: app.$2,
          source: 'app',
          program: command,
        ));
      }
    }
  }
  return servers;
}

String promptFor(List<McpServer> servers) {
  const where = {
    'app': 'an app unpacked from its AppImage',
    'npm': 'npm package',
    'pypi': 'PyPI package',
  };
  return _prompt.replaceFirst(
    '{lines}',
    [
      for (final s in servers)
        '- ${s.name}: ${s.app} ${s.version} (${where[s.source]})',
    ].join('\n'),
  );
}

/// _answer_json: the first JSON object with a "servers" list.
Map answerJson(String text) {
  var rest = text;
  while (true) {
    final found = firstJson(rest, 'servers');
    if (found['servers'] is List) return found;
    final at = rest.indexOf('{');
    rest = rest.substring(at + 1);
  }
}

String safeUrl(dynamic url) {
  if (url is! String ||
      url.length > 300 ||
      url.runes.any(
        (c) =>
            String.fromCharCode(c).trim().isEmpty ||
            '"\'<>`\\'.contains(String.fromCharCode(c)),
      )) {
    return '';
  }
  final parts = Uri.tryParse(url);
  return parts != null && parts.scheme == 'https' && parts.host.contains('.')
      ? url
      : '';
}

/// validate: what the agent found, only where it holds up: a server asked
/// about, a newer plain version, an https link.
List<McpFound> validate(Map answer, List<McpServer> servers) {
  final byName = {for (final s in servers) s.name: s};
  final found = <McpFound>[];
  final items = answer['servers'];
  for (final item in (items is List ? items : const []).take(maxServers)) {
    if (item is! Map || !byName.containsKey(item['name'])) continue;
    final server = byName.remove(item['name'])!;
    final raw = item['latest'];
    final latest =
        (raw == null || raw == '' || raw == false || raw == 0 ? '' : '$raw')
            .trim()
            .replaceFirst(RegExp(r'^[vV]+'), '');
    final url = safeUrl(item['release_url']);
    if (!_version.hasMatch(latest) ||
        url.isEmpty ||
        !newer(latest, server.version)) {
      continue;
    }
    found.add((
      name: server.name,
      app: server.app,
      current: server.version,
      latest: latest,
      url: url,
      notes: oneLine(item['notes'] ?? '', 160),
      source: server.source,
      program: server.program,
    ));
  }
  return found;
}

/// _read: the cache (own file, no link, small).
Map readCache(String cache) {
  try {
    if (FileSystemEntity.isLinkSync(cache)) return {};
    final file = File(cache);
    if (file.lengthSync() > 256 * 1024) return {};
    final data = jsonDecode(file.readAsStringSync());
    return data is Map ? data : {};
  } on Object {
    return {};
  }
}

List<McpFound> cached(String cache) {
  final found = <McpFound>[];
  final items = readCache(cache)['found'];
  for (final item in items is List ? items : const []) {
    if (item is! Map) continue;
    if (!['name', 'app', 'current', 'latest', 'url'].every(item.containsKey)) {
      continue;
    }
    String text(String k) => item.containsKey(k) ? '${item[k]}' : '';
    found.add((
      name: text('name'),
      app: text('app'),
      current: text('current'),
      latest: text('latest'),
      url: text('url'),
      notes: text('notes'),
      source: text('source'),
      program: text('program'),
    ));
  }
  return found;
}

/// still_open: hints still worth showing: the server is there in the
/// version the answer was about.
List<McpFound> stillOpen(List<McpFound> found, List<McpServer> servers) {
  final now = {for (final s in servers) s.name: s.version};
  return [
    for (final f in found)
      if (now[f.name] == f.current && newer(f.latest, f.current)) f,
  ];
}

/// on_pc: the newer version of an app is already here (unpacked or as its
/// AppImage), only the agents still start the old one.
bool onPc(McpFound update, String home, List<String> appimages) {
  if (update.source != 'app') return false;
  if (Directory(
    p.join(home, 'Applications', '${update.app}-${update.latest}'),
  ).existsSync()) {
    return true;
  }
  final folder = update.program.isEmpty ? null : folderOf(update.program, home);
  if (folder != null &&
      Directory(
        p.join(p.dirname(folder), '${update.app}-${update.latest}'),
      ).existsSync()) {
    return true;
  }
  final want = [for (final x in update.latest.split('.')) int.tryParse(x)];
  if (want.contains(null)) return false;
  return appimages.any((image) {
    final info = FoundScan.appVersion(FoundScan.appimageStem(image));
    return info != null &&
        info.$1 == update.app &&
        info.$2.join('.') == want.join('.');
  });
}

bool due(double now, String cache) {
  final saved = readCache(cache);
  final checked = saved['checked'];
  if (checked is! num) return true;
  final wait = saved['ok'] == true || (saved['ok'] is num && saved['ok'] != 0)
      ? checkEvery
      : retryFailed;
  final since = now - checked;
  return !(0 <= since && since < wait);
}

/// The look-up's result line in the token log.
String resultOf(String text, List<McpServer> servers) {
  final count = validate(answerJson(text), servers).length;
  return '$count update${count != 1 ? 's' : ''} found';
}

/// check (the asking part, in the worker): one web look-up by `command`
/// with the servers' prompt; the cache written either way (a failure keeps
/// the old answer and is tried again after six hours).
Future<List<McpFound>> checkNow(
  Adapter adapter,
  String command,
  List<McpServer> servers,
  String cache,
  double now,
  Map<String, String> env,
  String home,
  String plugin,
) async {
  final posix = Posix();
  try {
    final research = [
      for (final x in (adapter.table('research')['argv'] as List? ?? const []))
        '$x',
    ];
    if (research.isEmpty) throw StateError('no look-up');
    final output = '${adapter.table('research')['output'] ?? 'text'}';
    final work = '$home/.cache/maprisma/research';
    if (!Directory(work).existsSync()) {
      Directory(work).createSync(recursive: true);
      posix.chmodPath(work, 0x1c0);
    }
    final schemaFile = '$work/schema-mcp-updates.json';
    posix.atomicWrite(schemaFile, utf8.encode(pyJsonDumps(updatesSchema)));
    final prompt = promptFor(servers);
    final stdin = research.contains('{prompt}') ? null : utf8.encode(prompt);
    final binary = whichIn(command, env['PATH'] ?? '') ?? command;
    final fill = {'{prompt}': prompt, '{schema}': schemaFile};
    final argv = guardBackground(
      adapter,
      command,
      [binary, for (final a in research.skip(1)) fill[a] ?? a],
      env,
      home,
    );
    final runEnv = {...env, 'MAPRISMA_NO_PROVIDERS': '1'};
    ({int input, int cached, int output, double? cost})? usage;
    var ok = false, result = '';
    List<McpFound> found;
    try {
      final (out, done, cancelled) = await runLookUp(argv, stdin, runEnv, work);
      if (cancelled) throw StateError('MCP update check stopped');
      final text = utf8.decode(out, allowMalformed: true);
      final (answer, used) = parseOutput(output, text);
      usage = used;
      if (!done) {
        final tail = (answer.isNotEmpty ? answer : text).trim();
        throw StateError(
          tail.isEmpty
              ? 'no answer'
              : (tail.length > 200 ? tail.substring(tail.length - 200) : tail),
        );
      }
      found = validate(answerJson(answer), servers);
      ok = true;
      result = resultOf(answer, servers);
    } catch (error) {
      result = '$error'.length > 120 ? '$error'.substring(0, 120) : '$error';
      rethrow;
    } finally {
      recordRun(
        runLogPath(env, home),
        plugin,
        'mcp-updates',
        command,
        usage,
        ok,
        result: result,
      );
    }
    _write(cache, {
      'checked': now,
      'ok': true,
      'agent': command,
      'found': [for (final f in found) foundJson(f)],
    });
    return found;
  } catch (error) {
    final text = '$error';
    _write(cache, {
      ...readCache(cache),
      'checked': now,
      'ok': false,
      'error': text.length > 200 ? text.substring(0, 200) : text,
    });
    return stillOpen(cached(cache), servers);
  }
}

void _write(String cache, Map data) {
  Directory(p.dirname(cache)).createSync(recursive: true);
  Posix().atomicWrite(cache, utf8.encode(pyJsonDumps(data, indent: 1)));
}

/// task_prompt: what "Do it with `<agent>`…" asks the agent to do in its
/// terminal tab.
String taskPrompt(McpFound update, String home) {
  final apps = p.join(home, 'Applications');
  if (update.source == 'app') {
    final folder =
        (update.program.isEmpty ? null : folderOf(update.program, home)) ??
        p.join(apps, '${update.app}-${update.current}');
    return 'Download the MCP server app "${update.app}" ${update.latest} (I have ${update.current}, in '
        '$folder). Release (found by an automatic web look-up: '
        'check first that it is the app\'s official project): ${update.url}\n'
        'Get the Linux x86_64 AppImage of ${update.latest} from that official release only and save it in '
        '$apps under its release file name. Check its SHA-256 against the checksum the release '
        'publishes and show me both; if the release publishes none or they differ, delete the download '
        'and stop. Do not '
        'unpack it, do not change any agent\'s settings and do not delete the old version: AI Agents '
        'Map finds the new AppImage, unpacks it and moves the agents over, with Undo. Ask me before '
        'each step that changes files.';
  }
  final manager = update.source == 'npm' ? 'npm' : 'PyPI';
  return 'The MCP server "${update.name}" runs the $manager package ${update.app} pinned to ${update.current}; '
      'an automatic web look-up says ${update.latest} is out (${update.url}). Check that on $manager itself '
      'first. Show me what changed and which agents\' MCP settings pin '
      '${update.app}@${update.current}, then, after I agree, change the pinned version to ${update.latest}. '
      'Ask me before each change.';
}
