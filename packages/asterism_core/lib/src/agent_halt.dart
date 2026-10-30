import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'agent_catalog.dart';
import 'core_tasks.dart';
import 'posix_ffi.dart';
import 'provider_scans.dart';
import 'pty_sessions.dart';

/// agent_terminals: this account's processes, read from /proc.
const _ticks = 100; // SC_CLK_TCK on Linux

List<String>? _statFields(int pid, Posix posix) {
  if (posix.lstatFull('/proc/$pid', follow: true)?.uid != posix.uid) {
    return null;
  }
  try {
    final file = File('/proc/$pid/stat').openSync();
    try {
      final stat = utf8.decode(file.readSync(4096), allowMalformed: true);
      return stat.substring(stat.lastIndexOf(')') + 2).split(RegExp(r'\s+'));
    } finally {
      file.closeSync();
    }
  } catch (_) {
    return null;
  }
}

int parentOf(int pid, Posix posix) {
  final fields = _statFields(pid, posix);
  return fields == null || fields.length < 2 ? 0 : int.tryParse(fields[1]) ?? 0;
}

/// ancestors: its parents, nearest first (to init or another account's).
List<int> ancestors(int pid, Posix posix) {
  final found = <int>[];
  for (var step = 0; step < 32; step++) {
    pid = parentOf(pid, posix);
    if (pid <= 1) break;
    found.add(pid);
  }
  return found;
}

/// started: when it was started (seconds since the epoch), 0 unknown.
double startedAt(int pid, Posix posix) {
  final fields = _statFields(pid, posix);
  if (fields == null || fields.length < 20) return 0.0;
  try {
    final boot = const LineSplitter()
        .convert(File('/proc/stat').readAsStringSync())
        .firstWhere((l) => l.startsWith('btime '))
        .split(RegExp(r'\s+'))[1];
    return int.parse(boot) + int.parse(fields[19]) / _ticks;
  } catch (_) {
    return 0.0;
  }
}

String cwdOf(int pid, Posix posix) {
  if (posix.lstatFull('/proc/$pid', follow: true)?.uid != posix.uid) return '';
  try {
    return Link('/proc/$pid/cwd').targetSync();
  } on FileSystemException {
    return '';
  }
}

/// alive: this account's process runs and is still the one started then.
bool aliveSince(int pid, double since, Posix posix) {
  final fields = _statFields(pid, posix);
  if (fields == null || fields.isEmpty || fields[0] == 'Z') return false;
  return since == 0 || (startedAt(pid, posix) - since).abs() < 0.5 / _ticks;
}

