import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'context.dart';
import 'desktop.dart' show whichIn;
import 'model_hub.dart' show boundedOutput;

/// llama_tune (task 029): each llama.cpp model measured on this card with
/// the build the llama-server service really runs (ROCm or Vulkan):
/// llama-bench tries three batch sizes with the model's KV cache and flash
/// attention, the fastest prompt processing wins, and the context is what
/// the card's video memory leaves after the measured use. Numbers and
/// names only; nothing is written here (the core turns it into a preview
/// and keeps the record, llm-tuning.json in the app's state folder).

/// llama-bench's batch sizes tried, the batch, the prompt and generation
/// lengths of a run, and the memory kept free for the desktop and growth.
const tuneUbatches = [512, 1024, 2048];
const tuneBatch = 2048, tunePrompt = 2048, tuneGen = 64, tuneMemGen = 16;
const tuneMargin = 512 * 1024 * 1024;

/// What runs the llama-server service: its binary, environment, kind and
/// device lines. [script] marks a wrapper script read while the service was
/// not running: the build it starts and its environment are not known.
final class LlamaBuild {
  LlamaBuild(
    this.binary,
    this.environment,
    this.kind,
    this.version, {
    this.devices = '',
    this.script = false,
  });
  final String binary, kind, version, devices;
  final Map<String, String> environment;
  final bool script;

  /// The build's mark in llm-tuning.json: its kind, the binary's real
  /// folder (a "current" link moved to a new build changes it) and version.
  String get mark {
    var folder = p.dirname(binary);
    try {
      folder = p.dirname(File(binary).resolveSymbolicLinksSync());
    } on FileSystemException {
      // gone: its path as given
    }
    return '$kind $folder $version';
  }
}

/// One run's result: its process output and whether it finished in time.
typedef TuneRun =
    Future<(String, bool)> Function(
      List<String> argv,
      Map<String, String> env,
      Duration timeout,
    );

Future<(String, bool)> _run(
  List<String> argv,
  Map<String, String> env,
  Duration timeout,
) async {
  final (out, ok) = await boundedOutput(
    argv,
    maxBytes: 256 * 1024,
    timeout: timeout,
    environment: env,
    // llama-server prints its version to stderr.
    mergeStderr: true,
  );
  return (utf8.decode(out, allowMalformed: true), ok);
}

/// systemd's property line "Environment=A=1 B=two" as a map.
Map<String, String> unitEnvironment(String line) => {
  for (final pair in RegExp(r'(\w+)=("[^"]*"|\S*)').allMatches(line))
    pair.group(1)!: pair.group(2)!.replaceAll('"', ''),
};

/// A KEY=VALUE file (comments and blank lines skipped).
Map<String, String> envFile(String path) {
  try {
    return {
      for (final line in File(path).readAsLinesSync())
        if (RegExp(r'^\s*[A-Za-z_]\w*=').hasMatch(line))
          line.split('=').first.trim(): line
              .substring(line.indexOf('=') + 1)
              .trim()
              .replaceAll(RegExp(r'''^["']|["']$'''), ''),
    };
  } on FileSystemException {
    return const {};
  }
}

final class LlamaTuner {
  LlamaTuner({
    required this.home,
    required this.environment,
    this.sysfs = '/sys/class/drm',
    this.proc = '/proc',
    TuneRun? run,
    Future<String?> Function(String url)? fetch,
    this.sample = const Duration(milliseconds: 200),
  }) : run = run ?? _run,
       fetch = fetch ?? _fetch;
  final String home, sysfs, proc;
  final Map<String, String> environment;
  final TuneRun run;
  final Future<String?> Function(String url) fetch;
  final Duration sample;

