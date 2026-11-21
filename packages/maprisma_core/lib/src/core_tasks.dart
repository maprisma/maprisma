import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'connect_apply.dart';
import 'line_diff.dart';
import 'protocol.dart' show ServiceError;

/// Handles this core made start with this prefix, so a Devel router can send
/// apply, Undo and task requests to the side that knows them.
const coreHandle = 'core-';
String newHandle() {
  final random = Random.secure();
  final token = List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  // The oldest handle no store keeps makes room. One a store keeps routes
  // however old it is; when every handle is kept, refuse rather than break a
  // live one.
  if (!_issued.contains(token) && !_makeRoom()) {
    throw ServiceError('too_many_handles');
  }
  _issued.add(token);
  _unheld
    ..remove(token)
    ..add(token);
  return coreHandle + token;
}

/// Forgets the oldest unkept handles until one more fits; false when every
/// handle is kept.
bool _makeRoom() {
  while (_issued.length >= maxIssuedHandles) {
    if (_unheld.isEmpty) return false;
    final oldest = _unheld.first;
    _unheld.remove(oldest);
    _issued.remove(oldest);
    _noteReleased([oldest]);
  }
  return true;
}

/// Tokens this process issued and that still count: kept by a store, or not
/// yet forgotten. Some routes return the bare 32-hex token without the
/// prefix; provenance, not the shape, decides that a string is a handle. A
/// handle its last store lets go of stops counting at once (a cached result
/// that still names it does not revive it); one no store took is forgotten,
/// oldest first, past [maxIssuedHandles].
const maxIssuedHandles = 65536;
final _issued = <String>{};

/// Issued tokens no store keeps, oldest first (the ones to forget first).
final _unheld = <String>{};

/// Bare tokens the stores keep, with how many stores keep each.
final _held = <String, int>{};

/// Recently released tokens: a store that moves a handle to another store
/// (releasing it before it holds it again) keeps its provenance.
final _retired = <String>{};

String? _bareToken(String key) {
  final token = key.startsWith(coreHandle)
      ? key.substring(coreHandle.length)
      : key;
  return token.length == 32 ? token : null;
}

/// Whether a store still keeps [value] (with or without the prefix).
bool heldHandle(String value) => _held.containsKey(_bareToken(value));

/// How many handles count now (tests only).
int get issuedHandleCountForTest => _issued.length;

/// Forgets every handle (tests only: the registry is per process).
void resetHandlesForTest() {
  _issued.clear();
  _unheld.clear();
  _held.clear();
  _retired.clear();
  _released.clear();
}

/// A feature backend reports the handles it released, so its host stops
/// routing them (set by the feature worker).
bool recordReleasedHandles = false;

/// Released, not yet reported; in order, each once. A handle held again
/// before it is reported is taken off (it was moved, not let go).
final _released = <String>{};

void _noteReleased(Iterable<String> tokens) {
  if (!recordReleasedHandles) return;
  _released.addAll(tokens);
  // Bounded: beyond this the host falls back to its own memory bound.
  while (_released.length > 2 * maxIssuedHandles) {
    _released.remove(_released.first);
  }
}

/// Up to [max] released tokens, oldest first, taken off the list.
List<String> takeReleasedHandles([int max = 4096]) {
  final taken = _released.take(max).toList();
  _released.removeAll(taken);
  return taken;
}

/// A store's map of handles. While a key is in it, the handle stays known
/// (it is never forgotten for age); removing it, by expiry, a bound or use,
/// releases it.
final class HandleMap<V> extends MapBase<String, V> {
  final _map = <String, V>{};

  @override
  V? operator [](Object? key) => _map[key];

  @override
  void operator []=(String key, V value) {
    if (!_map.containsKey(key)) _hold(key);
    _map[key] = value;
  }

  @override
  V? remove(Object? key) {
    if (!_map.containsKey(key)) return null;
    final value = _map.remove(key);
    _release(key as String);
    return value;
  }

  @override
  void clear() {
    for (final key in _map.keys.toList()) {
      remove(key);
    }
  }

  @override
  Iterable<String> get keys => _map.keys;

