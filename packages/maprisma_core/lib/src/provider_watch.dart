import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'identity.dart';
import 'model_guard.dart' show agentInstances;
import 'posix_ffi.dart';
import 'agent_catalog.dart';
import 'inventory.dart';
import 'provider_ops.dart';
import 'settings.dart';
import 'provider_scans.dart';
import 'py_values.dart';
import 'scan_files.dart';
import 'provider_facts.dart';

/// provider_watch: start an agent's local LLMs when the agent starts, stop
/// them when it closes. The service (`maprisma-core provider-watch --config
/// FILE`) looks at this user's processes once a second; what is connected to
/// what comes from the config the app writes (only runtime keys, unit names,
/// ports and a built-in controller are read from it, never a command line).

final _unloadPath = RegExp(r'^/[A-Za-z0-9/_.-]{1,100}$');
final _name = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.+-]{0,63}$');
final _unit = RegExp(r'^[A-Za-z0-9][A-Za-z0-9@_.-]{0,99}$');
final unitSafe = RegExp(r'^[A-Za-z0-9/._+-]{1,1024}$');
const watchControls = {'lms'};
const watchInterval = Duration(seconds: 1);
const grace = 5.0, retry = 30.0, maxConfig = 64 * 1024;

void watchLog(String text) => stdout.writeln(text);

/// _unload: a checked {"path", "body"} request, or null.
Map<String, dynamic>? _unloadRequest(dynamic value) {
  if (value is! Map ||
      value['path'] is! String ||
      !_unloadPath.hasMatch(value['path'] as String) ||
      value['body'] is! Map) {
    return null;
  }
  final body = value['body'] as Map;
  if (body.length > 8 ||
      !body.entries.every(
        (e) =>
            e.key is String &&
            _name.hasMatch(e.key as String) &&
            e.value is String &&
            (e.value as String).length <= 100,
      )) {
    return null;
  }
  return {'path': value['path'], 'body': Map<String, dynamic>.from(body)};
}

/// _entry: {"service", "port"[, "control"][, "stays_up", "unload"]}, checked.
Map<String, dynamic>? watchEntry(dynamic key, dynamic entry) {
  if (key is! String || !_name.hasMatch(key) || entry is! Map) return null;
  final service = entry['service'] is String ? entry['service'] as String : '';
  final raw = entry['port'];
  final port = raw is int && raw > 0 && raw < 65536 ? raw : 0;
  if (service.isNotEmpty && !_unit.hasMatch(service)) return null;
  final control = watchControls.contains(entry['control'])
      ? entry['control'] as String
      : '';
  if (service.isEmpty && control.isEmpty) return null;
  final checked = <String, dynamic>{
    'service': service,
    'port': port,
    if (control.isNotEmpty) 'control': control,
  };
  final unload = _unloadRequest(entry['unload']);
  if (entry['stays_up'] == true && unload != null) {
    checked['stays_up'] = true;
    checked['unload'] = unload;
  }
  return checked;
}

Map _readJson(String path) {
  try {
    final file = File(path).openSync();
    try {
      final data = jsonDecode(utf8.decode(file.readSync(maxConfig)));
      return data is Map ? data : {};
    } finally {
      file.closeSync();
    }
  } on FileSystemException {
    return {};
  } on FormatException {
    return {};
  }
}

/// read_config: ({agent: [runtime keys]}, {runtime key: entry}), checked.
(Map<String, List<String>>, Map<String, Map<String, dynamic>>) readWatchConfig(
  String path,
) {
  final data = _readJson(path);
  final agents = <String, List<String>>{};
  final runtimes = <String, Map<String, dynamic>>{};
  if (data['runtimes'] is Map) {
    for (final e in (data['runtimes'] as Map).entries) {
      final checked = watchEntry(e.key, e.value);
      if (checked != null) runtimes[e.key as String] = checked;
    }
  }
  if (data['agents'] is Map) {
    for (final e in (data['agents'] as Map).entries) {
      if (e.key is String &&
          _name.hasMatch(e.key as String) &&
          e.value is List) {
        final wanted = [
          for (final k in e.value as List)
            if (k is String && runtimes.containsKey(k)) k,
        ];
        if (wanted.isNotEmpty) agents[e.key as String] = wanted;
      }
    }
  }
  return (agents, runtimes);
}

