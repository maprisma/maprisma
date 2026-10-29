import 'dart:io';
import 'package:path/path.dart' as p;
import 'adapter_assets.g.dart' show providerFacts;
import 'connect_apply.dart';
import 'context.dart';
import 'desktop.dart' show whichIn;
import 'installers.dart' show Gpu, LlamaCppInstaller;
import 'model_hub.dart' show boundedOutput;
import 'provider_scans.dart' show RuntimeRecord;
import 'system_actions.dart' show envWith;

/// llm_tuning: what runs a local LLM (the graphics card, ROCm, Vulkan or
/// CUDA, the build it is), its settings now (its engine's tuning keys, for
/// every model and per model) and, for each model, its size and the context
/// it has against the context the card holds. Names, numbers and settings
/// only. A setting is changed with a backup and Undo, as a connection is.

Map<String, dynamic> engineFacts(String key) => Map<String, dynamic>.from(
  (providerFacts['engines'] as Map)[key] as Map? ?? const {},
);

/// The engine's tuning keys: {key: (allowed values as a regex, what it does)}.
Map<String, (String, String)> tuningKeys(String key) => {
  for (final e in (engineFacts(key)['tuning'] as Map? ?? const {}).entries)
    e.key as String: (
      (e.value as List)[0] as String,
      (e.value as List)[1] as String,
    ),
};

bool _globAny(String folder, bool Function(String name) match) {
  try {
    return Directory(
      folder,
    ).listSync(followLinks: false).any((e) => match(p.basename(e.path)));
  } on FileSystemException {
    return false;
  }
}

/// llm_tuning.stacks_here: the GPU stacks this PC has (only whether their
/// files are there).
List<String> stacksHere(String? path) {
  final found = <String>[];
  bool hip(String folder) =>
      _globAny(folder, (n) => n.startsWith('libamdhip64.so'));
  final rocm = [
    for (final d in _list('/opt'))
      if (p.basename(d).startsWith('rocm')) '$d/lib',
  ];
  if (rocm.any(hip) || hip('/usr/lib')) found.add('ROCm');
  if (_globAny('/usr/share/vulkan/icd.d', (n) => n.endsWith('.json')) ||
      _globAny('/etc/vulkan/icd.d', (n) => n.endsWith('.json'))) {
    found.add('Vulkan');
  }
  if (whichIn('nvidia-smi', path) != null ||
      _globAny('/usr/lib', (n) => n.startsWith('libcuda.so'))) {
    found.add('CUDA');
  }
  return found;
}

List<String> _list(String folder) {
  try {
    return [
      for (final e in Directory(folder).listSync(followLinks: false)) e.path,
    ];
  } on FileSystemException {
    return const [];
  }
}

/// provider_llamacpp.devices: (build, its device lines) from
/// `llama-server --list-devices` (bounded, a few seconds).
Future<(String, String)> llamaDevices(String? path) async {
  final binary = whichIn('llama-server', path);
  if (binary == null) return ('', '');
  final (out, _) = await boundedOutput(
    [binary, '--list-devices'],
    maxBytes: 8192,
    timeout: const Duration(seconds: 20),
    mergeStderr: true,
  );
  final text = String.fromCharCodes(out);
  final lines = [
    for (final l in text.split(RegExp(r'\r\n|\r|\n')))
      if (RegExp(r'^\s+(ROCm|Vulkan|CUDA|Metal|SYCL|CPU)\d*:').hasMatch(l))
        l.trim(),
  ];
  final first = lines.isEmpty
      ? ''
      : lines.first
            .split(':')
            .first
            .replaceAll(RegExp(r'\d+$'), '')
            .toLowerCase();
  final build =
      const {'rocm': 'rocm', 'vulkan': 'vulkan', 'cuda': 'cuda'}[first] ??
      (out.isNotEmpty ? 'cpu' : '');
  return (build, lines.take(4).join('\n'));
}