  static Future<String?> _fetch(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 3));
      final response = await request.close().timeout(
        const Duration(seconds: 3),
      );
      if (response.statusCode != 200) return null;
      return await utf8
          .decodeStream(response)
          .timeout(const Duration(seconds: 3));
    } on Object {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// The build the llama-server service runs: while it runs, the program
  /// and environment of its main process (a wrapper script that execs the
  /// real binary included); else its ExecStart (links resolved), Environment
  /// and EnvironmentFiles, else llama-server on PATH; null when none is found.
  Future<LlamaBuild?> build() async {
    var binary = '';
    var pid = 0;
    final env = {...environment};
    final (shown, _) = await run(
      [
        whichIn('systemctl', environment['PATH']) ?? 'systemctl',
        '--user',
        'show',
        'llama-server',
        '--property=ExecStart,Environment,EnvironmentFiles,MainPID',
      ],
      environment,
      const Duration(seconds: 10),
    );
    for (final line in const LineSplitter().convert(shown)) {
      if (line.startsWith('ExecStart=')) {
        binary = RegExp(r'path=([^ ;]+)').firstMatch(line)?.group(1) ?? '';
      } else if (line.startsWith('MainPID=')) {
        pid = int.tryParse(line.substring('MainPID='.length).trim()) ?? 0;
      } else if (line.startsWith('EnvironmentFiles=')) {
        for (final file in RegExp(
          r'(/\S+) \(ignore_errors=\w+\)',
        ).allMatches(line)) {
          env.addAll(envFile(file.group(1)!));
        }
      } else if (line.startsWith('Environment=')) {
        env.addAll(unitEnvironment(line.substring('Environment='.length)));
      }
    }
    final running = pid > 0 ? _process(pid) : null;
    var script = false;
    if (running != null) {
      binary = running.$1;
      env
        ..clear()
        ..addAll(running.$2);
    } else {
      if (binary.isEmpty) {
        binary = whichIn('llama-server', environment['PATH']) ?? '';
      }
      if (binary.isEmpty) return null;
      try {
        binary = File(binary).resolveSymbolicLinksSync();
      } on FileSystemException {
        return null;
      }
      script = _isScript(binary);
    }
    final (devices, _) = await run(
      [binary, '--list-devices'],
      env,
      const Duration(seconds: 20),
    );
    final first = RegExp(
      r'^\s+(ROCm|Vulkan|CUDA|Metal|SYCL)\d*:',
      multiLine: true,
    ).firstMatch(devices);
    final (shownVersion, _) = await run(
      [binary, '--version'],
      env,
      const Duration(seconds: 20),
    );
    // "version: 0.8.0-dev (build 12078, …)", older "version: 12078 (…)".
    final version =
        (RegExp(r'build (\d+)').firstMatch(shownVersion) ??
                RegExp(r'version: (\d+)').firstMatch(shownVersion))
            ?.group(1) ??
        '';
    return LlamaBuild(
      binary,
      env,
      first == null ? 'cpu' : first.group(1)!.toLowerCase(),
      version.isEmpty ? '' : 'b$version',
      devices: [
        for (final l in const LineSplitter().convert(devices))
          if (RegExp(r'^\s+(ROCm|Vulkan|CUDA|Metal|SYCL|CPU)\d*:').hasMatch(l))
            l.trim(),
      ].join('\n'),
      script: script,
    );
  }

  /// The running service's program and environment, when its main process
  /// is a llama-server (a wrapper script that execs it counts).
  (String, Map<String, String>)? _process(int pid) {
    try {
      var exe = Link('$proc/$pid/exe').targetSync();
      if (exe.endsWith(' (deleted)')) return null; // replaced since it started
      if (!p.basename(exe).startsWith('llama-server') ||
          !File(exe).existsSync()) {
        return null;
      }
      final environ = File('$proc/$pid/environ').readAsBytesSync();
      final env = <String, String>{};
      for (final entry
          in utf8.decode(environ, allowMalformed: true).split('\x00')) {
        final at = entry.indexOf('=');
        if (at > 0) env[entry.substring(0, at)] = entry.substring(at + 1);
      }
      return (exe, env);
    } on FileSystemException {
      return null;
    }
  }

  static bool _isScript(String path) {
    try {
      final file = File(path).openSync();
      try {
        final head = file.readSync(2);
        return head.length == 2 && head[0] == 0x23 && head[1] == 0x21; // #!
      } finally {
        file.closeSync();
      }
    } on FileSystemException {
      return false;
    }
  }

  /// The card with the most video memory: (total, used) in bytes, or null.
  (int, int)? vram() {
    (int, int)? best;
    try {
      for (final e in Directory(sysfs).listSync()) {
        final name = p.basename(e.path);
        if (!RegExp(r'^card\d+$').hasMatch(name)) continue;
        int? read(String what) => int.tryParse(
          File(
            '${e.path}/device/mem_info_vram_$what',
          ).readAsStringSync().trim(),
        );
        final total = read('total'), used = read('used');
        if (total == null || used == null) continue;
        if (best == null || total > best.$1) best = (total, used);
      }
    } on FileSystemException {
      return best;
    }
    return best;
  }

  /// What holds the card now (the refusal's text), or '' when it is free: a
  /// model loaded in the llama.cpp router or in Ollama.
  Future<String> busy(String address) async {
    final router = await fetch('http://$address/models');
    if (router != null && RegExp(r'"value"\s*:\s*"loaded"').hasMatch(router)) {
      return 'The card is in use: a model is loaded in llama.cpp. Measure again when it is idle.';
    }
    final ollama = await fetch('http://127.0.0.1:11434/api/ps');
    if (ollama != null) {
      Object? models;
      try {
        final data = jsonDecode(ollama);
        models = data is Map ? data['models'] : null;
      } on FormatException {
        models = null; // not Ollama on that port
      }
      if (models is List && models.isNotEmpty) {
        return 'The card is in use: a model is loaded in Ollama. Measure again when it is idle.';
      }
    }
    return '';
  }

  /// Measures [names] (models of [folder]); [ini] is models.ini's text now.
  Future<Map<String, dynamic>> measure(
    List<String> names,
    String folder,
    String address,
    String ini,
    String? Function(String folder, String name) modelFile,
  ) async {
    final built = await build();
    if (built == null) {
      throw const FormatException('llama.cpp is not installed');
    }
    if (built.script) {
      throw const FormatException(
        'llama.cpp is started by a script: start its service, then measure again',
      );
    }
    final bench = p.join(p.dirname(built.binary), 'llama-bench');
    if (!File(bench).existsSync()) {
      throw const FormatException(
        'llama-bench is not next to the llama.cpp the service runs',
      );
    }
    final holder = await busy(address);
    if (holder.isNotEmpty) throw FormatException(holder);
    final measured = <Map<String, dynamic>>[];
    final skipped = <Map<String, dynamic>>[];
    for (final name in names) {
      try {
        final result = await _one(built, bench, name, folder, ini, modelFile);
        result.containsKey('reason')
            ? skipped.add(result)
            : measured.add(result);
      } on Object catch (error) {
        skipped.add({'name': name, 'reason': '$error'.split('\n').first});
      }
    }
    return {
      'build': built.kind,
      'build_path': built.binary,
      'version': built.version,
      'mark': built.mark,
      'models': measured,
      'skipped': skipped,
    };
  }

  Future<Map<String, dynamic>> _one(
    LlamaBuild built,
    String bench,
    String name,
    String folder,
    String ini,
    String? Function(String folder, String name) modelFile,
  ) async {
    final file = modelFile(folder, name);
    if (file == null) return {'name': name, 'reason': 'no model file'};
    final have = ContextReader.llamaEffective(ini, name);
    String setting(String key, String fallback) {
      final value = have[key] ?? '';
      return value.isEmpty ? fallback : value;
    }

    final cacheK = setting('cache-type-k', 'q8_0');
    final cacheV = setting('cache-type-v', cacheK);
    final flash = setting('flash-attn', 'on');
    final meta = readGguf(file);
    final arch = meta['general.architecture'] ?? '';
    final trained = meta['$arch.context_length'];
    final (perToken, _) = kvLayout(meta, cacheK);
    if (perToken <= 0) {
      return {'name': name, 'reason': 'its memory per token is not known'};
    }
    final card = vram();
    if (card == null) return {'name': name, 'reason': 'no graphics card found'};
    List<String> argv(List<int> ubatches, int gen, int repeats) => [
      bench,
      '-m',
      file,
      '-ngl',
      '99',
      '-fa',
      flash == 'off' ? '0' : '1',
      '-ctk',
      cacheK,
      '-ctv',
      cacheV,
      '-b',
      '$tuneBatch',
      '-ub',
      ubatches.join(','),
      '-p',
      '$tunePrompt',
      '-n',
      '$gen',
      '-r',
      '$repeats',
      '-o',
      'json',
    ];
    // Speed: the fastest prompt processing; within 3 % the smaller batch,
    // which needs less memory. Generation barely depends on it.
    final (speedText, done) = await run(
      argv(tuneUbatches, tuneGen, 2),
      built.environment,
      const Duration(minutes: 10),
    );
    if (!done) return {'name': name, 'reason': 'llama-bench did not finish'};
    final rows = _rows(speedText);
    double rate(int ub, {required bool prompt}) =>
        rows
            .where(
              (r) =>
                  r['n_ubatch'] == ub &&
                  (prompt ? r['n_prompt'] != 0 : r['n_gen'] != 0),
            )
            .map((r) => (r['avg_ts'] as num).toDouble())
            .firstOrNull ??
        0;
    var winner = 0;
    for (final ub in tuneUbatches) {
      if (rate(ub, prompt: true) <= 0) continue;
      if (winner == 0 ||
          rate(ub, prompt: true) > rate(winner, prompt: true) * 1.03) {
        winner = ub;
      }
    }
    if (winner == 0) return {'name': name, 'reason': 'llama-bench failed'};
    // Memory: one short run with the winner, the card's use sampled from
    // just before it.
    final before = vram()?.$2 ?? card.$2;
    var peak = before;
    final timer = Timer.periodic(sample, (_) {
      final now = vram();
      if (now != null && now.$2 > peak) peak = now.$2;
    });
    bool memDone;
    try {
      (_, memDone) = await run(
        argv([winner], tuneMemGen, 1),
        built.environment,
        const Duration(minutes: 5),
      );
    } finally {
      timer.cancel();
    }
    if (!memDone) {
      return {'name': name, 'reason': 'llama-bench did not finish'};
    }
    final now = vram();
    if (now != null && now.$2 > peak) peak = now.$2;
    final used = peak - before;
    // The run held a KV cache for its own tokens; the context gets the rest.
    final tokens = tunePrompt + tuneMemGen;
    final room = card.$1 - before - tuneMargin - used;
    var ctx = room > 0 ? room ~/ perToken + tokens : 0;
    ctx = ctx ~/ step * step;
    if (trained is int && trained > 0 && ctx > trained) ctx = trained;
    if (used <= 0 || ctx < minContext) {
      return {'name': name, 'reason': 'it does not fit on the card'};
    }
    return {
      'name': name,
      'ctx': ctx,
      'ubatch': winner,
      'batch': tuneBatch,
      'pp': rate(winner, prompt: true).round(),
      'tg': rate(winner, prompt: false).round(),
      'used': used,
      'cache': cacheK,
      'flash': flash,
    };
  }

  static List<Map> _rows(String text) {
    final start = text.indexOf('[');
    if (start < 0) return const [];
    try {
      final data = jsonDecode(text.substring(start));
      return data is List
          ? [
              for (final r in data)
                if (r is Map) r,
            ]
          : const [];
    } on FormatException {
      return const [];
    }
  }
}