/// json.dumps(sort_keys=True): maps sorted at every level.
dynamic sortedKeys(dynamic value) => value is Map
    ? {
        for (final k in (value.keys.map((k) => '$k').toList()..sort()))
          k: sortedKeys(value[k]),
      }
    : value is List
    ? [for (final v in value) sortedKeys(v)]
    : value;

/// write_config's text: which local LLM each agent uses now (only the
/// provider of its current model starts with it), every connected one listed
/// under "runtimes" so the watcher knows how to stop it.
String watchConfigText(List<RuntimeRecord> runtimes, Set<String> selfServed) {
  final out = <String, dynamic>{}, agents = <String, List<String>>{};
  for (final rt in runtimes) {
    final control = rt.key == 'lmstudio' ? 'lms' : '';
    if (!rt.installed ||
        rt.agents.isEmpty ||
        rt.service.isEmpty && control.isEmpty) {
      continue;
    }
    final port = rt.address.substring(rt.address.lastIndexOf(':') + 1);
    out[rt.key] = {
      'service': rt.service,
      'port': portNumber(port),
      if (control.isNotEmpty && rt.service.isEmpty) 'control': control,
    };
    final facts =
        (visibleProviderFacts['local'] as List).firstWhere(
              (f) => (f as Map)['key'] == rt.key,
              orElse: () => const {},
            )
            as Map;
    final unload = facts['unload'];
    if (facts['stays_up'] == true && unload is List && unload.length == 2) {
      (out[rt.key] as Map)
        ..['stays_up'] = true
        ..['unload'] = {'path': unload[0], 'body': unload[1]};
    }
    for (final agent in rt.activeAgents) {
      if (!selfServed.contains(agent)) {
        agents.putIfAbsent(agent, () => []).add(rt.key);
      }
    }
  }
  return '${pyJsonDumps(sortedKeys({'agents': agents, 'runtimes': out}), indent: 2)}\n';
}

/// The user service's unit: the core binary watching with this config.
String watchUnitText(String binary, String config) {
  final exec =
      '$binary provider-watch${unitSafe.hasMatch(config) ? ' --config $config' : ''}';
  return '[Unit]\n'
      'Description=Maprisma: start local LLMs with their agents, stop them when the agents close\n'
      '\n'
      '[Service]\n'
      'Type=simple\n'
      'ExecStart=$exec\n'
      'Restart=on-failure\n'
      'RestartSec=5\n'
      '\n'
      '[Install]\n'
      'WantedBy=default.target\n';
}

/// A command with no shell, its stderr's end logged on failure (run).
Future<bool> watchRun(List<String> argv) async {
  try {
    final result = await Process.run(
      argv.first,
      argv.skip(1).toList(),
    ).timeout(const Duration(seconds: 60));
    if (result.exitCode != 0) {
      final text = '${result.stderr}'.trim();
      watchLog(
        '${argv.join(' ')}: ${text.length > 300 ? text.substring(text.length - 300) : text}',
      );
    }
    return result.exitCode == 0;
  } catch (error) {
    watchLog('${argv.join(' ')}: $error');
    return false;
  }
}

/// The processes, ports and controls the watcher looks at.
final class WatchSystem {
  WatchSystem(this.files, this.scans);
  final ScanFiles files;
  final ProviderScans scans;
  String get proc => scans.proc;
  int get uid => files.posix.uid;

  /// running_agents: (agents of names with a process now, pids of agents'
  /// background servers).
  (Set<String>, Set<int>) runningAgents(Set<String> names) {
    final running = agentInstances(scans, names).keys.toSet();
    final background = <int>{};
    for (final process in scans.processes()) {
      final argv = process.argv;
      if (argv.isEmpty) continue;
      String bare(String v) =>
          v.endsWith('.exe') ? v.substring(0, v.length - 4) : v;
      bool interpreter(String v) =>
          const ['node', 'bun', 'deno', 'python', 'python3'].any(v.startsWith);
      final comm = bare(process.comm);
      if (!names.contains(comm) && !interpreter(comm) && comm.length < 15) {
        continue; // as _scan_agents: most processes are not looked at further
      }
      var name = bare(p.basename(argv[0])), args = argv.skip(1).toList();
      if (!names.contains(name) && interpreter(name) && argv.length > 1) {
        name = bare(p.basename(argv[1]));
        args = argv.skip(2).toList();
      }
      if (!names.contains(name) && names.contains(comm)) name = comm;
      if (names.contains(name) &&
          args
              .take(3)
              .any(
                const {
                  'serve',
                  'server',
                  'daemon',
                  '--service',
                  '--daemon',
                }.contains,
              )) {
        background.add(process.pid);
      }
    }
    return (running, background);
  }

