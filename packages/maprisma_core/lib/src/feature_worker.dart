import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'core.dart';
import 'core_tasks.dart';
import 'action_rules.dart';
import 'feature_plugins.dart';
import 'protocol.dart';
import 'pty_sessions.dart' show processIdentity;

/// A plugin executable owns feature state and can be replaced independently
/// within API v1. Stdio is private to the parent; it exposes no listening socket.
Future<void> serveFeaturePlugin(String id) async {
  if (!featureIds.contains(id)) throw ArgumentError.value(id);
  // A controller that vanished (EPIPE on an answer) must not end this
  // process before its bounded cleanup and handoff below.
  unawaited(stdout.done.then<void>((_) {}, onError: (Object _) {}));
  final environment = Map<String, String>.from(Platform.environment)
    ..remove('MAPRISMA_CORE_WORKER');
  // Generation belongs to this version of the feature too, rather than to an
  // older worker bundled with the host. Dart source mode uses its own script.
  if (Platform.resolvedExecutable.split('/').last != 'dart') {
    environment['MAPRISMA_CORE_WORKER'] = Platform.resolvedExecutable;
  }
  recordReleasedHandles = true;
  final service = CoreService(
    environment: environment,
    migrate: false,
    featureWorker: true,
  );
  var stopping = false;
  // Provenance comes from this process's own issued-handle registry: a
  // follow-up is accepted only for a token this process actually issued.
  bool owns(Object? value) => issuedHandlesIn(value).isNotEmpty;

  Future<void>? cleanup;
  Future<void> clean() => cleanup ??= (() async {
    await service.shutdownFeatures();
    service.starter.sessions.close();
    final tasks = service.tasks.items.entries.toList();
    for (final entry in tasks) {
      if (entry.value.state == 'running' &&
          !CoreTasks.commits.contains(entry.value.operation)) {
        service.tasks.cancel(entry.key);
      }
    }
    // Committed changes finish. Cancellable workers also finish termination,
    // including a process that was still spawning when shutdown started.
    await Future.wait([
      for (final entry in tasks)
        if (entry.value.completion != null) entry.value.completion!,
    ]);
  })();
  // A signal or a lost parent ends this process after a bounded cleanup.
  // Unconfirmed agent trees are handed to their supervisors (dispose closes
  // their control pipes); each keeps its project's run lock until empty, so
  // no replacement controller can dispatch into that work meanwhile.
  var ending = false;
  // Requests waiting to be answered; teardown closes this queue so nothing
  // is dispatched while (or after) cleanup runs.
  final lines = StreamController<String>();
  final eof = Completer<void>();
  Future<void> end() async {
    if (ending) return;
    ending = true;
    stopping = true;
    if (!eof.isCompleted) eof.complete();
    unawaited(lines.close());
    // A real deadline, not only a retry count: a task that never finishes
    // must not keep this process (and the store lock) alive. Commit workers
    // are separate processes and finish on their own after this one exits.
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await clean().timeout(const Duration(seconds: 15));
        break;
      } on Object {
        cleanup = null;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    service.dispose();
    try {
      await stdout.flush().timeout(const Duration(seconds: 2));
    } on Object {
      // The controller is gone.
    }
    exit(0);
  }

  Future<void> stopForSignal() async {
    stopping = true;
    await end();
  }

  final term = ProcessSignal.sigterm.watch().listen(
    (_) => unawaited(stopForSignal()),
  );
  final interrupt = ProcessSignal.sigint.watch().listen(
    (_) => unawaited(stopForSignal()),
  );
  final parent = int.tryParse(
    Platform.environment['MAPRISMA_FEATURE_PARENT_PID'] ?? '',
  );
  final parentStart = Platform.environment['MAPRISMA_FEATURE_PARENT_START'];
  final watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
    if (parent != null &&
        parentStart != null &&
        parentStart.isNotEmpty &&
        processIdentity(parent)?.$3 != parentStart) {
      unawaited(stopForSignal());
    }
  });

  /// Every answer (also an error) carries what its stores let go since the
  /// last one, so the host stops routing it; as many as fit in the frame,
  /// the rest with the next answers.
  void answer(Map<String, dynamic> frame) {
    final base = utf8.encode(jsonEncode(frame)).length;
    // A bare token costs 35 bytes in the list ("…",).
    final room = (maxResponse - base - 64) ~/ 35;
    final released = takeReleasedHandles(room.clamp(0, 4096));
    stdout.writeln(
      jsonEncode({...frame, if (released.isNotEmpty) 'released': released}),
    );
  }

  Future<void> reply(String line) async {
    int? requestId;
    try {
      if (utf8.encode(line).length > maxRequest) {
        throw ServiceError('request_too_large');
      }
      final request = jsonDecode(line);
      if (request is! Map ||
          request['id'] is! int ||
          request['method'] is! String ||
          request['params'] is! Map<String, dynamic>) {
        throw ServiceError('invalid_request');
      }
      requestId = request['id'] as int;
      final method = request['method'] as String;
      final params = request['params'] as Map<String, dynamic>;
      // The host's discovery generation: the Project Center rebuilds its
      // display snapshot when it grew.
      final generation = request['context'] is Map
          ? (request['context'] as Map)['generation']
          : null;
      if (id == 'ai-project-center' && generation is int) {
        service.discoveryGeneration = generation;
      }
      if (id == 'ask-ai' && request['context'] is Map<String, dynamic>) {
        service.applyAskAiHostContext(
          request['context'] as Map<String, dynamic>,
        );
      }
      Map<String, dynamic> result;
      if (method == '@hello') {
        result = {
          'id': id,
          'api': featureApiOwn[id],
          'capabilities': featureCapabilitiesOwn[id],
        };
      } else if (method == '@shutdown') {
        stopping = true;
        try {
          await clean();
        } on Object {
          cleanup = null;
          // During teardown the worker stays closed for new requests.
          if (!ending) stopping = false;
          rethrow;
        }
        result = {'ok': true};
      } else if (stopping) {
        throw ServiceError('feature_closing');
      } else if (id == 'ai-project-center') {
        if (method == '@summary') {
          service.projectCenter.discoveryGeneration =
              service.discoveryGeneration;
          result = {...service.projectCenter.summary(), 'connected': true};
        } else {
          result = await service.projectCenterCall(method, params);
        }
      } else {
        final allowed = id == 'reports'
            ? method.startsWith('reports.')
            : method.startsWith('map.smart_');
        if (!allowed && !owns(params)) {
          throw ServiceError('feature_operation_unknown');
        }
        result = await service.dispatchAsync(method, params);
      }
      answer({
        'id': requestId,
        'result': result,
        'handles': issuedHandlesIn(result).toList(),
      });
    } on ServiceError catch (error) {
      answer({
        'id': requestId,
        'error': {
          'code': error.code,
          if (error.reason != null) 'message': error.reason,
        },
      });
    } on RuleRefused catch (error) {
      answer({
        'id': requestId,
        'error': {'code': 'action_refused', 'message': error.message},
      });
    } on Object {
      answer({
        'id': requestId,
        'error': {'code': 'invalid_request'},
      });
    }
  }

  try {
    // Requests are answered a turn at a time; long operations return
    // durable/task handles. EOF is watched independently, so a request that
    // never finishes cannot keep this process from its bounded teardown.
    final buffer = <int>[];
    final input = stdin.listen(
      (chunk) {
        for (final byte in chunk) {
          // After EOF, an oversized frame or teardown nothing more is read.
          if (eof.isCompleted) return;
          if (byte == 10) {
            lines.add(utf8.decode(buffer, allowMalformed: true));
            buffer.clear();
          } else {
            buffer.add(byte);
            if (buffer.length > maxRequest) {
              buffer.clear();
              eof.complete();
              return;
            }
          }
        }
      },
      onError: (Object _) {
        if (!eof.isCompleted) eof.complete();
      },
      onDone: () {
        if (!eof.isCompleted) eof.complete();
      },
    );
    Future<void> answer() async {
      await for (final line in lines.stream) {
        if (eof.isCompleted || ending) break;
        await reply(line);
        if (stopping) break;
      }
    }

    await Future.any([answer(), eof.future]);
    await input.cancel();
  } finally {
    // EOF (or an accepted @shutdown) means the controller is gone or done.
    // The watchdog and signal handlers end here too; one bounded cleanup.
    watchdog.cancel();
    await term.cancel();
    await interrupt.cancel();
    await end();
  }
}
