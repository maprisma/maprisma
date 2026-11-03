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
/// names only; nothing is written here (the core turns it into a preview).

/// The marker line in a model's models.ini section: which build it was
/// measured for. Undo of the change puts the old marker back too.
const tunedMarker = '; maprisma tuned:';

/// llama-bench's batch sizes tried, the batch, the prompt and generation
/// lengths of a run, and the memory kept free for the desktop and growth.
const tuneUbatches = [512, 1024, 2048];
const tuneBatch = 2048, tunePrompt = 2048, tuneGen = 64, tuneMemGen = 16;
const tuneMargin = 512 * 1024 * 1024;

/// What runs the llama-server service: its binary, environment, and kind.
final class LlamaBuild {
  LlamaBuild(this.binary, this.environment, this.kind, this.version);
  final String binary, kind, version;
  final Map<String, String> environment;

  /// The marker value: the binary's real folder (a "current" link moved to
  /// a new build changes it) and its version.
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
    TuneRun? run,
    Future<String?> Function(String url)? fetch,
    this.sample = const Duration(milliseconds: 200),
  }) : run = run ?? _run,
       fetch = fetch ?? _fetch;
  final String home, sysfs;
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

  /// The build the llama-server service runs (its ExecStart, Environment and
  /// EnvironmentFiles), else llama-server on PATH; null when none is found.
  Future<LlamaBuild?> build() async {
    var binary = '';
    final env = {...environment};
    final (shown, _) = await run(
      [
        whichIn('systemctl', environment['PATH']) ?? 'systemctl',
        '--user',
        'show',
        'llama-server',
        '--property=ExecStart,Environment,EnvironmentFiles',
      ],
      environment,
      const Duration(seconds: 10),
    );
    for (final line in const LineSplitter().convert(shown)) {
      if (line.startsWith('ExecStart=')) {
        binary = RegExp(r'path=([^ ;]+)').firstMatch(line)?.group(1) ?? '';
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
    if (binary.isEmpty) {
      binary = whichIn('llama-server', environment['PATH']) ?? '';
    }
    if (binary.isEmpty) return null;
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
    );
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

  /// What holds the card now, or '' when it is free: a model loaded in the
  /// llama.cpp router or in Ollama.
  Future<String> busy(String address) async {
    final router = await fetch('http://$address/models');
    if (router != null && RegExp(r'"value"\s*:\s*"loaded"').hasMatch(router)) {
      return 'a model is loaded in llama.cpp';
    }
    final ollama = await fetch('http://127.0.0.1:11434/api/ps');
    if (ollama != null) {
      final models = (jsonDecode(ollama) as Map?)?['models'];
      if (models is List && models.isNotEmpty) {
        return 'a model is loaded in Ollama';
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
    final bench = p.join(p.dirname(built.binary), 'llama-bench');
    if (!File(bench).existsSync()) {
      throw const FormatException(
        'llama-bench is not next to the llama.cpp the service runs',
      );
    }
    final holder = await busy(address);
    if (holder.isNotEmpty) {
      throw FormatException(
        'The card is in use ($holder); tune when it is idle',
      );
    }
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
    // Memory: one short run with the winner, the card's use sampled.
    final before = card.$2;
    var peak = before;
    final timer = Timer.periodic(sample, (_) {
      final now = vram();
      if (now != null && now.$2 > peak) peak = now.$2;
    });
    try {
      await run(
        argv([winner], tuneMemGen, 1),
        built.environment,
        const Duration(minutes: 5),
      );
    } finally {
      timer.cancel();
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
/// the KV cache and flash attention where nothing is set, and the marker.
String tunedIniText(String old, Map<String, dynamic> m, String mark) {
  final name = m['name'] as String;
  var text = ContextReader.llamaSizedText(old, name, m['ctx'] as int);
  text = ContextReader.iniText(text, name, 'ubatch-size', '${m['ubatch']}');
  text = ContextReader.iniText(text, name, 'batch-size', '${m['batch']}');
  return markSection(text, name, '$tunedMarker $mark');
}

/// [text] with the marker line in [section] set to [line] (the section
/// exists: tunedIniText made it).
String markSection(String text, String section, String line) {
  final lines = text.split('\n');
  final start = lines.indexWhere(
    (l) => RegExp('^\\s*\\[${RegExp.escape(section)}\\]\\s*\$').hasMatch(l),
  );
  if (start < 0) return text;
  var end = lines.indexWhere((l) => RegExp(r'^\s*\[').hasMatch(l), start + 1);
  if (end < 0) end = lines.length;
  final at = lines
      .sublist(start + 1, end)
      .indexWhere((l) => l.startsWith(tunedMarker));
  if (at >= 0) {
    lines[start + 1 + at] = line;
  } else {
    lines.insert(start + 1, line);
  }
  return lines.join('\n');
}

/// The models of [names] whose section has no marker for [mark].
List<String> untunedModels(String ini, List<String> names, String mark) {
  final marks = <String, String>{};
  String? section;
  for (final line in ini.split('\n')) {
    final head = RegExp(r'^\s*\[(.+)\]\s*$').firstMatch(line);
    if (head != null) {
      section = head.group(1);
    } else if (section != null && line.startsWith(tunedMarker)) {
      marks[section] = line.substring(tunedMarker.length).trim();
    }
  }
  return [
    for (final n in names)
      if (marks[n] != mark) n,
  ];
}
