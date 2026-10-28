import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'connect_apply.dart';
import 'posix_ffi.dart';
import 'identity.dart';
import 'provider_ops.dart';
import 'provider_scans.dart';
import 'scan_files.dart';
import 'py_values.dart';

/// Python flutter_plan_wire: the private plan between backend and worker.
const planMaxBytes = 24 * 1024 * 1024;

(Plan, String) decodePlan(List<int> body) {
  if (body.length > planMaxBytes) {
    throw const FormatException('Private plan too large');
  }
  final data = jsonDecode(utf8.decode(body));
  if (data is! Map || data['version'] is! int) {
    throw const FormatException('Invalid private plan');
  }
  final version = data['version'] as int;
  final fields = {
    'version', 'backup_root', 'agent', 'runtime', 'provider', 'changes', //
    'contexts',
    if (version == 2 || version == 3) ...['links_add', 'links_remove'],
    if (version == 3) 'model_actions',
  };
  if (![1, 2, 3].contains(version) ||
      data.keys.toSet().length != fields.length ||
      !data.keys.every(fields.contains)) {
    throw const FormatException('Invalid private plan');
  }
  final root = data['backup_root'];
  if (root is! String || !p.isAbsolute(root)) {
    throw const FormatException('Expected an absolute backup root');
  }
  final changes = <Change>[];
  for (final change in data['changes'] as List) {
    final path = change['path'], old = change['old'], next = change['new'];
    if (path is! String ||
        !p.isAbsolute(path) ||
        old is! String ||
        next is! String) {
      throw const FormatException('Invalid configuration change');
    }
    changes.add(Change(path, old, next));
  }
  final contexts = <Map<String, dynamic>>[];
  for (final entry in data['contexts'] as List) {
    final tokens = entry['tokens'];
    if (tokens is! int || tokens <= 0 || entry['model'] is! String) {
      throw const FormatException('Invalid model context');
    }
    contexts.add(Map<String, dynamic>.from(entry as Map));
  }
  List<(String, String)> links(String key) {
    final entries = data[key] ?? [];
    if (entries is! List || entries.length > 200) {
      throw const FormatException('Too many skill links');
    }
    return [
      for (final entry in entries)
        () {
          if (entry is! List ||
              entry.length != 2 ||
              entry.any(
                (v) =>
                    v is! String ||
                    v.isEmpty ||
                    v.length > 4096 ||
                    v.contains('\x00'),
              )) {
            throw const FormatException('Invalid skill link');
          }
          final link = entry[0] as String, target = entry[1] as String;
          if (!p.isAbsolute(link) ||
              key == 'links_add' && !p.isAbsolute(target)) {
            throw const FormatException('Expected absolute skill paths');
          }
          return (link, target);
        }(),
    ];
  }

  final actions = data['model_actions'] ?? [];
  if (actions is! List || actions.length > 2) {
    throw const FormatException('Invalid model actions');
  }
  for (final action in actions) {
    if (action is! Map ||
        action.keys.toSet().length != 4 ||
        !const {
          'operation',
          'key',
          'model',
          'agents',
        }.containsAll(action.keys) ||
        !const {'model.load', 'model.unload'}.contains(action['operation']) ||
        ['key', 'model'].any(
          (k) =>
              action[k] is! String ||
              (action[k] as String).isEmpty ||
              (action[k] as String).length > 4096,
        ) ||
        action['agents'] is! List ||
        (action['agents'] as List).length > 32 ||
        (action['agents'] as List).any(
          (c) => c is! String || c.isEmpty || c.length > 128,
        ) ||
        (action['agents'] as List).toSet().length !=
            (action['agents'] as List).length) {
      throw const FormatException('Invalid model action');
    }
  }
  for (final key in ['agent', 'runtime', 'provider']) {
    if (data[key] is! String) {
      throw const FormatException('Invalid private plan');
    }
  }
  return (
    Plan(
      pyStr(data['agent']),
      pyStr(data['runtime']),
      pyStr(data['provider']),
      changes: changes,
      linksAdd: links('links_add'),
      linksRemove: links('links_remove'),
      contexts: contexts,
      modelActions: [
        for (final a in actions) Map<String, dynamic>.from(a as Map),
      ],
    ),
    root,
  );
}

