import 'package:yaml/yaml.dart';

/// DeepSeek Harness's profile patch (Python dsh_ctl, read side): a top-level
/// YAML list of loader patch entries, read block by block like the reference.
const dshProfile = '~/.dsh/profiles/web/cordis.patch.yml';
const _llmId = 'llm-pi-ai', _defaultId = 'agent-default-model';
const _mcpName = '@deepseek-ai/dsh-mcp-client';

/// (the comments before the list, one text block per top-level entry).
List<String> dshBlocks(String text) {
  final blocks = <String>[];
  for (final line in _lines(text)) {
    if (line.startsWith('- ') || line.trimRight() == '-') {
      blocks.add(line);
    } else if (blocks.isNotEmpty) {
      blocks[blocks.length - 1] += line;
    }
  }
  return blocks;
}

/// Python str.splitlines(keepends=True) for the line ends YAML uses.
Iterable<String> _lines(String text) sync* {
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      yield text.substring(start, i + 1);
      start = i + 1;
    }
  }
  if (start < text.length) yield text.substring(start);
}

Map _entry(String block) {
  try {
    final data = loadYaml(block);
    return data is List && data.isNotEmpty && data.first is Map
        ? data.first as Map
        : {};
  } on YamlException {
    return {};
  } on ArgumentError {
    return {};
  }
}

Map? _config(String text, String id) {
  for (final block in dshBlocks(text)) {
    final entry = _entry(block);
    if (entry['id'] == id) {
      final config = entry['config'];
      return config is Map ? config : null;
    }
  }
  return null;
}

Map dshProviders(String text) {
  final found = _config(text, _llmId)?['providers'];
  return found is Map ? found : {};
}

(String, String) dshDefaultModel(String text) {
  final config = _config(text, _defaultId);
  if (config == null) return ('', '');
  String plain(dynamic v) => v == null ? '' : '$v';
  return (plain(config['provider']), plain(config['model']));
}

/// serverName -> its config, for the MCP clients inserted in the patch.
Map<String, dynamic> dshMcpServers(String text) {
  final found = <String, dynamic>{};
  for (final block in dshBlocks(text)) {
    final rows = _entry(block)['insert'];
    for (final row in rows is List ? rows : const []) {
      if (row is Map && row['name'] == _mcpName && row['config'] is Map) {
        final name = '${(row['config'] as Map)['serverName'] ?? ''}';
        if (name.isNotEmpty) found[name] = Map.of(row['config'] as Map);
      }
    }
  }
  return found;
}

final _baseProvider = RegExp(
  r'-\s+id:\s*agent-default-model\s*\n(?:\s+.*\n){0,6}?\s+provider:\s*([a-z][a-z0-9_-]{0,63})\s*$',
  multiLine: true,
);
final _defaultModels = RegExp(r'const DEFAULT_MODELS = \[([\s\S]{0,4000}?)\];');
final _modelId = RegExp(r'\bid:\s*"([A-Za-z0-9][A-Za-z0-9._-]{0,63})"');

/// "provider/model" of its own DeepSeek route, from the installed packages'
/// texts (base profile and DeepSeek package); nothing when either is missing.
List<String> dshBuiltinChoices(String baseProfile, String deepseekIndex) {
  final found = _baseProvider.firstMatch(baseProfile);
  final catalog = _defaultModels.firstMatch(deepseekIndex);
  if (found == null || catalog == null) return [];
  final models = <String>{
    for (final m in _modelId.allMatches(catalog[1]!)) m[1]!,
  };
  return [for (final m in models) '${found[1]}/$m'].take(12).toList();
}
