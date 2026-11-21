import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:maprisma_core/maprisma_core.dart';
import 'service_transport.dart';

void _serveIsolate((SendPort, Map<String, String>?) args) {
  final inbox = ReceivePort();
  final service = CoreService(environment: args.$2);
  args.$1.send(inbox.sendPort);
  inbox.listen((message) {
    if (message == null) {
      // Synchronous release: the Project Center's store lock is a raw
      // descriptor that would outlive a killed isolate, and its supervisors
      // need EOF on their control pipes.
      service.dispose();
      args.$1.send('@disposed');
      inbox.close();
      return;
    }
    if (message == '@close') {
      // Await feature cleanup, then acknowledge so the host can end this
      // isolate without abandoning owned work.
      service.close().whenComplete(() {
        args.$1.send('@closed');
        inbox.close();
      });
      return;
    }
    if (message is String) {
      service.handleAsync(message).then(args.$1.send);
    }
  });
}

/// Longer than the core's worst case for `features.shutdown`: the AI Project
/// Center first (start 10 s, @shutdown 30 s, exit 10 s), then the other
/// features together (the same again), plus the embedded center's cleanup.
/// A shorter wait would abort the close while the core still finishes it.
const featuresShutdownTimeout = Duration(seconds: 180);

/// How long a call may take before the GUI gives up on its answer.
Duration callTimeout(String method) => method == 'features.shutdown'
    ? featuresShutdownTimeout
    : const Duration(seconds: 60);

final class IsolateTransport implements ServiceTransport {
  IsolateTransport._();
  final _inbox = ReceivePort(), _errors = ReceivePort(), _exit = ReceivePort();
  final _ready = Completer<SendPort>();
  final _closedAck = Completer<void>(),
      _disposedAck = Completer<void>(),
      _exited = Completer<void>();
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  Isolate? _isolate;
  SendPort? _send;
  var _id = 0;
  bool _closed = false;
  @override
  bool get isConnected => !_closed;
  static Future<IsolateTransport> start({
    Map<String, String>? environment,
  }) async {
    final t = IsolateTransport._();
    // Attach before spawn: startup can fail before the ready port arrives.
    t._ready.future.ignore();
    t._inbox.listen(t._receive);
    t._errors.listen((_) => t._fail(StateError('Core isolate failed')));
    t._exit.listen((_) {
      if (!t._exited.isCompleted) t._exited.complete();
      t._fail(StateError('Core isolate exited'));
    });
    try {
      t._isolate = await Isolate.spawn(
        _serveIsolate,
        (t._inbox.sendPort, environment),
        onError: t._errors.sendPort,
        onExit: t._exit.sendPort,
        // An uncaught error is reported (and fails this transport) but does
        // not end the isolate, so it still releases its store lock below.
        errorsAreFatal: false,
      );
      t._send = await t._ready.future.timeout(const Duration(seconds: 10));
      return t;
    } catch (_) {
      t.dispose();
      rethrow;
    }
  }

  void _receive(dynamic message) {
    if (message is SendPort) {
      if (!_ready.isCompleted) _ready.complete(message);
      return;
    }
    if (message == '@closed') {
      if (!_closedAck.isCompleted) _closedAck.complete();
      return;
    }
    if (message == '@disposed') {
      if (!_disposedAck.isCompleted) _disposedAck.complete();
      return;
    }
    try {
      if (message is! String || utf8.encode(message).length > maxResponse) {
        throw const FormatException('Invalid core reply');
      }
      final data = jsonDecode(message) as Map<String, dynamic>;
      final completer = _pending[data['id']];
      if (completer == null) return;
      if (data.containsKey('error')) {
        if (data['error'] is! Map || data['error']['code'] is! String) {
          throw const FormatException('Invalid error');
        }
        _pending.remove(data['id']);
        completer.completeError(
          ServiceError(
            data['error']['code'] as String,
            data['error']['message'] as String?,
          ),
        );
      } else {
        if (data['result'] is! Map<String, dynamic>) {
          throw const FormatException('Invalid result');
        }
        _pending.remove(data['id']);
        completer.complete(data['result'] as Map<String, dynamic>);
      }
    } catch (_) {
      _fail(StateError('Invalid core response'));
    }
  }

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (_closed) throw StateError('Service closed');
    final id = ++_id;
    final frame = jsonEncode({
      'protocol': protocolVersion,
      'id': id,
      'method': method,
      'params': params,
    });
    if (utf8.encode(frame).length + 1 > maxRequest) {
      throw ServiceError('request_too_large');
    }
    final pending = Completer<Map<String, dynamic>>();
    _pending[id] = pending;
    _send!.send(frame);
    try {
      return await pending.future.timeout(callTimeout(method));
    } finally {
      _pending.remove(id);
    }
  }

  void _fail(Object error) {
    if (_closed) return;
    _closed = true;
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final p in _pending.values) {
      p.completeError(error);
    }
    _pending.clear();
    var released = _closedAck.isCompleted || _exited.isCompleted;
    if (!released) {
      try {
        _send?.send(null);
      } catch (_) {
        released = true;
      }
    }
    void end() {
      _isolate?.kill(priority: Isolate.immediate);
      _inbox.close();
      _errors.close();
      _exit.close();
    }

    if (released || _send == null || _isolate == null) {
      end();
      return;
    }
    // Ended only after the isolate released: its raw store descriptor would
    // otherwise outlive it. An isolate busy with synchronous work answers once
    // it reaches the message; one that never can is still alive and still
    // owns the store, which a replacement then reports honestly as busy.
    unawaited(
      Future.any([
        _disposedAck.future,
        _closedAck.future,
        _exited.future,
      ]).whenComplete(end),
    );
  }

  @override
  void dispose() => _fail(StateError('Service closed'));

  /// An acknowledged close: the core finishes feature cleanup (bounded by its
  /// own deadlines) before the isolate is ended.
  @override
  Future<void> shutdown() async {
    if (_closed || _send == null) return dispose();
    try {
      _send!.send('@close');
      // The core retries feature cleanup before it confirms.
      await Future.any([
        _closedAck.future,
        _exited.future,
      ]).timeout(featuresShutdownTimeout);
    } on Object {
      // Ended or timed out; the supervisors keep any unconfirmed work.
    }
    dispose();
  }
}
