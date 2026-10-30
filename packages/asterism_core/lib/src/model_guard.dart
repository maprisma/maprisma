import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:path/path.dart' as p;
import 'adapter_assets.g.dart';
import 'provider_ops.dart';
import 'provider_scans.dart';
import 'scan_files.dart';

/// gpu_usage: only what `snapshot(...).generating` needs, for the model guard
/// (a model is generating when one is loaded and the GPU is busy).
final class GpuUsage {
  GpuUsage(this.files, this.scans);
  final ScanFiles files;
  final ProviderScans scans;
  static const busyPercent = 20;
  static const modelVram = 512 * 1024 * 1024; // Usage.loaded's threshold
  int get uid => files.posix.uid;

  late final String? gpuDir = _discreteGpu();
  late final String gpuSlot = () {
    if (gpuDir == null) return '';
    final text = _read('$gpuDir/uevent');
    return RegExp(r'PCI_SLOT_NAME=(\S+)').firstMatch(text)?[1] ?? '';
  }();

  /// gpu_usage._read: the head of a file (sysfs files report 4096 bytes).
  String _read(String path, {int limit = 65536}) =>
      files.text(
        path,
        limit: limit,
        follow: true,
        portion: 'head',
        allowRootOwned: true,
      ) ??
      '';

  /// gpu_usage.discrete_gpu: the card with the largest VRAM.
  String? _discreteGpu() {
    (int, String)? best;
    for (final entry in files.list(
      '/sys/class/drm',
      limit: 4000,
      allowRootOwned: true,
    )) {
      if (!p.basename(entry).startsWith('card')) continue;
      final size = int.tryParse(
        _read('$entry/device/mem_info_vram_total', limit: 64).trim(),
      );
      if (size == null) continue;
      if (best == null || size > best.$1) best = (size, '$entry/device');
    }
    return best?.$2;
  }

  double? _number(String path) =>
      double.tryParse(_read(path, limit: 64).trim());

  /// gpu_totals: (used, total, busy percent), from sysfs, else nvidia-smi.
  Future<(int, int, double?)> totals() async {
    if (gpuDir != null) {
      return (
        (_number('$gpuDir/mem_info_vram_used') ?? 0).toInt(),
        (_number('$gpuDir/mem_info_vram_total') ?? 0).toInt(),
        _number('$gpuDir/gpu_busy_percent'),
      );
    }
    try {
      final process = await Process.start('nvidia-smi', [
        '--query-gpu=memory.used,memory.total,utilization.gpu',
        '--format=csv,noheader,nounits',
      ]);
      unawaited(process.stdin.close());
      final out = <int>[];
      final done = process.stdout.forEach(
        (c) => out.length < 4096 ? out.addAll(c) : null,
      );
      unawaited(process.stderr.drain<void>());
      final code = await process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      await done.timeout(const Duration(seconds: 1), onTimeout: () {});
      if (code != 0) return (0, 0, null);
      final parts = utf8
          .decode(out, allowMalformed: true)
          .split('\n')
          .first
          .split(',');
      if (parts.length != 3) return (0, 0, null);
      final mib = 1024 * 1024;
      return (
        (double.parse(parts[0].trim()) * mib).toInt(),
        (double.parse(parts[1].trim()) * mib).toInt(),
        double.parse(parts[2].trim()),
      );
    } catch (_) {
      return (0, 0, null);
    }
  }

  /// gpu_totals()[2]: the busy percent.
  Future<double?> busy() async => (await totals()).$3;