/// context_ctl.fit: (trained, best, per token, known).
(int, int, int, bool) fitFacts(String modelFile, int vram, String cache) {
  final meta = readGguf(modelFile);
  final arch = '${meta['general.architecture'] ?? ''}';
  final raw = meta['$arch.context_length'];
  final native = raw is int ? raw : 0;
  final size = sizeOf(modelFile);
  final (perToken, fixed) = kvLayout(meta, cache);
  if (perToken == 0 && fixed == 0) return (native, native, 0, false);
  final room = vram - reserve - size - fixed;
  if (room <= 0) return (native, 0, perToken, true);
  var best = perToken != 0 ? room ~/ perToken : native;
  best = best ~/ step * step;
  if (native != 0 && native < best) best = native;
  return (native, best >= minContext ? best : 0, perToken, true);
}

final class LlmTuning {
  LlmTuning(this.context, this.home, {this.path});
  final ContextReader context;
  final String home;
  final String? path;

  String get ollamaEnv => '$home/.config/ollama/server.env';

  String _expand(String folder) => folder.isEmpty
      ? '.'
      : folder == '~' || folder.startsWith('~/')
      ? p.join(home, folder.length > 2 ? folder.substring(2) : '')
      : folder;

  /// engine.tuning_now: {"*": {key: value}, model: {key: value}}.
  Map<String, Map<String, String>> tuningNow(String key) {
    final keys = tuningKeys(key);
    if (key == 'llamacpp') {
      String text;
      try {
        text = File(context.modelsIni).readAsStringSync();
      } on FileSystemException {
        return {};
      }
      return {
        for (final e in ContextReader.iniSections(text).entries)
          e.key: {
            for (final v in e.value.entries)
              if (keys.containsKey(v.key)) v.key: v.value,
          },
      };
    }
    if (key == 'ollama') {
      // Not the app's service: its settings are not the app's to change.
      if (!File(ollamaEnv).existsSync()) return {};
      return {
        '*': {
          for (final v in context.readEnv(ollamaEnv).entries)
            if (keys.containsKey(v.key)) v.key: v.value,
        },
      };
    }
    return {};
  }

  /// engine.tuning_changes: what sets one setting (backup, Undo).
  List<Change> tuningChanges(
    String key,
    String section,
    String setting,
    String value,
  ) {
    final rule = tuningKeys(key)[setting];
    if (rule == null || !RegExp('^(?:${rule.$1})\$').hasMatch(value)) {
      throw FormatException(
        '$setting = $value is not a setting the app changes',
      );
    }
    if (key == 'llamacpp') {
      final before = _read(context.modelsIni);
      return [
        Change(
          context.modelsIni,
          before,
          ContextReader.iniText(before, section, setting, value),
        ),
      ];
    }
    if (key == 'ollama') {
      if (!File(ollamaEnv).existsSync()) {
        throw const FormatException(
          "not the app's own Ollama service: change it where it was set up",
        );
      }
      if (section != '*') {
        throw FormatException(
          '$setting = $value is not a setting the app changes',
        );
      }
      final before = _read(ollamaEnv);
      final next = envWith(before, setting, value);
      return next == before ? [] : [Change(ollamaEnv, before, next)];
    }
    throw const FormatException('nothing to change here');
  }

  /// provider_llamacpp.context_changes: a model's context in models.ini.
  List<Change> contextChanges(String key, String model, int ctx) {
    if (key != 'llamacpp') {
      throw const FormatException('the context is set in the local LLM itself');
    }
    final before = _read(context.modelsIni);
    return [
      Change(
        context.modelsIni,
        before,
        ContextReader.iniText(before, model, 'ctx-size', '$ctx'),
      ),
    ];
  }

  static String _read(String path) {
    try {
      return File(path).readAsStringSync();
    } on FileSystemException {
      return '';
    }
  }

  int _modelSize(RuntimeRecord rt, String name) {
    if (rt.modelsDir.isEmpty) return 0;
    final folder = _expand(rt.modelsDir);
    try {
      if (rt.key == 'llamacpp') {
        // The file named after it, else one whose name differs only in case.
        for (final candidate in ['$folder/$name.gguf', ..._list(folder)]) {
          if (candidate.endsWith('.gguf') &&
              p.basenameWithoutExtension(candidate).toLowerCase() ==
                  name.toLowerCase() &&
              FileSystemEntity.isFileSync(candidate)) {
            return File(candidate).lengthSync();
          }
        }
        return 0;
      }
      if (rt.key == 'ollama') {
        final blob = context.ollamaModelFile(folder, name);
        return blob == null ? 0 : File(blob).lengthSync();
      }
    } on Object {
      return 0;
    }
    return 0;
  }

