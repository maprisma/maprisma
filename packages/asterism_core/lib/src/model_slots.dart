import 'dart:convert';
import 'dart:io';
import 'connect_apply.dart' show Change;
import 'py_values.dart' show pyCompare, pyJsonDumps;
import 'system_actions.dart' show envWith;

/// model_slots: how many models a local LLM must keep loaded for its agents,
/// and whether they fit. When agents use different models of one local LLM
/// it must keep that many loaded, or it swaps them on every request while
/// they work. The app sets the number where the local LLM lets it
/// (llama.cpp's LLAMA_ARG_MODELS_MAX, Ollama's OLLAMA_MAX_LOADED_MODELS in
/// the app's own env files; LM Studio one or many); a number fixed in the
/// user's own start script is theirs, and only a warning says what to change.

const overhead = 1.15; // a model's file plus its context cache and runtime

/// engine.slots_kind.
const slotsKinds = {
  'llamacpp': 'count',
  'ollama': 'count',
  'lmstudio': 'switch',
};

/// model_slots.models_in_use: runtime id → {model label: [agent labels]}.
Map<String, Map<String, List<String>>> modelsInUse(Map? graph) {
  if (graph == null) return {};
  final nodes = {
    for (final n in (graph['nodes'] as List? ?? const []).cast<Map>())
      '${n['id']}': n,
  };
  final edges = (graph['edges'] as List? ?? const []).cast<Map>();
  final served = <String, Set<String>>{};
  for (final e in edges) {
    if (e['kind'] == 'serves' && '${e['source']}'.startsWith('runtime:')) {
      served.putIfAbsent('${e['target']}', () => {}).add('${e['source']}');
    }
  }
  final found = <String, Map<String, List<String>>>{};
  for (final e in edges) {
    if (e['kind'] != 'default' || !served.containsKey(e['target'])) continue;
    final agent = '${e['source']}', model = '${e['target']}';
    for (final runtime in served[model]!) {
      if (edges.any(
        (x) =>
            x['source'] == agent &&
            x['target'] == runtime &&
            x['kind'] == 'uses',
      )) {
        final label = nodes.containsKey(model)
            ? '${nodes[model]!['label']}'
            : model;
        final who = nodes.containsKey(agent)
            ? '${nodes[agent]!['label']}'
            : agent;
        found
            .putIfAbsent(runtime, () => {})
            .putIfAbsent(label, () => [])
            .add(who);
      }
    }
  }
  return found;
}

/// model_slots.Need as a map: key, name, models, kind, slots, fixed_by, sizes.
int needCount(Map need) => (need['models'] as Map).length;

/// Need.change: the app should set it.
bool needChange(Map need) {
  final kind = '${need['kind']}', count = needCount(need);
  if (kind.isEmpty || '${need['fixed_by']}'.isNotEmpty || count == 0) {
    return false;
  }
  if (kind == 'switch') return (need['slots'] == 1) != (count == 1);
  return need['slots'] != count;
}

/// Need.swaps: more models in use than it keeps loaded.
bool needSwaps(Map need) =>
    need['slots'] != 0 && needCount(need) > (need['slots'] as int);

String _gib(double size) {
  final g = size / (1 << 30);
  return size >= 10 * (1 << 30) ? _fixed(g, 0) : _fixed(g, 1);
}

/// Python's "{:.Nf}" (a tie to the even digit).
String _fixed(double x, int digits) {
  final scale = digits == 0 ? 1 : 10;
  final scaled = x * scale;
  var n = scaled.floorToDouble();
  final rest = scaled - n;
  if (rest > 0.5 || (rest == 0.5 && n % 2 != 0)) n += 1;
  return (n / scale).toStringAsFixed(digits);
}

/// model_slots.hints: warnings for a local LLM's models in use.
List<Map<String, dynamic>> slotHints(
  Map need,
  int vram,
  String Function(String) tr,
) {
  String f(String text, List<Object?> args) {
    var out = tr(text);
    for (var i = 0; i < args.length; i++) {
      out = out.replaceAll('{$i}', '${args[i]}');
    }
    return out;
  }

  final out = <Map<String, dynamic>>[];
  final count = needCount(need);
  if (count < 2) return out;
  final models = (need['models'] as Map).keys.map((k) => '$k').toList()
    ..sort(pyCompare);
  final who = [
    for (final m in models)
      '${((need['models'] as Map)[m] as List).join(', ')}: $m',
  ].join('; ');
  if (needSwaps(need) && !needChange(need)) {
    var text = f(
      'Its agents use {0} different models ({1}), but {2} keeps {3} loaded at a time: while they work at the same time it swaps them, which is slow.',
      [count, who, need['name'], need['slots']],
    );
    if ('${need['fixed_by']}'.isNotEmpty) {
      text +=
          ' ${f('The number is set in {0} (--models-max): raise it there, or give the agents the same model.', [need['fixed_by']])}';
    }
    out.add({'level': 'warning', 'text': text});
  }
  final known = [
    for (final s in (need['sizes'] as Map? ?? const {}).values)
      if (s is int && s != 0) s,
  ];
  final total = known.fold<int>(0, (a, b) => a + b) * overhead;
  if (vram != 0 && total > vram) {
    out.add({
      'level': 'warning',
      'text': f(
        'The {0} models its agents use need about {1} GB of video memory together; the graphics card has {2} GB. They cannot all stay loaded: choose smaller models, or the same one for several agents.',
        [count, _gib(total), _gib(vram.toDouble())],
      ),
    });
  }
  return out;
}

