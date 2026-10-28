import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'adapter_assets.g.dart';
import 'model_hub.dart';
import 'provider_scans.dart';
import 'scan_files.dart';

/// llm_engine.MODEL_KEY (Python's \w is Unicode).
final modelKey = RegExp(
  r'^[A-Za-z0-9][\p{L}\p{N}_.:/@+-]{0,199}$',
  unicode: true,
);

/// loopback.loopback_listeners: owners of the sockets listening on a
/// loopback-reachable address on this TCP port (/proc/net/tcp and tcp6).
List<int> loopbackListeners(int port, {String proc = '/proc/net'}) {
  final owners = <int>[];
  for (final name in ['tcp', 'tcp6']) {
    final String text;
    try {
      text = File('$proc/$name').readAsStringSync();
    } on FileSystemException {
      continue;
    }
    for (final line in const LineSplitter().convert(text).skip(1)) {
      final f = line.trim().split(RegExp(r'\s+'));
      if (f.length < 8 || f[3] != '0A') continue;
      final at = f[1].indexOf(':');
      if (at < 0 || int.tryParse(f[1].substring(at + 1), radix: 16) != port) {
        continue;
      }
      final address = f[1].substring(0, at);
      final reachable = name == 'tcp'
          ? address == '00000000' || address.endsWith('7F')
          : address == '0' * 32 ||
                address == '${'0' * 24}01000000' ||
                address.startsWith('${'0' * 16}FFFF0000') &&
                    address.endsWith('7F');
      if (reachable) owners.add(int.parse(f[7]));
    }
  }
  return owners;
}

bool ownPort(int port, int uid, {String proc = '/proc/net'}) {
  final owners = loopbackListeners(port, proc: proc);
  return owners.isNotEmpty && owners.every((o) => o == uid);
}

int portOf(RuntimeRecord rt) {
  final at = rt.address.lastIndexOf(':');
  return int.tryParse(at < 0 ? '' : rt.address.substring(at + 1)) ?? 0;
}

/// gpu_usage.http_json: a JSON reply from our own server on 127.0.0.1, or null.
Future<dynamic> httpJson(
  int port,
  String path,
  int uid, {
  String method = 'GET',
  Map? body,
  Duration timeout = const Duration(milliseconds: 1500),
}) async {
  if (port == 0 || !ownPort(port, uid)) return null;
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client
        .openUrl(method, Uri.parse('http://127.0.0.1:$port$path'))
        .timeout(timeout);
    if (body != null) {
      // One body with its length, as http.client sends it (no chunked encoding).
      final data = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      request.contentLength = data.length;
      request.add(data);
    }
    final response = await request.close().timeout(timeout);
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > 1024 * 1024) return null;
    }
    if (response.statusCode >= 400) return null;
    return bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// llm_engine._run: no shell, bounded output, 30 s.
Future<(bool, String)> runCommand(List<String> argv) async {
  try {
    final process = await Process.start(argv.first, argv.skip(1).toList());
    unawaited(process.stdin.close());
    final out = <int>[];
    final done = Future.wait([
      process.stdout.forEach(
        (c) => out.length < 64 * 1024 ? out.addAll(c) : null,
      ),
      process.stderr.forEach(
        (c) => out.length < 64 * 1024 ? out.addAll(c) : null,
      ),
    ]);
    final code = await process.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    await done.timeout(const Duration(seconds: 1), onTimeout: () => []);
    final lines = utf8.decode(out, allowMalformed: true).trim().split('\n');
    final last = lines.isEmpty ? '' : lines.last;
    return (code == 0, last.length > 300 ? last.substring(0, 300) : last);
  } on ProcessException {
    return (false, 'not found');
  }
}

/// flutter_providers.validate and execute for the runtime and model actions.
final class ProviderOps {
  ProviderOps(this.files, this.providers);
  final ScanFiles files;
  final ProviderScans providers;
  static const shapes = {
    'runtime.start': {'key'},
    'runtime.stop': {'key'},
    'model.load': {'key', 'model'},
    'model.unload': {'key', 'model'},
    'model.import': {'key', 'path'},
    'models.search': {'query'},
    'models.files': {'repo'},
    'models.download': {'key', 'repo', 'file', 'size'},
    'models.pull': {'key', 'name'},
  };

