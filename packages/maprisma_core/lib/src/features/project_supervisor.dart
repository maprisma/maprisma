import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../identity.dart' show appFolder;
import '../posix_ffi.dart';
import '../protocol.dart';
import '../pty_sessions.dart' show processIdentity;
import 'ai_project_center.dart' show ProjectProcess;

/// One supervisor process owns one agent assignment. It is a Linux child
/// subreaper, so every descendant of the agent stays in its process tree even
/// after setsid/setpgid or double forks: an orphan re-parents to the nearest
/// subreaper ancestor. "Stopped" therefore means that no live process has the
/// supervisor as an ancestor, rather than that a polled process group is empty.
///
/// Not owned: work an agent asks another service to start (systemd-run,
/// D-Bus activation, container daemons). Such processes are not descendants.
///
/// Control (stdin, JSON lines): `{"argv":[..],"cwd":"..","input":str|null}`,
/// then `{"stop":true}` any number of times. EOF means the controller is gone:
/// the tree is stopped as for a stop request.
/// Events (stdout, JSON lines): `{"out":".."}`, `{"leader":code}` when the
/// agent leader ended by itself, `{"stuck":n}` while n descendants survive SIGKILL, and
/// `{"exit":code}` and `{"stopped":true}` as the last lines, written only when
/// the tree is empty.
Future<int> runProjectSupervisor() async {
  // A controller that disappeared (EPIPE) must not end the supervisor before
  // its tree is empty: output failures are ignored, cleanup goes on.
  unawaited(stdout.done.then<void>((_) {}, onError: (Object _) {}));
  final libc = DynamicLibrary.open('libc.so.6');
  final prctl = libc
      .lookupFunction<
        Int Function(
          Int,
          UnsignedLong,
          UnsignedLong,
          UnsignedLong,
          UnsignedLong,
        ),
        int Function(int, int, int, int, int)
      >('prctl');
  const setChildSubreaper = 36;
  if (prctl(setChildSubreaper, 1, 0, 0, 0) != 0) {
    // Nothing was started, so nothing can be left running.
    stdout
      ..writeln(jsonEncode({'error': 'subreaper_unavailable'}))
      ..writeln(jsonEncode({'stopped': true}));
    return 2;
  }
  // Malformed UTF-8 on the control pipe must not throw out of the control
  // loop: an uncaught error would end this subreaper with its tree running.
  final control = StreamIterator(
    stdin
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter()),
  );
  Object? start;
  try {
    if (!await control.moveNext()) return 0;
    start = jsonDecode(control.current);
  } on Object {
    // Not a start line (bad JSON or a failing pipe): nothing was started.
    start = null;
  }
  if (start is! Map ||
      start['argv'] is! List ||
      (start['argv'] as List).isEmpty ||
      (start['argv'] as List).any((word) => word is! String) ||
      start['cwd'] is! String ||
      (start['input'] != null && start['input'] is! String) ||
      start['controller'] is! Map ||
      (start['controller'] as Map)['pid'] is! int ||
      (start['controller'] as Map)['start'] is! String) {
    stdout
      ..writeln(jsonEncode({'error': 'invalid_start'}))
      ..writeln(jsonEncode({'stopped': true}));
    return 2;
  }
  final argv = (start['argv'] as List).cast<String>();
  // The run lock is held while any owned process may live, also after the
  // controller is gone; a later controller sees the folder as still in use.
  final lock = start['lock'];
  final io = Posix();
  int? lockFd;
  if (lock is String) {
    try {
      final fd = io.openAt(-100, lock, Posix.noFollow | Posix.nonBlock);
      for (var i = 0; i < 100 && lockFd == null; i++) {
        if (io.tryFlock(fd, shared: true)) {
          lockFd = fd;
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      if (lockFd == null) io.close(fd);
    } on FileSystemException {
      lockFd = null;
    }
    if (lockFd == null) {
      stdout
        ..writeln(jsonEncode({'error': 'run_lock_unavailable'}))
        ..writeln(jsonEncode({'stopped': true}));
      return 2;
    }
  }
  // Ownership is continuous only if the controller that queued this start is
  // still the parent *after* the lock is held: had it died first, a
  // replacement may already have seen the lock free and dispatched, so this
  // late start must not launch. Had it died after, the lock is held.
  final controller = start['controller'] as Map;
  {
    String? parentStart;
    var parent = -1;
    try {
      final raw = File('/proc/self/stat').readAsStringSync();
      parent = int.parse(raw.substring(raw.lastIndexOf(')') + 2).split(' ')[1]);
      parentStart = processIdentity(parent)?.$3;
    } on Object {
      parent = -1;
    }
    if (parent != controller['pid'] ||
        parentStart == null ||
        parentStart != controller['start']) {
      if (lockFd != null) io.close(lockFd);
      stdout
        ..writeln(jsonEncode({'error': 'controller_gone'}))
        ..writeln(jsonEncode({'stopped': true}));
      return 2;
    }
  }
  // Launch only on the controller's explicit go-ahead, sent while it still
  // owns the project store. A controller retired in the same process (an
  // embedded core disposed, a worker between dispose and exit) never sends it;
  // EOF or a stop instead ends this supervisor without launching.
  stdout.writeln(jsonEncode({'locked': true}));
  var authorized = false;
  try {
    if (await control.moveNext()) {
      final message = jsonDecode(control.current);
      authorized = message is Map && message['launch'] == true;
    }
  } on Object {
    authorized = false;
  }
  if (!authorized) {
    if (lockFd != null) io.close(lockFd);
    stdout
      ..writeln(jsonEncode({'error': 'launch_withdrawn'}))
      ..writeln(jsonEncode({'stopped': true}));
    return 2;
  }
  final tree = ProcessTree(pid);
  final emit = StreamController<String>();
  final written = stdout
      .addStream(emit.stream.map((line) => utf8.encode('$line\n')))
      .catchError((Object _) {});
  Process leader;
  try {
    leader = await Process.start(
      argv.first,
      argv.skip(1).toList(),
      workingDirectory: start['cwd'] as String,
      environment: Platform.environment,
      includeParentEnvironment: false,
    );
  } on ProcessException {
    if (lockFd != null) io.close(lockFd);
    emit
      ..add(jsonEncode({'error': 'start_failed'}))
      ..add(jsonEncode({'stopped': true}));
    await emit.close();
    await written;
    return 0;
  }
  final input = start['input'] as String?;
  if (input != null) leader.stdin.add(utf8.encode(input));
  unawaited(leader.stdin.close().catchError((Object _) {}));
  final decoder = const Utf8Decoder(allowMalformed: true);
  final streams = [
    leader.stdout
        .transform(decoder)
        .listen((text) => emit.add(jsonEncode({'out': text})))
        .asFuture<void>(),
    leader.stderr
        .transform(decoder)
        .listen((text) => emit.add(jsonEncode({'out': text})))
        .asFuture<void>(),
  ];
  var stopRequested = Completer<void>();
  unawaited(() async {
    try {
      while (await control.moveNext()) {
        if (!stopRequested.isCompleted) stopRequested.complete();
      }
    } on Object {
      // A failing control pipe counts as a lost controller.
    }
    // EOF: the controller is gone; the owned tree must not outlive it.
    if (!stopRequested.isCompleted) stopRequested.complete();
  }());
  final code = await Future.any([
    leader.exitCode,
    stopRequested.future.then((_) => null),
  ]);
  int? exitCode = code;
  if (code != null) emit.add(jsonEncode({'leader': code}));
  // The owned tree ends with its assignment, even after a successful leader.
  // Confirmation is the kernel's: once the leader is reaped, this subreaper
  // reaps adopted zombies and the tree is empty only when waitpid reports
  // that no child at all remains (a /proc scan is not an atomic snapshot).
  var stuck = -1, unseen = 0;
  while (true) {
    var remaining = await tree.stop();
    if (exitCode == null) {
      try {
        exitCode = await leader.exitCode.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        remaining = remaining == 0 ? 1 : remaining;
      }
    }
    if (exitCode != null) {
      final children = tree.reap();
      if (children == 0 && remaining == 0) break;
      if (children > 0 && remaining == 0) {
        // A child the scan did not see yet: scan again shortly. One it cannot
        // see at all (e.g. hidepid) is reported as surviving, never spun on.
        if (++unseen < 20) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          continue;
        }
        remaining = 1;
      }
    }
    if (remaining != stuck) emit.add(jsonEncode({'stuck': remaining}));
    stuck = remaining;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  // Nothing in the tree can hold the pipes any longer; a process outside it
  // that received them (e.g. over a socket) cannot delay the result.
  try {
    await Future.wait(streams).timeout(const Duration(seconds: 2));
  } on Object {
    // The final output may be incomplete; the exit code remains reliable.
  }
  // The tree is empty: release the run lock before reporting it, so the
  // controller never sees a confirmed stop while the lock is still held.
  if (lockFd != null) io.close(lockFd);
  emit
    ..add(jsonEncode({'exit': exitCode}))
    ..add(jsonEncode({'stopped': true}));
  await emit.close();
  await written;
  return 0;
}

/// The live descendants of [root] in /proc, by parent links. Zombies are dead.
final class ProcessTree {
  ProcessTree(this.root);
  final int root;
  final _io = Posix();
  static final _libc = DynamicLibrary.open('libc.so.6');
  static final _openPid = _libc
      .lookupFunction<Int Function(Int, Uint32), int Function(int, int)>(
        'pidfd_open',
      );
  static final _sendPid = _libc
      .lookupFunction<
        Int Function(Int, Int, Pointer<Void>, Uint32),
        int Function(int, int, Pointer<Void>, int)
      >('pidfd_send_signal');

  static final _waitpid = _libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Int32>, Int32),
        int Function(int, Pointer<Int32>, int)
      >('waitpid');
  static final _errno = _libc
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__errno_location',
      );

  /// Reap exited children without waiting. 0 when this process has no child
  /// left (ECHILD), otherwise 1. Call only after Dart reaped its own child:
  /// a reap of any child here would otherwise take the leader's status.
  int reap() {
    final status = calloc<Int32>();
    try {
      while (true) {
        const noHang = 1, noChild = 10;
        final pid = _waitpid(-1, status, noHang);
        if (pid > 0) continue;
        if (pid == 0) return 1;
        final error = _errno().value;
        if (error == 4) continue; // EINTR
        return error == noChild ? 0 : 1;
      }
    } finally {
      calloc.free(status);
    }
  }

  /// pid -> start time of each live (non-zombie) descendant.
  Map<int, String> members() {
    final parents = <int, List<int>>{};
    final starts = <int, String>{};
    List<FileSystemEntity> entries;
    try {
      entries = Directory('/proc').listSync(followLinks: false);
    } on FileSystemException {
      return const {};
    }
    for (final entry in entries) {
      final pid = int.tryParse(p.basename(entry.path));
      if (pid == null) continue;
      try {
        final raw = File('/proc/$pid/stat').readAsStringSync();
        final fields = raw.substring(raw.lastIndexOf(')') + 2).split(' ');
        if (fields[0] == 'Z' || fields[0] == 'X') continue;
        parents.putIfAbsent(int.parse(fields[1]), () => []).add(pid);
        starts[pid] = fields[19];
      } on Object {
        continue;
      }
    }
    final found = <int, String>{};
    final queue = [...?parents[root]];
    while (queue.isNotEmpty) {
      final pid = queue.removeLast();
      if (pid == root || found.containsKey(pid)) continue;
      found[pid] = starts[pid]!;
      queue.addAll(parents[pid] ?? const []);
    }
    return found;
  }

  void _signal(int pid, String birth, int signal) {
    final descriptor = _openPid(pid, 0);
    if (descriptor < 0) return;
    try {
      // After pidfd_open the identity is pinned; check it is still the same
      // process and still ours before signalling.
      if (processIdentity(pid)?.$3 == birth &&
          _io.lstatOwn('/proc/$pid')?.uid == _io.uid) {
        _sendPid(descriptor, signal, nullptr, 0);
      }
    } finally {
      _io.close(descriptor);
    }
  }

  /// SIGTERM, a grace period, then SIGKILL until the tree is empty or the
  /// deadline passes. Returns the number of live descendants left.
  Future<int> stop({
    Duration grace = const Duration(milliseconds: 1500),
    Duration kill = const Duration(seconds: 2),
  }) async {
    var live = members();
    if (live.isEmpty) return 0;
    live.forEach((pid, birth) => _signal(pid, birth, 15));
    final graceEnd = DateTime.now().add(grace);
    while (DateTime.now().isBefore(graceEnd)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      live = members();
      if (live.isEmpty) return 0;
      // New children forked during termination get the same request.
      live.forEach((pid, birth) => _signal(pid, birth, 15));
    }
    final killEnd = DateTime.now().add(kill);
    while (true) {
      live = members();
      if (live.isEmpty) return 0;
      if (DateTime.now().isAfter(killEnd)) return live.length;
      live.forEach((pid, birth) => _signal(pid, birth, 9));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

/// The supervisor command: the AI Project Center executable's own
/// `supervise` mode, the bundle's plugin when the feature is embedded, or the
/// Dart VM running the package's entry point in a development checkout.
List<String>? projectSupervisorCommand() {
  final executable = Platform.resolvedExecutable;
  if (p.basename(executable) == 'dart') {
    final library = Isolate.resolvePackageUriSync(
      Uri.parse('package:maprisma_core/src/features/project_supervisor.dart'),
    );
    if (library == null) return null;
    final script = p.join(
      p.dirname(p.dirname(p.dirname(p.dirname(library.toFilePath())))),
      'bin',
      'maprisma-feature.dart',
    );
    if (!File(script).existsSync()) return null;
    return [
      executable,
      '--disable-dart-dev',
      if (Platform.packageConfig != null)
        '--packages=${Uri.parse(Platform.packageConfig!).toFilePath()}',
      script,
      'supervise',
    ];
  }
  if (Platform.environment['MAPRISMA_FEATURE_PROCESS'] == 'ai-project-center') {
    return [executable, 'supervise'];
  }
  final bundled = p.join(
    appFolder(),
    'features',
    'ai-project-center',
    'plugin',
  );
  return File(bundled).existsSync() ? [bundled, 'supervise'] : null;
}

/// The controller's view of one supervised assignment. A stop that cannot be
/// confirmed fails, and a later stop asks and waits again; nothing is cached
/// except a confirmed empty tree.
final class SupervisedProjectProcess implements ProjectProcess {
  SupervisedProjectProcess._(this._process) {
    _process.stderr.drain<void>().ignore();
    _process.stdin.done.ignore();
    _events = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_event, onDone: _lost, onError: (Object _) => _lost());
    // Loss is decided by the end of its output, never by its exit alone:
    // the final "stopped" line may still be buffered when the exit arrives.
  }

  static Future<SupervisedProjectProcess> start(
    List<String> supervisor,
    List<String> argv,
    String cwd,
    Map<String, String> environment,
    String? input,
    String lock, {
    bool Function()? authorize,
  }) async {
    final process = await Process.start(
      supervisor.first,
      supervisor.skip(1).toList(),
      // The supervisor's cwd is irrelevant to the agent; it changes into cwd.
      workingDirectory: cwd,
      environment: environment,
      includeParentEnvironment: false,
    );
    final managed = SupervisedProjectProcess._(process);
    managed._send({
      'argv': argv,
      'cwd': cwd,
      'input': input,
      'lock': lock,
      'controller': {'pid': pid, 'start': processIdentity(pid)?.$3},
    });
    // The supervisor holds the run lock before the controller authorizes the
    // launch, and the controller authorizes it only while it still owns the
    // store: there is no moment without an owner.
    final locked = await Future.any([
      managed._locked.future.then((_) => true),
      managed._confirmed.future.then((_) => false),
    ]).timeout(const Duration(seconds: 30), onTimeout: () => false);
    if (!locked) {
      await managed.detach();
      throw ServiceError('project_agent_unavailable');
    }
    if (authorize != null && !authorize()) {
      // Withdraw: EOF makes the supervisor end without launching; wait
      // (bounded) for its confirmation so its run lock is released.
      managed._inputOpen = false;
      try {
        await process.stdin.close();
      } on Object {
        // Already closed.
      }
      await managed._confirmed.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
      await process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () => 0,
      );
      await managed._events.cancel();
      throw ServiceError('project_launch_withdrawn');
    }
    managed._send({'launch': true});
    return managed;
  }

  final Process _process;
  late final StreamSubscription<String> _events;
  final _output = StreamController<String>();
  int? _leader, _exit;
  final _settled = Completer<void>();
  final _confirmed = Completer<bool>();
  final _locked = Completer<void>();
  int stuck = 0;
  bool _inputOpen = true;

  void _send(Map<String, dynamic> message) {
    if (!_inputOpen) return;
    try {
      _process.stdin.writeln(jsonEncode(message));
    } on Object {
      _inputOpen = false;
    }
  }

  void _settle() {
    if (!_settled.isCompleted) _settled.complete();
  }

  void _event(String line) {
    Object? data;
    try {
      data = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (data is! Map) return;
    if (data['out'] is String) {
      if (!_output.isClosed) _output.add(data['out'] as String);
    } else if (data['locked'] == true) {
      if (!_locked.isCompleted) _locked.complete();
    } else if (data['leader'] is int) {
      _leader = data['leader'] as int;
    } else if (data['stuck'] is int) {
      stuck = data['stuck'] as int;
      // The leader ended but part of its tree survives SIGKILL: the
      // assignment result is known, its cleanup is not confirmed.
      if (_leader != null) _settle();
    } else if (data['exit'] is int) {
      _exit = data['exit'] as int;
    } else if (data['error'] is String) {
      if (!_output.isClosed) {
        _output.addError(ServiceError('project_agent_unavailable'));
      }
    } else if (data['stopped'] == true && !_confirmed.isCompleted) {
      stuck = 0;
      _confirmed.complete(true);
      _settle();
      if (!_output.isClosed) unawaited(_output.close());
    }
  }

  void _lost() {
    _inputOpen = false;
    // A supervisor that disappears without "stopped" leaves the tree
    // unconfirmed: its descendants may have re-parented elsewhere.
    if (!_confirmed.isCompleted) _confirmed.complete(false);
    _settle();
    if (!_output.isClosed) unawaited(_output.close());
  }

  @override
  Stream<String> get output => _output.stream;

  /// The leader's exit code once the supervisor confirmed an empty tree. A
  /// result whose cleanup is unconfirmed fails instead of ending normally.
  @override
  Future<int> get exitCode async {
    await _settled.future;
    if (!_confirmed.isCompleted || !await _confirmed.future) {
      throw ServiceError('project_processes_still_running');
    }
    return _exit ?? _leader ?? -1;
  }

  @override
  Future<void> stop({Duration wait = const Duration(seconds: 4)}) async {
    if (_confirmed.isCompleted) {
      if (!await _confirmed.future) {
        throw ServiceError('project_processes_still_running');
      }
      await _process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () => 0,
      );
      return;
    }
    _send({'stop': true});
    bool confirmed;
    try {
      confirmed = await _confirmed.future.timeout(wait);
    } on TimeoutException {
      throw ServiceError('project_processes_still_running');
    }
    if (!confirmed) throw ServiceError('project_processes_still_running');
    await _process.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () => 0,
    );
  }

  /// Release the control pipe: the supervisor stops its tree on EOF.
  Future<void> detach() async {
    _inputOpen = false;
    try {
      await _process.stdin.close();
    } on Object {
      // Already closed.
    }
    await _events.cancel();
  }
}
