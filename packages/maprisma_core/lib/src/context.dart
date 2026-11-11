import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'connect_apply.dart';
import 'provider_scans.dart' show RuntimeRecord;
import 'posix_ffi.dart';
import 'py_values.dart';
import 'scan_files.dart';

/// Python context_ctl: the best context per model for this graphics card, and
/// how llama.cpp, LM Studio and Ollama keep it.
const gib = 1 << 30;
const reserve = gib * 3 ~/ 2, step = 4096, minContext = 4096, ubatch = 1024;
const cacheBytes = {
  'f16': 2.0,
  'bf16': 2.0,
  'f32': 4.0,
  'q8_0': 34 / 32,
  'q4_0': 18 / 32,
  'q4_1': 20 / 32, //
  'q5_0': 22 / 32, 'q5_1': 24 / 32, 'iq4_nl': 18 / 32,
};
const _maxKv = 100000,
    _maxArray = 4096,
    _maxDepth = 4,
    _maxKept = 32,
    _maxArch = 256;
const _wanted = [
  '.context_length',
  '.block_count',
  '.head_count_kv',
  '.head_count',
  '.embedding_length', //
  '.key_length',
  '.value_length',
  '.key_length_swa',
  '.value_length_swa',
  '.sliding_window',
  '.sliding_window_pattern',
];

/// context_ctl.open_regular: the file for reading only when the opened
/// descriptor is a regular file — opened without blocking, so a FIFO (or a
/// device) with a .gguf name returns at once instead of waiting for a writer,
/// and checked on that descriptor (no race with a replaced name). Links to a
/// regular file are fine. FormatException for anything else.
RandomAccessFile openRegular(String path) {
  final posix = Posix();
  final fd = posix.openAt(-100, path, Posix.nonBlock);
  try {
    if (posix.statFull(fd).mode & 0xf000 != 0x8000) {
      throw const FormatException('not a regular file');
    }
    // The same open file (its inode), now as a blocking reader.
    return File('/proc/self/fd/$fd').openSync();
  } finally {
    posix.close(fd);
  }
}

/// context_ctl.read_gguf: the header values needed here (bounded).
Map<String, dynamic> readGguf(String path) {
  final file = openRegular(path);
  try {
    Uint8List take(int n) {
      final data = file.readSync(n);
      if (data.length != n) throw const FormatException('short GGUF');
      return data;
    }

    ByteData bytes(int n) => ByteData.sublistView(take(n));
    int u32() => bytes(4).getUint32(0, Endian.little);
    int u64() => bytes(8).getUint64(0, Endian.little);
    if (ascii.decode(take(4), allowInvalid: true) != 'GGUF') {
      throw const FormatException('not a GGUF file');
    }
    final version = u32();
    final count = version >= 2 ? (u64(), u64()).$2 : (u32(), u32()).$2;
    if (count > _maxKv) throw const FormatException('implausible header');
    String? string({bool keep = true, int limit = 1 << 20}) {
      final length = u64();
      if (length > limit) throw const FormatException('implausible string');
      if (!keep) {
        file.setPositionSync(file.positionSync() + length);
        return null;
      }
      return utf8.decode(take(length), allowMalformed: true);
    }

    const sizes = {
      0: 1,
      1: 1,
      2: 2,
      3: 2,
      4: 4,
      5: 4,
      6: 4,
      7: 1,
      10: 8,
      11: 8,
      12: 8,
    };
    dynamic scalar(int kind) {
      final b = bytes(sizes[kind]!);
      return switch (kind) {
        0 => b.getUint8(0),
        1 => b.getInt8(0),
        2 => b.getUint16(0, Endian.little),
        3 => b.getInt16(0, Endian.little),
        4 => b.getUint32(0, Endian.little),
        5 => b.getInt32(0, Endian.little),
        6 => b.getFloat32(0, Endian.little),
        7 => b.getUint8(0) != 0,
        10 => b.getUint64(0, Endian.little),
        11 => b.getInt64(0, Endian.little),
        _ => b.getFloat64(0, Endian.little),
      };
    }

    dynamic value(int kind, {bool keep = true, int depth = 0}) {
      if (sizes.containsKey(kind)) return scalar(kind);
      if (kind == 8) return string(keep: false);
      if (kind == 9) {
        final sub = u32(), length = u64();
        if (keep) {
          if (!sizes.containsKey(sub) || length > _maxArray) {
            throw const FormatException('implausible array');
          }
          return [for (var i = 0; i < length; i++) scalar(sub)];
        }
        if (sizes.containsKey(sub)) {
          file.setPositionSync(file.positionSync() + sizes[sub]! * length);
          return null;
        }
        if (depth >= _maxDepth) {
          throw const FormatException('implausible array');
        }
        for (var i = 0; i < length; i++) {
          value(sub, keep: false, depth: depth + 1);
        }
        return null;
      }
      throw FormatException('unknown value type $kind');
    }

    final meta = <String, dynamic>{};
    for (var i = 0; i < count; i++) {
      final key = string()!;
      final kind = u32();
      if (key == 'general.architecture' && kind == 8) {
        meta[key] = string(limit: _maxArch);
        continue;
      }
      final keep =
          _wanted.any(key.endsWith) && (sizes.containsKey(kind) || kind == 9);
      final result = value(kind, keep: keep);
      if (keep) {
        if (meta.length >= _maxKept) {
          throw const FormatException('implausible header');
        }
        meta[key] = result;
      }
    }
    return meta;
  } finally {
    file.closeSync();
  }
}

