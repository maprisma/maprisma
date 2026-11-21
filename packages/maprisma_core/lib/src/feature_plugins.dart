import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'addons.dart' show signingKey;
import 'core_tasks.dart' show maxIssuedHandles;
import 'identity.dart';
import 'protocol.dart';
import 'posix_ffi.dart';
import 'pty_sessions.dart' show processIdentity;
import 'sshsig.dart';

const featureApi = 1;
const featureIds = {'reports', 'ask-ai', 'ai-project-center'};
const featureTitles = {
  'reports': 'Reports',
  'ask-ai': 'Ask AI',
  'ai-project-center': 'AI Project Center',
};

/// A feature owns its operations and opaque handles. The host does not know
/// their implementation language. Native Flutter presentation remains in the
/// shell; backend changes within this versioned contract replace only a plugin.
final class FeaturePluginHost {
  FeaturePluginHost(
    this.identity, {
    this.commands,
    this.shutdownTimeout = const Duration(seconds: 30),
  });
  final AppIdentity identity;
  final Duration shutdownTimeout;
  final Map<String, List<String>>? commands;
  final _processes = <String, _FeatureProcess>{};
  final _embedded = <String>{};
  final _owners = <String, String>{};
  bool _closing = false;

  List<Map<String, dynamic>> descriptors() => [
    for (final id in featureIds)
      {
        'id': id,
        'title': featureTitles[id],
        'api': featureApi,
        'backend': _embedded.contains(id)
            ? 'embedded'
            : _processes.containsKey(id) || _command(id) != null
            ? 'process'
            : 'embedded',
        'presentation': 'native',
      },
  ];

  List<String>? _command(String id) {
    if (!featureIds.contains(id)) throw ServiceError('feature_unknown');
    final explicit = commands?[id];
    if (explicit != null) return explicit;
    // User updates are executable features, distinct from data-only agent
    // add-ons. Only the author's signature can authorize them. No hooks run
    // while discovering one; a failed candidate never executes.
    final directory = p.join(identity.dataDir, 'feature-plugins', id);
    if (Directory(directory).existsSync()) {
      final manifest = _checkedFile(directory, 'feature.json', 32768);
      final signature = _checkedFile(directory, 'SIGNATURE', 8192);
      if (!sshSignatureOk(
        manifest,
        signature,
        'maprisma-feature',
        signingKey,
      )) {
        throw ServiceError('feature_signature_invalid');
      }
      final data = jsonDecode(utf8.decode(manifest));
      if (data is! Map || data['id'] != id || data['api'] != featureApi) {
        throw ServiceError('feature_incompatible');
      }
      final executable = _checkedFile(directory, 'plugin', 128 * 1024 * 1024);
      if (data['sha256'] != sha256.convert(executable).toString()) {
        throw ServiceError('feature_signature_invalid');
      }
      final staging = p.join(identity.cacheDir, 'feature-launches');
      final io = Posix();
      final dir = io.privateDirectory(staging);
      try {
        io.chmod(dir, 0x1c0);
        final target = p.join(staging, '$id-${data['sha256']}');
        io.atomicWrite(target, executable);
        final fd = io.openAt(
          dir,
          p.basename(target),
          Posix.noFollow | Posix.nonBlock,
        );
        try {
          io.chmod(fd, 0x140);
        } finally {
          io.close(fd);
        }
        return [target];
      } finally {
        io.close(dir);
      }
    }
    final bundled = p.join(appFolder(), 'features', id, 'plugin');
    return File(bundled).existsSync() ? [bundled] : null;
  }

  List<int> _checkedFile(String directory, String name, int limit) {
    if (Directory(directory).resolveSymbolicLinksSync() != directory ||
        FileSystemEntity.typeSync(
              p.join(directory, name),
              followLinks: false,
            ) !=
            FileSystemEntityType.file) {
      throw ServiceError('feature_signature_invalid');
    }
    final file = File(p.join(directory, name));
    if (file.lengthSync() > limit) throw ServiceError('feature_too_large');
    return file.readAsBytesSync();
  }

  String? owner(Map<String, dynamic> params) {
    final owners = <String>{};
    void visit(Object? value) {
      if (value is String && _owners.containsKey(value)) {
        owners.add(_owners[value]!);
      } else if (value is Map) {
        value.values.forEach(visit);
      } else if (value is List) {
        value.forEach(visit);
      }
    }

    visit(params);
    if (owners.length > 1) throw ServiceError('feature_handle_conflict');
    return owners.firstOrNull;
  }