  /// socket_inodes: the sockets these processes hold.
  Set<String> socketInodes(Set<int> pids) {
    final inodes = <String>{};
    for (final pid in pids) {
      for (final fd in files.list('$proc/$pid/fd', limit: 4096)) {
        try {
          final target = Link(fd).targetSync();
          if (target.startsWith('socket:[')) {
            inodes.add(target.substring(8, target.length - 1));
          }
        } on FileSystemException {
          continue;
        }
      }
    }
    return inodes;
  }

  /// in_use: a connection open to this loopback port (ESTABLISHED), not
  /// counting the client sockets in `ignore`.
  bool inUse(int port, Set<String> ignore) {
    if (port == 0) return false;
    for (final name in ['tcp', 'tcp6']) {
      final text = files.text('$proc/net/$name', allowRootOwned: true);
      if (text == null) continue;
      for (final line in const LineSplitter().convert(text).skip(1)) {
        final f = line.trim().split(RegExp(r'\s+'));
        if (f.length > 9 &&
            f[3] == '01' &&
            int.tryParse(
                  f[2].substring(f[2].lastIndexOf(':') + 1),
                  radix: 16,
                ) ==
                port &&
            !ignore.contains(f[9])) {
          return true;
        }
      }
    }
    return false;
  }

  bool ownListener(int port) {
    final owners = loopbackListeners(port, proc: '$proc/net');
    return owners.isNotEmpty && owners.every((o) => o == uid);
  }

  /// unload: free a runtime that stays up (its config entry's request).
  Future<bool> unload(Map entry, int port) async {
    if (port == 0 || !ownListener(port)) return false;
    final request = entry['unload'] as Map;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final call = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port${request['path']}'),
      );
      final body = utf8.encode(pyJsonDumps(request['body']));
      call.headers.contentType = ContentType.json;
      call.contentLength = body.length;
      call.add(body);
      final response = await call.close().timeout(const Duration(seconds: 30));
      await response.take(64).drain<void>();
      return response.statusCode < 400;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  String? lmsBinary() {
    for (final folder in (files.identity.environment['PATH'] ?? '').split(
      ':',
    )) {
      if (folder.isNotEmpty && FileSystemEntity.isFileSync('$folder/lms')) {
        return '$folder/lms';
      }
    }
    final own = files.expand('~/.lmstudio/bin/lms');
    return FileSystemEntity.isFileSync(own) ? own : null;
  }

  // --- LM Studio's background app ------------------------------------------------------

  List<(int, int, List<String>)> ownProcesses() {
    final found = <(int, int, List<String>)>[];
    for (final path in files.list(proc, limit: 100000, allowRootOwned: true)) {
      final pid = int.tryParse(p.basename(path));
      if (pid == null) continue;
      final stat = files.text('$path/stat', limit: 1024, portion: 'head');
      if (stat == null) continue; // not ours
      final fields = stat
          .substring(stat.lastIndexOf(')') + 1)
          .trim()
          .split(RegExp(r'\s+'));
      final parent = fields.length > 1 ? int.tryParse(fields[1]) ?? 0 : 0;
      final cmd =
          files.text('$path/cmdline', limit: 4096, portion: 'head') ?? '';
      found.add((pid, parent, cmd.split('\x00')));
    }
    return found;
  }

  static bool isLmstudio(List<String> argv) {
    final exe = argv.isEmpty ? '' : argv.first;
    if (exe.contains('/.lmstudio/apps/')) return false;
    return exe.contains('/.lmstudio/') ||
        p.basename(exe).toLowerCase().contains('lm-studio') ||
        exe.contains('/.mount_lm-stu');
  }

  static bool isOtherApp(List<String> argv) {
    final exe = argv.isEmpty ? '' : argv.first;
    return p.basename(exe).toLowerCase() == 'bionic' ||
        exe.contains('/.lmstudio/apps/');
  }