int _int(dynamic v) => v is bool
    ? (v ? 1 : 0)
    : v is num
    ? v.truncate()
    : 0;

/// context_ctl.kv_layout: (bytes per token of context, fixed sliding-window bytes).
(int, int) kvLayout(Map<String, dynamic> meta, String cache) {
  final arch = meta['general.architecture'] ?? '';
  dynamic get(String key) => meta['$arch.$key'];
  final layersRaw = pyTruthy(get('block_count')) ? get('block_count') : 0;
  if (layersRaw is! int || layersRaw < 0 || layersRaw > _maxArray) {
    throw const FormatException('implausible header');
  }
  final layers = layersRaw;
  final heads = get('attention.head_count');
  dynamic first(dynamic v) => v is List
      ? (v.isEmpty ? 0 : v.map((x) => x as num).reduce((a, b) => a > b ? a : b))
      : v;
  final embed = _int(
    pyTruthy(get('embedding_length')) ? get('embedding_length') : 0,
  );
  final firstHeads = first(heads);
  final headDim = embed != 0 && pyTruthy(firstHeads)
      ? embed ~/ _int(firstHeads)
      : 128;
  int or(String key, int fallback) =>
      pyTruthy(get(key)) ? _int(get(key)) : fallback;
  final kDim = or('attention.key_length', headDim),
      vDim = or('attention.value_length', headDim);
  final kSwa = or('attention.key_length_swa', kDim),
      vSwa = or('attention.value_length_swa', vDim);
  var kv = get('attention.head_count_kv');
  kv ??= heads;
  final perLayer = kv is List
      ? [for (final x in kv.take(layers)) _int(pyTruthy(x) ? x : 0)]
      : List.filled(layers, _int(pyTruthy(kv) ? kv : 0));
  final window = or('attention.sliding_window', 0);
  final pattern = get('attention.sliding_window_pattern');
  final List<bool> swa;
  if (pattern is List) {
    swa = [
      for (final x in pattern.take(layers)) pyTruthy(x),
      ...List.filled(
        layers > pattern.length ? layers - pattern.length : 0,
        false,
      ),
    ];
  } else if (pattern is int && pattern is! bool && pattern > 1 && window != 0) {
    swa = [for (var i = 0; i < layers; i++) i % pattern < pattern - 1];
  } else {
    swa = List.filled(layers, false);
  }
  final element = cacheBytes[cache] ?? 2.0;
  var perToken = 0.0, fixed = 0.0;
  for (var i = 0; i < perLayer.length && i < swa.length; i++) {
    if (swa[i] && window != 0) {
      fixed += perLayer[i] * (kSwa + vSwa) * element * (window + ubatch);
    } else {
      perToken += perLayer[i] * (kDim + vDim) * element;
    }
  }
  return (perToken.ceil(), fixed.ceil());
}