  @override
  bool containsKey(Object? key) => _map.containsKey(key);

  @override
  int get length => _map.length;

  static void _hold(String key) {
    final token = _bareToken(key);
    if (token == null) return;
    // Moved to another store: it counts again, within the bound. All or
    // nothing: without room the store does not take it.
    if (_retired.contains(token) && !_issued.contains(token)) {
      if (!_makeRoom()) throw ServiceError('too_many_handles');
      _retired.remove(token);
      _issued.add(token);
    }
    _held[token] = (_held[token] ?? 0) + 1;
    _unheld.remove(token);
    // Only a handle that counts again was not let go after all.
    if (_issued.contains(token)) _released.remove(token);
  }

  static void _release(String key) {
    final token = _bareToken(key);
    if (token == null) return;
    final count = (_held[token] ?? 1) - 1;
    if (count > 0) {
      _held[token] = count;
      return;
    }
    _held.remove(token);
    if (_issued.remove(token)) {
      _retired.add(token);
      if (_retired.length > 4096) _retired.remove(_retired.first);
      _noteReleased([token]);
    }
  }
}

/// Whether [value] (with or without the `core-` prefix) was issued here.
bool issuedHandle(String value) {
  final token = value.startsWith(coreHandle)
      ? value.substring(coreHandle.length)
      : value;
  return token.length == 32 && _issued.contains(token);
}

/// The strings in [value] that this process issued as handles.
Set<String> issuedHandlesIn(Object? value) {
  final found = <String>{};
  void visit(Object? item) {
    if (item is String) {
      if (issuedHandle(item)) found.add(item);
    } else if (item is Map) {
      item.values.forEach(visit);
    } else if (item is List) {
      item.forEach(visit);
    }
  }

  visit(value);
  return found;
}

/// The worker this core starts: the AOT executable itself, the Dart VM
/// running bin/maprisma-core.dart, or the bundle's helper (maprisma-core)
/// next to the app.
List<String> defaultWorkerCommand(Map<String, String> environment) {
  final explicit = environment['MAPRISMA_CORE_WORKER'];
  if (explicit != null && explicit.isNotEmpty) return [explicit, 'worker'];
  final executable = Platform.resolvedExecutable;
  if (p.basename(executable) == 'dart') {
    final script = Platform.script.toFilePath();
    return [
      executable,
      '--disable-dart-dev',
      if (Platform.packageConfig != null)
        '--packages=${Uri.parse(Platform.packageConfig!).toFilePath()}',
      p.join(p.dirname(script), 'maprisma-core.dart'),
      'worker',
    ];
  }
  if (p.basename(executable) == 'maprisma-core') return [executable, 'worker'];
  return [p.join(p.dirname(executable), 'lib', 'maprisma-core'), 'worker'];
}

final class CoreTask {
  CoreTask(this.operation, this.finalize);
  final String operation;
  final Map<String, dynamic> Function(Map<String, dynamic>)? finalize;
  String state = 'running', text = '';
  double fraction = 0;
  Map<String, dynamic> result = {};
  Process? process;
  Future<void>? completion;
}

/// Python flutter_tasks.Tasks for the operations this core runs: a worker
/// process per commit, its progress and result lines, commits never cancelled.
final class CoreTasks {
  CoreTasks(this.workerCommand);
  final List<String> workerCommand;
  final items = HandleMap<CoreTask>();
  static const maxFrame = 1024 * 1024,
      commits = {
        'connections.apply',
        'providers.restart',
        'providers.reload_model',
        'models.remove',
        'addons.install',
        'installers.install',
      };

  /// A provider operation in its own worker (flutter_tasks.Tasks.start).
  Map<String, dynamic> start(
    String operation,
    Map<String, dynamic> params, [
    Map<String, dynamic> Function(Map<String, dynamic>)? finalize,
  ]) {
    final ident = _slot(operation, finalize);
    items[ident]!.completion = _run(
      items[ident]!,
      null,
      request: {'operation': operation, 'params': params},
    );
    return {'task': ident};
  }

