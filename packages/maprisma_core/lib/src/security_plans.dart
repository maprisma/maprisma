import 'dart:convert';
import 'package:toml/toml.dart';
import 'connect_apply.dart';
import 'local_llm.dart' show LocalLlm;
import 'py_values.dart' show pyJsonDumps;
import 'security_reports.dart' show sameSecurityValue;

/// agent_security.plan: one security setting of an agent changed in its own
/// settings file, everything else in it kept as written; reviewed as a
/// connection preview (backup, Undo).

dynamic _dig(dynamic data, String key) {
  for (final part in key.split('.')) {
    if (data is! Map) return null;
    data = data[part];
  }
  return data;
}

/// agent_security._json_set.
String jsonSet(String text, String key, dynamic value) {
  final decoded = text.trim().isEmpty ? <String, dynamic>{} : jsonDecode(text);
  if (decoded is! Map) throw const FormatException('not a JSON object');
  final data = decoded;
  final parts = key.split('.');
  Map node = data;
  for (final part in parts.sublist(0, parts.length - 1)) {
    var child = node[part];
    if (child is String && identical(node, data) && part == 'permission') {
      child = {'*': child}; // OpenCode: one value for everything → per tool
    }
    if (child is! Map) {
      if (value == null) return text;
      child = <String, dynamic>{};
    }
    node[part] = child;
    node = child;
  }
  if (value == null) {
    node.remove(parts.last);
    if (node.isEmpty && parts.length > 1) {
      final parent = parts.length > 2
          ? _dig(data, parts.sublist(0, parts.length - 2).join('.'))
          : data;
      if (parent is Map) parent.remove(parts[parts.length - 2]);
    }
  } else {
    node[parts.last] = value;
  }
  return '${pyJsonDumps(data, indent: 2, ensureAscii: false)}\n';
}

String _tomlScalar(dynamic value) =>
    value is bool ? (value ? 'true' : 'false') : pyJsonDumps(value);

List<String> _keepEnds(String text) => [
  for (final m in RegExp(r'[^\n]*\n|[^\n]+$').allMatches(text)) m[0]!,
];

/// agent_security.toml_set: one `key` or `table.key`; the rest as written.
String tomlSet(String text, String key, dynamic value) {
  final dot = key.lastIndexOf('.');
  final table = dot < 0 ? '' : key.substring(0, dot),
      name = key.substring(dot + 1);
  final lines = _keepEnds(text);
  final headers = [
    for (var i = 0; i < lines.length; i++)
      if (RegExp(r'^\s*\[').hasMatch(lines[i])) i,
  ];
  int first, end;
  if (table.isNotEmpty) {
    final header = RegExp(
      '^\\s*\\[\\s*${RegExp.escape(table)}\\s*\\]\\s*(#.*)?\$',
    );
    final start = headers
        .where((i) => header.hasMatch(lines[i].replaceAll('\n', '')))
        .firstOrNull;
    if (start == null) {
      if (value == null) return text;
      final tail = text.isEmpty || text.endsWith('\n') ? '' : '\n';
      return '$text$tail${text.trim().isNotEmpty ? '\n' : ''}[$table]\n$name = ${_tomlScalar(value)}\n';
    }
    end = headers.where((i) => i > start).firstOrNull ?? lines.length;
    first = start + 1;
  } else {
    first = 0;
    end = headers.isNotEmpty ? headers.first : lines.length;
  }
  final assignment = RegExp('^\\s*${RegExp.escape(name)}\\s*=');
  for (var i = first; i < end; i++) {
    if (assignment.hasMatch(lines[i])) {
      if (value == null) {
        lines.removeAt(i);
      } else {
        lines[i] = '$name = ${_tomlScalar(value)}\n';
      }
      return lines.join();
    }
  }
  if (value == null) return text;
  lines.insert(first, '$name = ${_tomlScalar(value)}\n');
  return lines.join();
}

String _yamlScalar(dynamic value) =>
    value is bool ? (value ? 'true' : 'false') : pyJsonDumps('$value');

