import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// An agent's plan limits asked of its own program where no Omarchy
/// collector is (an adapter's `[plan_limits]`, adapter_data.LIMIT_RPCS):
/// the record Omarchy's collector would write (limits with label, percent
/// and resetsAt; tierLabel), or null when it could not be asked. No prompt
/// is sent to a model and Maprisma reads no credential: the agent's program
/// answers for its own sign-in. Each answer within [answer], the whole
/// exchange within [total]; the program is killed afterwards. [program] is
/// the agent's installed program (AgentCatalog.realProgram, never a
/// launcher that installs or updates it); without one nothing is asked,
/// never the first `argv.first` on PATH.
Future<Map<String, dynamic>?> askPlanLimits(
  String rpc,
  List<String> argv,
  Map<String, String> env, {
  required String? program,
  Duration answer = const Duration(seconds: 8),
  Duration total = const Duration(seconds: 20),
  DateTime Function() now = DateTime.now,
}) async {
  if (rpc != 'codex-app-server' ||
      argv.isEmpty ||
      program == null ||
      p.basename(program) != argv.first) {
    return null;
  }
  final binary = program;
  final Process process;
  try {
    process = await Process.start(
      'setsid',
      [binary, ...argv.skip(1)],
      environment: env,
      includeParentEnvironment: false,
      workingDirectory: env['HOME'],
    );
  } on ProcessException {
    return null;
  }
  final rpcs = _JsonLines(process);
  final deadline = Timer(total, rpcs.stop);
  try {
    return await _codexAppServer(rpcs, answer, now);
  } on Object {
    return null;
  } finally {
    deadline.cancel();
    rpcs.stop();
    process.kill(ProcessSignal.sigterm);
    Process.runSync('kill', ['-KILL', '--', '-${process.pid}']);
    await process.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}

/// omarchy-agent-usage-codex's fetch_codex_rpc: initialize, initialized,
/// account/rateLimits/read (account/read only when the limits name no plan).
Future<Map<String, dynamic>?> _codexAppServer(
  _JsonLines rpcs,
  Duration answer,
  DateTime Function() now,
) async {
  await rpcs.request(1, 'initialize', {
    'clientInfo': {'name': 'maprisma', 'version': '1'},
  }, answer);
  rpcs.send({'method': 'initialized', 'params': {}});
  final reply = await rpcs.request(2, 'account/rateLimits/read', {}, answer);
  final at = now().toUtc();
  final record = <String, dynamic>{
    'schemaVersion': 1,
    'updatedAt': at.toIso8601String(),
    'limitsStale': false,
    'limitsFetchedAt': at.millisecondsSinceEpoch,
    'limits': <Map<String, dynamic>>[],
    'tierLabel': '',
    'usageStatusText': '',
  };
  final error = reply['error'];
  if (error is Map) {
    // A home nobody is signed in to answers with an error, not limits.
    if (!'${error['message'] ?? ''}'.toLowerCase().contains('auth')) {
      return null;
    }
    return record..['usageStatusText'] = 'Waiting for auth';
  }
  final result = reply['result'] is Map ? reply['result'] as Map : const {};
  final limits = result['rateLimits'] is Map
      ? result['rateLimits'] as Map
      : const {};
  var plan = limits['planType'] is String ? limits['planType'] as String : '';
  if (plan.isEmpty) {
    try {
      final account = await rpcs.request(
        3,
        'account/read',
        {},
        const Duration(seconds: 2),
      );
      final found = account['result'] is Map
          ? (account['result'] as Map)['account']
          : null;
      if (found is Map) {
        plan = '${found['planType'] ?? found['type'] ?? ''}';
      }
    } on Object {
      // The limits stay; only the plan's name is not known.
    }
  }
  record['tierLabel'] = plan;
  record['ready'] = true;
  for (final window in [limits['primary'], limits['secondary']]) {
    final entry = _window(window);
    if (entry != null) (record['limits'] as List).add(entry);
  }
  final spend = _spend(limits['individualLimit']);
  if (spend != null) (record['limits'] as List).add(spend);
  return record;
}

double _number(dynamic v) =>
    v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

String _reset(dynamic v) {
  final seconds = _number(v);
  return seconds > 0
      ? DateTime.fromMillisecondsSinceEpoch(
          (seconds * 1000).round(),
          isUtc: true,
        ).toIso8601String()
      : '';
}

/// limit_window: a rate window's share used and when it resets.
Map<String, dynamic>? _window(dynamic window) {
  if (window is! Map || window['usedPercent'] is! num) return null;
  final mins = _number(window['windowDurationMins']).toInt();
  return {
    'label': mins == 10080
        ? 'Weekly (7-day)'
        : mins > 0 && mins % 60 == 0
        ? '${mins ~/ 60}h window'
        : mins > 0
        ? '${mins}m window'
        : 'Limit',
    'percent': (window['usedPercent'] as num) / 100,
    'resetsAt': _reset(window['resetsAt']),
  };
}

/// spend_limit: a spend cap's share used.
Map<String, dynamic>? _spend(dynamic snapshot) {
  if (snapshot is! Map) return null;
  final cap = _number(snapshot['limit']);
  final double used;
  if (cap > 0 && snapshot['used'] != null) {
    used = _number(snapshot['used']) / cap;
  } else if (snapshot['remainingPercent'] is num) {
    used = 1 - (snapshot['remainingPercent'] as num) / 100;
  } else {
    return null;
  }
  return {
    'label': 'Spend limit',
    'percent': used.clamp(0.0, 1.0),
    'resetsAt': _reset(snapshot['resetsAt']),
  };
}

/// One JSON object per line both ways; at most a mebibyte is read.
final class _JsonLines {
  _JsonLines(this.process) {
    _out = process.stdout.listen(
      (chunk) {
        _read += chunk.length;
        if (_read > 1024 * 1024) return stop();
        _buffer.addAll(chunk);
        var end = _buffer.indexOf(10);
        while (end >= 0) {
          final line = _buffer.sublist(0, end);
          _buffer.removeRange(0, end + 1);
          try {
            final message = jsonDecode(utf8.decode(line, allowMalformed: true));
            if (message is Map && message['id'] is int) {
              _waiting.remove(message['id'])?.complete(message);
            }
          } on FormatException {
            // a notification or log line: not an answer
          }
          end = _buffer.indexOf(10);
        }
      },
      onDone: stop,
      cancelOnError: true,
    );
    unawaited(process.stderr.drain<void>().catchError((_) {}));
    unawaited(process.stdin.done.catchError((_) {})); // gone: no answer
  }
  final Process process;
  late final StreamSubscription<List<int>> _out;
  final _buffer = <int>[];
  final _waiting = <int, Completer<Map>>{};
  var _read = 0, _stopped = false;

  void send(Map message) {
    if (_stopped) throw StateError('stopped');
    process.stdin.add(utf8.encode('${jsonEncode(message)}\n'));
  }

  Future<Map> request(int id, String method, Map params, Duration answer) {
    final waiting = _waiting[id] = Completer<Map>();
    send({'id': id, 'method': method, 'params': params});
    return waiting.future.timeout(answer);
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    unawaited(_out.cancel());
    for (final waiting in _waiting.values) {
      if (!waiting.isCompleted) waiting.completeError(StateError('stopped'));
    }
    _waiting.clear();
    unawaited(process.stdin.close().catchError((_) {}));
  }
}