  String _slot(
    String operation,
    Map<String, dynamic> Function(Map<String, dynamic>)? finalize,
  ) {
    final active = items.values.where((t) => t.state == 'running').length;
    if (active >= 4) throw const FormatException('Too many active operations');
    while (items.length >= 32) {
      final done = items.entries.where((e) => e.value.state != 'running');
      if (done.isEmpty) throw const FormatException('Too many operations');
      items.remove(done.first.key);
    }
    final ident = newHandle();
    items[ident] = CoreTask(operation, finalize);
    return ident;
  }

  Map<String, dynamic> startPlan(
    List<int> body,
    Map<String, dynamic> Function(Map<String, dynamic>) finalize,
  ) => startPrivate('connections.apply', body, finalize);

  /// Immediately available map facts use the same task/status contract as a helper.
  Map<String, dynamic> completed(
    String operation,
    Map<String, dynamic> result,
  ) {
    final id = _slot(operation, null);
    items[id]!
      ..state = 'done'
      ..result = result;
    return {'task': id};
  }

  /// A private operation: its body on the worker's stdin, never in argv
  /// (flutter_tasks._private).
  Map<String, dynamic> startPrivate(
    String operation,
    List<int> body, [
    Map<String, dynamic> Function(Map<String, dynamic>)? finalize,
  ]) {
    final ident = _slot(operation, finalize);
    items[ident]!.completion = _run(items[ident]!, body);
    return {'task': ident};
  }

  Future<void> _run(
    CoreTask task,
    List<int>? body, {
    Map<String, dynamic>? request,
  }) async {
    try {
      final process = await Process.start(workerCommand.first, [
        ...workerCommand.skip(1),
        if (body != null) '--plan-stdin',
      ]);
      task.process = process;
      if (task.state == 'stopped') {
        _stop(process); // cancelled while starting
        await process.exitCode;
        return;
      }
      process.stderr.drain<void>();
      if (body != null) {
        process.stdin
          ..add(
            utf8.encode(
              '{"operation": ${jsonEncode(task.operation)}, "params": {}}\n',
            ),
          )
          ..add(utf8.encode('${body.length}\n'))
          ..add(body);
      } else {
        process.stdin.add(utf8.encode('${jsonEncode(request)}\n'));
      }
      await process.stdin.close();
      final buffer = <int>[];
      await for (final chunk in process.stdout) {
        buffer.addAll(chunk);
        if (buffer.length > maxFrame) {
          task.state = 'failed';
          process.kill();
          break;
        }
        int newline;
        while ((newline = buffer.indexOf(10)) >= 0) {
          final line = utf8.decode(buffer.sublist(0, newline));
          buffer.removeRange(0, newline + 1);
          _message(task, line);
        }
      }
      await process.exitCode;
    } catch (_) {
      if (task.state == 'running') task.state = 'failed';
    }
    if (task.state == 'running') task.state = 'failed';
  }

  void _message(CoreTask task, String line) {
    if (task.state != 'running') return;
    try {
      final message = jsonDecode(line);
      if (message['type'] == 'progress') {
        task.fraction = (message['fraction'] as num).toDouble();
        task.text = '${message['text'] ?? ''}';
        if (task.text.length > 300) task.text = task.text.substring(0, 300);
      } else if (message['type'] == 'result' && message['result'] is Map) {
        final result = Map<String, dynamic>.from(message['result'] as Map);
        task.result = task.finalize == null ? result : task.finalize!(result);
        task.state = 'done';
      } else {
        task.state = 'failed';
      }
    } catch (_) {
      task.state = 'failed';
    }
  }

  Map<String, dynamic> status(String ident) {
    final task = items[ident];
    if (task == null) throw const FormatException('Unknown operation handle');
    return {
      'task': ident,
      'operation': task.operation,
      'state': task.state,
      'fraction': task.fraction,
      'text': task.text,
      'result': task.result,
    };
  }

  Map<String, dynamic> cancel(String ident) {
    final task = items[ident];
    if (task == null) throw const FormatException('Unknown operation handle');
    if (task.state == 'running' && commits.contains(task.operation)) {
      throw const FormatException('A commit cannot be cancelled');
    }
    if (task.state == 'running') {
      task.state = 'stopped';
      final process = task.process;
      if (process != null) _stop(process);
    }
    return status(ident);
  }

