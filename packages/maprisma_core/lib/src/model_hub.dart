import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'py_time.dart';

/// ai_core.read_bounded_output: argv (no shell), stdout with a byte cap and
/// one deadline; ok only for exit 0 within both.
Future<(List<int>, bool)> boundedOutput(
  List<String> argv, {
  int maxBytes = 64 * 1024,
  Duration timeout = const Duration(seconds: 5),
  List<int>? stdin,
  bool mergeStderr = false,
  Map<String, String>? environment,
  bool inheritEnvironment = true,
}) async {
  final Process process;
  try {
    process = await Process.start(
      argv.first,
      argv.skip(1).toList(),
      environment: environment,
      includeParentEnvironment: inheritEnvironment,
    );
  } on ProcessException {
    return (<int>[], false);
  }
  if (stdin != null) {
    process.stdin.add(stdin);
  }
  unawaited(process.stdin.close().catchError((_) {}));
  final out = <int>[];
  var over = false;
  final reading = Completer<void>();
  final source = mergeStderr
      ? _merged([process.stdout, process.stderr])
      : process.stdout;
  if (!mergeStderr) {
    unawaited(process.stderr.drain<void>().catchError((_) {}));
  }
  late final StreamSubscription<List<int>> subscription;
  subscription = source.listen(
    (chunk) {
      if (out.length + chunk.length > maxBytes) {
        over = true;
        subscription.cancel();
        if (!reading.isCompleted) reading.complete();
        return;
      }
      out.addAll(chunk);
    },
    onDone: () {
      if (!reading.isCompleted) reading.complete();
    },
    onError: (_) {
      over = true;
      if (!reading.isCompleted) reading.complete();
    },
  );
  try {
    await reading.future.timeout(timeout);
  } on TimeoutException {
    over = true;
  }
  if (over) process.kill(ProcessSignal.sigkill);
  final code = await process.exitCode.timeout(
    const Duration(seconds: 2),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
  return (
    out.length > maxBytes ? out.sublist(0, maxBytes) : out,
    code == 0 && !over,
  );
}

/// Both output streams into one (merge_stderr), done when both are.
Stream<List<int>> _merged(List<Stream<List<int>>> streams) {
  final controller = StreamController<List<int>>();
  var open = streams.length;
  for (final stream in streams) {
    stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: () {
        if (--open == 0) controller.close();
      },
    );
  }
  return controller.stream;
}

final class FetchError implements Exception {
  FetchError(this.message);
  final String message;
  @override
  String toString() => message;
}

final _bad = RegExp(r'[\x00-\x20\x7f"\\]');

