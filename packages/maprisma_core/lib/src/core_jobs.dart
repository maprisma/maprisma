import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'core_tasks.dart';
import 'posix_ffi.dart';

/// jobs.Jobs for the core: model downloads and Ollama pulls that the app
/// ends before they do (closed, crashed, logged out) are listed at the next
/// start as interrupted, to Continue (the download goes on from its .part
/// file, Ollama resumes its own pull) or Discard. What is kept is only how to
/// start the operation again (its checked parameters, never credentials), in
/// a 0600 file of the app's own state folder.

const durableOperations = {'models.download': 'model', 'models.pull': 'pull'};
const maxJobs = 32;
const _maxFile = 256 * 1024;

final class CoreJobs {
  CoreJobs(this.path, this.tasks, this.posix) {
    for (final entry in _load()) {
      interrupted[entry['id'] as String] = entry;
    }
  }

  final String path;
  final CoreTasks tasks;
  final Posix posix;

  /// Running jobs by their task handle.
  final running = <String, Map<String, dynamic>>{};

  /// Jobs a previous run left unfinished, by their own id.
  final interrupted = <String, Map<String, dynamic>>{};
  DateTime _saved = DateTime.fromMillisecondsSinceEpoch(0);

  static String newId() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 6; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  List<Map<String, dynamic>> _load() {
    try {
      if (FileSystemEntity.isLinkSync(path)) return [];
      final file = File(path);
      if (file.lengthSync() > _maxFile) return [];
      final data = jsonDecode(file.readAsStringSync());
      final found = <Map<String, dynamic>>[];
      for (final entry in data is List ? data : const []) {
        if (entry is! Map ||
            entry['id'] is! String ||
            !RegExp(r'^[0-9a-f]{12}$').hasMatch(entry['id'] as String) ||
            !durableOperations.containsKey(entry['operation']) ||
            entry['params'] is! Map ||
            entry['title'] is! String) {
          continue;
        }
        final fraction = entry['fraction'];
        found.add({
          'id': entry['id'],
          'kind': durableOperations[entry['operation']],
          'operation': entry['operation'],
          'params': Map<String, dynamic>.from(entry['params'] as Map),
          'title': (entry['title'] as String).length > 200
              ? (entry['title'] as String).substring(0, 200)
              : entry['title'],
          'fraction': fraction is num
              ? fraction.toDouble().clamp(0.0, 1.0)
              : 0.0,
        });
      }
      return found.take(maxJobs).toList();
    } on Object {
      return [];
    }
  }

  void _save() {
    final keep = [
      for (final e in [...running.values, ...interrupted.values])
        {
          'id': e['id'],
          'operation': e['operation'],
          'params': e['params'],
          'title': e['title'],
          'fraction': ((e['fraction'] as num) * 10000).round() / 10000,
        },
    ].take(maxJobs).toList();
    try {
      if (keep.isEmpty) {
        if (File(path).existsSync()) File(path).deleteSync();
      } else {
        posix.atomicWrite(path, utf8.encode(jsonEncode(keep)));
      }
      _saved = DateTime.now();
    } on Object {
      // Not kept: the job still runs; only a restart would not list it.
    }
  }

  /// A durable operation just started as task [task].
  void record(
    String task,
    String operation,
    Map<String, dynamic> params,
    String title, {
    String? replaces,
  }) {
    final kind = durableOperations[operation];
    if (kind == null) return;
    if (replaces != null) interrupted.remove(replaces);
    running[task] = {
      'id': newId(),
      'kind': kind,
      'operation': operation,
      'params': params,
      'title': title,
      'fraction': 0.0,
    };
    _save();
  }

  /// Ended tasks leave the file; the progress is kept now and then.
  void sync() {
    var changed = false;
    for (final ident in running.keys.toList()) {
      final task = tasks.items[ident];
      if (task == null || task.state != 'running') {
        running.remove(ident);
        changed = true;
      } else {
        running[ident]!['fraction'] = task.fraction.clamp(0.0, 1.0);
      }
    }
    if (changed || DateTime.now().difference(_saved).inSeconds >= 10) _save();
  }

  /// The jobs for the app: running ones by their task, interrupted ones.
  List<Map<String, dynamic>> list() {
    sync();
    return [
      for (final e in running.entries)
        {
          'id': e.value['id'],
          'task': e.key,
          'kind': e.value['kind'],
          'title': e.value['title'],
          'state': 'running',
          'fraction': tasks.items[e.key]?.fraction ?? 0.0,
          'text': tasks.items[e.key]?.text ?? '',
        },
      for (final e in interrupted.values)
        {
          'id': e['id'],
          'kind': e['kind'],
          'title': e['title'],
          'state': 'interrupted',
          'fraction': e['fraction'],
        },
    ];
  }

  Map<String, dynamic> take(dynamic id) {
    final entry = id is String ? interrupted[id] : null;
    if (entry == null) throw const FormatException('Unknown interrupted job');
    return entry;
  }

  void discard(dynamic id) {
    take(id);
    interrupted.remove(id);
    _save();
  }
}
