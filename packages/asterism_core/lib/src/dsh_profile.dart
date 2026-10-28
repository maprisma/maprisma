import 'package:yaml/yaml.dart';
import 'py_yaml.dart';

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

/// dsh_ctl's loader constructs `!!js` expressions as their text; package:yaml
/// refuses the unknown tag, so it is dropped before reading (never written back).
String _untagged(String block) =>
    block.replaceAll(RegExp(r'(?<=[\s:\-\[,{])!!js(?=\s)'), '');

Map _entry(String block) {
  try {
    final data = loadYaml(_untagged(block));
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

const _header =
    '# Your patch layer for this dsh profile, applied after every bundle layer:\n'
    '# a top-level YAML array of loader patch entries (id-targeted config\n'
    '# overrides, disables, and insert lists; `!!js` expressions allowed).\n';

/// dsh_ctl.split: (the comments before the list, one text block per entry).
(String, List<String>) dshSplit(String text) {
  final header = StringBuffer(), blocks = <String>[];
  for (final line in _lines(text)) {
    if (line.startsWith('- ') || line.trimRight() == '-') {
      blocks.add(line);
    } else if (blocks.isNotEmpty) {
      blocks[blocks.length - 1] += line;
    } else if (line.trim() == '[]' || line.trim().isEmpty) {
      continue; // the empty list dsh starts with
    } else {
      header.write(line);
    }
  }
  return (header.toString(), blocks);
}

String dshJoin(String header, List<String> blocks) {
  final head = header.isEmpty ? _header : header;
  if (blocks.isEmpty) return '$head[]\n';
  return head + blocks.map((b) => b.endsWith('\n') ? b : '$b\n').join();
}

/// dsh_ctl.parse for writes: a block PyYAML cannot read refuses the edit.
Map _strictEntry(String block) {
  final dynamic data;
  try {
    data = loadYaml(_untagged(block));
  } on YamlException {
    throw const FormatException('The profile has an entry YAML cannot read');
  }
  return data is List && data.isNotEmpty && data.first is Map
      ? data.first as Map
      : {};
}

/// dsh_ctl.mcp_text: MCP server [name] set to [config] (an insert of its own),
/// or removed. An insert that holds other entries too would be dumped again
/// from its parsed data; that needs PyYAML's YAML 1.1 reading (dates, yes/on,
/// !!js tags), so such an edit is refused here instead of written differently.
String dshMcpText(String text, String name, Map? config) {
  final (header, blocks) = dshSplit(text);
  final kept = <String>[];
  for (final block in blocks) {
    final rows = _strictEntry(block)['insert'];
    if (rows is! List) {
      kept.add(block);
      continue;
    }
    bool ours(dynamic r) =>
        r is Map &&
        r['name'] == _mcpName &&
        r['config'] is Map &&
        (r['config'] as Map)['serverName'] == name;
    final others = rows.where((r) => !ours(r)).toList();
    if (others.length == rows.length) {
      kept.add(block);
    } else if (others.isNotEmpty) {
      throw UnsupportedError(
        'This insert holds other entries too; edit it in dsh',
      );
    }
  }
  if (config != null) {
    final id =
        'mcp-${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '-')}';
    kept.add(
      pyYamlDump([
        {
          'insert': [
            {
              'id': id.length > 64 ? id.substring(0, 64) : id,
              'name': _mcpName,
              'config': {'serverName': name, ...config},
            },
          ],
        },
      ]),
    );
  }
  return dshJoin(header, kept);
}
