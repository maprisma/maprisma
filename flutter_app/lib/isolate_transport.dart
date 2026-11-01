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
      inbox.close();
      return;
    }
    if (message is String) args.$1.send(service.handle(message));
  });
}

final class IsolateTransport implements ServiceTransport {
  IsolateTransport._();
  final _inbox = ReceivePort(), _errors = ReceivePort(), _exit = ReceivePort();
  final _ready = Completer<SendPort>();
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
    t._exit.listen((_) => t._fail(StateError('Core isolate exited')));
    try {
      t._isolate = await Isolate.spawn(
        _serveIsolate,
        (t._inbox.sendPort, environment),
        onError: t._errors.sendPort,
        onExit: t._exit.sendPort,
        errorsAreFatal: true,
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
      return await pending.future.timeout(const Duration(seconds: 60));
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
    _isolate?.kill(priority: Isolate.immediate);
    _inbox.close();
    _errors.close();
    _exit.close();
  }

  @override
  void dispose() => _fail(StateError('Service closed'));
  @override
  Future<void> shutdown() async => dispose();
}