/// flutter_worker connections.apply: check skill sources, back up and write.
/// Context sizes and model load/unload need the provider engines (phase 4):
/// such a plan is refused before anything is written.
Map<String, dynamic> applyPlan(List<int> body, Posix posix, String home) {
  final (plan, root) = decodePlan(body);
  if (plan.contexts.isNotEmpty || plan.modelActions.isNotEmpty) {
    throw UnsupportedError('Provider operations are not in the core yet');
  }
  for (final (_, target) in plan.linksAdd) {
    if (!Directory(target).existsSync() ||
        !File(p.join(target, 'SKILL.md')).existsSync()) {
      throw StateError('Skill source changed; review again');
    }
  }
  final backup = ConfigFiles(posix, home).apply(plan, root);
  return {'backup': backup, 'context_failures': 0};
}

/// The worker process: one request line, the plan from an inherited private
/// file (--plan-fd N, as the Python backend passes it) or length-prefixed on
/// stdin (--plan-stdin, as the Dart core passes it). One result line.
Future<int> runWorker(List<String> args) async {
  void send(Map<String, dynamic> message) =>
      stdout.writeln(pyJsonDumps(message));
  try {
    final input = BytesBuilder(copy: false);
    await for (final chunk in stdin) {
      input.add(chunk);
      if (input.length > planMaxBytes + 128 * 1024) {
        throw const FormatException('Request too large');
      }
    }
    final bytes = input.takeBytes();
    final newline = bytes.indexOf(10);
    if (newline < 0 || newline > 64 * 1024) {
      throw const FormatException('Invalid worker request');
    }
    final request = jsonDecode(utf8.decode(bytes.sublist(0, newline)));
    if (request is! Map ||
        request.keys.toSet().length != 2 ||
        !request.containsKey('operation') ||
        !request.containsKey('params') ||
        request['params'] is! Map) {
      throw const FormatException('Invalid worker request');
    }
    // A provider operation: no private plan, its parameters checked again here.
    if (args.isEmpty && ProviderOps.shapes.containsKey(request['operation'])) {
      final identity = AppIdentity();
      final files = ScanFiles(identity);
      final ops = ProviderOps(files, ProviderScans(files));
      send({
        'type': 'result',
        'result': await ops.execute(
          request['operation'] as String,
          request['params'] as Map,
        ),
      });
      return 0;
    }
    if (request['operation'] != 'connections.apply' ||
        (request['params'] as Map).isNotEmpty) {
      throw const FormatException('Invalid private operation');
    }
    final posix = Posix();
    List<int> body;
    if (args.length == 2 && args[0] == '--plan-fd') {
      final fd = int.parse(args[1]);
      final info = posix.stat(fd);
      if (info.mode & 0xf000 != 0x8000 ||
          info.uid != posix.uid ||
          info.mode & 0x3f != 0) {
        throw const FormatException('Expected a private plan file');
      }
      body = posix.readAt(fd, 0, planMaxBytes + 1);
    } else if (args.length == 1 && args[0] == '--plan-stdin') {
      final rest = bytes.sublist(newline + 1);
      final space = rest.indexOf(10);
      final length = space < 0
          ? -1
          : int.tryParse(utf8.decode(rest.sublist(0, space))) ?? -1;
      if (length < 0 ||
          length > planMaxBytes ||
          rest.length - space - 1 != length) {
        throw const FormatException('Invalid private plan');
      }
      body = rest.sublist(space + 1);
    } else {
      throw const FormatException('Invalid worker arguments');
    }
    send({
      'type': 'result',
      'result': applyPlan(body, posix, Platform.environment['HOME'] ?? ''),
    });
    return 0;
  } catch (_) {
    send({'type': 'error', 'code': 'operation_failed'});
    return 0;
  }
}