/// context_ctl._size_of: all parts of a split model.
int sizeOf(String path) {
  final split = RegExp(
    r'^(.*)-\d{5}-of-(\d{5})\.gguf$',
  ).firstMatch(p.basename(path));
  if (split == null) return File(path).lengthSync();
  var total = 0;
  for (final e in Directory(p.dirname(path)).listSync()) {
    final name = p.basename(e.path);
    if (name.startsWith('${split[1]}-') &&
        name.endsWith('-of-${split[2]}.gguf')) {
      total += File(e.path).lengthSync();
    }
  }
  return total;
}

/// context_ctl.fit(...).best: the context that fits (0: the model alone does not).
int bestContext(String modelFile, int vram, String cache) {
  final meta = readGguf(modelFile);
  final arch = meta['general.architecture'] ?? '';
  final raw = meta['$arch.context_length'];
  final native = _int(pyTruthy(raw) ? raw : 0);
  final size = sizeOf(modelFile);
  final (perToken, fixed) = kvLayout(meta, cache);
  if (perToken == 0 && fixed == 0) return native;
  final room = vram - reserve - size - fixed;
  if (room <= 0) return 0;
  var best = perToken != 0 ? room ~/ perToken : native;
  best = best ~/ step * step;
  if (native != 0 && native < best) best = native;
  return best >= minContext ? best : 0;
}

final class ContextReader {
  ContextReader(this.files, this.config);
  final ScanFiles files;
  final ConfigFiles config;
  String get home => files.identity.home;
  String get modelsIni => p.join(home, '.config/llama.cpp/models.ini');
  String get lmstudio => p.join(home, '.lmstudio');

  /// gpu_usage.gpu_totals()[1]: the discrete card's VRAM (sysfs), else nvidia-smi.
  int vramTotal() {
    int? best;
    for (final entry in files.list(
      '/sys/class/drm',
      limit: 4000,
      allowRootOwned: true,
    )) {
      if (!p.basename(entry).startsWith('card')) continue;
      final text = files.text(
        '$entry/device/mem_info_vram_total',
        limit: 64,
        follow: true,
        // sysfs files report 4096 bytes: read the head, as the reference does.
        portion: 'head',
        allowRootOwned: true,
      );
      final size = int.tryParse((text ?? '').trim());
      if (size == null) continue;
      if (best == null || size > best) best = size;
    }
    if (best != null) return best;
    try {
      final out = Process.runSync('nvidia-smi', [
        '--query-gpu=memory.used,memory.total,utilization.gpu',
        '--format=csv,noheader,nounits',
      ]);
      if (out.exitCode != 0) return 0;
      final parts = (out.stdout as String).split('\n').first.split(',');
      return (double.parse(parts[1].trim()) * 1024 * 1024).toInt();
    } catch (_) {
      return 0;
    }
  }

  // --- llama.cpp ------------------------------------------------------------------------

  static Map<String, Map<String, String>> iniSections(String text) {
    final sections = <String, Map<String, String>>{};
    String? current;
    for (final line in const LineSplitter().convert(text)) {
      final header = RegExp(r'^\s*\[([^\]]+)\]\s*$').firstMatch(line);
      if (header != null) {
        current = header[1]!;
        sections.putIfAbsent(current, () => {});
        continue;
      }
      final pair = RegExp(
        r'^\s*([A-Za-z0-9_-]+)\s*=\s*(.*?)\s*$',
      ).firstMatch(line);
      if (current != null && pair != null) {
        sections[current]![pair[1]!] = pair[2]!;
      }
    }
    return sections;
  }

  (int, String) llamaSettings(String name) {
    String text;
    try {
      text = File(modelsIni).readAsStringSync();
    } on FileSystemException {
      text = '';
    }
    final sections = iniSections(text);
    final own = sections[name] ?? {}, shared = sections['*'] ?? {};
    final ctx = [
      own['ctx-size'],
      shared['ctx-size'],
      '0',
    ].firstWhere((v) => v != null && v.isNotEmpty)!;
    final cache = [
      own['cache-type-k'],
      shared['cache-type-k'],
      'f16',
    ].firstWhere((v) => v != null && v.isNotEmpty)!;
    return (RegExp(r'^\d+$').hasMatch(ctx) ? int.parse(ctx) : 0, cache);
  }

