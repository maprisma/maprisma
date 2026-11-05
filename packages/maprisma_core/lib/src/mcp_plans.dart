import 'dart:convert';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';
import 'package:yaml/yaml.dart';
import 'agent_catalog.dart';
import 'agent_details.dart' show dig;
import 'connect_apply.dart';
import 'dsh_profile.dart';
import 'local_llm.dart';
import 'py_values.dart';
import 'scan_files.dart';
import 'skill_plans.dart' show AgentProfiles;

/// Python mcp_ctl: copy an MCP server from an agent that has it into another
/// agent's own format (or the app's list of known servers), or remove it.
final _name = RegExp(r'^[A-Za-z0-9_.-]{1,64}$');

/// A key of the app's list of known servers: the name, or name~2, name~3, …
/// for another server of that name ("~" is no part of a name).
final libraryKeyPattern = RegExp(r'^[A-Za-z0-9_.-]{1,64}(?:~[0-9]{1,4})?$');

/// The configuration name of a map id or library key: "fs~2" is "fs".
String mcpBaseName(String id) => id.replaceFirst(RegExp(r'~[0-9]+$'), '');

/// What makes two servers of one name the same server: how it is reached (the
/// transport and the whole address, path, port and query included) or what is
/// started (the transport, the command and every argument), and the
/// environment or headers it is given (another ROOT or workspace is another
/// server). Those may hold keys, so they take part only as a salted digest of
/// their sorted names and values, never in clear text; an entry without any
/// keeps the identity it had before they took part. '' for an entry that tells
/// neither.
String mcpIdentity(dynamic entry) {
  final e = normalEntry(entry);
  if (e == null) return '';
  final env = e['env'] as Map<String, String>,
      headers = e['headers'] as Map<String, String>;
  return jsonEncode([
    ...e['transport'] == 'stdio'
        ? [e['transport'], e['command'], e['args']]
        : [e['transport'], e['url']],
    if (env.isNotEmpty || headers.isNotEmpty) _settingsDigest(env, headers),
  ]);
}

/// mcp_ctl._settings_digest: the env and headers of a server, digested.
String _settingsDigest(Map<String, String> env, Map<String, String> headers) {
  List<List<String>> pairs(Map<String, String> m) => [
    for (final k in m.keys.toList()..sort(pyCompare)) [k, m[k]!],
  ];
  return sha256
      .convert(
        utf8.encode(
          'maprisma-mcp-settings\n${jsonEncode([pairs(env), pairs(headers)])}',
        ),
      )
      .toString();
}

/// [mcpIdentity] as a short digest, for files kept beside a server's answer.
String mcpIdentityHash(dynamic entry) =>
    sha256.convert(utf8.encode(mcpIdentity(entry))).toString().substring(0, 16);
final _fieldName = RegExp(r'^[A-Za-z_][A-Za-z0-9_-]{0,127}$');

List<String> _strs(dynamic value) =>
    value is List ? [for (final v in value) pyStr(v)] : [];
Map<String, String> _map(dynamic value) => value is Map
    ? {for (final e in value.entries) pyStr(e.key): pyStr(e.value)}
    : {};
dynamic _or(List<dynamic> values) =>
    values.firstWhere(pyTruthy, orElse: () => values.last);