/// agent_security.yaml_set: `block.key` (two levels); the rest as written.
String yamlSet(String text, String key, dynamic value) {
  final at = key.indexOf('.');
  final top = at < 0 ? key : key.substring(0, at),
      sub = at < 0 ? '' : key.substring(at + 1);
  final line = '  $sub: ${_yamlScalar(value)}\n';
  final block = LocalLlm.topBlock(text, top);
  if (block == null) {
    if (value == null) return text;
    final tail = text.isEmpty || text.endsWith('\n') ? '' : '\n';
    return '$text$tail$top:\n$line';
  }
  final start = text.indexOf(block), end = start + block.length;
  final nl = block.indexOf('\n');
  var head = nl < 0 ? block : block.substring(0, nl);
  var body = nl < 0 ? '' : block.substring(nl + 1);
  if (RegExp('^${RegExp.escape(top)}:[ \\t]*\\{\\s*\\}').hasMatch(head)) {
    head = '$top:';
    body = '';
  }
  final found = RegExp(
    '^[ \\t]+${RegExp.escape(sub)}:.*(\\n|\$)',
    multiLine: true,
  ).firstMatch(body);
  if (found != null) {
    body =
        body.substring(0, found.start) +
        (value == null ? '' : line) +
        body.substring(found.end);
  } else if (value != null) {
    body = line + body;
  }
  return '${text.substring(0, start)}$head\n$body${text.substring(end)}';
}

/// agent_security._yaml_value.
dynamic yamlValue(String text, String key) {
  final at = key.indexOf('.');
  final top = at < 0 ? key : key.substring(0, at),
      sub = at < 0 ? '' : key.substring(at + 1);
  final block = RegExp(
    '^${RegExp.escape(top)}:[ \\t]*\\n((?:[ \\t]+.*\\n?|[ \\t]*\\n)+)',
    multiLine: true,
  ).firstMatch(text);
  if (block == null) return null;
  final found = RegExp(
    '^[ \\t]+${RegExp.escape(sub)}:[ \\t]*(.*?)[ \\t]*(?:#.*)?\$',
    multiLine: true,
  ).firstMatch(block[1]!);
  if (found == null) return null;
  final raw = found[1]!.trim();
  final quoted = found[1]!.startsWith("'") || found[1]!.startsWith('"');
  if (const ['true', 'yes', 'on'].contains(raw.toLowerCase()) && !quoted) {
    return true;
  }
  if (const ['false', 'no'].contains(raw.toLowerCase()) && !quoted) {
    return false;
  }
  return raw.replaceAll(RegExp(r'''^['"]+|['"]+$'''), '');
}

/// agent_security.plan: the change of one setting, for the preview.
Plan securityPlan(
  Map<String, dynamic> report,
  String agent,
  String key,
  dynamic value,
  ConfigFiles config,
) {
  final setting = (report['settings'] as List? ?? const [])
      .cast<Map>()
      .where((s) => s['key'] == key)
      .firstOrNull;
  if (setting == null || setting['editable'] != true) {
    throw FormatException('$key cannot be changed here');
  }
  if (!(setting['choices'] as List).any(
    (c) => sameSecurityValue((c as Map)['value'], value),
  )) {
    throw FormatException('${jsonEncode(value)} is not a choice for $key');
  }
  final path = setting['path'] as String;
  final old = config.read(path);
  String next;
  if (setting['fmt'] == 'toml') {
    next = tomlSet(old, key, value);
    final check = _dig(TomlDocument.parse(next).toMap(), key);
    // As the reference: only a value set is checked (a removal may leave
    // a default the file never named).
    if (value != null && !sameSecurityValue(check, value)) {
      throw const FormatException('the TOML file could not be changed safely');
    }
  } else if (setting['fmt'] == 'yaml') {
    next = yamlSet(old, key, value);
    final check = yamlValue(next, key);
    if (value != null && check != value && check != '$value') {
      throw const FormatException('the YAML file could not be changed safely');
    }
  } else {
    next = jsonSet(old, key, value);
  }
  final plan = Plan(agent, '', 'security');
  if (next != old) plan.changes.add(Change(path, old, next));
  return plan;
}
