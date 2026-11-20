import 'dart:convert';
import 'dart:io';
import 'adapters.dart';
import 'package:path/path.dart' as p;
import 'connect_apply.dart';
import 'context.dart';
import 'installers.dart' show checkTrusted;
import 'inventory.dart' show chatModels;
import 'llama_tune.dart';
import 'local_llm.dart';
import 'model_guard.dart';
import 'pc_facts.dart';
import 'provider_config.dart';
import 'provider_ops.dart';
import 'provider_scans.dart';
import 'scan_files.dart';
import 'system_actions.dart' show envWith;

/// The schema selects the format; user files never select a writer or path.
final class ProviderConfigFiles {
  ProviderConfigFiles(this.files, this.config);
  final ScanFiles files;
  final ConfigFiles config;
  late final context = ContextReader(files, config);
  String get home => files.identity.home;
  String read(String path, {bool anchor = false}) {
    checkTrusted(p.dirname(path), files.posix);
    final st = files.posix.lstatFull(path);
    if (anchor && st == null) {
      throw const FormatException('Configuration file is missing');
    }
    if (st != null && st.mode & 0x12 != 0) {
      throw const FormatException('Configuration file permissions are unsafe');
    }
    return config.read(path);
  }

  Map jsonObject(String text) {
    if (text.trim().isEmpty) return <String, dynamic>{};
    final value = jsonDecode(text);
    if (value is! Map) {
      throw const FormatException('Configuration is not a JSON object');
    }
    return value;
  }

  String select(Map facts, String? requested) {
    final schema = (facts['schema'] as List).cast<Map>();
    final scope = schema.first['scope'];
    final models = (facts['models'] as List).cast<Map>();
    if (scope == 'global') {
      if (requested != null && requested.isNotEmpty) {
        throw const FormatException('This provider has global settings');
      }
      return '';
    }
    final name =
        requested ??
        (scope == 'global' || scope == 'default'
            ? '*'
            : '${models.where((m) => m['loaded'] == true).firstOrNull?['name'] ?? models.firstOrNull?['name'] ?? ''}');
    if (name == '*' && scope != 'per_model') return name;
    if (name.isEmpty && scope == 'per_model' && models.isEmpty) return name;
    if (!models.any((m) => m['name'] == name)) {
      throw const FormatException('Choose an available model');
    }
    return name;
  }

  Map<String, String> paths(RuntimeRecord rt, String model) {
    final schema = configSchema(rt.key),
        writer = '${schema.firstOrNull?['writer']}';
    switch (writer) {
      case 'ini_defaults':
        return {
          'main': context.modelsIni,
          'unit':
              '$home/.config/systemd/user/${rt.service.isEmpty ? 'llama-server' : rt.service}.service',
        };
      case 'environment':
        return {
          'main': '$home/.config/ollama/server.env',
          'unit':
              '$home/.config/systemd/user/${rt.service.isEmpty ? 'ollama' : rt.service}.service',
        };
      case 'lms_fields':
        final file = context.lmstudioDefaultsFile(context.lmstudioEntry(model));
        if (file == null) {
          throw const FormatException('LM Studio does not list this model');
        }
        return {'main': file};
      case 'jan_pair':
        final data = context.janDataFolder();
        final file = context.janModelYml(model, data);
        if (file == null) {
          throw const FormatException('Jan does not list this model');
        }
        return {'main': file, 'preset': '$data/llamacpp/router.preset.ini'};
      case 'kobold_json':
        if (!model.endsWith('.kcpps') || p.basename(model) != model) {
          throw const FormatException('KoboldCpp does not list this model');
        }
        return {'main': '${context.koboldConfigs}/$model'};
      default:
        return {};
    }
  }