  /// Record the handles a feature says it issued. Only listed strings that
  /// occur in the result count, so an arbitrary 32-hex hash or id is never
  /// mistaken for a handle; a pre-provenance plugin is trusted only for the
  /// prefixed `core-` form.
  void _remember(String id, Map<String, dynamic> result, List<String>? issued) {
    final present = <String>{};
    void visit(Object? value) {
      if (value is String) {
        present.add(value);
      } else if (value is Map) {
        value.values.forEach(visit);
      } else if (value is List) {
        value.forEach(visit);
      }
    }

    visit(result);
    final handles = issued == null
        ? present.where(
            (value) => RegExp(r'^core-[a-f0-9]{32}$').hasMatch(value),
          )
        : issued.where(
            (value) =>
                present.contains(value) &&
                RegExp(r'^(core-)?[a-f0-9]{32}$').hasMatch(value),
          );
    for (final handle in handles) {
      if (_owners.length >= maxIssuedHandles && !_owners.containsKey(handle)) {
        // Oldest first: a handle store keeps far fewer handles alive.
        _owners.remove(_owners.keys.first);
      }
      _owners.remove(handle);
      _owners[handle] = id;
    }
  }

  Future<Map<String, dynamic>> call(
    String id,
    String operation,
    Map<String, dynamic> params,
    FutureOr<Map<String, dynamic>> Function() embedded,
  ) async {
    if (_closing) throw ServiceError('feature_closing');
    if (_embedded.contains(id)) return embedded();
    final previous = _processes[id];
    if (previous != null && previous.cleanlyStopped) {
      // It confirmed @shutdown after an aborted close; start it again.
      _processes.remove(id);
      _owners.removeWhere((_, owner) => owner == id);
    }
    final command = _processes.containsKey(id) ? null : _command(id);
    if (command == null && !_processes.containsKey(id)) {
      _embedded.add(id);
      return embedded();
    }
    final plugin = _processes.putIfAbsent(
      id,
      () =>
          _FeatureProcess(id, command!, identity.environment, shutdownTimeout),
    );
    final (result, issued) = await plugin.call(operation, params);
    _remember(id, result, issued);
    return result;
  }

  /// The stateful AI Project Center stops first; the other features are
  /// asked only once it confirmed. A feature that stopped is forgotten, so a
  /// later call starts it again: an aborted close leaves every feature usable.
  Future<void>? _shuttingDown;

  /// Concurrent requests share one shutdown attempt.
  Future<void> shutdown() =>
      _shuttingDown ??= _shutdown().whenComplete(() => _shuttingDown = null);

  Future<void> _shutdown() async {
    _closing = true;
    try {
      final project = _processes['ai-project-center'];
      if (project != null) await _stop('ai-project-center', project);
      final others = [
        for (final entry in _processes.entries.toList())
          _stop(entry.key, entry.value),
      ];
      await Future.wait(others);
    } on Object {
      _closing = false;
      rethrow;
    }
  }

  Future<void> _stop(String id, _FeatureProcess process) async {
    await process.shutdown();
    if (_processes[id] == process) _processes.remove(id);
    _owners.removeWhere((_, owner) => owner == id);
  }

  void dispose() {
    _closing = true;
    for (final process in _processes.values) {
      process.dispose();
    }
  }
}

final class _FeatureProcess {
  _FeatureProcess(
    this.id,
    this.command,
    this.environment,
    this.shutdownTimeout,
  );
  final Duration shutdownTimeout;
  final String id;
  final List<String> command;
  final Map<String, String> environment;
  Process? _process;
  Future<void>? _starting;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  bool _shutdownPending = false;

  /// The feature answered @shutdown successfully (also after a timeout).
  bool cleanlyStopped = false;
  int _serial = 0;
  bool _failed = false;
  bool _stopRequested = false;

