import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'line_diff.dart' show pySplitlines;
import 'mcp_plans.dart' show checkEntry;
import 'model_hub.dart' show boundedOutput;
import 'py_values.dart';

/// mcp_tools: ask an MCP server which tools (and prompts) it offers, the way
/// an agent does: initialize, then tools/list. Only when asked, as it starts
/// the server's program or talks to its address.
///
/// - stdio: the server's command with its args and env (as the agent's own
///   settings have them), in a session of its own, ended afterwards;
/// - streamable HTTP: JSON-RPC posts with the entry's headers (plain JSON or
///   an event-stream answer), through curl with the headers on its stdin.
/// Legacy SSE servers are not asked. Answers are kept in
/// ~/.cache/ai-agents-map/mcp-tools/NAME.json, as the reference keeps them.

const toolsTimeout = Duration(seconds: 90); // npx/uvx may download it first
const maxLine = 4 * 1024 * 1024;
const maxTools = 300;
const maxCursor = 1024;
const mcpProtocol = '2025-06-18';
const _client = {'name': 'ai-agents-map', 'version': '1'};
final _nameRe = RegExp(r'^[A-Za-z0-9_.-]{1,64}$');
final _space = RegExp(
  '[\\t\\n\\x0b\\x0c\\r\\x1c-\\x1f \\x85\\xa0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000]+',
);

final class AskError implements Exception {
  AskError(this.message);
  final String message;
  @override
  String toString() => message;
}

String _cut(String text, int limit) {
  final runes = text.runes;
  return runes.length <= limit ? text : String.fromCharCodes(runes.take(limit));
}

/// mcp_tools._params: a tool's parameter names, a few and short.
List<String> toolParams(dynamic schema) {
  final Iterable names;
  if (schema is Map) {
    names = schema['properties'] is Map
        ? (schema['properties'] as Map).keys
        : const [];
  } else if (schema is List) {
    names = [
      for (final a in schema)
        if (a is Map) a['name'],
    ];
  } else {
    names = const [];
  }
  return [
    for (final n in names)
      if (n is String && _nameRe.hasMatch(_cut(n, 64))) _cut(n, 64),
  ].take(40).toList();
}

Map<String, dynamic> _result(Map message) {
  final error = message['error'];
  if (error != null) {
    final text = error is Map && error.containsKey('message')
        ? error['message']
        : error;
    throw AskError(_cut(pyStr(text), 200));
  }
  final result = message['result'];
  return result is Map<String, dynamic> ? result : {};
}

/// mcp_tools._clean.
List<Map<String, dynamic>> cleanTools(dynamic items, String kind) {
  final found = <Map<String, dynamic>>[];
  for (final item in items is List ? items : const []) {
    if (item is Map && item['name'] is String) {
      final raw = item['description'] is String
          ? item['description'] as String
          : '';
      final text = raw.split(_space).where((w) => w.isNotEmpty).join(' ');
      found.add({
        'name': _cut(item['name'] as String, 100),
        'description': _cut(text, 400),
        'kind': kind,
        'params': toolParams(
          item[kind == 'tool' ? 'inputSchema' : 'arguments'],
        ),
      });
    }
  }
  return found.take(maxTools).toList();
}

abstract interface class _Link {
  Future<void> send(Map<String, dynamic> message);
  Future<Map<String, dynamic>> answer(int wanted);
  Future<void> close();
}

final class _Stdio implements _Link {
  _Stdio(this.process) : deadline = DateTime.now().add(toolsTimeout) {
    _reading = process.stdout.listen(
      (chunk) {
        _buffer.addAll(chunk);
        _wake();
      },
      onDone: () {
        _ended = true;
        _wake();
      },
    );
    unawaited(process.stderr.drain<void>());
  }

  static Future<_Stdio> start(
    Map entry,
    String home,
    Map<String, String> environment,
  ) async {
    final env = {
      ...environment,
      for (final e in (entry['env'] as Map).entries) '${e.key}': '${e.value}',
    };
    final process = await Process.start(
      'setsid',
      [
        '--',
        entry['command'] as String,
        ...(entry['args'] as List).cast<String>(),
      ],
      environment: env,
      includeParentEnvironment: false,
      workingDirectory: home,
    );
    return _Stdio(process);
  }

  final Process process;
  final DateTime deadline;
  final _buffer = <int>[];
  late final StreamSubscription<List<int>> _reading;
  var _ended = false;
  Completer<void>? _waiting;