  bool ownedUnit(String text) => RegExp(
    r'^Description=.*installed by (?:Maprisma|Asterism|AI Agents Map)\)',
    multiLine: true,
  ).hasMatch(text);
  Map<String, dynamic> readValues(
    List<Map> schema,
    Map<String, String> paths,
    String model,
  ) {
    final writer = '${schema.first['writer']}', path = paths['main'];
    if (path == null) return {};
    final old = read(
      path,
      anchor: const ['environment', 'jan_pair', 'kobold_json'].contains(writer),
    );
    if (writer == 'ini_defaults') {
      return {
        ...?ContextReader.iniSections(old)['*'],
        ...?ContextReader.iniSections(old)[model],
      };
    }
    if (writer == 'environment') {
      return {
        for (final m in RegExp(
          r'^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.*)$',
          multiLine: true,
        ).allMatches(old))
          m[1]!: m[2]!.trim().replaceAll(
            RegExp(
              '^['
              '"\''
              ']|['
              '"\''
              ']\$',
            ),
            '',
          ),
      };
    }
    if (writer == 'lms_fields') {
      final data = jsonObject(old), load = data['load'];
      final fields = load is Map && load['fields'] is List
          ? load['fields'] as List
          : const [];
      return {
        for (final s in schema)
          for (final f in fields.whereType<Map>())
            if (f['key'] ==
                (s['wire'] is Map ? (s['wire'] as Map)['key'] : s['wire']))
              '${s['id']}': f['value'] is Map
                  ? (f['value'] as Map)['checked'] == true
                        ? (f['value'] as Map)['value']
                        : s['default']
                  : f['value'],
      };
    }
    if (writer == 'jan_pair') {
      final preset = read(paths['preset']!, anchor: true);
      final ini = {
        ...?ContextReader.iniSections(preset)['*'],
        ...?ContextReader.iniSections(preset)[model],
      };
      final result = <String, dynamic>{};
      for (final field in schema) {
        final value =
            ini[(field['wire'] as Map)['ini']] ??
            RegExp(
              '^${RegExp.escape('${(field['wire'] as Map)['yaml']}')}:\\s*([^#\\n]+)',
              multiLine: true,
            ).firstMatch(old)?[1]?.trim().replaceAll(RegExp('["\']'), '');
        if (value != null) result['${field['id']}'] = value;
      }
      return result;
    }
    final data = jsonObject(old);
    return {
      for (final field in schema)
        if (data.containsKey(field['id']) ||
            field['id'] == 'flashattention' &&
                data.containsKey('noflashattention') ||
            field['id'] == 'blasbatchsize' && data.containsKey('batchsize'))
          '${field['id']}':
              field['id'] == 'flashattention' &&
                  data.containsKey('noflashattention')
              ? data['noflashattention'] != true
              : field['id'] == 'blasbatchsize'
              ? data['batchsize'] ?? data['blasbatchsize']
              : data[field['id']],
    };
  }

  dynamic typed(Map s, dynamic value) {
    if (value is String) {
      value = value.replaceFirst(RegExp(r'\s+[;#].*$'), '').trim();
    }
    if (s['role'] == 'cache_level' && value is String) {
      value = const {'f16': 0, 'q8_0': 1, 'q4_0': 2}[value] ?? value;
    }
    if (value == null) return s['default'];
    if (s['type'] == 'enum' &&
        (s['values'] as List? ?? const []).every((v) => v is int) &&
        value is String) {
      value = int.tryParse(value) ?? value;
    }
    if ((s['special'] as List? ?? const []).contains(value)) return value;
    if (s['type'] == 'int' || s['type'] == 'int_or_special') {
      return int.tryParse('$value') ?? value;
    }
    if (s['type'] == 'float') {
      if (value == 'max') return 1.0;
      if (value == 'off') return 0.0;
      return double.tryParse('$value') ?? value;
    }
    if (s['type'] == 'bool') {
      return value == true || value == 'true' || value == '1';
    }
    return value;
  }

