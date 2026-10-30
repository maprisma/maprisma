import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:asterism/service_transport.dart';
import 'package:asterism_core/asterism_core.dart';

/// Test support only: drives a fake service script (python3) over the same
/// line protocol, for widget tests of the app. The app itself has no Python
/// transport.
class PythonTransport implements ServiceTransport {
  PythonTransport._(this._process) {
    _process.stdout.listen(
      _receiveBytes,
      onError: (Object error) => _fail(error),
      onDone: () => _fail(StateError('Service disconnected')),
    );
    // Drain diagnostics without retaining potential private adapter output.
    _process.stderr.listen((_) {});
    _process.stdin.done.catchError((Object error) => _fail(error));
  }

  final Process _process;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  var _next = 0;
  bool _closed = false;
  bool _disposed = false;

  @override
  bool get isConnected => !_closed;

  static Future<PythonTransport> start(String root) async {
    if (!File('$root/flutter_backend.py').existsSync()) {
      throw StateError('Asterism service was not found');
    }
    return PythonTransport._(
      await Process.start(
        '/usr/bin/python3',
        ['-u', '$root/flutter_backend.py'],
        workingDirectory: root,
        environment: const {'ASTERISM_FLUTTER_DEVEL': '1'},
      ),
    );
  }

  final _frame = <int>[];

  void _receiveBytes(List<int> bytes) {
    for (final byte in bytes) {
      if (_closed) return;
      if (byte == 10) {
        try {
          _receive(utf8.decode(_frame));
        } catch (error) {
          _fail(error);
        }
        _frame.clear();
      } else {
        if (_frame.length >= 1024 * 1024) {
          _fail(const FormatException('Service response too large'));
          return;
        }
        _frame.add(byte);
      }
    }
  }

  void _receive(String line) {
    try {
      final message = jsonDecode(line) as Map<String, dynamic>;
      if (message['id'] == null && message.containsKey('error')) return;
      if (message['id'] is! int ||
          (!message.containsKey('error') &&
              message['result'] is! Map<String, dynamic>)) {
        throw const FormatException('Invalid service response');
      }
      final completer = _pending.remove(message['id']);
      if (completer == null) return;
      if (message.containsKey('error')) {
        final error = message['error'];
        if (error is! Map || error['code'] is! String) {
          completer.completeError(
            const FormatException('Invalid service error'),
          );
          throw const FormatException('Invalid service error');
        }
        completer.completeError(ServiceError(error['code'] as String));
      } else {
        completer.complete(message['result'] as Map<String, dynamic>);
      }
    } catch (error) {
      _fail(error);
    }
  }

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (_closed) throw StateError('Service disconnected');
    final id = ++_next;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      _process.stdin.writeln(
        jsonEncode({
          'protocol': 1,
          'id': id,
          'method': method,
          'params': params,
        }),
      );
      if (const {
        'agents.action_apply',
        'guide.snapshot',
        'guide.choose',
        'addons.catalog',
        'existing.scan',
        'system.refresh',
        'system.help_apply',
        'system.move_preview',
        'system.move_apply',
        'system.move_undo',
        'system.tool_check',
        'existing.check',
        'existing.apply',
        'addons.install',
        'setup.apply',
        'setup.later',
        'setup.detect',
        'sessions.start',
        'sessions.write',
        'connections.apply',
        'connections.undo',
        'models.remove_apply',
        'providers.run',
      }.contains(method)) {
        return await completer.future;
      }
      return await completer.future.timeout(
        Duration(seconds: method.startsWith('sessions.') ? 5 : 60),
      );
    } finally {
      _pending.remove(id);
    }
  }

  void _fail(Object error) {
    if (_closed) return;
    _closed = true;
    _process.kill();
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
  }

  @override
  Future<void> shutdown() async {
    dispose();
    await _process.exitCode.timeout(
      const Duration(seconds: 35),
      onTimeout: () => 0,
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _closed = true;
    for (final completer in _pending.values) {
      completer.completeError(StateError('Service closed'));
    }
    _pending.clear();
    // EOF gives a pending spawn time to register its PTY before cleanup.
    _process.stdin.close().catchError((Object _) {});
    final fallback = Timer(const Duration(seconds: 35), () => _process.kill());
    _process.exitCode.then((_) => fallback.cancel());
  }
}