/// mcp_ctl.normal: one shape for every agent's entry, or null.
Map<String, dynamic>? normalEntry(dynamic entry) {
  if (entry is! Map) return null;
  final kind = pyStr(
    _or([entry['type'], entry['transport'], '']),
  ).toLowerCase();
  final url = _or([
    entry['httpUrl'],
    entry['url'],
    entry['serverUrl'],
    entry['uri'],
  ]);
  if (url is String && url.isNotEmpty) {
    final sse =
        kind == 'sse' ||
        !pyTruthy(entry['httpUrl']) &&
            kind.isEmpty &&
            url.replaceFirst(RegExp(r'/+$'), '').endsWith('/sse');
    return {
      'transport': sse ? 'sse' : 'http',
      'command': '',
      'args': <String>[],
      'env': <String, String>{},
      'url': url,
      'headers': _map(_or([entry['headers'], entry['http_headers']])),
    };
  }
  var command = _or([entry['command'], entry['cmd']]);
  var args = _strs(entry['args']);
  if (command is List) {
    args = _strs(command.skip(1).toList());
    command = command.isEmpty ? '' : pyStr(command.first);
  }
  if (command is! String || command.isEmpty) return null;
  return {
    'transport': 'stdio',
    'command': command,
    'args': args,
    'env': _map(_or([entry['env'], entry['environment'], entry['envs']])),
    'url': '',
    'headers': <String, String>{},
  };
}

/// mcp_ctl.check_entry: a known server's entry from the app's list, checked.
Map<String, dynamic> checkEntry(dynamic entry) {
  if (entry is! Map) throw const FormatException('unknown type');
  final transport = entry['transport'];
  if (transport == 'stdio') {
    final command = entry['command'];
    if (command is! String ||
        command.trim().isEmpty ||
        command.contains('\n')) {
      throw const FormatException('no command');
    }
  } else if (transport == 'http' || transport == 'sse') {
    final url = entry['url'] ?? '';
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const FormatException('not an http(s) address');
    }
  } else {
    throw const FormatException('unknown type');
  }
  final stdio = transport == 'stdio';
  final clean = <String, dynamic>{
    'transport': transport,
    'command': stdio ? (entry['command'] ?? '') : '',
    'args': stdio
        ? [for (final a in entry['args'] as List? ?? []) pyStr(a)]
        : <String>[],
    'env': <String, String>{},
    'url': stdio ? '' : (entry['url'] ?? ''),
    'headers': <String, String>{},
  };
  for (final field in ['env', 'headers']) {
    final given = entry[field];
    if (!pyTruthy(given)) continue;
    if (given is! Map) throw const FormatException('not a mapping');
    for (final e in given.entries) {
      if (!_fieldName.hasMatch(pyStr(e.key)) || pyStr(e.value).contains('\n')) {
        throw FormatException('bad name ${e.key}');
      }
      (clean[field] as Map)[pyStr(e.key)] = pyStr(e.value);
    }
  }
  if (!stdio) {
    clean['env'] = <String, String>{};
  } else {
    clean['headers'] = <String, String>{};
  }
  return clean;
}

final class McpPlans {
  McpPlans(
    this.files,
    this.config,
    this.catalog,
    this.profiles,
    this.libraryFile,
  );
  final ScanFiles files;
  final ConfigFiles config;
  final AgentCatalog catalog;
  final AgentProfiles profiles;
  final String libraryFile;

  String get home => files.identity.home;
  String expand(String path) =>
      path.startsWith('~/') ? p.join(home, path.substring(2)) : path;

  /// The agent's [mcp] facts with Python's defaults, or null (none, or in its app).
  Map<String, dynamic>? spec(String agent) {
    final a = catalog.adapter(agent);
    if (a == null || !a.facts.containsKey('mcp')) return null;
    final raw = a.table('mcp');
    if ((raw['in_app'] as String? ?? '').isNotEmpty) return null;
    return {'format': 'json', 'key': 'mcpServers', 'shape': 'plain', ...raw};
  }

  Map<String, dynamic>? profile(String agent) => profiles.mcp(agent);

  bool supported(String agent) => spec(agent) != null || profile(agent) != null;

  Map<String, dynamic> _readJson(
    String path, {
    int limit = ConfigFiles.maxBytes,
  }) => files.json(path, limit: limit, comments: false);