  /// Hugging Face metadata only; no model code, tokenizer or trust_remote_code.
  (Map<String, dynamic>, int) hfModel(RuntimeRecord rt, String name) {
    final roots = <String>{
      if (p.isAbsolute(name)) name,
      if (rt.modelsDir.isNotEmpty) files.expand(rt.modelsDir),
      if (rt.modelsDir.isNotEmpty) p.join(files.expand(rt.modelsDir), name),
    };
    for (final root in roots.toList()) {
      final hub = p.join(
        root,
        'models--${name.replaceAll('/', '--')}',
        'snapshots',
      );
      roots.addAll(files.list(hub, limit: 8));
    }
    for (final root in roots) {
      final raw = files.json(p.join(root, 'config.json'), limit: 256 * 1024);
      if (raw.isEmpty) continue;
      int number(List<String> keys) {
        for (final key in keys) {
          final value = raw[key];
          if (value is int && value > 0 && value <= 10000000) return value;
        }
        return 0;
      }

      final heads = number(['num_attention_heads', 'n_head']);
      final meta = <String, dynamic>{
        'general.architecture': 'hf',
        'hf.context_length': number([
          'max_position_embeddings',
          'max_sequence_length',
          'n_positions',
        ]),
        'hf.block_count': number(['num_hidden_layers', 'n_layer']),
        'hf.embedding_length': number(['hidden_size', 'n_embd']),
        'hf.attention.head_count': heads,
        'hf.attention.head_count_kv': number(['num_key_value_heads']) == 0
            ? heads
            : number(['num_key_value_heads']),
        if (number(['head_dim']) > 0)
          'hf.attention.key_length': number(['head_dim']),
        if (number(['head_dim']) > 0)
          'hf.attention.value_length': number(['head_dim']),
      };
      final index = files.json(
        p.join(root, 'model.safetensors.index.json'),
        limit: 1024 * 1024,
      );
      var size = configInt((index['metadata'] as Map?)?['total_size']);
      if (size == 0) {
        for (final path in files.list(root, limit: 512)) {
          if (path.endsWith('.safetensors')) {
            size += File(path).lengthSync();
          }
        }
      }
      return (meta, size);
    }
    return (<String, dynamic>{}, 0);
  }