  /// flutter_providers.validate.
  static void validate(String operation, Map params) {
    final shape = shapes[operation];
    if (shape == null) {
      throw const FormatException('Unknown provider operation');
    }
    if (params.length != shape.length ||
        !params.keys.every(shape.contains) ||
        params.entries.any(
          (e) =>
              e.key != 'size' && (e.value is! String || e.value.length > 4096),
        )) {
      throw const FormatException('Invalid provider operation');
    }
    if (operation == 'models.download' &&
        (params['size'] is! int || (params['size'] as int) < 0)) {
      throw const FormatException('Invalid model size');
    }
    if (params.containsKey('repo') &&
        !ModelHub.repoRe.hasMatch(params['repo'] as String)) {
      throw const FormatException('Invalid model repository');
    }
    if (params.containsKey('model') &&
        !modelKey.hasMatch(params['model'] as String)) {
      throw const FormatException('Invalid model name');
    }
    if (operation == 'models.search') {
      final length = (params['query'] as String).trim().length;
      if (length < 1 || length > 120) {
        throw const FormatException('Invalid search');
      }
    }
    if (operation == 'models.pull' &&
        !ModelHub.ollamaNameRe.hasMatch(params['name'] as String)) {
      throw const FormatException('Invalid pull name');
    }
    if (operation == 'models.download') {
      final file = params['file'] as String;
      if (!ModelHub.fileRe.hasMatch(file) ||
          file.startsWith('/') ||
          file.split('/').any((part) => part == '.' || part == '..')) {
        throw const FormatException('Invalid model filename');
      }
    }
  }

  Map get _engines => providerFacts['engines'] as Map;
  int get uid => files.posix.uid;

  String? lmsBinary() {
    for (final folder in (files.identity.environment['PATH'] ?? '').split(
      ':',
    )) {
      if (folder.isNotEmpty && FileSystemEntity.isFileSync('$folder/lms')) {
        return '$folder/lms';
      }
    }
    final own = files.expand('~/.lmstudio/bin/lms');
    return FileSystemEntity.isFileSync(own) ? own : null;
  }

  bool canControl(RuntimeRecord rt) =>
      (_engines[rt.key] as Map?)?['lms_control'] == true
      ? rt.installed && (rt.service.isNotEmpty || lmsBinary() != null)
      : rt.installed && rt.service.isNotEmpty;

  Future<(bool, String)> _systemctl(String verb, RuntimeRecord rt) =>
      runCommand(['systemctl', '--user', verb, '${rt.service}.service']);

  Future<(bool, String)> _lmsRun(List<String> args) async {
    final binary = lmsBinary();
    return binary == null
        ? (false, 'lms not found')
        : runCommand([binary, ...args]);
  }

  Future<(bool, String)> start(RuntimeRecord rt) async {
    if (rt.key == 'lmstudio' && rt.service.isEmpty) {
      return _lmsRun(['server', 'start']);
    }
    return rt.service.isNotEmpty
        ? _systemctl('start', rt)
        : (false, 'no way to start it');
  }

  Future<(bool, String)> stop(RuntimeRecord rt) async {
    if (rt.key == 'lmstudio' && rt.service.isEmpty) {
      return _lmsRun(['server', 'stop']);
    }
    return rt.service.isNotEmpty
        ? _systemctl('stop', rt)
        : (false, 'no way to stop it');
  }

  bool _router(String key) => key == 'llamacpp' || key == 'jan';