  (int, String, String?)? _contextNow(
    RuntimeRecord rt,
    String folder,
    String name,
  ) {
    if (rt.key == 'llamacpp') {
      final (now, cache) = context.llamaSettings(name);
      return (now, cache, context.llamaModelFile(folder, name));
    }
    if (rt.key == 'ollama') {
      final env = context.readEnv(ollamaEnv);
      final fallback = int.tryParse(env['OLLAMA_CONTEXT_LENGTH'] ?? '0') ?? 0;
      return (
        context.ollamaContext(folder, name, fallback),
        env['OLLAMA_KV_CACHE_TYPE'] ?? 'f16',
        context.ollamaModelFile(folder, name),
      );
    }
    return null;
  }

  /// llm_tuning.collect: the facts for one local LLM.
  Future<Map<String, dynamic>> collect(
    RuntimeRecord rt,
    Gpu gpu, {
    Future<String> Function()? llamaVersion,
  }) async {
    final engine = engineFacts(rt.key);
    final builds = [
      for (final b in engine['builds'] as List? ?? const [])
        (b as List).cast<String>(),
    ];
    final stacks = stacksHere(path);
    var build = '', devices = '';
    if (rt.key == 'llamacpp') {
      final found = await llamaDevices(path);
      devices = found.$2;
      try {
        final version = await (llamaVersion ?? () async => '')();
        build = version.contains('-') ? version.split('-').last : found.$1;
      } on Object {
        build = found.$1;
      }
    }
    final label = {for (final b in builds) b[0]: b[1]}[build] ?? '';
    if (label.isNotEmpty && !stacks.contains(label) && build != 'cpu') {
      stacks.add(label); // it runs on it: installed where the app does not look
    }
    Map<String, Map<String, String>> settings;
    try {
      settings = tuningNow(rt.key);
    } on Object {
      settings = {};
    }
    final folder = _expand(rt.modelsDir);
    final models = <Map<String, dynamic>>[];
    for (final name in rt.models.take(40)) {
      final model = <String, dynamic>{
        'name': name,
        'size': _modelSize(rt, name),
        'context': 0,
        'best': 0,
        'trained': 0,
        'per_token': 0,
      };
      (int, String, String?)? found;
      try {
        found = _contextNow(rt, folder, name);
      } on Object {
        found = null;
      }
      if (found != null) {
        model['context'] = found.$1;
        if (found.$3 != null && gpu.vram != 0) {
          try {
            final (trained, best, perToken, known) = fitFacts(
              found.$3!,
              gpu.vram,
              found.$2.isEmpty ? 'f16' : found.$2,
            );
            if (!known) continue; // speech, tokenizer models: no context
            model
              ..['best'] = best
              ..['trained'] = trained
              ..['per_token'] = perToken;
          } on Object {
            // Its header could not be read: no fit.
          }
        }
      }
      models.add(model);
    }
    return {
      'runtime': rt.name,
      'key': rt.key,
      'gpu': gpu.name.isNotEmpty ? gpu.name : gpu.vendor,
      'vram': gpu.vram,
      'stacks': stacks,
      'build': build,
      'builds': [for (final b in builds) b[0]],
      'devices': devices,
      'settings': settings,
      'tuning': {
        for (final e in tuningKeys(rt.key).entries)
          e.key: [e.value.$1, e.value.$2],
      },
      'per_model': engine['tuning_per_model'] != false,
      'models': models,
      'loaded': <String>[],
      'vram_used': 0,
    };
  }
}

/// The installed llama.cpp's version ("b11658-rocm"), '' when not the app's.
Future<String> Function() llamaVersionOf(LlamaCppInstaller installer) =>
    () async => installer.currentVersion();