  Future<Map<String, dynamic>> collect(
    RuntimeRecord rt, {
    PcFacts? pc,
    LlamaBuild? built,
    Map<String, dynamic>? hardware,
    Map<String, dynamic>? measurements,
  }) async {
    final schema = configSchema(rt.key);
    if (schema.isEmpty || !rt.installed) {
      throw const FormatException('Unknown local provider');
    }
    final writer = '${schema.first['writer']}';
    final hw = hardware ?? await (pc ?? PcFacts(files)).collect(rt);
    if (writer == 'ini_defaults' && built == null) {
      built = await LlamaTuner(
        home: home,
        environment: files.identity.environment,
      ).build();
    }
    final models = <Map<String, dynamic>>[],
        settings = <String, Map<String, dynamic>>{};
    final configured = <String, List<String>>{};
    final notes = <String>[];
    var writable = !const ['command_advice', 'launch_advice'].contains(writer);
    String unit = '';
    if (writer == 'environment' || writer == 'ini_defaults') {
      final unitPath = paths(rt, '*')['unit']!;
      if (files.exists(unitPath)) {
        try {
          unit = read(unitPath, anchor: true);
        } on Object {
          writable = false;
          notes.add('Configuration file is unavailable');
        }
      }
      if (writer == 'environment' &&
          (!ownedUnit(unit) || !files.exists(paths(rt, '*')['main']!))) {
        writable = false;
      }
      if (writer == 'ini_defaults' && !ownedUnit(unit)) {
        notes.add(
          'The unit or launcher may override these settings; its flags win',
        );
      }
    }
    for (final name in chatModels(rt.models).take(40)) {
      String? file;
      var currentContext = 0;
      Map<String, dynamic> meta = {};
      var size = 0;
      var modelWritable = writable;
      try {
        final raw = writer == 'environment' && !writable
            ? <String, dynamic>{}
            : readValues(schema, paths(rt, name), name);
        if (writer == 'ini_defaults' && ownedUnit(unit)) {
          raw.addAll(unitFlags(unit));
        }
        configured[name] = [
          for (final field in schema)
            if (raw.containsKey(field['id'])) '${field['id']}',
        ];
        settings[name] = {
          for (final field in schema)
            '${field['id']}': typed(field, raw[field['id']]),
        };
        currentContext = configInt(
          settings[name]![schema
              .where((s) => s['role'] == 'context')
              .first['id']],
        );
      } on Object {
        modelWritable = false;
        notes.add('Some model settings could not be read');
      }
      try {
        final folder = files.expand(rt.modelsDir);
        if (writer == 'ini_defaults') {
          file = context.llamaModelFile(folder, name);
        } else if (writer == 'environment') {
          file = context.ollamaModelFile(folder, name);
        } else if (writer == 'lms_fields') {
          file = context.lmstudioModelFile(context.lmstudioEntry(name));
        } else if (writer == 'jan_pair') {
          final locations = paths(rt, name);
          final preset = read(locations['preset']!, anchor: true);
          final yml = read(locations['main']!, anchor: true);
          final sections = ContextReader.iniSections(preset);
          file =
              sections[name]?['model'] ??
              RegExp(
                r'''^model_path:\s*['"]?([^'"\n]+?)['"]?\s*$''',
                multiLine: true,
              ).firstMatch(yml)?[1];
          if (file != null && !p.isAbsolute(file)) {
            file = p.join(context.janDataFolder(), file);
          }
        } else if (writer == 'kobold_json') {
          final raw = jsonObject(read(paths(rt, name)['main']!, anchor: true));
          final value = raw['model_param'] ?? raw['model'];
          file = value is String ? files.expand(value) : null;
        } else if (writer == 'command_advice') {
          (meta, size) = hfModel(rt, name);
        }
        if (file != null) {
          if (files.credential(file) ||
              files.credential(File(file).resolveSymbolicLinksSync())) {
            throw const FormatException('Credential file unavailable');
          }
          meta = readGguf(file);
          size = sizeOf(file);
        }
      } on Object {
        notes.add('Model memory is not fully known; this is an estimate');
      }
      models.add({
        'name': name,
        'size': size,
        'meta': meta,
        'context': currentContext,
        'chat': true,
        'loaded': false,
        'writable': modelWritable,
      });
    }
    final hasDefault = schema.first['scope'] != 'per_model';
    if (hasDefault) {
      try {
        final raw = writer == 'environment' && !writable
            ? <String, dynamic>{}
            : readValues(schema, paths(rt, '*'), '*');
        if (writer == 'ini_defaults' && ownedUnit(unit)) {
          raw.addAll(unitFlags(unit));
        }
        configured['*'] = [
          for (final field in schema)
            if (raw.containsKey(field['id'])) '${field['id']}',
        ];
        settings['*'] = {
          for (final s in schema) '${s['id']}': typed(s, raw[s['id']]),
        };
      } on Object {
        writable = false;
        notes.add('Configuration file is unavailable');
      }
    }
    // Read-only loaded-model endpoint; never calls refresh/sync or starts a server.
    if (rt.running) {
      try {
        final loaded = await GpuUsage(
          files,
          ProviderScans(files),
        ).loadedModels(rt);
        for (final m in models) {
          m['loaded'] = loaded.containsKey('${m['name']}'.toLowerCase());
        }
      } on Object {
        /* Settings remain available when the server does not answer. */
      }
    }
    final overrides = <String, dynamic>{};
    if (writer == 'ini_defaults' && writable) {
      try {
        for (final e in ContextReader.iniSections(
          read(context.modelsIni),
        ).entries) {
          if (e.key != '*') overrides[e.key] = e.value.keys.toList();
        }
      } on Object {
        writable = false;
        notes.add('Configuration file is unavailable');
      }
    }
    return {
      'key': rt.key,
      'runtime': rt.name,
      'schema': schema,
      'hardware': hw,
      'settings': settings,
      'configured': configured,
      'defaults':
          settings['*'] ?? {for (final s in schema) '${s['id']}': s['default']},
      'models': models,
      'overrides': overrides,
      'scope_models': schema.first['scope'] == 'global'
          ? <String>[]
          : [if (hasDefault) '*', for (final m in models) m['name']],
      'writable': writable,
      'read_only_reason': writable
          ? ''
          : writer == 'environment'
          ? 'System Ollama is configured outside Maprisma'
          : 'This provider offers configuration advice',
      'restart': schema.first['restart'],
      'can_control':
          writer != 'launch_advice' &&
          ProviderOps(files, ProviderScans(files)).canControl(rt),
      'can_reload': writer == 'lms_fields' || writer == 'kobold_json',
      'running': rt.running,
      'build': built?.kind ?? '',
      'version': built?.version ?? '',
      'build_mark': built?.script == true ? '' : built?.mark ?? '',
      'measurements':
          measurements ??
          readTuningRecord(
            '${files.identity.stateDir}/llm-tuning.json',
          )['models'],
      'notes': {
        if (writer == 'environment' && models.isEmpty)
          'No installed chat model: using a conservative context',
        ...notes,
      }.toList(),
      'untuned': built == null
          ? const <String>[]
          : untunedModels(
              {
                'models':
                    measurements ??
                    readTuningRecord(
                      '${files.identity.stateDir}/llm-tuning.json',
                    )['models'],
              },
              rt.models,
              built.mark,
            ),
    };
  }