  Future<(bool, String)> _engineLoad(RuntimeRecord rt, String model) async {
    final port = portOf(rt);
    if (_router(rt.key)) {
      final reply = await httpJson(
        port,
        '/models/load',
        uid,
        method: 'POST',
        body: {'model': model},
        timeout: const Duration(seconds: 300),
      );
      return reply != null ? (true, '') : (false, 'it did not load the model');
    }
    if (rt.key == 'ollama') {
      final reply = await httpJson(
        port,
        '/api/generate',
        uid,
        method: 'POST',
        body: {'model': model, 'keep_alive': '30m'},
        timeout: const Duration(seconds: 300),
      );
      return reply != null ? (true, '') : (false, 'it did not load the model');
    }
    if (rt.key == 'lmstudio') return _lmsRun(['load', '--', model]);
    return (false, 'it cannot be asked to load a model');
  }

  Future<(bool, String)> unloadModel(RuntimeRecord rt, String model) async {
    if (!modelKey.hasMatch(model)) return (false, 'not a model name');
    final port = portOf(rt);
    if (_router(rt.key)) {
      final reply = await httpJson(
        port,
        '/models/unload',
        uid,
        method: 'POST',
        body: {'model': model},
        timeout: const Duration(seconds: 30),
      );
      return reply != null
          ? (true, '')
          : (false, 'it did not unload the model');
    }
    if (rt.key == 'ollama') {
      final reply = await httpJson(
        port,
        '/api/generate',
        uid,
        method: 'POST',
        body: {'model': model, 'keep_alive': 0},
        timeout: const Duration(seconds: 30),
      );
      return reply != null
          ? (true, '')
          : (false, 'it did not unload the model');
    }
    if (rt.key == 'lmstudio') return _lmsRun(['unload', '--', model]);
    // Engines that cannot unload one model stop the server (unload_all).
    return canControl(rt) ? stop(rt) : (false, 'no way to stop it');
  }

  /// runtime_ctl.load: the local LLM started first when nothing listens yet.
  Future<(bool, String)> load(RuntimeRecord rt, String model) async {
    if (!modelKey.hasMatch(model)) return (false, 'not a model name');
    if ((_engines[rt.key] as Map?)?['can_load'] != true) {
      return (false, 'it cannot be asked to load a model');
    }
    final port = portOf(rt);
    if (port == 0) return (false, 'no address');
    if (loopbackListeners(port).isEmpty) {
      final (ok, why) = await start(rt);
      if (!ok) return (false, why);
      final until = DateTime.now().add(const Duration(seconds: 30));
      while (loopbackListeners(port).isEmpty) {
        if (DateTime.now().isAfter(until)) return (false, 'it did not start');
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    return _engineLoad(rt, model);
  }

  RuntimeRecord runtime(String key) {
    final found = providers.scan().where((r) => r.key == key).toList();
    if (found.isEmpty) throw const FormatException('Unknown local provider');
    return found.first;
  }

  Future<Map<String, dynamic>> execute(
    String operation,
    Map params, {
    ModelHub? hub,
  }) async {
    validate(operation, params);
    hub ??= ModelHub();
    if (operation == 'models.search') {
      return {
        'repos': await hub.search(
          (params['query'] as String).trim(),
          limit: 25,
        ),
      };
    }
    if (operation == 'models.files') {
      final repo = params['repo'] as String;
      return {
        'repo': repo,
        'files': (await hub.files(repo)).take(100).toList(),
      };
    }
    final rt = runtime(params['key'] as String);
    if (!rt.installed) throw const FormatException('Provider is not installed');
    if (operation.startsWith('runtime.')) {
      if (!canControl(rt)) {
        throw const FormatException('Provider cannot be controlled');
      }
      final (ok, _) = operation == 'runtime.start'
          ? await start(rt)
          : await stop(rt);
      if (!ok) throw StateError('Provider operation failed');
    } else {
      final model = params['model'] as String;
      if (!rt.models.contains(model) ||
          (_engines[rt.key] as Map?)?['can_load'] != true) {
        throw const FormatException('Model unavailable');
      }
      final (ok, _) = operation == 'model.load'
          ? await load(rt, model)
          : await unloadModel(rt, model);
      if (!ok) throw StateError('Model operation failed');
    }
    return {'ok': true};
  }
}