  Future<void> _start() async {
    if (_failed) throw ServiceError('feature_disconnected');
    final process = await Process.start(
      command.first,
      command.skip(1).toList(),
      environment: {
        ...environment,
        'MAPRISMA_FEATURE_PROCESS': id,
        'MAPRISMA_FEATURE_PARENT_PID': '$pid',
        'MAPRISMA_FEATURE_PARENT_START': processIdentity(pid)?.$3 ?? '',
        'MAPRISMA_FEATURE_BUNDLE_ROOT': appFolder(),
      },
      includeParentEnvironment: false,
    );
    _process = process;
    if (_failed) {
      process.kill();
      throw ServiceError('feature_closing');
    }
    process.stdin.done.ignore();
    process.stderr.drain<void>();
    var buffer = <int>[];
    process.stdout.listen(
      (chunk) {
        if (_failed) return;
        for (final byte in chunk) {
          if (byte == 10) {
            try {
              final data = jsonDecode(utf8.decode(buffer));
              buffer = [];
              if (data is! Map || data['id'] is! int) {
                throw const FormatException();
              }
              final waiter = _pending.remove(data['id']);
              if (waiter == null) throw const FormatException();
              if (data['result'] is Map<String, dynamic> &&
                  (data['handles'] == null ||
                      data['handles'] is List &&
                          (data['handles'] as List).every(
                            (value) => value is String,
                          ))) {
                waiter.complete(Map<String, dynamic>.from(data));
              } else {
                waiter.completeError(
                  ServiceError(
                    data['error'] is Map && data['error']['code'] is String
                        ? data['error']['code'] as String
                        : 'feature_invalid_response',
                    data['error'] is Map && data['error']['message'] is String
                        ? data['error']['message'] as String
                        : null,
                  ),
                );
              }
            } catch (_) {
              _fail();
            }
          } else {
            buffer.add(byte);
            if (buffer.length > maxResponse) _fail();
          }
        }
      },
      onError: (_) => _fail(),
      onDone: _fail,
    );
    // The end of its output decides; an exit can arrive before the last
    // buffered answer (e.g. the @shutdown reply) has been read.
    unawaited(
      process.exitCode.then(
        (_) => Future<void>.delayed(const Duration(seconds: 2), _fail),
      ),
    );
    final hello =
        (await _request(
              '@hello',
              {},
            ).timeout(const Duration(seconds: 10)))['result']
            as Map;
    if (hello['id'] != id || hello['api'] != featureApi) {
      _fail();
      throw ServiceError('feature_incompatible');
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params,
  ) {
    if (_failed || _process == null) throw ServiceError('feature_disconnected');
    final serial = ++_serial;
    final frame = jsonEncode({
      'id': serial,
      'method': method,
      'params': params,
    });
    if (utf8.encode(frame).length > maxRequest) {
      throw ServiceError('request_too_large');
    }
    final waiter = Completer<Map<String, dynamic>>();
    _pending[serial] = waiter;
    _process!.stdin.writeln(frame);
    return waiter.future;
  }

  Future<(Map<String, dynamic>, List<String>?)> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    try {
      await (_starting ??= _start());
      // A pending @shutdown is still being answered: a request would queue
      // behind it and could be dropped when the process exits.
      if (_stopRequested || _shutdownPending || cleanlyStopped) {
        throw ServiceError('feature_closing');
      }
      final frame = await _request(
        method,
        params,
      ).timeout(const Duration(seconds: 45));
      return (
        frame['result'] as Map<String, dynamic>,
        (frame['handles'] as List?)?.cast<String>(),
      );
    } on TimeoutException {
      _fail();
      throw ServiceError('feature_timeout');
    }
  }

  void _fail() {
    _failed = true;
    _process?.kill();
    for (final waiter in _pending.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(ServiceError('feature_disconnected'));
      }
    }
    _pending.clear();
  }

  /// The feature's own cleanup deadline is about ten seconds; 30 seconds
  /// leave room for it. A late answer is not a dead backend: the request stays
  /// pending, the process keeps its ownership and a retry asks again.
  Future<void> shutdown() async {
    _stopRequested = true;
    try {
      try {
        await _starting?.timeout(const Duration(seconds: 10));
      } on Object {
        if (_process == null) {
          _fail();
          return;
        }
      }
      if (_process == null) return;
      if (_failed || cleanlyStopped) {
        await _process!.exitCode.timeout(const Duration(seconds: 20));
        return;
      }
      if (_shutdownPending) throw ServiceError('project_still_pausing');
      _shutdownPending = true;
      final request = _request('@shutdown', {});
      try {
        await request.timeout(shutdownTimeout);
        _shutdownPending = false;
        cleanlyStopped = true;
      } on TimeoutException {
        // Keep waiting in the background so a later retry sees the answer.
        unawaited(
          request.then((_) {
            _shutdownPending = false;
            cleanlyStopped = true;
          }, onError: (Object _) => _shutdownPending = false),
        );
        throw ServiceError('project_still_pausing');
      } on Object {
        _shutdownPending = false;
        rethrow;
      }
      await _process!.stdin.close();
      await _process!.exitCode.timeout(const Duration(seconds: 10));
    } on ServiceError {
      if (!_failed) _stopRequested = false;
      rethrow;
    } on Object {
      _fail();
      throw ServiceError('feature_shutdown_failed');
    }
  }

  void dispose() => _fail();
}