  bool canWrite(Map facts, String model) =>
      facts['writable'] == true &&
      ((facts['schema'] as List).first['scope'] == 'global' ||
          model.isNotEmpty) &&
      (model == '*' || configModel(facts, model)['writable'] != false);

  Map<String, dynamic> view(
    Map<String, dynamic> facts,
    String model,
    String profile,
  ) {
    final math = ConfigMath(facts, model),
        recommended = math.recommend(profile);
    final writable = canWrite(facts, model);
    return {
      for (final e in facts.entries)
        if (!const [
          'settings',
          'defaults',
          'measurements',
          'build_mark',
          'overrides',
          'configured',
        ].contains(e.key))
          e.key: e.value,
      'writable': writable,
      if (!writable && facts['writable'] == true)
        'read_only_reason': model.isEmpty
            ? 'Add a model before configuring this provider.'
            : 'Configuration file is unavailable',
      'model': model,
      'profile': profile,
      'current': math.displayCurrent,
      'overrides': (facts['overrides'] as Map?)?[model] ?? const <String>[],
      'recommended': recommended['recommended'],
      'fit': recommended['fit'],
      if (!writable &&
          const {
            'environment',
            'command_advice',
            'launch_advice',
          }.contains(configWriter(facts)))
        'snippet': snippet(facts, model, recommended['values'] as Map),
    };
  }

  static Map<String, String> unitFlags(String unit) {
    final flags = <String, String>{};
    for (final line
        in unit.split('\n').where((l) => l.startsWith('ExecStart='))) {
      for (final m in RegExp(
        r'''\s+--(gpu-layers|flash-attn)(?:=|\s+)(?:"([^"]*)"|'([^']*)'|(\S+))''',
      ).allMatches(line)) {
        final value = m[2] ?? m[3] ?? m[4]!;
        if (m[1] == 'gpu-layers'
            ? RegExp(r'^(all|\d{1,3})$').hasMatch(value)
            : const ['on', 'off', 'auto'].contains(value)) {
          flags[m[1]!] = value;
        } else {
          throw const FormatException('Not verified on this PC');
        }
      }
    }
    return flags;
  }