  /// snapshot: the GPU's totals and, per local LLM, whether it runs, the
  /// GPU memory its processes hold and its loaded models (asked only of the
  /// running ones, on loopback).
  Future<Map<String, dynamic>> snapshot(List<RuntimeRecord> runtimes) async {
    final (used, total, percent) = await totals();
    final groups = runtimePids(scans.processes());
    final found = <String, dynamic>{};
    for (final rt in runtimes) {
      final pids = groups[rt.key] ?? const <int>{};
      found[rt.key] = {
        'running': pids.isNotEmpty,
        'vram': pids.fold(0, (a, pid) => a + procVram(pid)),
        'models': pids.isEmpty ? <String, String>{} : await loadedModels(rt),
      };
    }
    return {
      'vram_used': used,
      'vram_total': total,
      'busy': percent,
      'runtimes': found,
    };
  }

  static int _kib(String info, List<String> keys) {
    for (final key in keys) {
      final match = RegExp(
        '^${RegExp.escape(key)}:\\s*(\\d+)\\s*KiB',
        multiLine: true,
      ).firstMatch(info);
      if (match != null) return int.parse(match[1]!) * 1024;
    }
    return 0;
  }

  /// proc_vram: GPU memory really on the GPU for one of this user's processes.
  int procVram(int pid) {
    if (files.posix.lstatFull('/proc/$pid', follow: true)?.uid != uid) {
      return 0;
    }
    final clients = <String, int>{};
    for (final fd in files.list('/proc/$pid/fd', limit: 4096)) {
      try {
        if (!Link(fd).targetSync().startsWith('/dev/dri/')) continue;
      } on FileSystemException {
        continue;
      }
      final info = files.text(
        '/proc/$pid/fdinfo/${p.basename(fd)}',
        limit: 8192,
        portion: 'head',
      );
      if (info == null) continue;
      final client = RegExp(r'drm-client-id:\s*(\d+)').firstMatch(info);
      if (client == null ||
          gpuSlot.isNotEmpty &&
              info.contains('drm-pdev:') &&
              !info.contains('drm-pdev:\t$gpuSlot')) {
        continue;
      }
      clients[client[1]!] = _kib(info, [
        'drm-resident-vram',
        'drm-memory-vram',
      ]);
    }
    return clients.values.fold(0, (a, b) => a + b);
  }

  /// llm_engine.runtime_of: which local LLM a process belongs to (the surest
  /// claim of the engines, in providers.local() order).
  static String runtimeOf(String comm, List<String> argv) {
    final exe = argv.isEmpty ? '' : argv.first, base = p.basename(exe);
    final claims = <String, int>{
      'llamacpp': comm.startsWith('llama-') || base == 'llama-server' ? 1 : 0,
      'ollama': comm == 'ollama' || base == 'ollama' ? 1 : 0,
      'lmstudio':
          exe.contains('.lmstudio') ||
              comm.toLowerCase().startsWith('lm studio') ||
              const {'lm-studio', 'lm studio'}.contains(base.toLowerCase())
          ? 2
          : 0,
      'vllm':
          comm.startsWith('VLLM') ||
              argv.length > 1 &&
                  argv.take(2).any((a) => p.basename(a) == 'vllm') &&
                  argv.sublist(1, math.min(3, argv.length)).contains('serve')
          ? 1
          : 0,
      'jan':
          const {'jan-llama-worker', 'jan-llama-worke'}.contains(comm) ||
              const {'jan-llama-worker', 'jan-llama-worke'}.contains(base)
          ? 1
          : 0,
      'koboldcpp': comm == 'koboldcpp' || base.startsWith('koboldcpp') ? 1 : 0,
    };
    var best = 0, key = '';
    for (final e in claims.entries) {
      if (e.value > best) (best, key) = (e.value, e.key);
    }
    return key;
  }