  /// flutter_tasks._close: SIGTERM, which ends an agent's run too (runLookUp),
  /// then SIGKILL for a worker that does not go.
  void _stop(Process process) {
    process.kill();
    Future<void>.delayed(
      const Duration(milliseconds: 500),
      () => process.kill(ProcessSignal.sigkill),
    );
  }
}

/// Python flutter_connections.Connections: reviewed plans behind opaque,
/// expiring handles, applied by the worker, undone by token.
final class CoreConnections {
  CoreConnections(
    this.files,
    this.tasks,
    this.backupRoot, {
    void Function()? daemonReload,
  }) : daemonReload = daemonReload ?? reloadUserUnits;
  final void Function() daemonReload;
  final ConfigFiles files;
  final CoreTasks tasks;
  final String backupRoot;
  final _plans = HandleMap<(DateTime, Plan)>();
  final _undos = HandleMap<String>();
  final _undoChoices = <String, List<(String, String?, String?)>>{};
  static const lifetime = Duration(minutes: 10);

  /// Settings › provider_models for a plan's [Plan.choices]: the model a
  /// local LLM uses now, and a change of it, made only from [from]
  /// (FormatException when another change came first).
  String? Function(String provider)? chosenModel;
  void Function(String provider, String? from, String? to)? chooseModel;

  Map<String, dynamic> keep(Plan plan) {
    for (final links in [plan.linksAdd, plan.linksRemove]) {
      final unique = <String, String>{};
      for (final (link, target) in links) {
        if (unique.containsKey(link) && unique[link] != target) {
          throw const FormatException('Conflicting skill names');
        }
        unique[link] = target;
      }
      if (unique.length > 200) {
        throw const FormatException(
          'Too many skill links; select fewer agents or skills',
        );
      }
      links
        ..clear()
        ..addAll([for (final e in unique.entries) (e.key, e.value)]);
    }
    final size = plan.changes.fold<int>(
      0,
      (sum, c) => sum + utf8.encode(c.old).length + utf8.encode(c.next).length,
    );
    if (size > 8 * 1024 * 1024) {
      throw const FormatException('Connection preview too large');
    }
    final now = DateTime.now();
    _plans.removeWhere((_, value) => now.difference(value.$1) >= lifetime);
    while (_plans.length >= 8) {
      _plans.remove(_plans.keys.first);
    }
    final ident = newHandle();
    _plans[ident] = (now, plan);
    return {
      'plan': ident,
      'empty': plan.empty && plan.contexts.isEmpty,
      'files': [
        for (final change in plan.changes)
          () {
            final (added, removed) = lineChanges(change.old, change.next);
            return {
              'path': files.tilde(change.path),
              'added': added,
              'removed': removed,
            };
          }(),
      ],
      'contexts': [
        for (final c in plan.contexts)
          {
            'provider': (c['runtime'] as Map)['name'],
            'model': c['model'],
            'tokens': c['tokens'],
          },
      ],
      // Only this core's own plans add files (a skill from the web).
      if (plan.filesAdd.isNotEmpty || plan.filesStaged.isNotEmpty)
        'new_files': [
          for (final (path, _, _) in plan.filesAdd) files.tilde(path),
          for (final (path, _, _, _) in plan.filesStaged) files.tilde(path),
        ],
      'links_add': [
        for (final (l, t) in plan.linksAdd) [files.tilde(l), files.tilde(t)],
      ],
      'links_remove': [
        for (final (l, t) in plan.linksRemove) [files.tilde(l), files.tilde(t)],
      ],
      // Only an app update moves its old folders into the backup.
      if (plan.retire.isNotEmpty)
        'retire': [for (final path in plan.retire) files.tilde(path)],
    };
  }

  /// The plan behind a preview handle, taken out (repair adds to it).
  Plan take(String ident) {
    final kept = _plans.remove(ident);
    if (kept == null) throw const FormatException('Unknown connection preview');
    return kept.$2;
  }