  String? snippet(Map facts, String model, Map values) {
    final writer = configWriter(facts);
    if (writer == 'environment') {
      return '[Service]\n${[for (final e in values.entries) 'Environment="${e.key}=${e.value}"'].join('\n')}\n';
    }
    if (writer == 'command_advice') {
      return 'vllm serve <model> ${[for (final e in values.entries) '--${e.key} ${e.value}'].join(' ')}';
    }
    if (writer == 'launch_advice') return 'strata launch';
    return null;
  }

  List<Change> changes(RuntimeRecord rt, String model, Map values) {
    final schema = configSchema(rt.key), writer = '${schema.first['writer']}';
    final path = paths(rt, model), main = path['main'];
    if (main == null) {
      throw const FormatException('This provider offers configuration advice');
    }
    final old = read(
      main,
      anchor: const ['environment', 'jan_pair', 'kobold_json'].contains(writer),
    );
    var next = old;
    final unit =
        writer == 'ini_defaults' &&
            path['unit'] != null &&
            files.exists(path['unit']!)
        ? read(path['unit']!, anchor: true)
        : '';
    if (ownedUnit(unit)) {
      // Migrate the effective hard flags before removing them. Preserve the
      // other models' current settings when editing only one model or key.
      final sections = ContextReader.iniSections(old);
      for (final section in {'*', ...sections.keys}) {
        for (final flag in unitFlags(unit).entries) {
          if (section == '*' || sections[section]!.containsKey(flag.key)) {
            next = ContextReader.iniText(next, section, flag.key, flag.value);
          }
        }
      }
    }
    final changes = <Change>[];
    var preset = writer == 'jan_pair'
        ? read(path['preset']!, anchor: true)
        : '';
    final oldPreset = preset;
    final data = const ['lms_fields', 'kobold_json'].contains(writer)
        ? jsonObject(old)
        : null;
    if (writer == 'environment' &&
        !ownedUnit(read(path['unit']!, anchor: true))) {
      throw const FormatException('This provider offers configuration advice');
    }
    for (final e in values.entries) {
      final s = schema.where((s) => s['id'] == e.key).firstOrNull;
      if (s == null || s['verified'] != true) {
        throw const FormatException('Not verified on this PC');
      }
      final v = e.value;
      switch (writer) {
        case 'ini_defaults':
          next = ContextReader.iniText(
            next,
            model,
            '${s['wire']}',
            v == null ? null : '$v',
          );
        case 'environment':
          next = envWith(next, '${s['wire']}', '$v');
        case 'lms_fields':
          data!.putIfAbsent('preset', () => '');
          data.putIfAbsent('operation', () => {'fields': []});
          if (data['load'] is! Map) data['load'] = <String, dynamic>{};
          final load = data['load'] as Map, wire = s['wire'];
          final key = wire is Map ? wire['key'] : wire;
          final fields = [
            for (final f
                in load['fields'] is List ? load['fields'] as List : const [])
              if (f is! Map || f['key'] != key) f,
          ];
          fields.add({
            'key': key,
            'value': wire is Map ? {'checked': true, 'value': v} : v,
          });
          load['fields'] = fields;
        case 'jan_pair':
          final wire = s['wire'] as Map;
          next = yamlValue(next, '${wire['yaml']}', v);
          preset = ContextReader.iniText(preset, model, '${wire['ini']}', '$v');
        case 'kobold_json':
          data![e.key] = v;
          if (e.key == 'flashattention' &&
              data.containsKey('noflashattention')) {
            data['noflashattention'] = v != true;
          }
          if (e.key == 'blasbatchsize' && data.containsKey('batchsize')) {
            data['batchsize'] = v;
          }
        default:
          throw const FormatException(
            'This provider offers configuration advice',
          );
      }
    }
    if (data != null) {
      next = '${const JsonEncoder.withIndent('  ').convert(data)}\n';
    }
    if (next != old) changes.add(Change(main, old, next));
    if (preset != oldPreset) {
      changes.add(Change(path['preset']!, oldPreset, preset));
    }
    if (writer == 'ini_defaults' &&
        path['unit'] != null &&
        files.exists(path['unit']!)) {
      if (ownedUnit(unit)) {
        final nextUnit = unit
            .split('\n')
            .map(
              (l) => l.startsWith('ExecStart=')
                  ? l.replaceAll(
                      RegExp(
                        r'''\s+--(?:gpu-layers|flash-attn)(?:=|\s+)(?:"[^"]*"|'[^']*'|\S+)''',
                      ),
                      '',
                    )
                  : l,
            )
            .join('\n');
        if (nextUnit != unit) {
          changes.add(Change(path['unit']!, unit, nextUnit));
        }
      }
    }
    return changes;
  }