  static Set<int> otherAppFamily(List<(int, int, List<String>)> processes) {
    final family = {
      for (final (pid, _, argv) in processes)
        if (isOtherApp(argv)) pid,
    };
    final parents = {for (final (pid, parent, _) in processes) pid: parent};
    for (final pid in parents.keys.toList()) {
      var seen = 0, current = pid;
      while (current != 0 && seen < 64) {
        if (family.contains(current)) {
          family.add(pid);
          break;
        }
        current = parents[current] ?? 0;
        seen++;
      }
    }
    return family;
  }

  /// lmstudio_up: LM Studio runs already (not ours to stop).
  bool lmstudioUp() {
    final processes = ownProcesses(), others = otherAppFamily(processes);
    return processes.any((x) => isLmstudio(x.$3) && !others.contains(x.$1));
  }

  /// lmstudio_pids: everything of the LM Studio we started; nothing while an
  /// LM Studio window is open.
  static List<int> lmstudioPids(List<(int, int, List<String>)> processes) {
    for (final (_, _, argv) in processes) {
      final exe = argv.isEmpty ? '' : p.basename(argv.first).toLowerCase();
      if (exe.contains('lm-studio') &&
          !argv.contains('--run-as-service') &&
          !argv.any((a) => a.startsWith('--type='))) {
        return [];
      }
    }
    final others = otherAppFamily(processes);
    final picked = {
      for (final (pid, _, argv) in processes)
        if (isLmstudio(argv) && !others.contains(pid)) pid,
    };
    final children = <int, List<int>>{};
    for (final (pid, parent, _) in processes) {
      children.putIfAbsent(parent, () => []).add(pid);
    }
    final todo = picked.toList();
    while (todo.isNotEmpty) {
      for (final child in children[todo.removeLast()] ?? const <int>[]) {
        if (!picked.contains(child) && !others.contains(child)) {
          picked.add(child);
          todo.add(child);
        }
      }
    }
    return picked.toList()..sort();
  }

  /// _lms_role: runtime (the AppImage), engine, main, outlives or helper.
  static String lmsRole(List<String> argv) {
    final exe = argv.isEmpty ? '' : argv.first;
    final name = p.basename(exe).toLowerCase();
    if (name.endsWith('.appimage')) return 'runtime';
    if (exe.contains('/.lmstudio/extensions/backends/')) return 'engine';
    if (name == 'chrome_crashpad_handler' ||
        exe.contains('/.lmstudio/') && !name.contains('lm-studio')) {
      return 'outlives';
    }
    if (name.contains('lm-studio') &&
        !argv.any((a) => a.startsWith('--type='))) {
      return 'main';
    }
    return 'helper';
  }