  /// context_ctl.llama_own_context: the ctx-size of the model's own section
  /// (0: none; "[*]" does not count).
  int llamaOwnContext(String name) {
    String text;
    try {
      text = File(modelsIni).readAsStringSync();
    } on FileSystemException {
      text = '';
    }
    final ctx = iniSections(text)[name]?['ctx-size'] ?? '';
    return RegExp(r'^\d+$').hasMatch(ctx) ? int.parse(ctx) : 0;
  }

  /// context_ctl.SIZED: what the app sets along with a context it worked
  /// out, where nothing is set yet (own section or "[*]"): a q8_0 KV cache
  /// (half the memory of f16) and flash attention, which a quantized KV
  /// cache needs. A setting the user chose stays.
  static const sized = [
    ('cache-type-k', 'q8_0'),
    ('cache-type-v', 'q8_0'),
    ('flash-attn', 'on'),
  ];

  /// context_ctl.llama_effective: "[*]", then the model's own section.
  static Map<String, String> llamaEffective(String text, String name) {
    final sections = iniSections(text);
    return {...?sections['*'], ...?sections[name]};
  }

  /// context_ctl.llama_auto_cache: the KV cache type a worked-out context is
  /// sized for: the one set, else q8_0.
  String llamaAutoCache(String name) {
    String text;
    try {
      text = File(modelsIni).readAsStringSync();
    } on FileSystemException {
      text = '';
    }
    final set = llamaEffective(text, name)['cache-type-k'] ?? '';
    return set.isEmpty ? 'q8_0' : set;
  }

  /// context_ctl.llama_sized_text: the model's ctx-size, and [sized] where
  /// nothing is set; the rest stays.
  static String llamaSizedText(String old, String name, int ctx) {
    final have = llamaEffective(old, name);
    var text = iniText(old, name, 'ctx-size', '$ctx');
    for (final (key, value) in sized) {
      if ((have[key] ?? '').isEmpty) text = iniText(text, name, key, value);
    }
    return text;
  }

  static String iniText(String old, String section, String key, String value) {
    if (!RegExp(r'^[^\[\]\x00-\x1f\x7f]{1,200}$').hasMatch(section) ||
        !RegExp(r'^[a-z0-9][a-z0-9-]{0,40}$').hasMatch(key) ||
        !RegExp(r'^[A-Za-z0-9_.:+-]{1,40}$').hasMatch(value)) {
      throw const FormatException('bad section, key or value');
    }
    if (old.isEmpty) old = 'version = 1\n';
    final lines = <String>[];
    var startAt = 0;
    for (var i = 0; i < old.length; i++) {
      if (old[i] == '\n') {
        lines.add(old.substring(startAt, i + 1));
        startAt = i + 1;
      }
    }
    if (startAt < old.length) lines.add(old.substring(startAt));
    final header = RegExp('^\\s*\\[${RegExp.escape(section)}\\]\\s*\$');
    final start = lines.indexWhere(
      (l) => header.hasMatch(l.replaceFirst(RegExp(r'\n$'), '')),
    );
    if (start < 0) {
      return '${old.replaceFirst(RegExp(r'\n+$'), '')}\n\n[$section]\n$key = $value\n';
    }
    var end = lines.length;
    for (var i = start + 1; i < lines.length; i++) {
      if (RegExp(r'^\s*\[').hasMatch(lines[i])) {
        end = i;
        break;
      }
    }
    var replaced = false;
    for (var i = start + 1; i < end; i++) {
      if (RegExp('^\\s*${RegExp.escape(key)}\\s*=').hasMatch(lines[i])) {
        lines[i] = '$key = $value\n';
        replaced = true;
        break;
      }
    }
    if (!replaced) lines.insert(start + 1, '$key = $value\n');
    return lines.join();
  }

  /// The model's file: `<name>.gguf` first, else the first `<name>*.gguf` of a
  /// small listing (it may run while a page is built: never a whole huge
  /// folder). Regular files only (or links to them), never a FIFO.
  String? llamaModelFile(String folder, String name) {
    final exact = p.join(folder, '$name.gguf');
    final candidates = [exact];
    if (FileSystemEntity.typeSync(exact) != FileSystemEntityType.file) {
      final listed = [
        for (final e in files.list(folder, limit: 5000, allowRootOwned: true))
          if (p.basename(e).startsWith(name) && e.endsWith('.gguf')) e,
      ]..sort();
      candidates.addAll(listed);
    }
    for (final c in candidates) {
      if (FileSystemEntity.typeSync(c) == FileSystemEntityType.file) {
        try {
          return File(c).resolveSymbolicLinksSync();
        } on FileSystemException {
          return c;
        }
      }
    }
    return null;
  }