  /// runtime_pids: key -> the runtime's own processes and all their children.
  Map<String, Set<int>> runtimePids(List<ProcessRecord> processes) {
    final parent = <int, int>{}, roots = <int, String>{};
    for (final process in processes) {
      final stat =
          files.text(
            '/proc/${process.pid}/stat',
            limit: 1024,
            portion: 'head',
          ) ??
          '';
      final fields = stat
          .substring(stat.lastIndexOf(')') + 1)
          .trim()
          .split(RegExp(r'\s+'));
      if (fields.length > 1 && RegExp(r'^\d+$').hasMatch(fields[1])) {
        parent[process.pid] = int.parse(fields[1]);
      }
      final key = runtimeOf(process.comm, process.argv);
      if (key.isNotEmpty) roots[process.pid] = key;
    }
    // A process belongs to the outermost local LLM above it.
    final groups = <String, Set<int>>{};
    for (final pid in {...parent.keys, ...roots.keys}) {
      var seen = 0, current = pid, owner = '';
      while (current != 0 && seen < 64) {
        owner = roots[current] ?? owner;
        current = parent[current] ?? 0;
        seen++;
      }
      if (owner.isNotEmpty) groups.putIfAbsent(owner, () => {}).add(pid);
    }
    return groups;
  }

  List _rows(dynamic reply, String key, int limit) {
    final rows = reply is Map ? reply[key] : null;
    return rows is List ? rows.take(limit).toList() : const [];
  }

  /// The engines' loaded_models: lower-case model name -> state.
  Future<Map<String, String>> loadedModels(RuntimeRecord rt) async {
    final port = portOf(rt);
    Future<dynamic> get(String path) => httpJson(port, path, uid);
    final found = <String, String>{};
    switch (rt.key) {
      case 'llamacpp' || 'jan':
        for (final row in _rows(await get('/models'), 'data', 500)) {
          final status = row is Map ? row['status'] : null;
          final state = status is Map ? '${status['value'] ?? ''}' : '';
          if (const {'loaded', 'loading', 'sleeping'}.contains(state)) {
            found['${(row as Map)['id'] ?? ''}'.toLowerCase()] = state;
          }
        }
      case 'ollama':
        for (final row in _rows(await get('/api/ps'), 'models', 100)) {
          if (row is Map && _truthy(row['name'])) {
            found['${row['name']}'.toLowerCase()] = 'loaded';
          }
        }
      case 'lmstudio':
        if (!ownPort(port, uid)) return _lmsLoaded();
        for (final row in _rows(await get('/api/v0/models'), 'data', 500)) {
          if (row is Map && row['state'] == 'loaded') {
            found['${row['id'] ?? ''}'.toLowerCase()] = 'loaded';
          }
        }
      case 'koboldcpp':
        final rows = _rows(await get('/v1/models'), 'data', 500);
        final first = rows.isNotEmpty && rows.first is Map
            ? '${(rows.first as Map)['id'] ?? ''}'
            : '';
        if (first.startsWith('koboldcpp/')) {
          found['${first.substring(first.indexOf('/') + 1).toLowerCase()}.kcpps'] =
              'loaded';
        }
      default:
        for (final row in _rows(await get('/v1/models'), 'data', 20)) {
          if (row is Map && _truthy(row['id'])) {
            found['${row['id']}'.toLowerCase()] = 'loaded';
          }
        }
    }
    return found;
  }

  static bool _truthy(dynamic v) =>
      v != null && v != false && v != '' && v != 0;

  /// provider_lmstudio.lms_loaded: `lms ps --json` when its server is off.
  Future<Map<String, String>> _lmsLoaded() async {
    final binary = ProviderOps(files, scans).lmsBinary();
    if (binary == null) return {};
    try {
      final process = await Process.start(binary, ['ps', '--json']);
      unawaited(process.stdin.close());
      unawaited(process.stderr.drain<void>());
      final out = <int>[];
      final done = process.stdout.forEach(
        (c) => out.length <= 1024 * 1024 ? out.addAll(c) : null,
      );
      final code = await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      await done.timeout(const Duration(seconds: 1), onTimeout: () {});
      if (code != 0 || out.isEmpty || out.length > 1024 * 1024) return {};
      final rows = jsonDecode(utf8.decode(out));
      final found = <String, String>{};
      for (final row in (rows is List ? rows : const []).take(100)) {
        if (row is Map && row['type'] == 'llm' && row['identifier'] is String) {
          final name = (row['identifier'] as String).toLowerCase();
          found[name.length > 200 ? name.substring(0, 200) : name] = 'loaded';
        }
      }
      return found;
    } catch (_) {
      return {};
    }
  }

