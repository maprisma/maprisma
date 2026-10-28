import 'dart:convert';
import 'adapter_assets.g.dart';
import 'adapters.dart';
import 'dsh_profile.dart';
import 'py_values.dart';
import 'scan_files.dart';

/// Python connect.is_connected / is_active: whether an agent's own settings
/// name a local LLM's provider, by the built-in reader of each adapter's
/// `[local_llm]` hooks (read only; the transforms come with the write phase).
final class LocalLlm {
  LocalLlm(this.files);
  final ScanFiles files;
  static const maxBytes = 2 * 1024 * 1024;

  /// connect._read: own regular file, not through a link, strict UTF-8.
  String? _read(String path) {
    final data = files.bytes(path, limit: maxBytes);
    if (data == null) return files.exists(path) ? null : '';
    try {
      return utf8.decode(data);
    } on FormatException {
      return null;
    }
  }

  /// connect._json: "" is {}, anything but an object fails.
  Map? _json(String? text) {
    if (text == null) return null;
    if (text.trim().isEmpty) return {};
    try {
      final data = jsonDecode(text);
      return data is Map ? data : null;
    } on FormatException {
      return null;
    }
  }

  /// connect._top_block: the text of a top-level `key:` block in YAML.
  static String? topBlock(String text, String key) {
    final start = RegExp(
      '^${RegExp.escape(key)}:.*\\n?',
      multiLine: true,
    ).firstMatch(text);
    if (start == null) return null;
    final rest = text.substring(start.end);
    var offset = 0;
    for (final line in RegExp(r'^.*\n?', multiLine: true).allMatches(rest)) {
      final value = line[0]!;
      if (value.isNotEmpty &&
          !value.startsWith(' ') &&
          !value.startsWith('\t') &&
          !value.startsWith('\n') &&
          !value.startsWith('#')) {
        return text.substring(start.start, start.end + offset);
      }
      offset = line.end;
    }
    return text.substring(start.start);
  }

  static bool _has(dynamic container, String key) => container is Map
      ? container.containsKey(key)
      : container is List
      ? container.contains(key)
      : container is String && container.contains(key);

  List<String> _texts(Adapter adapter) => [
    for (final f in adapter.table('local_llm')['files'] as List? ?? const [])
      _read(f as String) ?? '\u0000',
  ];

  String provider(String runtime) =>
      (providerFacts['connect_keys'] as Map)[runtime] as String? ?? '';

  bool connected(Adapter adapter, String runtime) {
    if (adapter.table('local_llm').isEmpty) return false;
    final key = provider(runtime), texts = _texts(adapter);
    if (texts.isEmpty || texts.any((t) => t == '\u0000')) return false;
    switch (adapter.command) {
      case 'hermes' || 'omp':
        final block = topBlock(texts[0], 'providers');
        return block != null &&
            block.isNotEmpty &&
            RegExp(
              '^  ${RegExp.escape(key)}:',
              multiLine: true,
            ).hasMatch(block);
      case 'pi':
        final data = _json(texts[0]);
        return data != null && _has(data['providers'] ?? {}, key);
      case 'opencode':
        final data = _json(texts[0]);
        return data != null && _has(data['provider'] ?? {}, key);
      case 'openclaw':
        final models = _json(texts[0])?['models'];
        return models is Map &&
            models['providers'] is Map &&
            (models['providers'] as Map).containsKey(key);
      case 'dsh':
        return dshProviders(texts[0]).containsKey(key);
    }
    return false;
  }

  /// connect.is_active: the agent uses this runtime's provider right now (its
  /// current model); an agent with a fixed provider uses only that one.
  bool active(Adapter adapter, String runtime) {
    final fixed = adapter.facts['fixed_provider'];
    if (fixed is String && fixed.isNotEmpty) return fixed == runtime;
    if (adapter.table('local_llm').isEmpty) return false;
    final key = provider(runtime), texts = _texts(adapter);
    if (texts.isEmpty || texts.any((t) => t == '\u0000')) return false;
    String second() => texts.length > 1 ? texts[1] : '\u0000';
    switch (adapter.command) {
      case 'hermes':
        final block = topBlock(texts[0], 'model');
        return block != null &&
            RegExp(
              '^  provider:\\s*["\']?${RegExp.escape(key)}["\']?\\s*\$',
              multiLine: true,
            ).hasMatch(block);
      case 'omp':
        final text = second();
        if (text == '\u0000') return false;
        final block = topBlock(text, 'modelRoles');
        if (block == null) return false;
        final found = RegExp(
          r'^  default:\s*(.*?)\s*$',
          multiLine: true,
        ).firstMatch(block);
        if (found == null) return false;
        final value = found[1]!.replaceAll(RegExp('^[\'"]+|[\'"]+\$'), '');
        return value.startsWith('$key/');
      case 'pi':
        final text = second();
        return text != '\u0000' && _json(text)?['defaultProvider'] == key;
      case 'opencode':
        final data = _json(texts[0]);
        return data != null && pyStr(data['model'] ?? '').startsWith('$key/');
      case 'openclaw':
        final data = _json(texts[0]);
        if (data == null) return false;
        final agents = data['agents'];
        final chosen = agents is Map && agents['defaults'] is Map
            ? (agents['defaults'] as Map)['model']
            : null;
        final value = chosen is Map ? chosen['primary'] : chosen;
        return value is String && value.startsWith('$key/');
      case 'dsh':
        return dshDefaultModel(texts[0]).$1 == key;
    }
    return false;
  }
}