  // --- Ollama ---------------------------------------------------------------------------

  Map ollamaManifest(String root, String name) {
    final colon = name.indexOf(':');
    final base = colon < 0 ? name : name.substring(0, colon);
    final tag = colon < 0 || colon == name.length - 1
        ? 'latest'
        : name.substring(colon + 1);
    var parts = base.split('/');
    if (parts.length == 1) parts = ['registry.ollama.ai', 'library', parts[0]];
    if (parts.length == 2) parts = ['registry.ollama.ai', ...parts];
    if (parts.any((s) => s == '..' || s.isEmpty) ||
        tag.contains('..') ||
        tag.contains('/')) {
      throw const FormatException('bad model name');
    }
    var path = p.joinAll([root, 'manifests', ...parts, tag]);
    if (!FileSystemEntity.isFileSync(path) &&
        parts.first == 'registry.ollama.ai') {
      final v2 = p.joinAll([
        root,
        'manifests-v2',
        'ollama.com',
        ...parts.skip(1),
        tag,
      ]);
      if (FileSystemEntity.isFileSync(v2)) path = v2;
    }
    final data = files.bytes(
      path,
      limit: 1000000,
      portion: 'head',
      follow: true,
    );
    if (data == null) throw const FileSystemException('no manifest');
    final value = jsonDecode(utf8.decode(data));
    return value is Map ? value : {};
  }

  String? ollamaModelFile(String root, String name) {
    for (final layer in ollamaManifest(root, name)['layers'] as List? ?? []) {
      if (layer is Map &&
          layer['mediaType'] == 'application/vnd.ollama.image.model') {
        final digest = '${layer['digest'] ?? ''}'.replaceAll(':', '-');
        if (RegExp(r'^sha256-[0-9a-f]{64}$').hasMatch(digest)) {
          return p.join(root, 'blobs', digest);
        }
      }
    }
    return null;
  }

  int ollamaContext(String root, String name, int fallback) {
    for (final layer in ollamaManifest(root, name)['layers'] as List? ?? []) {
      if (layer is Map &&
          layer['mediaType'] == 'application/vnd.ollama.image.params') {
        final digest = '${layer['digest'] ?? ''}'.replaceAll(':', '-');
        try {
          final data = files.bytes(
            p.join(root, 'blobs', digest),
            limit: 100000,
            portion: 'head',
            follow: true,
          );
          final params = data == null ? null : jsonDecode(utf8.decode(data));
          if (params is Map && params['num_ctx'] is int) {
            return params['num_ctx'] as int;
          }
        } on FormatException {
          continue;
        }
      }
    }
    return fallback;
  }

  Map<String, String> readEnv(String path) {
    final data = files.bytes(path, limit: 65536, portion: 'head', follow: true);
    final text = data == null ? '' : utf8.decode(data, allowMalformed: true);
    return {
      for (final m in RegExp(
        r'^\s*([A-Z_][A-Z0-9_]*)=(.*)$',
        multiLine: true,
      ).allMatches(text))
        m[1]!: m[2]!.trim().replaceAll(RegExp('''^['"]+|['"]+\$'''), ''),
    };
  }

  // --- LM Studio ------------------------------------------------------------------------

  Map lmstudioEntry(String name) {
    final index = files.json(
      p.join(lmstudio, '.internal/model-index-cache.json'),
      limit: 8 * 1024 * 1024,
      comments: false,
    );
    final models = index['models'];
    for (final entry in (models is List ? models : const []).take(500)) {
      if (entry is Map && entry['defaultIdentifier'] == name) return entry;
    }
    return {};
  }

