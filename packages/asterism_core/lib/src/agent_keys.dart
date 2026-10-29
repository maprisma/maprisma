import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'adapters.dart';
import 'agent_details.dart' show keyStepOf;
import 'agent_start.dart' show isAgentSessionVar;
import 'posix_ffi.dart';

/// An API key put where the agent itself reads it (signin.save_key): handed
/// to the agent's own command on stdin (it stores it itself), or written into
/// the .env file the agent reads (owner-only, atomic, a link at the path
/// replaced, never followed). The key never goes into an argv, a log, a
/// backup, a preview or the app's settings; nothing keeps it afterwards.

final _keyRe = RegExp(r'^[A-Za-z0-9._~+/=:-]{8,512}$');
final _varRe = RegExp(r'^[A-Z][A-Z0-9_]{1,63}$');
const _maxEnvFile = 64 * 1024, _maxOutput = 4096;

bool validKey(String key) => _keyRe.hasMatch(key);

/// agents.key_preview / agents.key_apply: what happens to the key, shown
/// before it is typed; the key itself goes to the worker on stdin only.
final class AgentKeys {
  AgentKeys(this.newToken);
  final String Function() newToken;
  final _previews = <String, (DateTime, String, String)>{};

  /// What the preview shows: the variable, where it goes, where to get one.
  static Map<String, dynamic>? describe(Adapter adapter) {
    final step = keyStepOf(adapter);
    if (step == null) return null;
    return {
      'variable': step.variable,
      'url': step.url.startsWith('https://') ? step.url : '',
      'stores': step.stdin.isNotEmpty ? 'itself' : 'file',
      'command': step.stdin.join(' '),
      'file': step.envFile,
    };
  }

  Map<String, dynamic> preview(
    Map<String, dynamic> params,
    Adapter? adapter,
    bool installed,
    String name,
  ) {
    if (params.length != 1 || params['command'] is! String) {
      throw const FormatException('Invalid API-key request');
    }
    final described = adapter == null ? null : describe(adapter);
    if (!installed || described == null) {
      throw const FormatException('This agent takes no API key here');
    }
    final now = DateTime.now();
    _previews.removeWhere((_, v) => now.difference(v.$1).inSeconds >= 600);
    while (_previews.length >= 8) {
      _previews.remove(_previews.keys.first);
    }
    final token = newToken();
    _previews[token] = (
      now,
      params['command'] as String,
      jsonEncode(described),
    );
    return {'preview': token, 'name': name, ...described};
  }

  /// The checked request for the worker: the reviewed agent and the key.
  List<int> apply(
    Map<String, dynamic> params,
    Adapter? Function(String) adapterOf,
  ) {
    if (params.length != 2 ||
        params['preview'] is! String ||
        params['key'] is! String) {
      throw const FormatException('Invalid API-key request');
    }
    final kept = _previews[params['preview']];
    if (kept == null || DateTime.now().difference(kept.$1).inSeconds >= 600) {
      throw const FormatException('Unknown or expired API-key preview');
    }
    final key = (params['key'] as String).trim();
    if (!validKey(key)) throw const FormatException('Not an API key');
    final adapter = adapterOf(kept.$2);
    if (adapter == null || jsonEncode(describe(adapter)) != kept.$3) {
      throw const FormatException('The agent changed; preview again');
    }
    _previews.remove(params['preview']);
    return utf8.encode(jsonEncode({'command': kept.$2, 'key': key}));
  }
}

/// signin.write_env: VAR=value set in a .env file, other lines kept.
void writeEnv(String path, String variable, String value, Posix posix) {
  if (!_varRe.hasMatch(variable) || !validKey(value)) {
    throw const FormatException('bad variable or value');
  }
  final dir = p.dirname(path);
  if (!Directory(dir).existsSync()) {
    // mkdir(mode=0o700, parents=True): the folders made here are private.
    var probe = dir;
    final made = <String>[];
    while (!Directory(probe).existsSync()) {
      made.insert(0, probe);
      probe = p.dirname(probe);
    }
    for (final folder in made) {
      Directory(folder).createSync();
      posix.chmodPath(folder, 0x1c0);
    }
  }
  var old = '';
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type != FileSystemEntityType.notFound &&
      type != FileSystemEntityType.link) {
    final fd = posix.openAt(-100, path, Posix.noFollow);
    try {
      final st = posix.statFull(fd);
      if (st.mode & 0xf000 != 0x8000 || st.uid != posix.uid) {
        throw FileSystemException('not a file of yours', path);
      }
      final data = posix.readAt(fd, 0, _maxEnvFile + 1);
      if (data.length > _maxEnvFile) throw FileSystemException('too big', path);
      old = utf8.decode(data, allowMalformed: true);
    } finally {
      posix.close(fd);
    }
  }
  final pattern = RegExp('^\\s*(export\\s+)?${RegExp.escape(variable)}\\s*=');
  final lines = [
    for (final line in const LineSplitter().convert(old))
      if (!pattern.hasMatch(line)) line,
    '$variable=$value',
  ];
  // A new owner-only file beside it, renamed over: a link at the path is
  // replaced, its target left alone.
  posix.replaceFile(path, utf8.encode('${lines.join('\n')}\n'), 0x180);
}

/// The worker's part: the agent's own command with the key on stdin, or its
/// .env file. The answer never contains the key.
Future<Map<String, dynamic>> storeKey(
  Map request,
  Adapter? adapter,
  String home,
  Map<String, String> environment,
) async {
  final key = '${request['key'] ?? ''}'.trim();
  if (!validKey(key)) throw const FormatException('Not an API key');
  final step = adapter == null ? null : keyStepOf(adapter);
  if (step == null) {
    throw const FormatException('This agent takes no API key here');
  }
  if (step.stdin.isNotEmpty) {
    final env = {
      for (final e in environment.entries)
        if (!isAgentSessionVar(e.key)) e.key: e.value,
    };
    final Process process;
    try {
      process = await Process.start(
        step.stdin.first,
        step.stdin.skip(1).toList(),
        environment: env,
        includeParentEnvironment: false,
      );
    } on ProcessException {
      return {'ok': false, 'message': '${step.stdin.first} was not found'};
    }
    process.stdin.add(utf8.encode('$key\n'));
    unawaited(process.stdin.close().catchError((_) {}));
    final out = <int>[];
    void keep(List<int> chunk) {
      final room = _maxOutput - out.length;
      if (room > 0) {
        out.addAll(chunk.length > room ? chunk.sublist(0, room) : chunk);
      }
    }

    final reading = [
      process.stdout.listen(keep).asFuture<void>(),
      process.stderr.listen(keep).asFuture<void>(),
    ];
    final code = await process.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    await Future.wait(
      reading,
    ).timeout(const Duration(seconds: 2), onTimeout: () => []);
    final text = utf8.decode(out, allowMalformed: true).replaceAll(key, '…');
    final lines = [
      for (final l in const LineSplitter().convert(text))
        if (l.trim().isNotEmpty) l,
    ];
    final last = lines.isEmpty ? '' : lines.last;
    return {
      'ok': code == 0,
      'message': last.length > 200 ? last.substring(0, 200) : last,
    };
  }
  if (!_varRe.hasMatch(step.variable) || !step.envFile.startsWith('~/')) {
    throw const FormatException('no way to store the key');
  }
  writeEnv(
    p.join(home, step.envFile.substring(2)),
    step.variable,
    key,
    Posix(),
  );
  return {'ok': true, 'message': ''};
}
