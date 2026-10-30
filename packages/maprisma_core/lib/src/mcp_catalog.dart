import 'dart:convert';
import 'dart:io';
import 'desktop.dart' show whichIn;
import 'model_hub.dart' show netFetch, FetchError;
import 'py_values.dart';

/// mcp_catalog and mcp_registry: MCP servers to start with and the official
/// MCP registry's servers, each turned into ways to run it (an entry in the
/// agents' MCP shape with {placeholders} where the user's values go, and the
/// fields for them). Nothing here runs a server; the reference's comments
/// say why each limit is there.

const registryApi = 'https://registry.modelcontextprotocol.io/v0/servers';
const registryTimeout = 45;
const registryMaxBytes = 4 * 1024 * 1024;
const maxServers = 100;
const maxOptions = 6;
const maxArguments = 40;
const maxPlaceholders = 10;
const maxFields = 40;
const registryPage = 20;
const listMaxAge = 12 * 3600;
const listMaxPages = 1000;
const saveEvery = 10;
const listPageTimeout = 90;
const listMaxFile = 96 * 1024 * 1024;
const listMaxServers = 100000;
const listMaxItem = 128 * 1024;
const _serverKeys = [
  'name',
  'title',
  'description',
  'version',
  'repository',
  'websiteUrl',
  'packages',
  'remotes',
];

final placeholderRe = RegExp(r'\{([A-Za-z_][A-Za-z0-9_-]{0,63})\}');
final _fieldRe = RegExp(r'\{([A-Za-z_][A-Za-z0-9_-]*|arg:\d+)\}');
// Python's str.split() whitespace.
final _space = RegExp(
  '[\\t\\n\\x0b\\x0c\\r\\x1c-\\x1f \\x85\\xa0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000]+',
);

/// A string cut to `limit` code points, as Python slices.
String _cut(String text, int limit) {
  final runes = text.runes;
  return runes.length <= limit ? text : String.fromCharCodes(runes.take(limit));
}

String _s(dynamic value, [int limit = 300]) {
  if (value is! String && value is! num && value is! bool) return '';
  final words = pyStr(value).split(_space).where((w) => w.isNotEmpty);
  return _cut(words.join(' '), limit);
}

Map _dict(dynamic value) => value is Map ? value : const {};
List _list(dynamic value) => value is List ? value : const [];

Map<String, dynamic> need(
  String name, {
  String description = '',
  bool required = false,
  bool secret = false,
  String value = '',
  String hint = '',
  List inner = const [],
}) => {
  'name': name,
  'description': description,
  'required': required,
  'secret': secret,
  'value': value,
  'hint': hint,
  'inner': inner,
};

/// mcp_registry.publisher: (kind, who) from a registry name.
(String, String) publisher(String name) {
  final space = name.split('/').first;
  if (space.toLowerCase().startsWith('io.github.') && space.length > 10) {
    return ('github', space.substring(10));
  }
  final parts = space.split('.');
  if (parts.length >= 2 &&
      parts.every((x) => RegExp(r'^[A-Za-z0-9-]{1,63}$').hasMatch(x))) {
    return ('domain', parts.reversed.join('.'));
  }
  return ('', '');
}