  /// stop_lmstudio_service: after `lms server stop`, the background LM Studio
  /// we started goes too, each process held by a pidfd from the moment it is
  /// found (engines first with SIGTERM, then the program and its helpers with
  /// SIGKILL at once, the AppImage process last).
  Future<void> stopLmstudio(String lms) async {
    await watchRun([lms, 'daemon', 'down']);
    final posix = files.posix;
    final opened = <int, int>{};
    for (final pid in lmstudioPids(ownProcesses())) {
      final fd = posix.pidfdOpen(pid);
      if (fd >= 0) opened[pid] = fd;
    }
    final now = ownProcesses();
    final still = lmstudioPids(now).toSet();
    for (final pid in opened.keys.where((x) => !still.contains(x)).toList()) {
      posix.close(opened.remove(pid)!);
    }
    final argvOf = {for (final (pid, _, argv) in now) pid: argv};
    final roles = <String, List<int>>{};
    for (final e in opened.entries) {
      roles
          .putIfAbsent(lmsRole(argvOf[e.key] ?? const []), () => [])
          .add(e.value);
    }
    Future<List<int>> waitGone(List<int> fds, double seconds) async {
      final until = DateTime.now().add(
        Duration(milliseconds: (seconds * 1000).round()),
      );
      while (true) {
        fds = [
          for (final fd in fds)
            if (!posix.pidfdExited(fd)) fd,
        ];
        if (fds.isEmpty || !DateTime.now().isBefore(until)) return fds;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    void signal(List<int> fds, int sig) {
      for (final fd in fds) {
        posix.pidfdSignal(fd, sig);
      }
    }

    Future<void> end(List<int> fds) async {
      signal(fds, 15);
      fds = await waitGone(fds, 5.0);
      if (fds.isNotEmpty) {
        signal(fds, 9);
        await waitGone(fds, 3.0);
      }
    }

    try {
      await end(roles['engine'] ?? []);
      final program = [
        ...?roles['main'],
        ...?roles['helper'],
        ...?roles['outlives'],
      ];
      signal(program, 9);
      await waitGone(program, 3.0);
      await end(await waitGone(roles['runtime'] ?? [], 2.0));
    } finally {
      for (final fd in opened.values) {
        posix.close(fd);
      }
    }
  }
}

/// Watcher: one tick a second; what is needed or waiting to be stopped is
/// saved with each runtime's service and port, so a restart still stops it.
final class Watcher {
  Watcher(
    this.config, {
    required this.run,
    required this.clock,
    required this.agentsNow,
    required this.busy,
    required this.lmsUp,
    required this.stopLms,
    required this.sockets,
    required this.unload,
    required this.lmsBinary,
    this.state,
  }) {
    loadState();
  }
  final String config;
  final String? state;
  final Future<bool> Function(List<String> argv) run;
  final double Function() clock;
  final (Set<String>, Set<int>) Function(Set<String> names) agentsNow;
  final bool Function(int port, Set<String> ignore) busy;
  final bool Function() lmsUp;
  final Future<void> Function(String argv0) stopLms;
  final Set<String> Function(Set<int> pids) sockets;
  final Future<bool> Function(Map entry, int port) unload;
  final String? Function() lmsBinary;

  int? mtime;
  var agents = <String, List<String>>{};
  var runtimes = <String, Map<String, dynamic>>{};
  final known = <String, Map<String, dynamic>>{};
  var needed = <String>{};
  final started = <String, Object>{}; // key -> time, '$key:ok' -> bool
  final stopAt = <String, double>{};
  var lmsWasUp = true;
  var background = <int>{};
  var running = <String>{};
  String? saved;

  void loadState() {
    if (state == null) return;
    final data = _readJson(state!);
    if (data.isEmpty) return;
    if (data['pending'] is Map) {
      for (final e in (data['pending'] as Map).entries) {
        final checked = watchEntry(e.key, e.value);
        if (checked != null) {
          known[e.key as String] = checked;
          needed.add(e.key as String);
        }
      }
    }
    lmsWasUp = data['lms_was_up'] != false;
  }

  void saveState() {
    if (state == null) return;
    final pending = {
      for (final key in ({...needed, ...stopAt.keys}.toList()..sort()))
        if (known.containsKey(key)) key: known[key],
    };
    final text =
        '${pyJsonDumps(sortedKeys({'pending': pending, 'lms_was_up': lmsWasUp}), indent: 2)}\n';
    if (text == saved) return;
    try {
      final file = File(state!);
      file.parent.createSync(recursive: true);
      final tmp = File(p.join(file.parent.path, '.${p.basename(state!)}.new'));
      tmp.writeAsStringSync(text);
      Posix().chmodPath(tmp.path, 0x180);
      tmp.renameSync(state!);
      saved = text;
    } on FileSystemException catch (error) {
      watchLog('could not save $state: ${error.message}');
    }
  }

  void load() {
    int? now;
    try {
      final st = File(config).statSync();
      now = st.type == FileSystemEntityType.notFound
          ? null
          : st.modified.microsecondsSinceEpoch * 1000 + st.size;
    } on FileSystemException {
      now = null;
    }
    if (now != mtime) {
      mtime = now;
      final read = readWatchConfig(config);
      agents = read.$1;
      runtimes = read.$2;
      known.addAll(runtimes);
    }
  }

  Set<String> look() {
    load();
    final (now, bg) = agents.isNotEmpty
        ? agentsNow(agents.keys.toSet())
        : (<String>{}, <int>{});
    background = bg;
    running = now;
    return {
      for (final agent in now)
        for (final key in agents[agent] ?? const <String>[]) key,
    };
  }

  List<String>? command(Map entry, String action) {
    if ('${entry['service'] ?? ''}'.isNotEmpty) {
      return ['systemctl', '--user', action, '${entry['service']}.service'];
    }
    final lms = lmsBinary();
    if (entry['control'] == 'lms' && lms != null) {
      return [lms, 'server', action];
    }
    return null;
  }

  Future<bool> stop(String key, String why) async {
    final entry = runtimes[key] ?? known[key];
    if (entry == null) return true;
    final port = entry['port'] as int? ?? 0;
    if (busy(port, sockets(background))) return false;
    if (entry['stays_up'] == true) {
      final ok = await unload(entry, port);
      watchLog('unload $key ($why): ${ok ? 'ok' : 'not running'}');
      started.remove(key);
      started.remove('$key:ok');
      return true;
    }
    final argv = command(entry, 'stop');
    if (argv != null) {
      final ok = await run(argv);
      watchLog('stop $key ($why): ${ok ? 'ok' : 'failed'}');
      if (entry['control'] == 'lms' && !lmsWasUp) await stopLms(argv.first);
    }
    started.remove(key);
    started.remove('$key:ok');
    return true;
  }

  Future<void> tick() async {
    final now0 = look();
    final now = clock();
    for (final key in now0.toList()..sort()) {
      stopAt.remove(key);
      final last = started[key] as double?;
      if (!needed.contains(key) ||
          last != null && now - last > retry && started['$key:ok'] != true) {
        final argv = command(runtimes[key]!, 'start');
        if (argv != null &&
            runtimes[key]!['control'] == 'lms' &&
            !needed.contains(key)) {
          lmsWasUp = lmsUp();
        }
        if (argv != null) {
          final ok = await run(argv);
          started[key] = now;
          started['$key:ok'] = ok;
          final users = [
            for (final a in running)
              if (agents[a]?.contains(key) ?? false) a,
          ]..sort();
          watchLog(
            'start $key for ${users.join(', ')}: ${ok ? 'ok' : 'failed'}',
          );
        }
      }
    }
    for (final key in needed.difference(now0).toList()..sort()) {
      stopAt.putIfAbsent(key, () => now + grace);
    }
    for (final e in stopAt.entries.toList()) {
      if (!now0.contains(e.key) &&
          now >= e.value &&
          await stop(e.key, 'no agent using it is running')) {
        stopAt.remove(e.key);
      }
    }
    needed = now0;
    saveState();
  }

  Future<void> shutdown() async {
    Set<String> now0;
    try {
      now0 = look();
    } catch (_) {
      now0 = {};
    }
    for (final key in ({
      ...needed,
      ...stopAt.keys,
    }.difference(now0).toList()..sort())) {
      if (await stop(key, 'the watcher stops')) stopAt.remove(key);
    }
    needed = {...now0, ...stopAt.keys};
    stopAt.clear();
    saveState();
  }
}

/// `maprisma-core provider-watch [--config FILE]`: the service loop. Exit
/// code 75 when the binary was updated (systemd starts the new one).
Future<int> runProviderWatch(List<String> args) async {
  final files = ScanFiles(AppIdentity());
  final home = files.identity.home;
  final config =
      args.length == 2 &&
          args[0] == '--config' &&
          unitSafe.hasMatch(args[1]) &&
          args[1].startsWith('/')
      ? args[1]
      : p.join(files.identity.configDir, 'providers-with-agents.json');
  final system = WatchSystem(files, ProviderScans(files));
  final watcher = Watcher(
    config,
    run: watchRun,
    clock: () => DateTime.now().microsecondsSinceEpoch / 1e6,
    agentsNow: system.runningAgents,
    busy: system.inUse,
    lmsUp: system.lmstudioUp,
    stopLms: system.stopLmstudio,
    sockets: system.socketInodes,
    unload: system.unload,
    lmsBinary: system.lmsBinary,
    state: p.join(home, '.local/state/maprisma/provider-watch.json'),
  );
  String stamp() {
    try {
      final st = File(Platform.resolvedExecutable).statSync();
      return '${st.modified.microsecondsSinceEpoch}:${st.size}';
    } on FileSystemException {
      return '';
    }
  }

  final first = stamp();
  var stopping = false;
  final term = ProcessSignal.sigterm.watch().listen((_) => stopping = true);
  watchLog('watching agents and their local LLMs');
  var code = 0;
  try {
    while (!stopping) {
      try {
        await watcher.tick();
      } catch (error) {
        watchLog('error: $error');
      }
      if (stamp() != first) {
        watchLog('updated: restarting with the new version');
        code = 75;
        break;
      }
      await Future<void>.delayed(watchInterval);
    }
  } finally {
    await watcher.shutdown();
    // An open signal subscription would keep the process alive.
    await term.cancel();
  }
  return code;
}

/// The app side: the watcher's config after each inventory scan, and its user
/// service on while the setting is on and some agent is connected to a local
/// LLM it can start (sync_provider_watch). Only a compiled release core
/// manages the unit: a Devel build or a run from source never touches it.
final class WatchService {
  WatchService(this.identity, this.settings, this.workerCommand, this.ops);
  final AppIdentity identity;
  final SettingsStore settings;
  final List<String> workerCommand;
  final ProviderOps ops;
  List<RuntimeRecord> _runtimes = const [];

  String get config => p.join(identity.configDir, 'providers-with-agents.json');
  String get unitName => '${identity.shortName}-providers.service';
  String get unitFile =>
      p.join(identity.home, '.config/systemd/user', unitName);

  /// The compiled core this unit runs, or null when it must not be managed.
  String? get binary {
    final env = identity.environment;
    if (env['MAPRISMA_FLUTTER_DEVEL'] == '1' || env['MAPRISMA_DEVEL'] == '1') {
      return null;
    }
    if (workerCommand.length != 2 || workerCommand[1] != 'worker') return null;
    final path = workerCommand.first;
    // Only an installed core: never a build or a copy in a temporary folder
    // (a development bundle, a test run), whose unit would start a binary
    // that is replaced or gone, at the next login.
    final temp = env['TMPDIR'] ?? '';
    if (p.isWithin('/tmp', path) ||
        p.isWithin('/var/tmp', path) ||
        temp.isNotEmpty && p.isWithin(temp, path) ||
        path.contains('/.flutter-previews/') ||
        path.contains('/build/linux/')) {
      return null;
    }
    return p.isAbsolute(path) &&
            unitSafe.hasMatch(path) &&
            p.basename(path) == 'maprisma-core'
        ? path
        : null;
  }

  /// write_config: true when the file changed.
  bool writeConfig(List<RuntimeRecord> runtimes, List<AgentRecord> agents) {
    final selfServed = {
      for (final a in agents)
        if (a.adapter.facts['self_served'] == true) a.command,
    };
    final text = watchConfigText(runtimes, selfServed);
    final file = File(config);
    try {
      if (file.readAsStringSync() == text) return false;
    } on FileSystemException {
      // not there yet
    }
    if (!file.parent.existsSync()) {
      // mkdir(parents=True, mode=0o700): the folder itself private.
      file.parent.createSync(recursive: true);
      Posix().chmodPath(file.parent.path, 0x1c0);
    }
    final tmp = File(p.join(file.parent.path, '.${p.basename(config)}.new'));
    tmp.writeAsStringSync(text);
    Posix().chmodPath(tmp.path, 0x180);
    tmp.renameSync(config);
    return true;
  }

  bool get wanted =>
      settings.value(settings.load(), 'providers_with_agents') == true &&
      _runtimes.any((rt) => rt.agents.isNotEmpty && ops.canControl(rt));

  void sync(InventorySnapshot inventory, List<AgentRecord> agents) {
    _runtimes = inventory.runtimes;
    bool changed;
    try {
      changed = writeConfig(inventory.runtimes, agents);
    } on FileSystemException {
      changed = false;
    }
    if (changed) unawaited(ensure(wanted));
  }

  /// The setting changed: on or off at once.
  void settingChanged() => unawaited(ensure(wanted));

  Future<bool> _systemctl(List<String> args) async {
    try {
      final result = await Process.run('systemctl', [
        '--user',
        ...args,
      ]).timeout(const Duration(seconds: 60));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// ensure_service: install, enable and start the watcher (on), or stop,
  /// disable and remove it (off); a unit of an older version is rewritten.
  Future<bool> ensure(bool on) async {
    final core = binary;
    if (core == null) return false;
    final unit = File(unitFile);
    if (!on) {
      if (!unit.existsSync()) return true;
      await _systemctl(['disable', '--now', unitName]);
      try {
        unit.deleteSync();
      } on FileSystemException {
        // gone already
      }
      await _systemctl(['daemon-reload']);
      return true;
    }
    final text = watchUnitText(core, config);
    bool changed;
    try {
      changed = unit.readAsStringSync() != text;
    } on FileSystemException {
      changed = true;
    }
    if (changed) {
      unit.parent.createSync(recursive: true);
      unit.writeAsStringSync(text);
      await _systemctl(['daemon-reload']);
      await _systemctl(['enable', unitName]);
      return _systemctl(['restart', unitName]);
    }
    if (!await _systemctl(['is-active', '--quiet', unitName])) {
      await _systemctl(['enable', unitName]);
      return _systemctl(['start', unitName]);
    }
    return true;
  }
}