  /// snapshot(runtimes).generating: a model loaded and the GPU busy. The
  /// snapshot is taken whole, as the reference takes it (each running
  /// runtime is asked for its models).
  Future<bool> generating(List<RuntimeRecord> runtimes) async {
    final percent = await busy();
    final groups = runtimePids(scans.processes());
    var loaded = false;
    for (final rt in runtimes) {
      final pids = groups[rt.key] ?? const <int>{};
      final vram = pids.fold(0, (a, pid) => a + procVram(pid));
      final models = pids.isEmpty
          ? const <String, String>{}
          : await loadedModels(rt);
      if (vram > modelVram ||
          models.values.any((s) => s == 'loaded' || s == 'loading')) {
        loaded = true;
      }
    }
    return loaded && (percent ?? 0) >= busyPercent;
  }
}

/// provider_watch.agent_instances: how many open instances of these agents
/// run now (background servers and the app's own look-ups left out).
Map<String, int> agentInstances(ProviderScans scans, Set<String> names) {
  String bare(String value) =>
      value.endsWith('.exe') ? value.substring(0, value.length - 4) : value;
  bool interpreter(String value) =>
      const ['node', 'bun', 'deno', 'python', 'python3'].any(value.startsWith);
  const background = {'serve', 'server', 'daemon', '--service', '--daemon'};
  final found = <String, int>{};
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
    found[name] = (found[name] ?? 0) + 1;
  }
  return found;
}

/// flutter_map_editor._guard_model: no unloading while an agent or another
/// consumer uses the runtime.
Future<void> guardModel(
  ScanFiles files,
  ProviderScans scans,
  RuntimeRecord rt,
  List<String> commands,
) async {
  final users = {...commands, ...rt.activeAgents};
  if (agentInstances(scans, users).values.any((n) => n > 0) ||
      await GpuUsage(files, scans).generating([rt])) {
    throw const FormatException('Model is in use; stop its users first');
  }
}

/// flutter_map_editor.validate_actions: the plan's model load/unload actions
/// checked against the runtime as it is now.
Future<List<Map<String, dynamic>>> validateActions(
  ProviderOps ops,
  dynamic actions,
) async {
  if (actions is! List || actions.length > 2) {
    throw const FormatException('Invalid model actions');
  }
  final resolved = <Map<String, dynamic>>[];
  for (final action in actions) {
    if (action is! Map ||
        action.length != 4 ||
        !const {
          'operation',
          'key',
          'model',
          'agents',
        }.every(action.containsKey)) {
      throw const FormatException('Invalid model action');
    }
    if (!const {'model.load', 'model.unload'}.contains(action['operation'])) {
      throw const FormatException('Invalid model operation');
    }
    final commands = action['agents'];
    if (commands is! List ||
        commands.length > 32 ||
        commands.any((c) => c is! String || c.isEmpty || c.length > 128) ||
        commands.toSet().length != commands.length) {
      throw const FormatException('Invalid model users');
    }
    final operation = action['operation'] as String;
    ProviderOps.validate(operation, {
      'key': action['key'],
      'model': action['model'],
    });
    final rt = ops.runtime(action['key'] as String);
    if (!rt.models.contains(action['model']) ||
        (providerFacts['engines'] as Map)[rt.key]?['can_load'] != true) {
      throw const FormatException('Model changed');
    }
    if (operation == 'model.unload') {
      await guardModel(ops.files, ops.providers, rt, [
        for (final c in commands) c as String,
      ]);
    }
    resolved.add(Map<String, dynamic>.from(action));
  }
  return resolved;
}