/// mcp_registry.short_name.
String shortName(String name) {
  var last = name.split('/').last.toLowerCase();
  last = last.replaceAll(
    RegExp(
      r'^(mcp[-_]server[-_]|mcp[-_]|server[-_])|([-_]mcp[-_]server|[-_]mcp|[-_]server)(?=\n?$)',
    ),
    '',
  );
  final out = last
      .replaceAll(RegExp(r'[^a-z0-9_.-]', unicode: true), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final cut = _cut(out, 64);
  return cut.isEmpty ? 'server' : cut;
}

List<String> _unique(Iterable<String> items) => {...items}.toList();

List<Map<String, dynamic>> _innerNeeds(Map item, String value) {
  final variables = _dict(item['variables']);
  return [
    for (final name in _unique(
      placeholderRe.allMatches(value).map((m) => m[1]!),
    ).take(maxPlaceholders))
      () {
        final info = _dict(variables[name]);
        final description = _s(info['description']);
        final fallback = _s(item['description']);
        return need(
          name,
          description: description.isNotEmpty
              ? description
              : fallback.isNotEmpty
              ? fallback
              : name,
          required: info['isRequired'] == true || item['isRequired'] == true,
          secret: info['isSecret'] == true || item['isSecret'] == true,
          value: _s(pyTruthy(info['default']) ? info['default'] : '', 500),
        );
      }(),
  ];
}

dynamic _or(dynamic a, dynamic b) => pyTruthy(a) ? a : b;

List<Map<String, dynamic>> _needsEnv(dynamic items) {
  final needs = <Map<String, dynamic>>[];
  for (final item in items is List ? items.take(maxArguments) : const []) {
    if (item is Map &&
        item['name'] is String &&
        RegExp(
          r'^[A-Za-z_][A-Za-z0-9_-]{0,127}$',
        ).hasMatch(item['name'] as String)) {
      final value = _s(_or(_or(item['default'], item['value']), ''), 500);
      needs.add(
        need(
          item['name'] as String,
          description: _s(item['description']),
          required: item['isRequired'] == true,
          secret: item['isSecret'] == true,
          value: value,
          inner: _innerNeeds(item, value),
        ),
      );
    }
  }
  return needs.take(40).toList();
}

/// The fields to show: a value with {placeholders} asks for those.
List<Map<String, dynamic>> _flat(List<Map<String, dynamic>> needs) {
  final out = <String, Map<String, dynamic>>{};
  for (final n in needs) {
    final inner = (n['inner'] as List).cast<Map<String, dynamic>>();
    for (final x in inner.isNotEmpty ? inner : [n]) {
      out[x['name'] as String] = x;
    }
  }
  return out.values.toList();
}

(List<String>, List<Map<String, dynamic>>)? _arguments(dynamic items) {
  if (items is List && items.length > maxArguments) return null;
  final args = <String>[], needs = <Map<String, dynamic>>[];
  final list = items is List ? items : const [];
  for (var number = 0; number < list.length; number++) {
    final item = list[number];
    if (item is! Map) continue;
    var value = _s(_or(_or(item['value'], item['default']), ''), 500);
    final name = _s(item['name'], 80);
    if (value.isEmpty && pyTruthy(item['isRequired'])) {
      final key = 'arg:$number';
      final description = _s(item['description']), hint = _s(item['valueHint']);
      needs.add(
        need(
          key,
          description: description.isNotEmpty
              ? description
              : hint.isNotEmpty
              ? hint
              : name,
          required: true,
          secret: item['isSecret'] == true,
          hint: _s(item['valueHint'], 60),
        ),
      );
      value = '{$key}';
    } else if (placeholderRe.hasMatch(value)) {
      needs.addAll(_innerNeeds(item, value));
    } else if (value.isEmpty) {
      continue;
    }
    if (item['type'] == 'named' && name.isNotEmpty) {
      args.addAll(name.endsWith('=') ? ['$name$value'] : [name, value]);
    } else {
      args.add(value);
    }
  }
  return (args, needs);
}

bool _envFlag(dynamic item) {
  if (item is! Map ||
      item['type'] != 'named' ||
      !const ['-e', '--env'].contains(item['name'])) {
    return false;
  }
  final value = pyStr(_or(_or(item['value'], item['default']), ''));
  return RegExp(
    '^[A-Za-z_][A-Za-z0-9_]{0,127}(=[^\\x00-\\x1f\\x7f]*)?\$',
  ).hasMatch(value);
}

/// mcp_registry.option_from_package.
Map<String, dynamic>? optionFromPackage(Map package, String? path) {
  final kind = package['registryType'];
  final ident = _s(package['identifier'], 200);
  final version = _s(package['version'], 60);
  final transport = _dict(package['transport']).containsKey('type')
      ? _dict(package['transport'])['type']
      : 'stdio';
  if (ident.isEmpty ||
      ident.startsWith('-') ||
      transport != 'stdio' ||
      !RegExp(r'^[@\p{L}\p{N}_./:-]+$', unicode: true).hasMatch(ident)) {
    return null;
  }
  final envNeeds = _needsEnv(package['environmentVariables']);
  final arguments = _arguments(package['packageArguments']);
  final runtime = _list(package['runtimeArguments']);
  if (arguments == null || runtime.length > maxArguments) return null;
  final (args, argNeeds) = arguments;
  final env = <String, String>{
    for (final n in envNeeds)
      n['name'] as String: (n['value'] as String).isNotEmpty
          ? n['value'] as String
          : '{${n['name']}}',
  };
  final String command;
  final List<String> base;
  final pinned = version.isNotEmpty && version != 'latest';
  if (kind == 'npm') {
    command = 'npx';
    base = ['-y', pinned ? '$ident@$version' : ident];
  } else if (kind == 'pypi') {
    command = 'uvx';
    base = [pinned ? '$ident==$version' : ident];
  } else if (kind == 'oci') {
    command = 'docker';
    final image = ident.split('/').last.contains(':') || version.isEmpty
        ? ident
        : '$ident:$version';
    final passed = <String>[];
    for (final item in runtime) {
      if (_envFlag(item)) {
        final text = pyStr(_or((item as Map)['value'], item['default']));
        final at = text.indexOf('=');
        if (at < 0) {
          passed.add(text);
          continue;
        }
        final name = text.substring(0, at), value = text.substring(at + 1);
        env.putIfAbsent(name, () => value);
        argNeeds.addAll(_innerNeeds(item, value));
      }
    }
    final names = [
      ...env.keys,
      ..._unique(passed).where((n) => !env.containsKey(n)),
    ];
    base = [
      'run',
      '-i',
      '--rm',
      for (final n in names) ...['-e', n],
      image,
    ];
  } else {
    return null;
  }
  final fields = _flat([...envNeeds, ...argNeeds]);
  if (fields.length > maxFields) return null;
  return {
    'kind': kind,
    'label': '$kind · $ident${version.isNotEmpty ? ' $version' : ''}',
    'entry': {
      'transport': 'stdio',
      'command': command,
      'args': [...base, ...args],
      'env': env,
      'url': '',
      'headers': <String, String>{},
    },
    'needs': fields,
    'runnable': whichIn(command, path) != null,
  };
}

/// mcp_registry.option_from_remote.
Map<String, dynamic>? optionFromRemote(Map remote) {
  final url = _s(remote['url'], 500);
  final kind = remote['type'];
  if (!url.startsWith('https://') ||
      !const ['streamable-http', 'sse'].contains(kind)) {
    return null;
  }
  final envNeeds = _needsEnv(remote['headers']);
  final headers = <String, String>{
    for (final n in envNeeds)
      n['name'] as String: (n['value'] as String).isNotEmpty
          ? n['value'] as String
          : '{${n['name']}}',
  };
  final needs = _flat(envNeeds);
  if (needs.length > maxFields) return null;
  var host = url;
  try {
    final parsed = Uri.parse(url).host;
    if (parsed.isNotEmpty) host = parsed;
  } on FormatException {
    // As urlsplit's hostname being None: the address itself.
  }
  return {
    'kind': 'remote',
    'label': 'remote · $host',
    'entry': {
      'transport': kind == 'streamable-http' ? 'http' : 'sse',
      'command': '',
      'args': <String>[],
      'env': <String, String>{},
      'url': url,
      'headers': headers,
    },
    'needs': needs,
    'runnable': true,
  };
}

/// mcp_registry.parse.
List<Map<String, dynamic>> parseServers(dynamic data, String? path) {
  final servers = <Map<String, dynamic>>[];
  final items = data is Map ? data['servers'] : null;
  for (final item in (items is List ? items : const []).take(maxServers)) {
    final server = item is Map ? item['server'] : null;
    if (server is! Map || server['name'] is! String) continue;
    final packages = _list(server['packages']),
        remotes = _list(server['remotes']);
    final options = [
      for (final p in packages.take(maxOptions))
        if (p is Map) ?optionFromPackage(p, path),
      for (final r in remotes.take(maxOptions))
        if (r is Map) ?optionFromRemote(r),
    ].take(maxOptions).toList();
    if (options.isEmpty) continue;
    final repo = _dict(server['repository']);
    final official = _dict(
      _dict(
        (item as Map)['_meta'],
      )['io.modelcontextprotocol.registry/official'],
    );
    final website = _s(server['websiteUrl'], 300);
    final name = server['name'] as String;
    servers.add({
      'name': _cut(name, 200),
      'short': shortName(name),
      'title': _s(server['title'], 100),
      'description': _s(server['description'], 400),
      'version': _s(server['version'], 60),
      'repository': _s(repo['url'], 300),
      'options': options,
      'updated': _s(official['updatedAt'], 40),
      'status': _s(official['status'], 20),
      'website': website.startsWith('https://') ? website : '',
    });
  }
  return servers;
}

/// mcp_registry.fill: the {placeholders} replaced by what the user typed.
Map<String, dynamic> fillEntry(Map entry, Map<String, String> values) {
  String put(String text) =>
      text.replaceAllMapped(_fieldRe, (m) => values[m[1]] ?? m[0]!);
  return {
    ...entry,
    'args': [for (final a in entry['args'] as List) put(a as String)],
    'env': {
      for (final e in (entry['env'] as Map).entries)
        e.key as String: put(e.value as String),
    },
    'headers': {
      for (final e in (entry['headers'] as Map).entries)
        e.key as String: put(e.value as String),
    },
    'url': put(entry['url'] as String),
  };
}

/// mcp_registry.drop_unfilled: optional fields left empty go, with the flag
/// before an argument that asked for one.
Map<String, dynamic> dropUnfilled(Map entry, Iterable<String> optional) {
  final skip = optional.toSet();
  bool asks(String text) =>
      _fieldRe.allMatches(text).any((m) => skip.contains(m[1]));
  final env = (entry['env'] as Map).cast<String, String>();
  final dropped = {
    for (final e in env.entries)
      if (asks(e.value)) e.key,
  };
  final args = <String>[];
  for (final arg in (entry['args'] as List).cast<String>()) {
    if (asks(arg) ||
        (entry['command'] == 'docker' &&
            dropped.contains(arg) &&
            args.isNotEmpty &&
            args.last == '-e')) {
      if (args.isNotEmpty &&
          args.last.startsWith('-') &&
          !args.last.contains('=')) {
        args.removeLast();
      }
      continue;
    }
    args.add(arg);
  }
  return {
    ...entry,
    'args': args,
    'env': {
      for (final e in env.entries)
        if (!dropped.contains(e.key)) e.key: e.value,
    },
    'headers': {
      for (final e in (entry['headers'] as Map).cast<String, String>().entries)
        if (!asks(e.value)) e.key: e.value,
    },
  };
}

List<String> unfilled(Map entry) => [
  for (final m in _fieldRe.allMatches(pyJsonDumps(entry))) m[1]!,
];

/// mcp_registry.secret_in_args: secret fields the command line would show
/// (/proc/PID/cmdline is readable by every user of this PC).
List<String> secretInArgs(Map entry, Iterable<String> secrets) {
  final found = {
    for (final arg in (entry['args'] as List).cast<String>())
      for (final m in _fieldRe.allMatches(arg)) m[1]!,
  };
  return [
    for (final name in secrets)
      if (found.contains(name)) name,
  ];
}

// --- The saved registry list ------------------------------------------------

dynamic _trim(dynamic value, [int depth = 0]) {
  if (value is String) return _cut(value, 500);
  if (value == null || value is bool || value is num) return value;
  if (depth >= 4) return null;
  if (value is List) {
    return [for (final v in value.take(maxArguments + 1)) _trim(v, depth + 1)];
  }
  if (value is Map) {
    return {
      for (final e in value.entries.take(maxFields))
        _cut(pyStr(e.key), 128): _trim(e.value, depth + 1),
    };
  }
  return null;
}

int _size(dynamic item) =>
    utf8.encode(pyJsonDumps(item, ensureAscii: false)).length;

/// mcp_registry._kept: only what parseServers reads of a list item.
Map<String, dynamic>? keptItem(dynamic item) {
  final raw = item is Map ? item['server'] : null;
  if (raw is! Map || raw['name'] is! String) return null;
  final server = <String, dynamic>{
    for (final k in _serverKeys)
      if (raw.containsKey(k))
        k: _trim(
          (k == 'packages' || k == 'remotes') && raw[k] is List
              ? (raw[k] as List).take(maxOptions).toList()
              : raw[k],
        ),
  };
  server['name'] = _cut(server['name'] as String, 200);
  if (server.containsKey('repository')) {
    final repo = server['repository'];
    server['repository'] = repo is Map && repo['url'] is String
        ? {'url': repo['url']}
        : <String, dynamic>{};
  }
  final official = _dict(
    (item as Map)['_meta'],
  )['io.modelcontextprotocol.registry/official'];
  final kept = official is Map
      ? {
          'server': server,
          '_meta': {
            'io.modelcontextprotocol.registry/official': _trim(official),
          },
        }
      : {'server': server};
  return _size(kept) <= listMaxItem ? kept : null;
}

/// mcp_registry.load_list: the saved list, or null.
Map<String, dynamic>? loadList(String path) {
  try {
    final file = File(path);
    if (file.lengthSync() > listMaxFile) return null;
    final data = jsonDecode(utf8.decode(file.readAsBytesSync()));
    if (data is! Map<String, dynamic> || data['servers'] is! Map) return null;
    return data;
  } on Object {
    return null;
  }
}

final _strptime = RegExp(
  r'^(\d\d\d\d)-(1[0-2]|0[1-9]|[1-9])-(3[01]|[12]\d|0[1-9]|[1-9]| [1-9])'
  r'T(2[0-3]|[0-1]\d|\d):([0-5]\d|\d):(6[0-1]|[0-5]\d|\d)$',
);

/// mcp_registry._epoch: local time, as time.mktime(time.strptime(...)).
double registryEpoch(dynamic text) {
  final m = _strptime.firstMatch(_cut(pyStr(text), 19));
  if (m == null) return 0;
  final n = [for (var i = 1; i <= 6; i++) int.parse(m[i]!.trim())];
  return DateTime(n[0], n[1], n[2], n[3], n[4], n[5]).millisecondsSinceEpoch /
      1000;
}

/// mcp_registry.search_list: (servers, next cursor, total) from the saved
/// list; null when it was never downloaded in full.
(List<Map<String, dynamic>>, String, int)? searchList(
  String query,
  String listPath,
  String? path, {
  int offset = 0,
  int limit = registryPage,
}) {
  final data = loadList(listPath);
  if (data == null || !pyTruthy(data['fetched'])) return null;
  final words = query.toLowerCase().split(_space).where((w) => w.isNotEmpty);
  final queryText = query.trim().toLowerCase();
  final matched = <(bool, double, String, dynamic)>[];
  for (final e in (data['servers'] as Map).entries) {
    final item = e.value, name = pyStr(e.key);
    final server = item is Map ? item['server'] : null;
    if (server is! Map) continue;
    final text = [
      for (final k in ['name', 'title', 'description'])
        pyTruthy(server[k]) ? pyStr(server[k]) : '',
    ].join(' ').toLowerCase();
    if (words.every(text.contains)) {
      final meta = _dict(
        _dict(
          (item as Map)['_meta'],
        )['io.modelcontextprotocol.registry/official'],
      );
      if (!const ['', 'active'].contains(_s(meta['status'], 20))) continue;
      matched.add((
        !name.toLowerCase().contains(queryText),
        -registryEpoch(meta['updatedAt']),
        name,
        item,
      ));
    }
  }
  matched.sort((a, b) {
    if (a.$1 != b.$1) return a.$1 ? 1 : -1;
    if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
    return pyCompare(a.$3, b.$3);
  });
  final end = offset + limit < matched.length ? offset + limit : matched.length;
  final page = parseServers({
    'servers': [
      for (final m in matched.sublist(offset.clamp(0, matched.length), end))
        m.$4,
    ],
  }, path);
  return (
    page,
    offset + limit < matched.length ? '#${offset + limit}' : '',
    matched.length,
  );
}

/// urllib.parse.quote with the given safe characters.
String quoteUrl(String text, {String safe = '/'}) {
  final out = StringBuffer();
  for (final byte in utf8.encode(text)) {
    final c = String.fromCharCode(byte);
    if (RegExp(r'[A-Za-z0-9_.\-~]').hasMatch(c) || safe.contains(c)) {
      out.write(c);
    } else {
      out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

/// urllib.parse.urlencode (quote_plus).
String urlencode(Map<String, dynamic> params) => [
  for (final e in params.entries)
    '${quoteUrl(e.key, safe: '').replaceAll('%20', '+')}='
        '${quoteUrl(pyStr(e.value), safe: '').replaceAll('%20', '+')}',
].join('&');

Future<dynamic> _fetchJson(
  String url, {
  required int maxBytes,
  required int timeout,
  required int redirects,
}) async => jsonDecode(
  utf8.decode(
    await netFetch(
      url,
      maxBytes: maxBytes,
      timeout: timeout,
      redirects: redirects,
      headers: const {'Accept': 'application/json'},
    ),
  ),
);

/// mcp_registry.search_page against the official registry: the saved list
/// when there is one ("#offset" cursors), else the registry's own search.
Future<Map<String, dynamic>> searchPage(
  String query,
  String listPath,
  String? path, {
  String cursor = '',
  int limit = registryPage,
  Future<dynamic> Function(String url)? fetch,
}) async {
  if (cursor.isEmpty || cursor.startsWith('#')) {
    final digits = cursor.length > 1 ? cursor.substring(1) : '';
    final offset = RegExp(r'^\d+$').hasMatch(digits) ? int.parse(digits) : 0;
    final found = searchList(
      query,
      listPath,
      path,
      offset: offset,
      limit: limit,
    );
    if (found != null) {
      return {'servers': found.$1, 'cursor': found.$2, 'total': found.$3};
    }
    cursor = '';
  }
  final params = <String, dynamic>{
    'search': _cut(query.trim(), 100),
    'limit': limit,
    'version': 'latest',
    if (cursor.isNotEmpty) 'cursor': _cut(cursor, 300),
  };
  final url = '$registryApi?${urlencode(params)}';
  final dynamic data;
  try {
    data =
        await (fetch ??
            (u) => _fetchJson(
              u,
              maxBytes: registryMaxBytes,
              timeout: registryTimeout,
              redirects: 0,
            ))(url);
  } on FetchError catch (error) {
    throw FormatException(error.message);
  }
  final meta = _dict(_dict(data)['metadata']);
  final following = meta['nextCursor'] is String
      ? meta['nextCursor'] as String
      : '';
  return {
    'servers': parseServers(data is Map ? data : const {}, path),
    'cursor': following != cursor ? _cut(following, 300) : '',
    'total': null,
  };
}

String _isoNow(double now) {
  final t = DateTime.fromMillisecondsSinceEpoch(
    (now * 1000).floor(),
    isUtc: true,
  );
  String two(int n) => '$n'.padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}'
      'T${two(t.hour)}:${two(t.minute)}:${two(t.second)}Z';
}

/// mcp_registry.refresh_list: the registry's list (or what changed since)
/// saved into listPath when older than listMaxAge; saved every saveEvery
/// pages with where it stopped, so a download cut short goes on next time.
/// The caller makes sure only one runs. False: not needed, or stopped early.
Future<bool> refreshList(
  String listPath, {
  required double now,
  required Future<dynamic> Function(String url) fetch,
  required void Function(String path, List<int> bytes) write,
}) async {
  final old = loadList(listPath) ?? <String, dynamic>{};
  var resume = old['resume'] is Map
      ? Map<String, dynamic>.from(old['resume'] as Map)
      : null;
  final checked = old['checked'];
  if (resume == null &&
      pyTruthy(old['fetched']) &&
      now - (checked is num ? checked.toDouble() : 0) < listMaxAge) {
    return false;
  }
  resume ??= {
    'since': pyStr(pyTruthy(old['fetched']) ? old['fetched'] : ''),
    'cursor': '',
    'started': _isoNow(now),
  };
  final servers = <String, dynamic>{};
  for (final item in _dict(old['servers']).values) {
    final kept = keptItem(item);
    if (kept != null) servers[(kept['server'] as Map)['name'] as String] = kept;
  }
  final out = <String, dynamic>{
    'fetched': old.containsKey('fetched') ? old['fetched'] : '',
    'checked': old.containsKey('checked') ? old['checked'] : 0,
    'servers': servers,
    'resume': {...resume},
  };
  void save(Map<String, dynamic> data) {
    final bytes = utf8.encode(pyJsonDumps(data, ensureAscii: false));
    if (bytes.length > listMaxFile) {
      throw const FileSystemException('the MCP server list is over its limit');
    }
    write(listPath, bytes);
  }

  try {
    var cursor = pyStr(pyTruthy(resume['cursor']) ? resume['cursor'] : '');
    final sizes = {
      for (final e in servers.entries)
        e.key: _size(e.value) + utf8.encode(e.key).length + 8,
    };
    var total = sizes.values.fold(0, (a, b) => a + b);
    var full = false, finished = false;
    for (var page = 1; page <= listMaxPages; page++) {
      final params = <String, dynamic>{
        'limit': 100,
        'version': 'latest',
        if (pyTruthy(resume['since'])) 'updated_since': resume['since'],
        if (cursor.isNotEmpty) 'cursor': cursor,
      };
      dynamic data;
      try {
        data = await fetch('$registryApi?${urlencode(params)}');
      } on Object {
        if (page > 1) save(out);
        return false;
      }
      data = data is Map ? data : const {};
      final items = _list(data['servers']);
      for (final item in items.take(maxServers)) {
        final kept = keptItem(item);
        if (kept == null) continue;
        final name = (kept['server'] as Map)['name'] as String;
        final size = _size(kept) + utf8.encode(name).length + 8;
        final grown = total - (sizes[name] ?? 0) + size;
        if (grown > listMaxFile - listMaxItem ||
            (!servers.containsKey(name) && servers.length >= listMaxServers)) {
          full = true;
          break;
        }
        servers[name] = kept;
        sizes[name] = size;
        total = grown;
      }
      final meta = _dict(data['metadata']);
      final following = meta['nextCursor'] is String
          ? meta['nextCursor'] as String
          : '';
      if (full || following.isEmpty || following == cursor || items.isEmpty) {
        finished = true;
        break;
      }
      cursor = _cut(following, 300);
      (out['resume'] as Map)['cursor'] = cursor;
      if (page % saveEvery == 0) save(out);
    }
    if (!finished) {
      save(out);
      return false;
    }
    save({'fetched': resume['started'], 'checked': now, 'servers': servers});
    return true;
  } on FileSystemException {
    return false;
  }
}

// --- Servers to start with --------------------------------------------------

const catalogGroups = [
  ('files', 'Files and data'),
  ('web', 'Web and browser'),
  ('code', 'Coding'),
  ('think', 'Thinking and memory'),
];
const catalogTrust = {
  'reference': 'Reference server · MCP project',
  'official': 'Official · {0}',
};
const catalogTrustHints = {
  'reference':
      'Written by the people behind MCP as examples of how a server works. Fine for everyday use on your own PC; they are kept simple on purpose.',
  'official':
      'Made by the company behind the service, from its own repository.',
};
const _ref = 'https://github.com/modelcontextprotocol/servers';

Map<String, dynamic> _npm(
  String name, [
  Map<String, dynamic> extra = const {},
]) => {
  'registryType': 'npm',
  'identifier': name,
  'version': 'latest',
  'transport': {'type': 'stdio'},
  ...extra,
};

Map<String, dynamic> _pypi(String name) => {
  'registryType': 'pypi',
  'identifier': name,
  'version': 'latest',
  'transport': {'type': 'stdio'},
};

Map<String, dynamic> _pick(
  String key,
  String title,
  String group,
  String maker,
  String trust,
  String about,
  List<String> tries,
  String needs,
  String repository,
  Map<String, dynamic> spec, [
  String keyUrl = '',
]) => {
  'key': key,
  'title': title,
  'group': group,
  'maker': maker,
  'trust': trust,
  'about': about,
  'tries': tries,
  'needs': needs,
  'repository': repository,
  'spec': spec,
  'key_url': keyUrl,
};

/// mcp_catalog.PICKS, in its order.
final catalogPicks = [
  _pick(
    'filesystem',
    'Filesystem',
    'files',
    'MCP project',
    'reference',
    'Lets the agents read, write, move and search files, but only in the folder you choose.',
    [
      'Sort the PDFs in my folder into subfolders by year',
      'Which files mention the invoice 2041?',
    ],
    'A folder the agents may use.',
    '$_ref/tree/main/src/filesystem',
    {
      'packages': [
        _npm('@modelcontextprotocol/server-filesystem', {
          'packageArguments': [
            {
              'type': 'positional',
              'isRequired': true,
              'valueHint': '~/Documents',
              'description': 'Folder',
            },
          ],
        }),
      ],
    },
  ),
  _pick(
    'git',
    'Git',
    'code',
    'MCP project',
    'reference',
    'Reads and changes Git repositories: status, history, diffs, branches and commits.',
    [
      'What changed in this repository last week?',
      'Commit my staged changes with a good message',
    ],
    'Nothing: it works on the repository the agent names.',
    '$_ref/tree/main/src/git',
    {
      'packages': [_pypi('mcp-server-git')],
    },
  ),
  _pick(
    'fetch',
    'Fetch',
    'web',
    'MCP project',
    'reference',
    'Opens a web address and hands the page to the agent as plain text.',
    ['Read this article and give me the three main points: https://…'],
    'Nothing.',
    '$_ref/tree/main/src/fetch',
    {
      'packages': [_pypi('mcp-server-fetch')],
    },
  ),
  _pick(
    'playwright',
    'Playwright',
    'web',
    'Microsoft',
    'official',
    'A real browser the agent can drive: open pages, click, fill in forms, take screenshots.',
    ['Open my web app on localhost:3000 and check that the login works'],
    'Nothing: it downloads its own browser on first use.',
    'https://github.com/microsoft/playwright-mcp',
    {
      'packages': [_npm('@playwright/mcp')],
    },
  ),
  _pick(
    'chrome-devtools',
    'Chrome DevTools',
    'web',
    'Google',
    'official',
    'Inspects a page in Chrome: console messages, network requests, performance.',
    ['Why does this page load so slowly?'],
    'Google Chrome.',
    'https://github.com/ChromeDevTools/chrome-devtools-mcp',
    {
      'packages': [_npm('chrome-devtools-mcp')],
    },
  ),
  _pick(
    'brave-search',
    'Brave Search',
    'web',
    'Brave',
    'official',
    "Web, news and image search for the agents through Brave's search service.",
    ['Search for reviews of the Framework 13 from this year'],
    'A Brave Search API key (there is a free plan).',
    'https://github.com/brave/brave-search-mcp-server',
    {
      'packages': [
        _npm('@brave/brave-search-mcp-server', {
          'environmentVariables': [
            {
              'name': 'BRAVE_API_KEY',
              'isRequired': true,
              'isSecret': true,
              'description': 'Your Brave Search API key',
            },
          ],
        }),
      ],
    },
    'https://brave.com/search/api/',
  ),
  _pick(
    'github',
    'GitHub',
    'code',
    'GitHub',
    'official',
    'Works with GitHub for the agents: repositories, issues, pull requests, Actions.',
    [
      'List the open issues of my repository labelled bug',
      'Summarise pull request 42',
    ],
    'A GitHub personal access token. The server runs at GitHub; nothing is installed.',
    'https://github.com/github/github-mcp-server',
    {
      'remotes': [
        {
          'type': 'streamable-http',
          'url': 'https://api.githubcopilot.com/mcp/',
          'headers': [
            {
              'name': 'Authorization',
              'value': 'Bearer {GITHUB_TOKEN}',
              'isRequired': true,
              'isSecret': true,
              'variables': {
                'GITHUB_TOKEN': {
                  'isRequired': true,
                  'isSecret': true,
                  'description': 'Your GitHub personal access token',
                },
              },
            },
          ],
        },
      ],
    },
    'https://github.com/settings/personal-access-tokens',
  ),
  _pick(
    'context7',
    'Context7',
    'code',
    'Upstash',
    'official',
    'Current documentation and code examples of libraries, so the agent does not guess old APIs.',
    ['How do I stream a response with the newest FastAPI? use context7'],
    'Nothing; a free API key gives higher limits.',
    'https://github.com/upstash/context7',
    {
      'packages': [
        _npm('@upstash/context7-mcp', {
          'environmentVariables': [
            {
              'name': 'CONTEXT7_API_KEY',
              'isSecret': true,
              'description': 'API key (optional)',
            },
          ],
        }),
      ],
      'remotes': [
        {
          'type': 'streamable-http',
          'url': 'https://mcp.context7.com/mcp',
          'headers': [
            {
              'name': 'Authorization',
              'value': 'Bearer {CONTEXT7_API_KEY}',
              'isSecret': true,
              'variables': {
                'CONTEXT7_API_KEY': {
                  'isSecret': true,
                  'description': 'API key (optional)',
                },
              },
            },
          ],
        },
      ],
    },
    'https://context7.com/dashboard',
  ),
  _pick(
    'time',
    'Time',
    'think',
    'MCP project',
    'reference',
    'The current time and conversions between time zones.',
    ['What time is it in Tokyo when it is 9:00 here?'],
    'Nothing.',
    '$_ref/tree/main/src/time',
    {
      'packages': [_pypi('mcp-server-time')],
    },
  ),
  _pick(
    'memory',
    'Memory',
    'think',
    'MCP project',
    'reference',
    'A memory that lasts between chats: the agent stores facts as a small graph in a local file.',
    ['Remember that my server is called atlas and runs Debian'],
    'Nothing.',
    '$_ref/tree/main/src/memory',
    {
      'packages': [_npm('@modelcontextprotocol/server-memory')],
    },
  ),
  _pick(
    'sequential-thinking',
    'Sequential Thinking',
    'think',
    'MCP project',
    'reference',
    'Gives the agent a way to think through a hard problem step by step and revise its steps.',
    ['Plan the move of my photos to the new disk, step by step'],
    'Nothing.',
    '$_ref/tree/main/src/sequentialthinking',
    {
      'packages': [_npm('@modelcontextprotocol/server-sequential-thinking')],
    },
  ),
  _pick(
    'everything',
    'Everything',
    'think',
    'MCP project',
    'reference',
    'A test server with every MCP feature. Useful to see whether an agent handles MCP at all.',
    ['Which tools does the everything server offer?'],
    'Nothing.',
    '$_ref/tree/main/src/everything',
    {
      'packages': [_npm('@modelcontextprotocol/server-everything')],
    },
  ),
];

/// mcp_catalog.latest_version: the newest version on npm or PyPI, '' when
/// it cannot be asked.
Future<String> latestVersion(
  String kind,
  String name, {
  Future<dynamic> Function(String url)? fetch,
}) async {
  final url = kind == 'npm'
      ? 'https://registry.npmjs.org/${quoteUrl(name, safe: '@')}/latest'
      : 'https://pypi.org/pypi/${quoteUrl(name, safe: '')}/json';
  dynamic data;
  try {
    data =
        await (fetch ??
            (u) => _fetchJson(
              u,
              maxBytes: 4 * 1024 * 1024,
              timeout: 10,
              redirects: 1,
            ))(url);
  } on Object {
    return '';
  }
  final version = data is Map
      ? (kind == 'npm' ? data['version'] : _dict(data['info'])['version'])
      : null;
  return version is String &&
          RegExp(r'^[0-9A-Za-z.+_-]{1,60}$').hasMatch(version)
      ? version
      : '';
}

/// mcp_catalog.resolve: the pick as a registry server, its packages pinned
/// to their newest version.
Future<Map<String, dynamic>> resolvePick(
  Map<String, dynamic> pick,
  String? path, {
  Future<String> Function(String kind, String name)? ask,
}) async {
  final spec = pick['spec'] as Map;
  final packages = <Map<String, dynamic>>[];
  for (final package in _list(spec['packages']).cast<Map>()) {
    final version = await (ask ?? latestVersion)(
      package['registryType'] as String,
      package['identifier'] as String,
    );
    packages.add({
      ...package.cast<String, dynamic>(),
      'version': version.isNotEmpty ? version : 'latest',
    });
  }
  final server = parseServers({
    'servers': [
      {
        'server': {
          'name': pick['key'],
          'title': pick['title'],
          'description': pick['about'],
          'repository': {'url': pick['repository']},
          'packages': packages,
          'remotes': spec['remotes'] ?? const [],
        },
      },
    ],
  }, path).first;
  server['short'] = pick['key'];
  server['version'] =
      packages
          .map((p) => p['version'])
          .where((v) => v != 'latest')
          .firstOrNull ??
      '';
  return server;
}

// --- Options as the app sees them -------------------------------------------

/// The ways to run a shown server, kept under opaque handles: the app picks
/// one and sends only the values the user typed; the entry itself never
/// comes back from the app.
String _same(String text) => text;

final class McpOptions {
  McpOptions(this.newToken);
  final String Function() newToken;
  final items = <String, (DateTime, Map<String, dynamic>)>{};
  static const keep = Duration(minutes: 30);
  static const most = 400;

  Map<String, dynamic> _public(
    Map<String, dynamic> option,
    String Function(String) translate,
  ) {
    final entry = option['entry'] as Map;
    final needs = (option['needs'] as List).cast<Map<String, dynamic>>();
    final now = DateTime.now();
    items.removeWhere((_, v) => now.difference(v.$1) >= keep);
    while (items.length >= most) {
      items.remove(items.keys.first);
    }
    final token = newToken();
    items[token] = (now, option);
    return {
      'option': token,
      'kind': option['kind'],
      'label': option['label'],
      'runnable': option['runnable'],
      'command': entry['command'],
      'args': entry['args'],
      'env': (entry['env'] as Map).keys.toList(),
      'url': entry['url'],
      'headers': (entry['headers'] as Map).keys.toList(),
      'needs': [
        for (final n in needs)
          {
            'name': n['name'],
            'description': translate(n['description'] as String),
            'required': n['required'],
            'secret': n['secret'],
            'value': n['secret'] == true ? '' : n['value'],
            'hint': n['hint'],
          },
      ],
      // Secret fields this way would put on the command line: not offered.
      'on_command_line': secretInArgs(entry, [
        for (final n in needs)
          if (n['secret'] == true) n['name'] as String,
      ]),
    };
  }

  /// A server for the app: its options under handles, the publisher named.
  Map<String, dynamic> server(
    Map<String, dynamic> server, {
    String Function(String) translate = _same,
  }) {
    final (kind, who) = publisher(server['name'] as String);
    return {
      for (final e in server.entries)
        if (e.key != 'options') e.key: e.value,
      'publisher': {'kind': kind, 'who': who},
      'options': [
        for (final o
            in (server['options'] as List).cast<Map<String, dynamic>>())
          _public(o, translate),
      ],
    };
  }

  /// The entry of a picked option filled with the user's values (the GTK
  /// form's new_mcp_entry without its free-form lines).
  Map<String, dynamic> entryFor(dynamic handle, dynamic values, String home) {
    final kept = handle is String ? items[handle] : null;
    if (kept == null || DateTime.now().difference(kept.$1) >= keep) {
      throw const FormatException('Show the server again');
    }
    final option = kept.$2;
    final needs = {
      for (final n in (option['needs'] as List).cast<Map<String, dynamic>>())
        n['name'] as String: n,
    };
    if (values is! Map ||
        values.length > needs.length ||
        values.entries.any(
          (e) =>
              e.key is! String ||
              !needs.containsKey(e.key) ||
              e.value is! String ||
              (e.value as String).length > 4096 ||
              RegExp('[\\x00-\\x1f\\x7f]').hasMatch(e.value as String),
        )) {
      throw const FormatException('Invalid server fields');
    }
    final typed = <String, String>{
      for (final name in needs.keys)
        name: () {
          final v = '${values[name] ?? ''}'.trim();
          return v.startsWith('~/') ? '$home${v.substring(1)}' : v;
        }(),
    };
    final missing = [
      for (final e in needs.entries)
        if (e.value['required'] == true && typed[e.key]!.isEmpty)
          e.key.startsWith('arg:') ? e.value['description'] : e.key,
    ];
    if (missing.isNotEmpty) {
      throw FormatException('Fill in: ${missing.join(', ')}');
    }
    final optional = [
      for (final e in needs.entries)
        if (e.value['required'] != true && typed[e.key]!.isEmpty) e.key,
    ];
    final filled = {
      for (final e in typed.entries)
        if (e.value.isNotEmpty) e.key: e.value,
    };
    // A field shown with the registry's default: what the user typed replaces
    // it (the GTK form's free-form lines did that).
    final entry = {...option['entry'] as Map};
    for (final part in ['env', 'headers']) {
      final values = Map<String, String>.from(entry[part] as Map);
      for (final e in needs.entries) {
        final fallback = e.value['value'] as String;
        if (fallback.isNotEmpty &&
            values[e.key] == fallback &&
            typed[e.key]!.isNotEmpty) {
          values[e.key] = typed[e.key]!;
        }
      }
      entry[part] = values;
    }
    final secrets = [
      for (final e in needs.entries)
        if (e.value['secret'] == true && filled.containsKey(e.key)) e.key,
    ];
    if (secretInArgs(entry, secrets).isNotEmpty) {
      throw const FormatException('A secret would be on the command line');
    }
    final out = dropUnfilled(fillEntry(entry, filled), optional);
    final whole = RegExp(r'^\{[^}]+\}$');
    out['env'] = {
      for (final e in (out['env'] as Map).entries)
        if (!whole.hasMatch(e.value as String)) e.key: e.value,
    };
    out['headers'] = {
      for (final e in (out['headers'] as Map).entries)
        if (!whole.hasMatch(e.value as String)) e.key: e.value,
    };
    if (unfilled(out).isNotEmpty) {
      throw FormatException('Fill in: ${unfilled(out).join(', ')}');
    }
    return out;
  }
}
