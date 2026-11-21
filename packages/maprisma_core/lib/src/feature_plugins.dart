import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'addons.dart' show signingKey;
import 'core_tasks.dart' show coreHandle, maxIssuedHandles;
import 'identity.dart';
import 'protocol.dart';
import 'posix_ffi.dart';
import 'pty_sessions.dart' show processIdentity;
import 'sshsig.dart';

/// The host's bound on routed handles per feature (a memory bound only;
/// backends report the handles their stores released). Twice a backend's own
/// bound leaves room for releases still on their way.
const maxOwnedHandles = 2 * maxIssuedHandles;

/// The API a feature backend speaks when it gives none (the first version).
const featureApi = 1;

/// The API versions the host accepts, per feature.
const featureApiRanges = {
  'reports': (1, 1),
  'ask-ai': (1, 1),
  'ai-project-center': (1, 2),
};

/// What this build's own backends speak, per feature (also embedded mode).
const featureApiOwn = {'reports': 1, 'ask-ai': 1, 'ai-project-center': 2};

/// Named capabilities of this build's own backends (`@hello` lists them).
const featureCapabilitiesOwn = {
  'reports': <String>[],
  'ask-ai': <String>[],
  'ai-project-center': ['summary2'],
};

/// Whether [api] is accepted for [id].
bool featureApiAccepted(String id, Object? api) {
  final range = featureApiRanges[id];
  return range != null && api is int && api >= range.$1 && api <= range.$2;
}

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
    this.restartDelay = const Duration(seconds: 1),
    DateTime Function()? clock,
    this.ownedLimit = maxOwnedHandles,
    this.trustedKey = signingKey,
  }) : clock = clock ?? DateTime.now;

  /// The key that signs user updates (another one only in tests).
  final String trustedKey;

  /// [maxOwnedHandles], smaller in tests.
  final int ownedLimit;
  final AppIdentity identity;

  /// The time for restart pauses (a test sets it).
  final DateTime Function() clock;
  final Duration shutdownTimeout;

  /// The first wait before a failed backend is started again; it doubles
  /// with each failure in a row, up to a minute.
  final Duration restartDelay;
  final Map<String, List<String>>? commands;
  final _processes = <String, _FeatureProcess>{};
  final _embedded = <String>{};
  final _owners = <String, String>{};

  /// The same handles per feature, oldest first.
  final _owned = <String, Set<String>>{};

  void _own(String handle, String id) {
    _disown(handle);
    _owners[handle] = id;
    (_owned[id] ??= <String>{}).add(handle);
  }

  void _disown(String handle) {
    final id = _owners.remove(handle);
    if (id != null) _owned[id]?.remove(handle);
  }

  void _disownAll(String id) {
    for (final handle in _owned.remove(id) ?? const <String>{}) {
      _owners.remove(handle);
    }
  }

  final _failures = <String, int>{};

  /// Features that ran as a process: a restart never turns them embedded.
  final _processBacked = <String>{};
  bool _closing = false;

  /// Whether the host closed its features (a confirmed shutdown).
  bool get closing => _closing;

  /// Whether the feature runs as a process, or did: also a failed one, one
  /// that has not exited yet, or one whose replacement could not start.
  bool tracked(String id) =>
      _processes.containsKey(id) || _processBacked.contains(id);

  /// What backend a feature would use, without verifying or staging a user
  /// update: listing the features must stay cheap and never fail because of
  /// one broken update.
  List<Map<String, dynamic>> descriptors() => [
    for (final id in featureIds)
      {
        'id': id,
        'title': featureTitles[id],
        'api': featureApiOwn[id],
        'api_range': [featureApiRanges[id]!.$1, featureApiRanges[id]!.$2],
        'negotiated_api': negotiatedApi(id),
        'capabilities': capabilities(id),
        'backend': _embedded.contains(id)
            ? 'embedded'
            : _processes.containsKey(id) ||
                  _processBacked.contains(id) ||
                  commands?[id] != null ||
                  Directory(_updateDirectory(id)).existsSync() ||
                  File(_bundled(id)).existsSync()
            ? 'process'
            : 'embedded',
        'presentation': 'native',
      },
  ];

  /// Whether the feature's backend process is up (started and not failed or
  /// stopped).
  bool running(String id) {
    final process = _processes[id];
    return process != null &&
        !process.cleanlyStopped &&
        process.failedAt == null;
  }

  String _updateDirectory(String id) =>
      p.join(identity.dataDir, 'feature-plugins', id);
  String _bundled(String id) => p.join(appFolder(), 'features', id, 'plugin');

  /// The API the running backend of [id] answered (embedded: this build's),
  /// or null before a backend answered `@hello`.
  int? negotiatedApi(String id) {
    if (_embedded.contains(id)) return featureApiOwn[id];
    final process = _processes[id];
    return process == null || process.retired || !process.greeted
        ? null
        : process.api;
  }

  /// The capabilities the running backend named (embedded: this build's),
  /// or null before a backend answered `@hello`.
  List<String>? capabilities(String id) {
    if (_embedded.contains(id)) return featureCapabilitiesOwn[id];
    final process = _processes[id];
    return process == null || process.retired || !process.greeted
        ? null
        : process.capabilities;
  }

  /// The API a signed user update's manifest names, by feature.
  final _manifestApi = <String, int>{};

  List<String>? _command(String id) {
    if (!featureIds.contains(id)) throw ServiceError('feature_unknown');
    _manifestApi.remove(id);
    final explicit = commands?[id];
    if (explicit != null) return explicit;
    if (Directory(_updateDirectory(id)).existsSync()) {
      // A rejected installed candidate surfaces its error; it never runs,
      // and the bundled backend does not silently stand in for it.
      try {
        return _userUpdate(id);
      } on FormatException {
        throw ServiceError('feature_incompatible');
      }
    }
    final bundled = _bundled(id);
    return File(bundled).existsSync() ? [bundled] : null;
  }

  List<String> _userUpdate(String id) {
    // User updates are executable features, distinct from data-only agent
    // add-ons. Only the author's signature can authorize them. No hooks run
    // while discovering one; a failed candidate never executes.
    final io = Posix();
    // The signed manifest is checked before the (large) executable is read.
    Map checked(List<int> manifest, List<int> signature) {
      if (!sshSignatureOk(
        manifest,
        signature,
        'maprisma-feature',
        trustedKey,
      )) {
        throw ServiceError('feature_signature_invalid');
      }
      final data = jsonDecode(utf8.decode(manifest));
      if (data is! Map ||
          data['id'] != id ||
          !featureApiAccepted(id, data['api']) ||
          data['sha256'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(data['sha256'] as String)) {
        throw ServiceError('feature_incompatible');
      }
      return data;
    }

    final Map data;
    final List<int> executable;
    try {
      (data, executable) = _readUpdate(io, id, checked);
    } on FileSystemException {
      // A link, a missing file or an untrusted folder.
      throw ServiceError('feature_signature_invalid');
    }
    if (data['sha256'] != sha256.convert(executable).toString()) {
      throw ServiceError('feature_signature_invalid');
    }
    final staging = p.join(identity.cacheDir, 'feature-launches');
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
      _manifestApi[id] = data['api'] as int;
      return [target];
    } finally {
      io.close(dir);
    }
  }

  /// The data folder is resolved once through trusted aliases (it may live
  /// on another disk behind a symbolic link); `feature-plugins`, the update
  /// folder and its files must be real, not links. Each file is read through
  /// its own descriptor: type and size are checked on what is read, so a file
  /// swapped or grown after the check cannot pass, and a FIFO cannot block.
  (Map, List<int>) _readUpdate(
    Posix io,
    String id,
    Map Function(List<int> manifest, List<int> signature) checked,
  ) {
    final opened = <int>[];
    int open(int parent, String name, int flags) {
      final fd = io.openAt(parent, name, flags | Posix.noFollow);
      opened.add(fd);
      return fd;
    }

    try {
      opened.add(io.existingDirectory(identity.dataDir));
      final plugins = open(opened.first, 'feature-plugins', Posix.directory);
      final folder = open(plugins, id, Posix.directory);
      List<int> read(String name, int limit) {
        final fd = open(folder, name, Posix.nonBlock);
        final stat = io.statFull(fd);
        if (stat.mode & 0xf000 != 0x8000) {
          throw ServiceError('feature_signature_invalid');
        }
        if (stat.size > limit) throw ServiceError('feature_too_large');
        final bytes = io.readAt(fd, 0, limit + 1);
        if (bytes.length > limit) throw ServiceError('feature_too_large');
        return bytes;
      }

      final data = checked(
        read('feature.json', 32768),
        read('SIGNATURE', 8192),
      );
      return (data, read('plugin', 128 * 1024 * 1024));
    } finally {
      for (final fd in opened.reversed) {
        io.close(fd);
      }
    }
  }

  String? owner(Map<String, dynamic> params) {
    final owners = <String>{};
    void visit(Object? value) {
      if (value is String && _owners.containsKey(value)) {
        final id = _owners[value]!;
        final process = _processes[id];
        if (process == null || process.retired) {
          // Its process stopped, failed or exited: its handles died with it,
          // also before that was otherwise noticed.
          _disownAll(id);
          return;
        }
        owners.add(id);
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
      final own = _owned[id];
      if (own != null && own.length >= ownedLimit && _owners[handle] != id) {
        // Only a memory bound, per feature: a backend reports the handles
        // its stores released, so routing follows the stores. A feature over
        // its bound (one that does not report) loses its own oldest handle,
        // never another feature's.
        _disown(own.first);
      }
      _own(handle, id);
    }
  }

  /// The handles a backend's stores released (expired, evicted or used):
  /// they route no more.
  void _forget(String id, List<String> released) {
    for (final token in released) {
      final bare = token.startsWith(coreHandle)
          ? token.substring(coreHandle.length)
          : token;
      // Only its own: a backend cannot release another feature's handle.
      for (final handle in [bare, '$coreHandle$bare']) {
        if (_owners[handle] == id) _disown(handle);
      }
    }
  }

  Future<Map<String, dynamic>> call(
    String id,
    String operation,
    Map<String, dynamic> params,
    FutureOr<Map<String, dynamic>> Function() embedded, {
    Map<String, dynamic> Function()? context,
  }) async {
    if (_closing) throw ServiceError('feature_closing');
    if (_embedded.contains(id)) return embedded();
    final previous = _processes[id];
    _FeatureProcess plugin;
    if (previous != null &&
        (previous.cleanlyStopped || previous.failedAt != null)) {
      final failures = _failures[id] ?? 0;
      if (previous.cleanlyStopped) {
        // It confirmed @shutdown late, after an aborted close: it ends on
        // EOF. It is replaced only once it has exited; one that hangs is
        // killed like a failed one.
        previous.endInput();
        final since = clock().difference(
          previous.stoppedAt ?? previous.failedAt ?? clock(),
        );
        if (since >= _killAfter) previous.kill();
        if (!previous.exited) throw ServiceError('feature_closing');
      } else {
        // A crashed, hung or unstartable backend is started again, after a
        // wait that doubles with each failure in a row (the summary is
        // polled every two seconds), and only once its process has exited:
        // until then it may still be cleaning up and holding its store. It
        // stays tracked meanwhile, so shutdown and dispose still reach it.
        final wait = restartDelay * (1 << failures.clamp(0, 6));
        final waited = clock().difference(previous.failedAt!);
        if (waited >= _killAfter) previous.kill();
        if (!previous.exited ||
            waited < (wait > _maxRestartDelay ? _maxRestartDelay : wait)) {
          throw ServiceError('feature_disconnected');
        }
      }
      // The replacement is found first: without one the old entry stays, and
      // the feature stays process-backed (and disconnected), never embedded.
      final command = _command(id);
      if (command == null) throw ServiceError('feature_disconnected');
      _processes.remove(id);
      _disownAll(id);
      if (previous.failedAt != null && !previous.cleanlyStopped) {
        _failures[id] = failures + 1;
      }
      plugin = _launch(id, command);
    } else if (previous != null) {
      plugin = previous;
    } else {
      final command = _command(id);
      if (command == null) {
        // A feature that ran as a process does not turn embedded.
        if (_processBacked.contains(id)) {
          throw ServiceError('feature_disconnected');
        }
        _embedded.add(id);
        return embedded();
      }
      plugin = _launch(id, command);
    }
    try {
      // Host state a process backend cannot see itself, sent beside the
      // params on this private pipe only (never taken from a client).
      // Releases and new handles are taken from each answer in the order the
      // answers arrive (onReleased, onIssued), not after the await.
      return await plugin.call(operation, params, context?.call());
    } finally {
      // It answered (a result or its own error): it works again.
      if (plugin.answered && plugin.failedAt == null) _failures.remove(id);
    }
  }

  _FeatureProcess _launch(String id, List<String> command) {
    _processBacked.add(id);
    late final _FeatureProcess process;
    process = _FeatureProcess(
      id,
      command,
      identity.environment,
      shutdownTimeout,
      clock,
      manifestApi: _manifestApi[id],
      // Its handles die with it, unless it was already replaced: then the
      // handles are its replacement's.
      onFailed: () {
        if (_processes[id] == process) {
          _disownAll(id);
        }
      },
      // With every answer, in arrival order: first what it let go, then what
      // it issued. A process that failed or was replaced issues nothing.
      onReleased: (released) {
        if (_processes[id] == process) _forget(id, released);
      },
      onIssued: (result, issued) {
        // Not from one that stopped, failed or exited meanwhile.
        if (_processes[id] == process && !process.retired) {
          _remember(id, result, issued);
        }
      },
    );
    return _processes[id] = process;
  }

  static const _maxRestartDelay = Duration(minutes: 1);

  /// A failed backend that has not exited by then (its own cleanup is
  /// bounded to about 50 seconds) is killed.
  static const _killAfter = Duration(minutes: 1);

  /// The stateful AI Project Center stops first; the other features are
  /// asked only once it confirmed. A refused or timed-out shutdown leaves
  /// every feature usable; a confirmed one is final for this host.
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
    _disownAll(id);
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
    this.clock, {
    this.manifestApi,
    this.onFailed,
    this.onReleased,
    this.onIssued,
  });
  final void Function(Map<String, dynamic> result, List<String>? issued)?
  onIssued;

  /// The method of each pending request (control requests issue nothing).
  final _methods = <int, String>{};
  final DateTime Function() clock;

  /// The API a signed update's manifest names; `@hello` must say the same.
  final int? manifestApi;

  /// What `@hello` answered (until then the first API, no capabilities).
  int api = featureApi;
  List<String> capabilities = const [];

  /// `@hello` was answered and accepted.
  bool greeted = false;
  final void Function()? onFailed;
  final void Function(List<String> released)? onReleased;

  /// The process answered a request (not only @hello).
  bool answered = false;

  /// No process runs (none started, or it exited).
  bool get exited => _process == null || _exitedProcess;

  /// It stopped, failed or exited: it serves nothing any more.
  bool get retired => cleanlyStopped || failedAt != null || _exitedProcess;

  /// When it confirmed @shutdown.
  DateTime? stoppedAt;

  /// It confirmed @shutdown: it gets EOF, and its handles end with it.
  void _confirmStopped() {
    cleanlyStopped = true;
    stoppedAt ??= clock();
    endInput();
    onFailed?.call();
  }

  bool _exitedProcess = false;

  /// Ends a process that did not exit on its own.
  void kill() => _process?.kill(ProcessSignal.sigkill);

  /// EOF: a feature that confirmed @shutdown exits on it.
  void endInput() {
    final process = _process;
    if (process == null || _inputEnded) return;
    _inputEnded = true;
    process.stdin.close().ignore();
  }

  bool _inputEnded = false;
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

  /// When the backend failed (crashed, hung, did not start); null while usable.
  DateTime? failedAt;
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
    unawaited(process.exitCode.then((_) => _exitedProcess = true));
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
              // Checked while the caller still waits: a bad frame fails the
              // backend, and with it every waiting caller.
              final released = data['released'];
              if (released != null &&
                  (released is! List ||
                      released.any((value) => value is! String))) {
                throw const FormatException();
              }
              final waiter = _pending.remove(data['id']);
              final method = _methods.remove(data['id']);
              if (waiter == null) throw const FormatException();
              if (released is List && released.isNotEmpty) {
                onReleased?.call(released.cast<String>());
              }
              final issued = data['handles'];
              if (method != null &&
                  !method.startsWith('@') &&
                  data['result'] is Map<String, dynamic> &&
                  (issued == null ||
                      issued is List && issued.every((v) => v is String))) {
                onIssued?.call(
                  data['result'] as Map<String, dynamic>,
                  (issued as List?)?.cast<String>(),
                );
              }
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
    final caps = hello['capabilities'];
    if (hello['id'] != id ||
        !featureApiAccepted(id, hello['api']) ||
        (manifestApi != null && hello['api'] != manifestApi) ||
        (hello.containsKey('capabilities') &&
            (caps is! List ||
                caps.length > 32 ||
                caps.any((c) => c is! String || c.isEmpty || c.length > 64)))) {
      _fail();
      throw ServiceError('feature_incompatible');
    }
    api = hello['api'] as int;
    capabilities = caps == null ? const [] : List<String>.unmodifiable(caps);
    greeted = true;
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params, [
    Map<String, dynamic>? context,
  ]) {
    if (_failed || _process == null) throw ServiceError('feature_disconnected');
    final serial = ++_serial;
    final frame = jsonEncode({
      'id': serial,
      'method': method,
      'params': params,
      'context': ?context,
    });
    if (utf8.encode(frame).length > maxRequest) {
      throw ServiceError('request_too_large');
    }
    final waiter = Completer<Map<String, dynamic>>();
    _pending[serial] = waiter;
    _methods[serial] = method;
    _process!.stdin.writeln(frame);
    return waiter.future;
  }

  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params, [
    Map<String, dynamic>? context,
  ]) async {
    try {
      try {
        await (_starting ??= _start());
      } on ProcessException {
        _fail();
        throw ServiceError('feature_disconnected');
      } on Object {
        // Also a failed @hello: the cached start never succeeds again.
        _fail();
        rethrow;
      }
      // A pending @shutdown is still being answered: a request would queue
      // behind it and could be dropped when the process exits.
      if (_stopRequested || _shutdownPending || cleanlyStopped) {
        throw ServiceError('feature_closing');
      }
      final Map<String, dynamic> frame;
      try {
        frame = await _request(
          method,
          params,
          context,
        ).timeout(const Duration(seconds: 45));
      } on ServiceError catch (error) {
        // Its own error frame is an answer too; a lost process, a request
        // refused before sending and an invalid reply are not.
        if (!_failed &&
            error.code != 'request_too_large' &&
            error.code != 'feature_invalid_response') {
          answered = true;
        }
        rethrow;
      }
      answered = true;
      return frame['result'] as Map<String, dynamic>;
    } on TimeoutException {
      _fail();
      throw ServiceError('feature_timeout');
    }
  }

  void _fail() {
    if (failedAt == null) {
      failedAt = clock();
      onFailed?.call();
    }
    _failed = true;
    _process?.kill();
    for (final waiter in _pending.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(ServiceError('feature_disconnected'));
      }
    }
    _pending.clear();
    _methods.clear();
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
        if (cleanlyStopped) endInput();
        await _process!.exitCode.timeout(const Duration(seconds: 20));
        return;
      }
      if (_shutdownPending) throw ServiceError('project_still_pausing');
      _shutdownPending = true;
      final request = _request('@shutdown', {});
      try {
        await request.timeout(shutdownTimeout);
        _shutdownPending = false;
        _confirmStopped();
      } on TimeoutException {
        // Keep waiting in the background so a later retry sees the answer.
        unawaited(
          request.then((_) {
            _shutdownPending = false;
            _confirmStopped();
          }, onError: (Object _) => _shutdownPending = false),
        );
        throw ServiceError('project_still_pausing');
      } on Object {
        _shutdownPending = false;
        rethrow;
      }
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