  void _wake() {
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  Duration get _left => deadline.difference(DateTime.now());

  @override
  Future<void> send(Map<String, dynamic> message) async {
    if (_left <= Duration.zero) throw AskError('the server does not read');
    process.stdin.add(utf8.encode('${jsonEncode(message)}\n'));
    try {
      await process.stdin.flush().timeout(_left);
    } on TimeoutException {
      throw AskError('the server does not read');
    } on Object {
      throw AskError('the server stopped');
    }
  }

  @override
  Future<Map<String, dynamic>> answer(int wanted) async {
    while (true) {
      var newline = _buffer.indexOf(10);
      while (newline >= 0) {
        final line = _buffer.sublist(0, newline);
        _buffer.removeRange(0, newline + 1);
        newline = _buffer.indexOf(10);
        dynamic message;
        try {
          message = jsonDecode(utf8.decode(line, allowMalformed: true));
        } on FormatException {
          continue; // a server printing other things on stdout
        }
        if (message is Map && message['id'] == wanted) return _result(message);
      }
      if (_buffer.length > maxLine) throw AskError('answer too large');
      if (_ended) throw AskError('the server stopped');
      final left = _left;
      if (left <= Duration.zero) throw TimeoutException('no answer');
      _waiting = Completer<void>();
      await _waiting!.future.timeout(left, onTimeout: () {});
    }
  }

  @override
  Future<void> close() async {
    final group = '-${process.pid}';
    await Process.run('kill', ['-TERM', '--', group]);
    final code = await process.exitCode
        .then<int?>((c) => c)
        .timeout(const Duration(seconds: 5), onTimeout: () => null);
    if (code == null) await Process.run('kill', ['-KILL', '--', group]);
    await _reading.cancel();
  }
}

final _bad = RegExp(r'[\x00-\x20\x7f"\\]');

String _quote(String value) {
  if (value.codeUnits.any((c) => c < 32 || c == 0x7f)) {
    throw AskError('control characters in a request header');
  }
  return '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}

/// netfetch.fetch(user_url=True, include=True, method="POST", data=...): an
/// address the user set up (http or https, no redirects), the response
/// headers before the body, headers and body on curl's stdin.
Future<List<int>> postUserUrl(
  String url,
  Map<String, String> headers,
  List<int> data, {
  int maxBytes = maxLine,
  int timeout = 30,
}) async {
  final parts = Uri.tryParse(url);
  if (_bad.hasMatch(url) ||
      parts == null ||
      parts.userInfo.isNotEmpty ||
      parts.host.isEmpty) {
    throw AskError('not a usable address');
  }
  if (parts.scheme != 'https' && parts.scheme != 'http') {
    throw AskError('only https addresses');
  }
  final config = ['url = ${_quote(url)}'];
  for (final e in headers.entries) {
    if (!RegExp(r'^[A-Za-z0-9-]{1,100}$').hasMatch(e.key)) {
      throw AskError('not a header name');
    }
    config.add('header = ${_quote('${e.key}: ${e.value}')}');
  }
  config.add('data-binary = ${_quote(utf8.decode(data))}');
  final (out, ok) = await boundedOutput(
    [
      'curl',
      '--config',
      '-',
      '--silent',
      '--show-error',
      '--fail',
      '--proto',
      '=http,https',
      '--max-time',
      '$timeout',
      '--max-filesize',
      '$maxBytes',
      '--user-agent',
      'ai-agents-map',
      '--max-redirs',
      '0',
      '--include',
      '--request',
      'POST',
    ],
    maxBytes: maxBytes,
    timeout: Duration(seconds: timeout + 5),
    stdin: utf8.encode('${config.join('\n')}\n'),
  );
  if (!ok) {
    throw AskError(
      '${parts.host} did not answer (or the answer was too large)',
    );
  }
  return out;
}

final class _Http implements _Link {
  _Http(Map entry, this.post)
    : url = entry['url'] as String,
      headers = {
        for (final e in (entry['headers'] as Map).entries)
          '${e.key}': '${e.value}',
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
      };
  final String url;
  final Map<String, String> headers;
  final Future<List<int>> Function(
    String url,
    Map<String, String> headers,
    List<int> data,
  )
  post;
  String? session;
  final results = <dynamic, Map>{};

  @override
  Future<void> send(Map<String, dynamic> message) async {
    final raw = await post(url, {
      ...headers,
      'Mcp-Session-Id': ?session,
    }, utf8.encode(jsonEncode(message)));
    final text = utf8.decode(raw, allowMalformed: true);
    var head = '', body = text;
    while (body.startsWith('HTTP/')) {
      final found = RegExp(r'^(.*?)\r?\n\r?\n', dotAll: true).firstMatch(body);
      if (found == null) break;
      head = found[1]!;
      body = body.substring(found.end);
      if (!RegExp(r'^HTTP/\S+ 100\b').hasMatch(head)) break;
    }
    final id = RegExp(
      r'^mcp-session-id:\s*([!-~]{1,200})\s*$',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(head);
    if (id != null) session = id[1];
    final kind = RegExp(
      r'^content-type:\s*(\S+)',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(head);
    if (!message.containsKey('id')) return;
    final texts = kind != null && kind[1]!.contains('event-stream')
        ? [
            for (final line in pySplitlines(body))
              if (line.startsWith('data:')) line.substring(5).trim(),
          ]
        : [body];
    for (final item in texts) {
      dynamic answer;
      try {
        answer = jsonDecode(item);
      } on FormatException {
        continue;
      }
      if (answer is Map && answer['id'] == message['id']) {
        results[message['id']] = answer;
      }
    }
  }

  @override
  Future<Map<String, dynamic>> answer(int wanted) async {
    final message = results[wanted];
    if (message == null) throw AskError('no answer');
    return _result(message);
  }

  @override
  Future<void> close() async {}
}

/// mcp_tools.ask: {tools, prompts, server} from a server (normal entry).
Future<Map<String, dynamic>> askTools(
  Map entry, {
  required String home,
  required Map<String, String> environment,
  Future<List<int>> Function(String, Map<String, String>, List<int>)? post,
}) async {
  entry = checkEntry(entry); // the shape every agent's entry is read into
  if (entry['transport'] == 'sse') throw AskError('an SSE server: not asked');
  final _Link link = entry['transport'] == 'stdio'
      ? await _Stdio.start(entry, home, environment)
      : _Http(entry, post ?? postUserUrl);
  try {
    await link.send({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {
        'protocolVersion': mcpProtocol,
        'capabilities': <String, dynamic>{},
        'clientInfo': _client,
      },
    });
    final hello = await link.answer(1);
    await link.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
    final tools = <Map<String, dynamic>>[];
    String? cursor;
    var number = 2;
    while (true) {
      await link.send({
        'jsonrpc': '2.0',
        'id': number,
        'method': 'tools/list',
        'params': cursor != null && cursor.isNotEmpty
            ? {'cursor': cursor}
            : <String, dynamic>{},
      });
      final page = await link.answer(number);
      tools.addAll(cleanTools(page['tools'], 'tool'));
      final next = page['nextCursor'];
      // An odd or huge cursor: the pages so far are enough.
      cursor = next is String && next.length <= maxCursor ? next : null;
      number++;
      if (cursor == null ||
          cursor.isEmpty ||
          tools.length >= maxTools ||
          number > 20) {
        break;
      }
    }
    var prompts = <Map<String, dynamic>>[];
    final capabilities = hello['capabilities'];
    if (capabilities is Map && capabilities.containsKey('prompts')) {
      await link.send({
        'jsonrpc': '2.0',
        'id': 99,
        'method': 'prompts/list',
        'params': <String, dynamic>{},
      });
      try {
        prompts = cleanTools((await link.answer(99))['prompts'], 'prompt');
      } on AskError {
        prompts = [];
      } on TimeoutException {
        prompts = [];
      }
    }
    final info = hello['serverInfo'] is Map ? hello['serverInfo'] as Map : {};
    final server = [
      for (final k in ['name', 'version'])
        _cut(pyStr(info.containsKey(k) ? info[k] : ''), 60),
    ].join(' ').trim();
    return {'tools': tools, 'prompts': prompts, 'server': server};
  } finally {
    await link.close();
  }
}

String toolsCacheFile(String home, String name) {
  if (!_nameRe.hasMatch(name)) throw FormatException(name);
  return '$home/.cache/ai-agents-map/mcp-tools/$name.json';
}

/// mcp_tools.cached.
Map<String, dynamic>? cachedTools(String home, String name) {
  try {
    final file = File(toolsCacheFile(home, name));
    if (file.lengthSync() > 8 * maxLine) return null;
    final data = jsonDecode(file.readAsStringSync());
    return data is Map<String, dynamic> ? data : null;
  } on Object {
    return null;
  }
}

String _localNow() {
  final t = DateTime.now();
  String two(int n) => '$n'.padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}'
      'T${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// The text of a failed ask, as the reference's str(error).
String askErrorText(Object error) => switch (error) {
  AskError(:final message) => message,
  TimeoutException() => 'no answer',
  ProcessException(:final message) => message,
  FormatException(:final message) => message,
  _ => '$error',
};

/// mcp_tools.ask_and_keep: ask, and keep the answer (or the error) with the
/// time. Never throws for an odd server.
Future<Map<String, dynamic>> askAndKeep(
  String name,
  Map entry, {
  required String home,
  required Map<String, String> environment,
  required void Function(String path, List<int> bytes) write,
  Future<List<int>> Function(String, Map<String, String>, List<int>)? post,
}) async {
  final now = _localNow();
  Map<String, dynamic> result;
  try {
    result = {
      'status': 'ok',
      'checked': now,
      ...await askTools(
        entry,
        home: home,
        environment: environment,
        post: post,
      ),
    };
  } on Object catch (error) {
    result = {
      'status': 'failed',
      'checked': now,
      'error': _cut(askErrorText(error), 300),
    };
  }
  try {
    write(
      toolsCacheFile(home, name),
      utf8.encode(pyJsonDumps(result, indent: 1, ensureAscii: false)),
    );
  } on Object {
    // Not kept: the answer is still shown.
  }
  return result;
}
