import 'dart:convert';
import 'adapters.dart';
import 'dsh_profile.dart';
import 'py_values.dart';
import 'scan_files.dart';
import 'provider_facts.dart';

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

  // connect._ENTRY_KEY / _BARE_KEY: a two-space providers entry key, bare,
  // "double" (no escapes) or 'single' quoted, spaces allowed before the colon.
  static final _entryKey = RegExp(
    r'''^  (?:"([^"\\\n]*)"|'((?:[^'\n]|'')*)'|([^\s"'#?&*!|>%@`{}\[\],:-][^\n:#]*?))[ \t]*:(?:[ \t]|$)''',
  );
  // connect._BARE_KEY / _NOT_STRINGS: a plain identifier YAML reads back as
  // the same string (not a boolean, null or number).
  static final _bareKey = RegExp(r'^[A-Za-z_][A-Za-z0-9_.-]*$');
  static const _notStrings = {
    'true', 'false', 'yes', 'no', 'on', 'off', 'y', 'n', 'null', //
  };

  /// connect._PROVIDERS_HEADER: block style, or an empty inline map.
  static final providersHeader = RegExp(
    r'^providers:[ \t]*(?:\{[ \t]*\})?[ \t]*(?:#.*)?$',
  );

  /// A provider name the writers can put down as a bare key.
  static bool bareProviderKey(String name) =>
      _bareKey.hasMatch(name) && !_notStrings.contains(name.toLowerCase());

  /// connect.provider_entries: (start, end, key) of each entry in a providers
  /// block's body (after its header line), with its deeper and blank lines.
  /// Throws FormatException on a line it cannot read safely.
  static List<(int, int, String)> providerEntries(String body) {
    final found = <(int, int, String)>[];
    var pos = 0;
    int? start, end;
    String? key;
    void close() {
      if (key != null) found.add((start!, end!, key!));
      key = null;
    }

    for (final m in RegExp(r'[^\n]*\n|[^\n]+$').allMatches(body)) {
      final line = m[0]!;
      final bare = line.replaceFirst(RegExp(r'[\r\n]+$'), '');
      if (key != null &&
          (bare.trim().isEmpty ||
              bare.startsWith('    ') ||
              bare.startsWith('\t\t'))) {
        end = pos + line.length;
      } else if (bare.trim().isEmpty || bare.trimLeft().startsWith('#')) {
        close();
      } else {
        final match = _entryKey.firstMatch(bare);
        if (match == null) {
          throw const FormatException(
            'providers entry not readable; edit it by hand',
          );
        }
        close();
        start = pos;
        end = pos + line.length;
        key = match[1] ?? match[2]?.replaceAll("''", "'") ?? match[3]!;
      }
      pos += line.length;
    }
    close();
    return found;
  }

  /// connect.provider_keys: [] when there is no readable providers block.
  static List<String> providerKeys(String text) {
    final block = topBlock(text, 'providers');
    if (block == null) return [];
    final cut = block.indexOf('\n');
    if (cut < 0) return [];
    try {
      return [for (final e in providerEntries(block.substring(cut + 1))) e.$3];
    } on FormatException {
      return [];
    }
  }

  /// hermes._entries: (start, end, key) with offsets into [text]; [] when
  /// there is none or it is not readable.
  static List<(int, int, String)> providerEntriesIn(String text) {
    final block = topBlock(text, 'providers');
    if (block == null) return [];
    final cut = block.indexOf('\n');
    if (cut < 0) return [];
    final offset =
        RegExp('^providers:', multiLine: true).firstMatch(text)!.start +
        cut +
        1;
    try {
      return [
        for (final e in providerEntries(block.substring(cut + 1)))
          (offset + e.$1, offset + e.$2, e.$3),
      ];
    } on FormatException {
      return [];
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
      (visibleProviderFacts['connect_keys'] as Map)[runtime] as String? ?? '';

  bool connected(Adapter adapter, String runtime) {
    if (adapter.table('local_llm').isEmpty) return false;
    final key = provider(runtime), texts = _texts(adapter);
    if (texts.isEmpty || texts.any((t) => t == '\u0000')) return false;
    switch (adapter.command) {
      case 'hermes' || 'omp':
        return providerKeys(texts[0]).contains(key);
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