  String? lmstudioDefaultsFile(Map entry) {
    final ident = entry['indexedModelIdentifier'];
    if (ident is! String ||
        ident.contains('..') ||
        !RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9._+@-]*(/[A-Za-z0-9][A-Za-z0-9._+@-]*){0,4}$',
        ).hasMatch(ident)) {
      return null;
    }
    return p.join(
      lmstudio,
      '.internal/user-concrete-model-default-config',
      '$ident.json',
    );
  }

  String? lmstudioModelFile(Map entry) {
    final point = entry['entryPoint'] is Map
        ? entry['entryPoint'] as Map
        : const {};
    final path = point['absPath'], root = point['rootAbsolutePath'];
    if (path is! String || root is! String || !path.endsWith('.gguf')) {
      return null;
    }
    try {
      final file = File(path).resolveSymbolicLinksSync(),
          base = Directory(root).resolveSymbolicLinksSync();
      return p.isWithin(base, file) && FileSystemEntity.isFileSync(file)
          ? file
          : null;
    } on FileSystemException {
      return null;
    }
  }

  (int, String) lmstudioSettings(Map entry) {
    final path = lmstudioDefaultsFile(entry);
    dynamic data;
    try {
      data = path == null ? {} : jsonDecode(File(path).readAsStringSync());
    } catch (_) {
      data = {};
    }
    var ctx = 0, cache = 'f16';
    final load = data is Map && data['load'] is Map
        ? data['load'] as Map
        : const {};
    for (final field
        in load['fields'] is List ? load['fields'] as List : const []) {
      if (field is! Map) continue;
      if (field['key'] == 'llm.load.contextLength' && field['value'] is int) {
        ctx = field['value'] as int;
      }
      if (field['key'] == 'llm.load.llama.kCacheQuantizationType') {
        var value = field['value'];
        if (value is Map) value = value['value'];
        if (value is String && cacheBytes.containsKey(value)) cache = value;
      }
    }
    return (ctx, cache);
  }

  static String lmstudioContextText(String old, int ctx) {
    dynamic data;
    try {
      data = old.trim().isEmpty ? <String, dynamic>{} : jsonDecode(old);
    } on FormatException {
      throw const FormatException(
        "LM Studio's settings file for this model is not valid JSON",
      );
    }
    if (data is! Map) data = <String, dynamic>{};
    data.putIfAbsent('preset', () => '');
    if (data['operation'] is! Map) data['operation'] = {'fields': <dynamic>[]};
    if (data['load'] is! Map) data['load'] = <String, dynamic>{};
    final load = data['load'] as Map;
    final fields = load['fields'] is List ? load['fields'] as List : const [];
    load['fields'] = [
      for (final f in fields)
        if (!(f is Map && f['key'] == 'llm.load.contextLength')) f,
      {'key': 'llm.load.contextLength', 'value': ctx},
    ];
    return '${pyJsonDumps(data, indent: 2)}\n';
  }

  // --- Jan ---------------------------------------------------------------------------------

  static final _janId = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,119}(/[A-Za-z0-9][A-Za-z0-9._+-]{0,119})?$',
  );

  /// inventory.jan_data_folder: settings.json's data_folder, else data/.
  String janDataFolder() {
    final root = p.join(home, '.local/share/Jan');
    final value = files.json('$root/settings.json')['data_folder'];
    if (value is String && value.trim().isNotEmpty) {
      final path = files.expand(value.trim());
      return p.isAbsolute(path) ? path : p.join(root, path);
    }
    return '$root/data';
  }

  /// jan_ctl._read: at most 256 KiB, strict UTF-8 (an undecodable file fails).
  static String _janRead(String path) {
    try {
      final file = File(path);
      if (file.lengthSync() > 256 * 1024) return '';
      return utf8.decode(file.readAsBytesSync());
    } on FileSystemException {
      return '';
    }
  }

  String? janModelYml(String name, String data) {
    if (!_janId.hasMatch(name)) return null;
    final path = p.join(data, 'llamacpp/models', name, 'model.yml');
    return FileSystemEntity.isFileSync(path) ? path : null;
  }

  /// jan_ctl.settings: (context, KV cache type, model file) from the preset
  /// section, else the model.yml.
  (int, String, String?) janSettings(String name) {
    final data = janDataFolder();
    final sections = iniSections(
      _janRead(p.join(data, 'llamacpp/router.preset.ini')),
    );
    final own = sections[name] ?? {}, shared = sections['*'] ?? {};
    String first(List<String?> values, String fallback) =>
        values.firstWhere(
          (v) => v != null && v.isNotEmpty,
          orElse: () => null,
        ) ??
        fallback;
    var ctx = first([own['ctx-size'], shared['ctx-size']], '');
    final cache = first([own['cache-type-k'], shared['cache-type-k']], 'f16');
    var model = own['model'] ?? '';
    final yml = janModelYml(name, data);
    final text = yml != null ? _janRead(yml) : '';
    if (ctx.isEmpty) {
      ctx =
          RegExp(
            r'^ctx_size:\s*(\d{1,8})\s*$',
            multiLine: true,
          ).firstMatch(text)?[1] ??
          '0';
    }
    if (model.isEmpty) {
      final found = RegExp(
        r'''^model_path:\s*['"]?([^'"\n]+?)['"]?\s*$''',
        multiLine: true,
      ).firstMatch(text);
      if (found != null) {
        model = found[1]!;
        if (!p.isAbsolute(model)) model = p.join(data, model);
      }
    }
    final path =
        model.isNotEmpty &&
            FileSystemEntity.typeSync(model) != FileSystemEntityType.notFound
        ? File(model).resolveSymbolicLinksSync()
        : null;
    return (RegExp(r'^\d+$').hasMatch(ctx) ? int.parse(ctx) : 0, cache, path);
  }

  /// jan_ctl.yml_context_text: ctx_size set (added at the end if missing).
  static String janYmlText(String old, int ctx) {
    if (!(0 < ctx && ctx < 10000000)) {
      throw const FormatException('bad context');
    }
    final line = RegExp(r'^ctx_size:.*$', multiLine: true);
    if (line.hasMatch(old)) return old.replaceFirst(line, 'ctx_size: $ctx');
    return '${old.replaceFirst(RegExp(r'\n+$'), '')}\nctx_size: $ctx\n';
  }

  /// jan_ctl.context_changes: the preset and the model.yml, one backup.
  List<Change> janContextChanges(String name, int ctx) {
    final data = janDataFolder(), changes = <Change>[];
    final preset = p.join(data, 'llamacpp/router.preset.ini');
    if (FileSystemEntity.isFileSync(preset)) {
      if (!(0 < ctx && ctx < 10000000)) {
        throw const FormatException('bad model or context');
      }
      final old = config.read(preset);
      changes.add(Change(preset, old, iniText(old, name, 'ctx-size', '$ctx')));
    }
    final yml = janModelYml(name, data);
    if (yml != null) {
      final old = config.read(yml);
      changes.add(Change(yml, old, janYmlText(old, ctx)));
    }
    if (changes.isEmpty) {
      throw const FormatException('Jan does not list this model');
    }
    return changes;
  }

  // --- KoboldCPP ---------------------------------------------------------------------------

  String get koboldConfigs => p.join(home, '.config/koboldcpp/models');

  /// kobold_ctl.read: a .kcpps of at most 64 KiB, an object, else {}.
  static Map _koboldRead(String path) {
    try {
      final file = File(path);
      if (file.lengthSync() > 64 * 1024) return {};
      final data = jsonDecode(utf8.decode(file.readAsBytesSync()));
      return data is Map ? data : {};
    } on FileSystemException {
      return {};
    } on FormatException {
      return {};
    }
  }

  /// kobold_ctl.settings: (context, "f16", model file) of a model id.
  (int, String, String?) koboldSettings(String name) {
    if (name.contains('/') || !name.endsWith('.kcpps')) return (0, 'f16', null);
    final data = _koboldRead(p.join(koboldConfigs, name));
    final v = data['contextsize'];
    final ctx = v is int ? v : 0;
    final model = '${data['model_param'] ?? ''}';
    final path =
        p.isAbsolute(model) &&
            FileSystemEntity.typeSync(model) != FileSystemEntityType.notFound
        ? File(model).resolveSymbolicLinksSync()
        : null;
    return (ctx, 'f16', path);
  }

  /// The .kcpps with its context set (kobold_ctl.context_text), one change.
  List<Change> koboldContextChanges(String name, int ctx) {
    final path = p.join(koboldConfigs, name);
    if (name.contains('/') ||
        !name.endsWith('.kcpps') ||
        !FileSystemEntity.isFileSync(path)) {
      throw const FormatException('KoboldCpp does not list this model');
    }
    final before = config.read(path);
    if (!(0 < ctx && ctx <= 262144)) {
      throw const FormatException('KoboldCpp takes 256 to 262144 tokens');
    }
    final data = jsonDecode(before.isEmpty ? '{}' : before);
    if (data is! Map) throw const FormatException('not a .kcpps file');
    data['contextsize'] = ctx;
    return [Change(path, before, '${pyJsonDumps(data, indent: 2)}\n')];
  }

  // --- the engines' connect_extra --------------------------------------------------------

  /// llm_engine.connect_extra: (contexts for the agent, file changes, contexts
  /// set through the API when applied). Engines without these: nothing.
  (Map<String, int>, List<Change>, List<Map<String, dynamic>>) connectExtra(
    RuntimeRecord rt,
    String model,
  ) {
    const none = (<String, int>{}, <Change>[], <Map<String, dynamic>>[]);
    if (model.isEmpty) return none;
    final vram = vramTotal();
    try {
      if (rt.key == 'lmstudio') {
        final entry = lmstudioEntry(model);
        final path = entry.isEmpty ? null : lmstudioDefaultsFile(entry);
        if (path == null) return none;
        final (now, cache) = lmstudioSettings(entry);
        String old;
        try {
          old = FileSystemEntity.isFileSync(path)
              ? File(path).readAsStringSync()
              : '';
        } on FileSystemException {
          return none;
        }
        if (now != 0) {
          return ({model: now}, <Change>[], <Map<String, dynamic>>[]);
        }
        final file = lmstudioModelFile(entry);
        if (file == null || vram <= 0) return none;
        final best = bestContext(file, vram, cache);
        if (best <= 0) return none;
        final next = lmstudioContextText(old, best);
        return (
          {model: best},
          [if (next != old) Change(path, old, next)],
          <Map<String, dynamic>>[],
        );
      }
      if (rt.key == 'jan' || rt.key == 'koboldcpp') {
        // Jan's models live in its own data folder; KoboldCPP needs its folder.
        if (rt.key == 'koboldcpp' && rt.modelsDir.isEmpty) return none;
        final (now, cache, file) = rt.key == 'jan'
            ? janSettings(model)
            : koboldSettings(model);
        if (now != 0) {
          return ({model: now}, <Change>[], <Map<String, dynamic>>[]);
        }
        if (file == null || vram <= 0) return none;
        final best = bestContext(file, vram, cache.isEmpty ? 'f16' : cache);
        if (best <= 0) return none;
        return (
          {model: best},
          rt.key == 'jan'
              ? janContextChanges(model, best)
              : koboldContextChanges(model, best),
          <Map<String, dynamic>>[],
        );
      }
      if (rt.key != 'llamacpp' && rt.key != 'ollama') return none;
      if (rt.modelsDir.isEmpty) return none;
      final folder = files.expand(rt.modelsDir);
      final int now;
      final String cache;
      final String? file;
      if (rt.key == 'llamacpp') {
        // Only the model's own section counts: "[*] ctx-size" is a fallback,
        // not its context (task 029). Sized for a q8_0 KV cache, set along.
        now = llamaOwnContext(model);
        cache = llamaAutoCache(model);
        file = llamaModelFile(folder, model);
      } else {
        final env = readEnv(p.join(home, '.config/ollama/server.env'));
        now = ollamaContext(
          folder,
          model,
          int.tryParse(env['OLLAMA_CONTEXT_LENGTH'] ?? '') ?? 0,
        );
        cache = env['OLLAMA_KV_CACHE_TYPE'] ?? 'f16';
        file = ollamaModelFile(folder, model);
      }
      if (now != 0) return ({model: now}, <Change>[], <Map<String, dynamic>>[]);
      if (file == null || vram <= 0) return none;
      final best = bestContext(file, vram, cache.isEmpty ? 'f16' : cache);
      if (best <= 0) return none;
      if (rt.key == 'ollama') {
        return (
          {model: best},
          <Change>[],
          [
            // As flutter_plan_wire carries it: the whole runtime record.
            {'runtime': rt.toJson(), 'model': model, 'tokens': best},
          ],
        );
      }
      final before = config.read(modelsIni);
      return (
        {model: best},
        [Change(modelsIni, before, llamaSizedText(before, model, best))],
        <Map<String, dynamic>>[],
      );
    } on FormatException {
      return none;
    } on FileSystemException {
      return none;
    } on RangeError {
      return none;
    } on StateError {
      return none;
    }
  }
}