/// llm_engine.arg_number: the number after --flag (or --flag=N).
int? argNumber(List<String>? argv, String flag) {
  final list = argv ?? const [];
  for (var i = 0; i < list.length; i++) {
    final arg = list[i];
    final value = arg == flag && i + 1 < list.length
        ? list[i + 1]
        : arg.startsWith('$flag=')
        ? arg.substring(flag.length + 1)
        : null;
    if (value != null && RegExp(r'^-*\d+$').hasMatch(value.trim())) {
      // int(value): the sign kept; "--5" is not a number there either.
      final number = int.tryParse(value.trim());
      if (number != null) return number;
    }
  }
  return null;
}

String _head(String path, int limit) {
  try {
    final file = File(path).openSync();
    try {
      return utf8.decode(file.readSync(limit), allowMalformed: true);
    } finally {
      file.closeSync();
    }
  } on FileSystemException {
    return '';
  }
}

/// The engines' slot facts and changes (provider_llamacpp / _ollama /
/// _lmstudio: slots, slots_fixed_by, slot_changes).
final class EngineSlots {
  EngineSlots({
    required this.home,
    required this.processes,
    required this.parentOf,
  });
  final String home;

  /// (pid, comm, argv) of this account's processes (inventory.own_processes).
  final List<(int, String, List<String>)> Function() processes;
  final int Function(int pid) parentOf;

  String get llamaEnv => '$home/.config/llama.cpp/server.env';
  String get ollamaEnv => '$home/.config/ollama/server.env';
  String get lmstudioSettings => '$home/.lmstudio/settings.json';

  String? _unit(Map rt) {
    final service = '${rt['service'] ?? ''}';
    if (service.isEmpty) return null;
    final path = '$home/.config/systemd/user/$service.service';
    return FileSystemEntity.isFileSync(path) ? path : null;
  }

  List<(String, String)> _startLines(Map rt) {
    final unit = _unit(rt);
    if (unit == null) return [];
    final text = _head(unit, 200000);
    final found = [(unit, text)];
    for (final m in RegExp(
      r'^ExecStart=[-@:+!]*(.+)$',
      multiLine: true,
    ).allMatches(text).take(3)) {
      final words = m[1]!.trim().split(RegExp(r'\s+'));
      if (words.isEmpty || words.first.isEmpty) continue;
      var program = words.first.replaceAll(RegExp('''^['"]|['"]\$'''), '');
      if (program == '~' || program.startsWith('~/')) {
        program = '$home${program.substring(1)}';
      }
      List<int> bytes;
      try {
        final file = File(program).openSync();
        try {
          bytes = file.readSync(200000);
        } finally {
          file.closeSync();
        }
      } on FileSystemException {
        continue;
      }
      if (bytes.length >= 4 &&
          bytes[0] == 0x7f &&
          bytes[1] == 0x45 &&
          bytes[2] == 0x4c &&
          bytes[3] == 0x46) {
        continue;
      }
      found.add((program, utf8.decode(bytes, allowMalformed: true)));
    }
    return found;
  }

  bool _ours(Map rt) {
    final unit = _unit(rt);
    return unit != null &&
        (_head(unit, 4000).contains('installed by Maprisma') ||
            _head(unit, 4000).contains('installed by AI Agents Map'));
  }

  Map<String, String> _env(String path) => {
    for (final m in RegExp(
      r'^\s*([A-Z_][A-Z0-9_]*)=(.*)$',
      multiLine: true,
    ).allMatches(_head(path, 65536)))
      m[1]!: m[2]!.trim().replaceAll(RegExp('''^['"]+|['"]+\$'''), ''),
  };

  Map _lmSettings() {
    try {
      final data = jsonDecode(_head(lmstudioSettings, 2000000));
      return data is Map ? data : {};
    } on Object {
      return {};
    }
  }

  List<String>? _routerArgv() {
    final servers = <int, List<String>>{
      for (final (pid, comm, argv) in processes())
        if (comm == 'llama-server' &&
            argv.isNotEmpty &&
            !argv.first.contains('/.lmstudio/'))
          pid: argv,
    };
    for (final e in servers.entries) {
      if (!servers.containsKey(parentOf(e.key))) return e.value;
    }
    return null;
  }