/// models.ini with a measured model's section: ctx-size, the batch sizes,
/// and the KV cache and flash attention where nothing is set.
String tunedIniText(String old, Map<String, dynamic> m) {
  final name = m['name'] as String;
  var text = ContextReader.llamaSizedText(old, name, m['ctx'] as int);
  text = ContextReader.iniText(text, name, 'ubatch-size', '${m['ubatch']}');
  return ContextReader.iniText(text, name, 'batch-size', '${m['batch']}');
}

/// llm-tuning.json in the app's state folder: each model's last
/// measurement, `{"models": {name: {mark, build_path, version, kind, ctx,
/// ubatch, pp, tg, date} or {mark, reason, date}}}`. Undo of the models.ini
/// change keeps it: a model is measured once per build, also when skipped.
Map<String, dynamic> readTuningRecord(String path) {
  try {
    final data = jsonDecode(File(path).readAsStringSync());
    if (data is Map && data['models'] is Map) {
      return Map<String, dynamic>.from(data);
    }
  } on Object {
    // none, or unreadable: nothing measured yet
  }
  return {'models': <String, dynamic>{}};
}

/// [record] with [measured]'s models and skipped models added.
Map<String, dynamic> withMeasurement(
  Map<String, dynamic> record,
  Map<String, dynamic> measured,
  DateTime now,
) {
  final models = Map<String, dynamic>.from(record['models'] as Map? ?? {});
  final common = {
    'mark': measured['mark'],
    'build_path': measured['build_path'],
    'version': measured['version'],
    'kind': measured['build'],
    'date': now.toUtc().toIso8601String(),
  };
  for (final m in (measured['models'] as List? ?? const []).cast<Map>()) {
    models['${m['name']}'] = {
      ...common,
      for (final k in const ['ctx', 'ubatch', 'pp', 'tg']) k: m[k],
    };
  }
  for (final m in (measured['skipped'] as List? ?? const []).cast<Map>()) {
    models['${m['name']}'] = {...common, 'reason': m['reason']};
  }
  return {'models': models};
}

/// The models of [names] with no record for the build [mark].
List<String> untunedModels(
  Map<String, dynamic> record,
  List<String> names,
  String mark,
) {
  final models = record['models'] as Map? ?? const {};
  return [
    for (final n in names)
      if ((models[n] as Map?)?['mark'] != mark) n,
  ];
}