  Map<String, dynamic> apply(String ident) {
    final kept = _plans[ident];
    if (kept == null) throw const FormatException('Unknown connection preview');
    final (created, plan) = kept;
    if (DateTime.now().difference(created) >= lifetime) {
      throw const FormatException('Connection preview expired');
    }
    if (plan.empty && plan.contexts.isEmpty && plan.modelActions.isEmpty) {
      _plans.remove(ident);
      return {'ok': true, 'undo': null};
    }
    for (final (provider, from, _) in plan.choices) {
      if (chosenModel?.call(provider) != from) {
        throw const FormatException('Model choice changed; refresh');
      }
    }
    final result = tasks.startPlan(
      encodePlan(plan, backupRoot),
      (done) => registerBackup(done, plan.choices),
    );
    _plans.remove(ident);
    return result;
  }

  Map<String, dynamic> registerBackup(
    Map<String, dynamic> result, [
    List<(String, String?, String?)> choices = const [],
  ]) {
    final keys = result.keys.toSet();
    if (!keys.contains('backup') ||
        !keys.every(
          const {'backup', 'context_failures', 'reload_failed'}.contains,
        ) ||
        result['backup'] is! String ||
        result['reload_failed'] != null && result['reload_failed'] is! bool) {
      throw const FormatException('Invalid private result');
    }
    final failures = result['context_failures'] ?? 0;
    if (failures is! int || failures < 0) {
      throw const FormatException('Invalid context result');
    }
    final backup = result['backup'] as String;
    if (FileSystemEntity.typeSync(backup, followLinks: false) !=
            FileSystemEntityType.directory ||
        Directory(p.dirname(backup)).resolveSymbolicLinksSync() !=
            Directory(backupRoot).resolveSymbolicLinksSync()) {
      throw const FormatException('Backup outside connection storage');
    }
    final token = newHandle();
    while (_undos.length >= 16) {
      _undoChoices.remove(_undos.keys.first);
      _undos.remove(_undos.keys.first);
    }
    _undos[token] = backup;
    // The files are written: the local LLM's own model follows, unless
    // something else changed it meanwhile or it cannot be saved. Either is
    // said in the result (choice_failures); the Undo of the files stays.
    final made = [
      for (final (provider, from, to) in choices)
        if (_choose(provider, from, to)) (provider, from, to),
    ];
    if (made.isNotEmpty) _undoChoices[token] = made;
    return {
      'ok': true,
      'undo': token,
      'context_failures': failures,
      'choice_failures': choices.length - made.length,
      if (result['reload_failed'] == true) 'reload_failed': true,
    };
  }

  /// A provider choice moved from [from] to [to]; false when another change
  /// came first or the settings could not be saved.
  bool _choose(String provider, String? from, String? to) {
    final write = chooseModel;
    if (write == null) return false;
    try {
      write(provider, from, to);
      return true;
    } on Exception {
      return false;
    }
  }

  Map<String, dynamic> undo(String token) {
    final folder = _undos[token];
    if (folder == null) throw const FormatException('Unknown Undo handle');
    final skipped = <String>[];
    final restored = files.undo(folder, skipped: skipped);
    var reloadFailed = false;
    if (changesUserUnits(restored)) {
      try {
        daemonReload();
      } on Object {
        reloadFailed = true;
      }
    }
    // With its files, the local LLM's own model it moved, if still so; only
    // when all of them came back: an agent file changed since stays on the
    // new model, so its provider does too (choice_failures says so).
    final choices = _undoChoices[token] ?? const [];
    var kept = choices.length;
    if (restored.isNotEmpty) {
      _undos.remove(token);
      _undoChoices.remove(token);
      if (skipped.isEmpty) {
        kept = 0;
        for (final (provider, from, to) in choices) {
          if (!_choose(provider, to, from)) kept++;
        }
      }
    }
    return {
      'ok': true,
      'restored': [for (final path in restored) files.tilde(path)],
      'choice_failures': kept,
      if (reloadFailed) 'reload_failed': true,
    };
  }
}