  /// mcp_ctl.raw_entries: name -> the agent's own entry, enabled or not.
  Map<String, dynamic> rawEntries(String agent) {
    dynamic found;
    var s = spec(agent);
    if (s == null && catalog.adapter(agent) == null && agent == 'lmstudio') {
      s = {
        'path': '~/.lmstudio/mcp.json',
        'format': 'json',
        'key': 'mcpServers',
      };
    }
    if (s == null) {
      final prof = profile(agent);
      if (prof != null) found = _profileEntries(prof);
    } else {
      final path = expand(s['path'] as String? ?? '');
      try {
        switch (s['format']) {
          case 'claude':
            found = _readJson(path, limit: ConfigFiles.claudeBytes)[s['key']];
          case 'toml':
            found = TomlDocument.parse(config.read(path)).toMap()[s['key']];
          case _ when s['read'] == 'hook':
            found = agent == 'dsh' ? dshMcpServers(config.read(path)) : null;
          case 'yaml':
            final data = loadYaml(config.read(path));
            found = data is Map ? data[s['key']] : null;
          default:
            found = dig(_readJson(path), s['key'] as String);
        }
      } catch (_) {
        found = null;
      }
    }
    return found is Map
        ? {
            for (final e in found.entries)
              if (e.value is Map) pyStr(e.key): e.value,
          }
        : {};
  }

  dynamic _profileEntries(Map<String, dynamic> prof) {
    final path = expand(prof['file'] as String);
    try {
      if (prof['format'] == 'json') {
        return dig(_readJson(path), prof['key'] as String);
      }
      if (prof['format'] == 'toml') {
        return TomlDocument.parse(config.read(path)).toMap()[prof['key']];
      }
      final data = loadYaml(config.read(path));
      return data is Map ? data[prof['key']] : null;
    } catch (_) {
      return null;
    }
  }

  (String?, Map<String, dynamic>?) entryFrom(
    List<String> sources,
    String name,
  ) {
    for (final agent in sources) {
      final entry = normalEntry(rawEntries(agent)[name]);
      if (entry != null) return (agent, entry);
    }
    return (null, null);
  }