/// agent_terminals.stop: SIGTERM, SIGKILL after 3 s; only while it is still
/// the one shown (its start time to the tick), always through a pidfd held
/// before that check. True when it is gone.
Future<bool> stopInstance(int pid, double since, Posix posix) async {
  if (pid <= 1 || since == 0) return false;
  final handle = posix.pidfdOpen(pid);
  if (handle < 0) return false;
  try {
    if (!aliveSince(pid, since, posix)) return false;
    posix.pidfdSignal(handle, 15);
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      if (!aliveSince(pid, since, posix)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (aliveSince(pid, since, posix)) {
      posix.pidfdSignal(handle, 9);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return !aliveSince(pid, since, posix);
  } finally {
    posix.close(handle);
  }
}

/// provider_watch.agent_instances with pids: name -> its open instances'
/// process ids (background servers and the app's own look-ups left out).
Map<String, List<int>> agentInstancePids(
  ProviderScans scans,
  Set<String> names,
) {
  String bare(String v) =>
      v.endsWith('.exe') ? v.substring(0, v.length - 4) : v;
  bool interpreter(String v) =>
      const ['node', 'bun', 'deno', 'python', 'python3'].any(v.startsWith);
  const background = {'serve', 'server', 'daemon', '--service', '--daemon'};
  final found = <String, List<int>>{};
  for (final process in scans.processes()) {
    final comm = bare(process.comm), argv = process.argv;
    if (!names.contains(comm) && !interpreter(comm) && comm.length < 15 ||
        argv.isEmpty) {
      continue;
    }
    var name = bare(p.basename(argv[0])), args = argv.skip(1).toList();
    if (!names.contains(name) && interpreter(name) && argv.length > 1) {
      name = bare(p.basename(argv[1]));
      args = argv.skip(2).toList();
    }
    if (!names.contains(name) && names.contains(comm)) name = comm;
    if (!names.contains(name) || args.take(3).any(background.contains)) {
      continue;
    }
    if (scans.processEnv(process.pid, {
          'MAPRISMA_NO_PROVIDERS',
        })['MAPRISMA_NO_PROVIDERS'] ==
        '1') {
      continue;
    }
    found.putIfAbsent(name, () => []).add(process.pid);
  }
  return found;
}

/// flutter_map_instances: short-lived reviewed handles for stopping an
/// agent instance that runs outside this app's own terminals.
final class AgentHalt {
  AgentHalt(this.catalog, this.scans, this.sessions, this.tasks);
  final AgentCatalog catalog;
  final ProviderScans scans;
  final PtySessions sessions;
  final CoreTasks tasks;
  final _plans = <String, (DateTime, String, int, double)>{};
  Posix get posix => scans.files.posix;

  Map<String, dynamic> preview(Map<String, dynamic> params) {
    if (params.length != 1 || params['command'] is! String) {
      throw const FormatException('Expected an agent');
    }
    final command = params['command'] as String;
    if (!catalog.scan().any((a) => a.command == command && a.installed)) {
      throw const FormatException('Agent unavailable');
    }
    final now = DateTime.now();
    _plans.removeWhere((_, v) => now.difference(v.$1).inSeconds >= 300);
    final pids = agentInstancePids(scans, {command})[command] ?? const [];
    final embedded = [
      for (final s in sessions.items.values)
        if (sessions.running(s)) s.pid,
    ];
    final outside = [
      for (final pid in pids)
        if (!embedded.any(
          (own) => pid == own || ancestors(pid, posix).contains(own),
        ))
          pid,
    ];
    final rows = <Map<String, dynamic>>[];
    for (final pid in outside.take(20)) {
      final since = startedAt(pid, posix);
      if (since == 0) continue;
      if (_plans.length >= 64) _plans.remove(_plans.keys.first);
      final token = newHandle().substring(coreHandle.length);
      _plans[token] = (now, command, pid, since);
      final cwd = cwdOf(pid, posix);
      rows.add({
        'preview': token,
        'label':
            '$command · $pid · ${cwd.length > 500 ? cwd.substring(0, 500) : cwd}',
      });
    }
    return {'instances': rows};
  }

  Map<String, dynamic> apply(Map<String, dynamic> params) {
    if (params.length != 1 || params['preview'] is! String) {
      throw const FormatException('Expected a preview');
    }
    final plan = _plans[params['preview']];
    if (plan == null || DateTime.now().difference(plan.$1).inSeconds >= 300) {
      throw const FormatException('Preview expired');
    }
    final (_, command, pid, since) = plan;
    final body = utf8.encode(
      jsonEncode({'command': command, 'pid': pid, 'started': since}),
    );
    final task = tasks.startPrivate('agents.halt', body);
    _plans.remove(params['preview']);
    return task;
  }
}

/// flutter_map_instances.execute (the worker): still that instance of that
/// agent, then stopped.
Future<Map<String, dynamic>> haltInstance(
  List<int> body,
  ProviderScans scans,
) async {
  final record = jsonDecode(utf8.decode(body));
  if (record is! Map ||
      record.length != 3 ||
      record['command'] is! String ||
      record['pid'] is! int ||
      record['started'] is! num) {
    throw const FormatException('Invalid instance');
  }
  final command = record['command'] as String, pid = record['pid'] as int;
  if (!(agentInstancePids(scans, {command})[command] ?? const []).contains(
    pid,
  )) {
    throw const FormatException('Instance changed');
  }
  if (!await stopInstance(
    pid,
    (record['started'] as num).toDouble(),
    scans.files.posix,
  )) {
    throw const FormatException('Instance could not be stopped');
  }
  return {'ok': true};
}