  static String yamlValue(String old, String key, dynamic value) {
    final re = RegExp('^${RegExp.escape(key)}:.*\$', multiLine: true);
    final match = re.firstMatch(old),
        comment = match == null
            ? ''
            : RegExp(r'\s+#.*$').firstMatch(match[0]!)?[0] ?? '';
    if (match != null) return old.replaceFirst(re, '$key: $value$comment');
    return '${old.trimRight()}\n$key: $value\n';
  }
}

List<String> configConnectedAgents(
  ScanFiles files,
  RuntimeRecord rt, {
  List<Adapter>? adapters,
}) {
  final local = LocalLlm(files);
  return {
    ...rt.agents,
    ...rt.activeAgents,
    for (final adapter in adapters ?? builtinAdapters())
      if (local.connected(adapter, rt.key)) adapter.command,
  }.toList();
}

/// Control is separate from configuration writes and always guarded first.
Future<Map<String, dynamic>> configControl(
  ProviderOps ops,
  String operation,
  Map params, {
  List<String> agents = const [],
  List<Adapter>? adapters,
  Future<void> Function(RuntimeRecord)? guard,
  RuntimeRecord Function(String)? runtime,
  Future<(bool, String)> Function(RuntimeRecord)? stop,
  Future<(bool, String)> Function(RuntimeRecord)? start,
  Future<(bool, String)> Function(RuntimeRecord, String)? unload,
  Future<(bool, String)> Function(RuntimeRecord, String)? load,
}) async {
  if (params['key'] is! String) {
    throw const FormatException('Invalid provider operation');
  }
  final rt = (runtime ?? ops.runtime)(params['key'] as String);
  if (!rt.installed || !configurable(rt.key)) {
    throw const FormatException('Unknown local provider');
  }
  if (operation == 'providers.restart' &&
      (params.length != 1 ||
          configWriter({'schema': configSchema(rt.key)}) == 'launch_advice' ||
          !ops.canControl(rt))) {
    throw const FormatException('Provider cannot be controlled');
  }
  final model = params['model'];
  if (operation == 'providers.reload_model' &&
      (params.length != 2 ||
          configSchema(rt.key).first['restart'] != 'model_reload' ||
          model is! String ||
          !rt.models.contains(model))) {
    throw const FormatException('Model unavailable');
  }
  if (!const [
    'providers.restart',
    'providers.reload_model',
  ].contains(operation)) {
    throw const FormatException('Invalid provider operation');
  }
  final users = {
    ...agents,
    ...configConnectedAgents(ops.files, rt, adapters: adapters),
  }.toList();
  await (guard ?? (r) => guardModel(ops.files, ops.providers, r, users))(rt);
  void require((bool, String) result) {
    if (!result.$1) {
      throw StateError(
        result.$2.isEmpty ? 'Provider operation failed' : result.$2,
      );
    }
  }

  if (operation == 'providers.restart') {
    require(await (stop ?? ops.stop)(rt));
    require(await (start ?? ops.start)(rt));
  } else {
    require(await (unload ?? ops.unloadModel)(rt, model as String));
    if (configWriter({'schema': configSchema(rt.key)}) != 'kobold_json') {
      require(await (load ?? ops.load)(rt, model));
    }
  }
  return {'ok': true};
}