  /// mcp_library.load: the servers the app knows (each checked).
  Map<String, dynamic> library() {
    final Map data;
    try {
      final text = config.read(libraryFile);
      final parsed = jsonDecode(text.isEmpty ? '{}' : text);
      data = parsed is Map ? parsed : {};
    } catch (_) {
      return {};
    }
    final servers = data['servers'];
    if (servers is! Map) return {};
    final found = <String, dynamic>{};
    for (final e in servers.entries.take(200)) {
      try {
        if (libraryKeyPattern.hasMatch(pyStr(e.key))) {
          found[pyStr(e.key)] = checkEntry(e.value);
        }
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
    return found;
  }

  /// mcp_library.remember: add the servers agents use now that the list lacks
  /// or has differently, written straight away; then the list as load() reads it.
  /// [serverAgents]: the map's ids (name, name~2, …) and their agents. Each
  /// server keeps the key that holds the same server ([mcpIdentity]); a new one
  /// takes its name when it is the first of that name and no saved server
  /// holds the name (used or not), else the next free name~N, so a second
  /// server of one name is remembered too and its definition stays when its
  /// last agent goes. Only an update (mcp_update) rewrites a saved server.
  Map<String, dynamic> knownServers(
    Map<String, List<String>> serverAgents,
    bool remember,
  ) {
    if (remember) {
      try {
        final servers = library();
        final merged = {...servers};
        final claimed = <String>{};
        final pending = <(String, String, Map<String, dynamic>)>[];
        for (final e in serverAgents.entries) {
          final name = mcpBaseName(e.key);
          final entry = entryFrom(e.value, name).$2;
          if (entry == null) continue;
          final same = mcpIdentity(entry);
          final keys = [
            for (final k in merged.keys.toList()..sort(pyCompare))
              if (mcpBaseName(k) == name &&
                  !claimed.contains(k) &&
                  mcpIdentity(merged[k]) == same)
                k,
          ];
          final key = keys.contains(e.key) ? e.key : keys.firstOrNull;
          if (key == null) {
            pending.add((e.key, name, entry));
          } else {
            claimed.add(key);
            merged[key] = entry;
          }
        }
        for (final (id, name, entry) in pending) {
          var key = name;
          // A saved server of another identity keeps its key, used or not.
          if (id != name || merged.containsKey(name)) {
            for (var n = 2; ; n++) {
              key = '$name~$n';
              if (!merged.containsKey(key) && !claimed.contains(key)) break;
            }
          }
          claimed.add(key);
          merged[key] = entry;
        }
        if (!const DeepCollectionEquality().equals(merged, servers)) {
          final folder = p.dirname(libraryFile);
          if (!Directory(folder).existsSync()) {
            Directory(folder).createSync(recursive: true);
            config.posix.chmodPath(folder, 0x1c0);
          }
          final keys = merged.keys.take(200).toList()..sort(pyCompare);
          config.write(
            libraryFile,
            '${pyJsonDumps({
              'servers': {for (final k in keys) k: merged[k]},
            }, indent: 2, ensureAscii: false)}\n',
          );
        }
      } on FileSystemException {
        // like the reference: a list that cannot be written stays as it is
      }
    }
    return library();
  }

  Map<String, dynamic> _fromProfile(
    Map<String, dynamic> prof,
    Map<String, dynamic> e,
  ) {
    final item = <String, dynamic>{};
    if (e['transport'] == 'stdio') {
      if ((prof['type_field'] as String).isNotEmpty &&
          (prof['stdio_type'] as String).isNotEmpty) {
        item[prof['type_field'] as String] = prof['stdio_type'];
      }
      if (prof['command_list'] == true) {
        item['command'] = [e['command'], ...e['args'] as List];
      } else {
        item['command'] = e['command'];
        item['args'] = e['args'];
      }
      if ((e['env'] as Map).isNotEmpty) {
        item[prof['env_field'] as String] = e['env'];
      }
      return item;
    }
    if ((prof['type_field'] as String).isNotEmpty &&
        (prof['http_type'] as String).isNotEmpty) {
      item[prof['type_field']
          as String] = e['transport'] == 'sse' && prof['http_type'] != 'remote'
          ? 'sse'
          : prof['http_type'];
    }
    item[prof['url_field'] as String] = e['url'];
    if ((e['headers'] as Map).isNotEmpty) {
      item[prof['headers_field'] as String] = e['headers'];
    }
    return item;
  }

  /// mcp_ctl.native: one entry in the agent's own form.
  Map<String, dynamic> native(String agent, Map<String, dynamic> e) {
    final stdio = e['transport'] == 'stdio';
    final s = spec(agent);
    if (s == null) return _fromProfile(profile(agent)!, e);
    if (s['native'] == 'hook' && agent == 'dsh') {
      if (stdio) {
        return {
          'transport': 'stdio',
          'command': e['command'],
          'args': List.of(e['args'] as List),
          if ((e['env'] as Map).isNotEmpty) 'env': Map.of(e['env'] as Map),
        };
      }
      return {
        'transport': 'streamable-http',
        'url': e['url'],
        if ((e['headers'] as Map).isNotEmpty)
          'headers': Map.of(e['headers'] as Map),
      };
    }
    final shape = s['shape'];
    final env = e['env'] as Map, headers = e['headers'] as Map;
    if (shape == 'muse' || shape == 'openclaw' || shape == 'crush') {
      if (stdio) {
        final kind = {
          'muse': 'transport',
          'openclaw': '',
          'crush': 'type',
        }[shape]!;
        return {
          if (kind.isNotEmpty) kind: 'stdio',
          'command': e['command'],
          'args': e['args'],
          if (env.isNotEmpty) 'env': env,
        };
      }
      var remote = {
        'muse': 'streamable_http',
        'openclaw': 'streamable-http',
        'crush': 'http',
      }[shape]!;
      if (e['transport'] == 'sse') remote = 'sse';
      return {
        shape != 'crush' ? 'transport' : 'type': remote,
        'url': e['url'],
        if (headers.isNotEmpty) 'headers': headers,
      };
    }
    if (shape == 'goose') {
      if (stdio) {
        return {
          'type': 'stdio',
          'enabled': true,
          'cmd': e['command'],
          'args': e['args'], //
          'envs': env, 'env_keys': <String>[], 'timeout': 300,
        };
      }
      return {
        'type': 'streamable_http',
        'enabled': true,
        'uri': e['url'],
        'headers': headers, //
        'envs': <String, String>{}, 'env_keys': <String>[], 'timeout': 300,
      };
    }
    if (shape == 'opencode') {
      if (stdio) {
        return {
          'type': 'local',
          'command': [e['command'], ...e['args'] as List],
          'enabled': true,
          if (env.isNotEmpty) 'environment': env,
        };
      }
      return {
        'type': 'remote',
        'url': e['url'],
        'enabled': true,
        if (headers.isNotEmpty) 'headers': headers,
      };
    }
    if (stdio) {
      final item = <String, dynamic>{
        'command': e['command'],
        'args': e['args'],
        if (env.isNotEmpty) 'env': env,
      };
      if (shape == 'claude') return {'type': 'stdio', ...item, 'env': env};
      if (shape == 'copilot') {
        return {
          'type': 'local',
          ...item,
          'tools': ['*'],
        };
      }
      return item;
    }
    final Map<String, dynamic> item;
    if (shape == 'gemini') {
      item = {e['transport'] == 'http' ? 'httpUrl' : 'url': e['url']};
    } else if (shape == 'antigravity') {
      // Streamable HTTP only, as serverUrl (no httpUrl, no SSE)
      item = {'serverUrl': e['url']};
    } else if (shape == 'claude' || shape == 'copilot' || shape == 'omp') {
      item = {'type': e['transport'], 'url': e['url']};
    } else {
      item = {'url': e['url']};
    }
    if (headers.isNotEmpty) {
      item[shape == 'codex' ? 'http_headers' : 'headers'] = headers;
    }
    if (shape == 'copilot') item['tools'] = ['*'];
    return item;
  }

  // --- text edits, as the reference makes them --------------------------------

  static Map _json(String text) {
    if (text.trim().isEmpty) return <String, dynamic>{};
    final data = jsonDecode(text);
    if (data is! Map) throw const FormatException('not a JSON object');
    return data;
  }

  static String _dump(Map data) =>
      '${pyJsonDumps(data, indent: 2, ensureAscii: false)}\n';

  static String jsonText(String text, String key, String name, Map? item) {
    final data = _json(text);
    final servers = data.putIfAbsent(key, () => <String, dynamic>{});
    if (servers is! Map) throw FormatException('$key is not an object');
    if (item == null) {
      servers.remove(name);
      if (servers.isEmpty) data.remove(key);
    } else {
      servers[name] = item;
    }
    return _dump(data);
  }

  static String jsonDotted(String text, String key, String name, Map? item) {
    final data = _json(text);
    final parts = key.split('.');
    var node = data;
    for (final part in parts.sublist(0, parts.length - 1)) {
      final next = node.putIfAbsent(part, () => <String, dynamic>{});
      if (next is! Map) throw FormatException('$part is not an object');
      node = next;
    }
    final last = parts.last;
    final inner = jsonText(
      pyJsonDumps({
        last: node.containsKey(last) ? node[last] : <String, dynamic>{},
      }),
      last,
      name,
      item,
    );
    final value = (jsonDecode(inner) as Map)[last];
    if (pyTruthy(value)) {
      node[last] = value;
    } else {
      node.remove(last);
    }
    return _dump(data);
  }

  static String _tomlKey(String key) =>
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(key) ? key : pyJsonDumps(key);

  static String _tomlValue(dynamic value) {
    if (value is Map) {
      return '{ ${[for (final e in value.entries) '${_tomlKey(pyStr(e.key))} = ${pyJsonDumps(e.value)}'].join(', ')} }';
    }
    return pyJsonDumps(value, ensureAscii: false);
  }

  /// str.splitlines(keepends=True).
  static List<String> _lines(String text) {
    const breaks = {
      0x0a,
      0x0b,
      0x0c,
      0x0d,
      0x1c,
      0x1d,
      0x1e,
      0x85,
      0x2028,
      0x2029,
    };
    final out = <String>[];
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (!breaks.contains(c)) continue;
      if (c == 0x0d && i + 1 < text.length && text.codeUnitAt(i + 1) == 0x0a) {
        i++;
      }
      out.add(text.substring(start, i + 1));
      start = i + 1;
    }
    if (start < text.length) out.add(text.substring(start));
    return out;
  }

  static String codexText(
    String text,
    String name,
    Map? item, [
    String table = 'mcp_servers',
  ]) {
    final header =
        '\\[${RegExp.escape(table)}\\.(?:${RegExp.escape(name)}|${RegExp.escape(pyJsonDumps(name))})(?:\\.[^\\]]*)?\\]';
    final pattern = RegExp('^\\s*$header\\s*(#.*)?\$');
    final out = <String>[];
    var skipping = false;
    for (final line in _lines(text)) {
      if (line.trimLeft().startsWith('[')) {
        skipping = pattern.hasMatch(line.replaceFirst(RegExp(r'\n+$'), ''));
      }
      if (!skipping) out.add(line);
    }
    var result = out.join();
    if (item != null) {
      final block = StringBuffer('[$table.${_tomlKey(name)}]\n');
      for (final e in item.entries) {
        block.write('${e.key} = ${_tomlValue(e.value)}\n');
      }
      result =
          result.replaceFirst(RegExp(r'\n+$'), '') +
          (result.trim().isNotEmpty ? '\n\n' : '') +
          block.toString();
    }
    return result;
  }

  static String hermesText(
    String text,
    String name,
    Map? item, [
    String key = 'mcp_servers',
  ]) {
    final entry = item == null
        ? ''
        : '  $name:\n${[for (final e in item.entries) '    ${e.key}: ${pyJsonDumps(e.value, ensureAscii: false)}\n'].join()}';
    final start = RegExp(
      '^${RegExp.escape(key)}:.*\\n?',
      multiLine: true,
    ).firstMatch(text);
    if (start == null) {
      if (item == null) return text;
      return '$text${text.endsWith('\n') || text.isEmpty ? '' : '\n'}$key:\n$entry';
    }
    final body = LocalLlm.topBlock(text, key)!;
    final begin = start.start, end = begin + body.length;
    final cut = body.indexOf('\n');
    var head = cut < 0 ? body : body.substring(0, cut);
    var rest = cut < 0 ? '' : body.substring(cut + 1);
    rest = rest.replaceAll(
      RegExp(
        '^  ${RegExp.escape(name)}:.*\\n(?:(?:    |\\t\\t).*\\n?|\\s*\\n)*',
        multiLine: true,
      ),
      '',
    );
    rest =
        rest.replaceFirst(RegExp(r'\n+$'), '') +
        (rest.trim().isNotEmpty ? '\n' : '') +
        entry;
    if (head.trim() == '$key: {}' || head.trim() == '$key:{}') head = '$key:';
    final newBody = rest.trim().isNotEmpty ? '$head\n$rest' : '';
    return text.substring(0, begin) + newBody + text.substring(end);
  }

  String _museWrite(
    String text,
    String key,
    Map defaults,
    String name,
    Map? item,
  ) {
    final next = jsonText(text, key, name, item);
    final data = _json(next);
    final missing = {
      for (final e in defaults.entries)
        if (!data.containsKey(e.key)) e.key: e.value,
    };
    return missing.isEmpty ? next : _dump({...missing, ...data});
  }

  static String openclawWrite(String text, String name, Map? item) {
    final Map data;
    try {
      data = _json(text);
    } on FormatException {
      throw const FormatException(
        '~/.openclaw/openclaw.json is JSON5: use `openclaw mcp set`',
      );
    }
    final mcp = data.putIfAbsent('mcp', () => <String, dynamic>{});
    if (mcp is! Map) throw const FormatException('mcp is not an object');
    final servers =
        (jsonDecode(
              jsonText(
                pyJsonDumps({
                  'servers': mcp.containsKey('servers')
                      ? mcp['servers']
                      : <String, dynamic>{},
                }),
                'servers',
                name,
                item,
              ),
            )
            as Map)['servers'];
    if (pyTruthy(servers)) {
      mcp['servers'] = servers;
    } else {
      mcp.remove('servers');
      if (mcp.isEmpty) data.remove('mcp');
    }
    return _dump(data);
  }

  List<Change> _claudeChange(String name, Map? item) {
    final path = p.join(home, '.claude.json');
    final text = config.read(path);
    final data = _json(text);
    final servers = data.putIfAbsent('mcpServers', () => <String, dynamic>{});
    if (servers is! Map) {
      throw const FormatException('mcpServers is not an object');
    }
    if (item == null) {
      if (!servers.containsKey(name)) return [];
      servers.remove(name);
    } else {
      servers[name] = item;
    }
    final next =
        pyJsonDumps(data, indent: 2, ensureAscii: false) +
        (text.endsWith('\n') ? '\n' : '');
    return next == text ? [] : [Change(path, text, next)];
  }

  /// mcp_ctl.plan: add server [name] (copied from the first of [sources] that
  /// has it, else from the app's list under [libraryKey], the name by
  /// default), or remove it.
  Plan plan(
    String agent,
    String name,
    List<String> sources, {
    required bool remove,
    Map<String, dynamic>? entry,
    String? libraryKey,
  }) {
    if (!supported(agent) || !_name.hasMatch(name)) {
      throw FormatException(agent);
    }
    final result = Plan(agent, '', name);
    if (remove) {
      entry = null;
    } else if (entry != null) {
      entry = checkEntry(entry); // a new server's definition
    } else {
      entry = entryFrom([
        for (final s in sources)
          if (s != agent) s,
      ], name).$2;
      entry ??= library()[libraryKey ?? name] as Map<String, dynamic>?;
      if (entry == null) throw FormatException('no agent has $name set up');
    }
    final s = spec(agent);
    if (s != null && s['format'] == 'claude') {
      result.changes.addAll(
        _claudeChange(name, remove ? null : native('claude', entry!)),
      );
      return result;
    }
    final prof = s == null ? profile(agent) : null;
    final path = expand(
      s == null ? prof!['file'] as String : s['path'] as String,
    );
    final old = config.read(path);
    Map? item = remove ? null : native(agent, entry!);
    if (item != null && s != null && s['shape'] == 'goose') {
      item = {'name': name, ...item};
    }
    final String next;
    if (prof != null) {
      next = switch (prof['format']) {
        'json' => jsonDotted(old, prof['key'] as String, name, item),
        'toml' => codexText(old, name, item, prof['key'] as String),
        _ => hermesText(old, name, item, prof['key'] as String),
      };
    } else if (s!['format'] == 'toml') {
      next = codexText(old, name, item, s['key'] as String);
    } else if (s['write'] == 'hook' && agent == 'openclaw') {
      next = openclawWrite(old, name, item);
    } else if (s['write'] == 'hook' && agent == 'dsh') {
      next = dshMcpText(old, name, item);
    } else if (s['write'] == 'hook') {
      throw UnsupportedError('No core writer for $agent');
    } else if (s.containsKey('defaults')) {
      next = _museWrite(
        old,
        s['key'] as String,
        s['defaults'] as Map,
        name,
        item,
      );
    } else if (s['format'] == 'yaml') {
      next = hermesText(old, name, item, s['key'] as String);
    } else {
      next = jsonText(old, s['key'] as String, name, item);
    }
    if (next != old) result.changes.add(Change(path, old, next));
    return result;
  }
}