  /// engine.slots_fixed_by: where the user fixed the number ('' = the app may set it).
  String slotsFixedBy(Map rt) {
    switch (rt['key']) {
      case 'llamacpp':
        for (final (where, text) in _startLines(rt)) {
          if (RegExp(r'--models-max(?:[ =])').hasMatch(text) &&
              !(where == _unit(rt) && _ours(rt))) {
            return where.replaceFirst(home, '~');
          }
        }
        return '';
      case 'ollama':
        return FileSystemEntity.isFileSync(ollamaEnv)
            ? ''
            : 'OLLAMA_MAX_LOADED_MODELS';
      case 'lmstudio':
        return FileSystemEntity.isFileSync(lmstudioSettings) ? '' : 'LM Studio';
    }
    return '';
  }

  /// engine.slots: models it keeps loaded now (0: no limit).
  int slots(Map rt) {
    switch (rt['key']) {
      case 'llamacpp':
        int? number = rt['running'] == true
            ? argNumber(_routerArgv(), '--models-max')
            : null;
        if (number == null) {
          for (final (_, text) in _startLines(rt)) {
            final m = RegExp(r'--models-max(?:\s+|=)(\d+)').firstMatch(text);
            if (m != null) {
              number = int.parse(m[1]!);
              break;
            }
          }
        }
        if (number == null) {
          final value = _env(llamaEnv)['LLAMA_ARG_MODELS_MAX'] ?? '';
          number = RegExp(r'^\d+$').hasMatch(value) ? int.parse(value) : 4;
        }
        return number;
      case 'ollama':
        final value = _env(ollamaEnv)['OLLAMA_MAX_LOADED_MODELS'] ?? '';
        return RegExp(r'^\d+$').hasMatch(value) ? int.parse(value) : 3;
      case 'lmstudio':
        final developer = _lmSettings()['developer'];
        final one = developer is Map
            ? developer['unloadPreviousJITModelOnLoad'] ?? true
            : true;
        return one != false ? 1 : 0;
    }
    return 1;
  }

  static String _read(String path) {
    try {
      return File(path).readAsStringSync();
    } on FileSystemException {
      return '';
    }
  }

  Change? _change(String path, String next) {
    final old = _read(path);
    return next == old ? null : Change(path, old, next);
  }

  /// engine.slot_changes: what makes it keep `count` models loaded.
  List<Change> slotChanges(Map rt, int count) {
    if (slotsFixedBy(rt).isNotEmpty || count < 1) return [];
    final changes = <Change?>[];
    switch (rt['key']) {
      case 'llamacpp':
        changes.add(
          _change(
            llamaEnv,
            envWith(_read(llamaEnv), 'LLAMA_ARG_MODELS_MAX', '$count'),
          ),
        );
        final unit = _unit(rt);
        if (unit != null && _ours(rt)) {
          // An older version put the number on the command line: it would win over the env file.
          changes.add(
            _change(
              unit,
              _read(unit).replaceAll(RegExp(r' --models-max(?:\s+|=)\d+'), ''),
            ),
          );
        }
      case 'ollama':
        changes.add(
          _change(
            ollamaEnv,
            envWith(_read(ollamaEnv), 'OLLAMA_MAX_LOADED_MODELS', '$count'),
          ),
        );
      case 'lmstudio':
        final data = Map<String, dynamic>.from(_lmSettings());
        final developer = data['developer'] is Map
            ? Map<String, dynamic>.from(data['developer'] as Map)
            : <String, dynamic>{};
        final one = developer['unloadPreviousJITModelOnLoad'] ?? true;
        if (one != false && count > 1 || one == false && count == 1) {
          data['developer'] = {
            ...developer,
            'unloadPreviousJITModelOnLoad': count == 1,
          };
          changes.add(
            _change(lmstudioSettings, '${pyJsonDumps(data, indent: 2)}\n'),
          );
        }
    }
    return [for (final c in changes) ?c];
  }
}

/// model_slots.plan: a need for every local LLM some agent uses, with what
/// its engine says (a read that fails keeps the defaults).
List<Map<String, dynamic>> slotPlan(
  List<Map> runtimes,
  Map<String, Map<String, List<String>>> inUse,
  EngineSlots engines,
  int Function(Map rt, String model) sizeOf,
) {
  final needs = <Map<String, dynamic>>[];
  for (final rt in runtimes) {
    final models = inUse['runtime:${rt['key']}'];
    if (models == null || models.isEmpty) continue;
    final need = <String, dynamic>{
      'key': rt['key'],
      'name': rt['name'],
      'models': {
        for (final e in models.entries) e.key: [...e.value],
      },
      'kind': slotsKinds[rt['key']] ?? '',
      'slots': 1,
      'fixed_by': '',
      'sizes': <String, int>{},
    };
    try {
      need['slots'] = engines.slots(rt);
      need['fixed_by'] = engines.slotsFixedBy(rt);
      need['sizes'] = {for (final m in models.keys) m: sizeOf(rt, m)};
    } on Object {
      // As the reference: what was read so far stays.
    }
    needs.add(need);
  }
  return needs;
}