/// flutter_plan_wire.encode (version 3) for this core's own plans.
List<int> encodePlan(Plan plan, String backupRoot) {
  final body = utf8.encode(
    jsonEncode({
      'version': 3,
      'model_actions': plan.modelActions,
      'backup_root': backupRoot,
      'agent': plan.agent,
      'runtime': plan.runtime,
      'provider': plan.provider,
      'links_add': [
        for (final (l, t) in plan.linksAdd) [l, t],
      ],
      'links_remove': [
        for (final (l, t) in plan.linksRemove) [l, t],
      ],
      'changes': [
        for (final c in plan.changes)
          {'path': c.path, 'old': c.old, 'new': c.next},
      ],
      'contexts': plan.contexts,
      if (plan.retire.isNotEmpty) 'retire': plan.retire,
      if (plan.filesStaged.isNotEmpty)
        'files_staged': [
          for (final (path, staged, digest, executable) in plan.filesStaged)
            [path, staged, digest, executable],
        ],
    }),
  );
  if (body.length > 24 * 1024 * 1024) {
    throw const FormatException('Private plan too large');
  }
  return body;
}

/// The handle field of the routes that only the side that made it can serve.
const handleRoutes = {
  'connections.apply': 'plan',
  'connections.undo': 'undo',
  'tasks.status': 'task',
  'tasks.cancel': 'task',
  'sessions.read': 'session',
  'sessions.write': 'session',
  'sessions.resize': 'session',
  'sessions.stop': 'session',
};

/// Dispatch of a handle route inside the core (the router checked the prefix).
Map<String, dynamic> dispatchHandle(
  String method,
  Map<String, dynamic> params,
  CoreConnections connections,
  CoreTasks tasks,
) {
  final field = handleRoutes[method]!;
  if (params.length != 1 || params[field] is! String) {
    throw const FormatException('Invalid handle request');
  }
  final value = params[field] as String;
  return switch (method) {
    'connections.apply' => connections.apply(value),
    'connections.undo' => connections.undo(value),
    'tasks.status' => tasks.status(value),
    _ => tasks.cancel(value),
  };
}

/// flutter_task_focus.resolve: the map's node ids a task concerns (never scans).
List<String> taskFocus(
  Map<String, dynamic> graph,
  Map<String, dynamic> params,
) {
  final nodes = graph['nodes'] as List? ?? [];
  final known = {for (final n in nodes) n['id']};
  final candidates = <String>{};
  final command = params['command'];
  if (command is String) candidates.add('agent:$command');
  var key = params['key'] ?? params['runtime'];
  if (key is String) candidates.add('runtime:$key');
  final kind = params['kind'], item = params['item'];
  if (item is String && const {'mcp', 'skills', 'provider'}.contains(kind)) {
    candidates.add('${kind == 'provider' ? 'runtime' : kind}:$item');
    if (kind == 'provider') key = item;
  }
  final model = params['model'];
  if (key is String && model is String && model.isNotEmpty) {
    candidates.add('model:runtime:$key:${model.toLowerCase()}');
  }
  return [
    for (final n in nodes)
      if (candidates.contains(n['id']) && known.contains(n['id']))
        n['id'] as String,
  ];
}

/// Map edits this core builds. The model previews fall back to the reference
/// (Devel) when the core answers unported_route: an add-on agent's own model
/// switcher (its hooks, phase 5).
const coreMapEdits = {'connections.move_preview', 'connections.author_preview'};
const coreFirstRoutes = {
  'connections.repair_preview',
  'models.switch_preview',
  'models.attach_preview',
};

/// providers.run operations this core runs.
bool coreProviderRun(Map<String, dynamic> params) => const {
  'runtime.start',
  'runtime.stop',
  'model.load',
  'model.unload',
  'models.search',
  'models.files',
  'models.pull',
  'models.download',
  'model.import',
}.contains(params['operation']);

/// The connection kinds whose previews this core builds (the others stay with
/// the Python reference until their phase).
const corePreviewKinds = {'skills', 'mcp', 'provider'};

/// Whether this core builds the preview.
bool corePreview(Map<String, dynamic> params) =>
    corePreviewKinds.contains(params['kind']);