/// netfetch._quote: a value for curl's config file, one quoted line.
String _quote(String value) {
  if (value.codeUnits.any((c) => c < 32 || c == 0x7f)) {
    throw FetchError('control characters in a request header');
  }
  return '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}

/// netfetch.fetch for the public web: curl, https only, at most `redirects`
/// redirects (https too), headers on stdin (never in argv), the answer capped
/// in size and time.
Future<List<int>> netFetch(
  String url, {
  int maxBytes = 2 * 1024 * 1024,
  int timeout = 20,
  int redirects = 3,
  Map<String, String> headers = const {},
}) async {
  final parts = Uri.tryParse(url);
  if (_bad.hasMatch(url) ||
      parts == null ||
      parts.userInfo.isNotEmpty ||
      parts.host.isEmpty) {
    throw FetchError('not a usable address');
  }
  if (parts.scheme != 'https') throw FetchError('only https addresses');
  final config = ['url = ${_quote(url)}'];
  for (final e in headers.entries) {
    if (!RegExp(r'^[A-Za-z0-9-]{1,100}$').hasMatch(e.key)) {
      throw FetchError('not a header name');
    }
    config.add('header = ${_quote('${e.key}: ${e.value}')}');
  }
  final argv = [
    'curl',
    '--config',
    '-',
    '--silent',
    '--show-error',
    '--fail',
    '--proto',
    '=https',
    '--max-time',
    '$timeout',
    '--max-filesize',
    '$maxBytes',
    '--user-agent',
    'maprisma',
    if (redirects > 0) ...[
      '--location',
      '--max-redirs',
      '$redirects',
      '--proto-redir',
      '=https',
    ],
  ];
  final (out, ok) = await boundedOutput(
    argv,
    maxBytes: maxBytes,
    timeout: Duration(seconds: timeout + 5),
    stdin: utf8.encode('${config.join('\n')}\n'),
  );
  if (!ok) {
    throw FetchError(
      '${parts.host} did not answer (or the answer was too large)',
    );
  }
  return out;
}

/// urllib.parse.quote with safe="/".
String pyQuote(String text) {
  final out = StringBuffer();
  for (final byte in utf8.encode(text)) {
    final c = String.fromCharCode(byte);
    if (RegExp(r'[A-Za-z0-9_.\-~/]').hasMatch(c)) {
      out.write(c);
    } else {
      out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

/// models_ctl: Hugging Face search and a repository's GGUF files.
final class ModelHub {
  ModelHub({this.base = hf, Future<List> Function(String url)? jsonList})
    : _jsonList = jsonList;
  static const hf = 'https://huggingface.co';
  final String base;
  final Future<List> Function(String url)? _jsonList;

  static final repoRe = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}$',
  );
  static final ollamaNameRe = RegExp(
    r'^(?:hf\.co/[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}'
    r'|(?!hf\.co/)[a-z0-9][a-z0-9._/-]{0,127})(?::[A-Za-z0-9._-]{1,64})?$',
  );
  static final fileRe = RegExp(r'^[A-Za-z0-9._/-]{1,255}\.gguf$');
  static final splitRe = RegExp(r'^(.*)-(\d{5})-of-(\d{5})\.gguf$');
  static final quantRe = RegExp(
    r'(IQ\d_[A-Z0-9_]+|Q\d_[A-Z0-9_]+|Q\d_\d|BF16|F16|F32|MXFP4|NVFP4)',
    caseSensitive: false,
  );
  static final mtpRe = RegExp(r'(^|[-_.])MTP([-_.]|$)', caseSensitive: false);
  static const chatTasks = {'text-generation', 'image-text-to-text', ''};
  static final expand = [
    'downloads',
    'likes',
    'lastModified',
    'pipeline_tag',
    'tags',
    'gguf',
  ].map((k) => '&expand[]=$k').join();

  static int count(dynamic value) =>
      value is int && value >= 0 && value < 1000000000000000 ? value : 0;

  static double epoch(dynamic value) {
    if (value is! String || value.length > 40) return 0.0;
    final time = pyFromIsoformat(value.replaceAll('Z', '+00:00'));
    return time == null ? 0.0 : time.microsecondsSinceEpoch / 1e6;
  }

  /// (vision, tools, reasoning, mtp) from the task, tags and chat template.
  static (bool, bool, bool, bool) capabilities(
    String repo,
    dynamic tags,
    String pipeline,
    dynamic template,
  ) {
    final words = tags is List ? tags.whereType<String>().toList() : <String>[];
    final text = template is String ? template : '';
    final vision = pipeline == 'image-text-to-text' || words.contains('vision');
    final tools = text.contains('tools') || text.contains('tool_call');
    final reasoning = const [
      '<think>',
      'enable_thinking',
      'reasoning_content',
      '<|channel|>',
    ].any(text.contains);
    final name = repo.contains('/')
        ? repo.substring(repo.indexOf('/') + 1)
        : repo;
    final mtp = mtpRe.hasMatch(name) || words.contains('mtp');
    return (vision, tools, reasoning, mtp);
  }

  /// _repo_from + asdict(Repo).
  static Map<String, dynamic>? repoFrom(dynamic item) {
    final repo = item is Map ? item['id'] : null;
    if (repo is! String || !repoRe.hasMatch(repo)) return null;
    final gguf = item['gguf'] is Map ? item['gguf'] as Map : const {};
    final pipeline = item['pipeline_tag'] is String
        ? item['pipeline_tag'] as String
        : '';
    final (vision, tools, reasoning, mtp) = capabilities(
      repo,
      item['tags'],
      pipeline,
      gguf['chat_template'],
    );
    return {
      'id': repo,
      'downloads': count(item['downloads']),
      'likes': count(item['likes']),
      'updated': epoch(item['lastModified']),
      'pipeline': pipeline.length > 40 ? pipeline.substring(0, 40) : pipeline,
      'params': count(gguf['total']),
      'vision': vision,
      'tools': tools,
      'reasoning': reasoning,
      'mtp': mtp,
    };
  }

  /// _json_list: a JSON list from the host (5 MB, 20 s), else an error.
  Future<List> jsonList(String url) async {
    if (_jsonList != null) return _jsonList(url);
    final host = Uri.parse(url).host;
    final dynamic data;
    try {
      data = jsonDecode(
        utf8.decode(
          await netFetch(url, maxBytes: 5000000, timeout: 20),
          allowMalformed: true,
        ),
      );
    } on FetchError {
      throw StateError('$host did not answer');
    } on FormatException {
      throw StateError('$host did not answer');
    }
    if (data is! List) throw StateError('unexpected answer from $host');
    return data;
  }

  /// search: GGUF models for the query, most downloaded first (trending
  /// without one), chat and vision models only.
  Future<List<Map<String, dynamic>>> search(
    String query, {
    int limit = 20,
  }) async {
    var text = query.trim();
    if (text.length > 100) text = text.substring(0, 100);
    final sort = text.isNotEmpty ? 'downloads' : 'trendingScore';
    final url =
        '$base/api/models?filter=gguf&sort=$sort&direction=-1&limit=${limit * 2}$expand'
        '${text.isNotEmpty ? '&search=${pyQuote(text)}' : ''}';
    final repos = <Map<String, dynamic>>[];
    for (final item in (await jsonList(url)).take(limit * 2)) {
      final repo = repoFrom(item);
      if (repo != null && chatTasks.contains(repo['pipeline'])) repos.add(repo);
    }
    return repos.take(limit).toList();
  }

  static int _pyInt(dynamic value) {
    if (value is bool) return value ? 1 : 0;
    if (value is int) return value;
    if (value is double) return value.truncate();
    if (value is String) return int.parse(value.trim());
    throw const FormatException('not a size');
  }

  static bool _truthy(dynamic v) =>
      v != null && v != false && v != 0 && v != '' && !(v is Map && v.isEmpty);

  /// files: the GGUF files of a repository (split files as one entry), the
  /// smallest first; with a card size, which fit and the recommended one.
  Future<List<Map<String, dynamic>>> files(String repo, {int vram = 0}) async {
    if (!repoRe.hasMatch(repo)) {
      throw const FormatException('not a Hugging Face model name');
    }
    final data = await jsonList('$base/api/models/$repo/tree/main?recursive=1');
    final groups = <String, Map<String, dynamic>>{};
    for (final item in data.take(2000)) {
      if (item is! Map || item['type'] != 'file') continue;
      final path = item['path'] ?? '';
      if (path is! String || !fileRe.hasMatch(path) || path.contains('..')) {
        continue;
      }
      if (p.basename(path).toLowerCase().contains('mmproj')) continue;
      final lfs = _truthy(item['lfs']) ? item['lfs'] : const {};
      final size = _pyInt(
        _truthy(lfs is Map ? lfs['size'] : null)
            ? (lfs as Map)['size']
            : _truthy(item['size'])
            ? item['size']
            : 0,
      );
      final split = splitRe.firstMatch(path);
      final key = split != null
          ? split[1]!
          : path.substring(0, path.length - 5);
      final entry = groups.putIfAbsent(
        key,
        () => {
          'name': p.basename(key),
          'paths': <String>[],
          'size': 0,
          'quant': '',
          'fits': false,
          'recommended': false,
        },
      );
      (entry['paths'] as List<String>).add(path);
      entry['size'] = (entry['size'] as int) + size;
    }
    // sorted(): stable, by size.
    final indexed = groups.values.toList().asMap().entries.toList()
      ..sort((a, b) {
        final bySize = (a.value['size'] as int).compareTo(
          b.value['size'] as int,
        );
        return bySize != 0 ? bySize : a.key.compareTo(b.key);
      });
    final found = [for (final e in indexed) e.value];
    for (final entry in found) {
      (entry['paths'] as List<String>).sort();
      final quant = quantRe.firstMatch(entry['name'] as String);
      entry['quant'] = quant != null ? quant[1]!.toUpperCase() : '';
      entry['fits'] = vram != 0 && (entry['size'] as int) < vram * 0.8;
    }
    recommend(found);
    return found;
  }

  /// recommend: Q4_K_M if it fits, else the largest that fits.
  static void recommend(
    List<Map<String, dynamic>> entries, [
    bool Function(Map<String, dynamic>)? usable,
  ]) {
    for (final e in entries) {
      e['recommended'] = false;
    }
    final fitting = [
      for (final e in entries)
        if (e['fits'] == true && (usable?.call(e) ?? true)) e,
    ];
    final best =
        fitting.where((e) => e['quant'] == 'Q4_K_M').firstOrNull ??
        fitting.lastOrNull;
    if (best != null) best['recommended'] = true;
  }
}
