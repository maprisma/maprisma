import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';
import 'agent_catalog.dart';
import 'agent_details.dart' show dig;
import 'connect_apply.dart';
import 'local_llm.dart';
import 'py_values.dart';
import 'scan_files.dart';

/// Python agent_profiles (read side): what an installed agent without an
/// adapter keeps where, looked up once on the web and checked before use.
final class AgentProfiles {
  AgentProfiles(this.files, this.configDir);
  final ScanFiles files;
  final String configDir;
  static final _command = RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$');
  static final _path = RegExp(r'^~/[A-Za-z0-9._@+/-]{1,200}$');
  static final _private = RegExp(
    r'(^|/)\.(ssh|gnupg|password-store|aws|azure|kube|docker|pki|netrc|git-credentials)(/|$)'
    r'|auth|credential|secret|token|password|keyring|\.pem$|\.key$',
    caseSensitive: false,
  );

  static bool pathOk(dynamic path) =>
      path is String &&
      _path.hasMatch(path) &&
      !path.split('/').contains('..') &&
      !_private.hasMatch(path) &&
      '/'.allMatches(path).length >= 2;

  static final _key = RegExp(
    r'^[A-Za-z_][A-Za-z0-9_-]{0,40}(\.[A-Za-z_][A-Za-z0-9_-]{0,40}){0,3}$',
  );
  static const _fields = {
    'type_field': ['', 'type', 'transport'],
    'stdio_type': ['', 'stdio', 'local'],
    'http_type': [
      '',
      'http',
      'streamable_http',
      'streamable-http',
      'remote',
      'sse',
    ],
    'url_field': ['url', 'httpUrl', 'serverUrl'],
    'env_field': ['env', 'environment'],
    'headers_field': ['headers', 'http_headers'],
  };

  Map<String, dynamic> _load(String command) => _command.hasMatch(command)
      ? files.json(
          '$configDir/agents/$command.json',
          limit: 64 * 1024,
          comments: false,
        )
      : {};

  /// load(command)["mcp"]: where its MCP servers go and how an entry looks.
  /// A profile whose skills and MCP parts are both unusable is no profile.
  Map<String, dynamic>? mcp(String command) {
    final data = _load(command);
    if (data['status'] != 'ok') return null;
    final raw = data['mcp'];
    if (raw is! Map ||
        !pathOk(raw['file']) ||
        !const {'json', 'toml', 'yaml'}.contains(raw['format']) ||
        raw['key'] is! String ||
        !_key.hasMatch(raw['key'] as String)) {
      return null;
    }
    if (raw['format'] != 'json' && (raw['key'] as String).contains('.')) {
      return null;
    }
    return {
      'file': raw['file'],
      'format': raw['format'],
      'key': raw['key'],
      'command_list': raw['command_list'] == true,
      for (final e in _fields.entries)
        e.key:
            e.value.contains(pyTruthy(raw[e.key]) ? raw[e.key] : '') &&
                pyTruthy(raw[e.key])
            ? raw[e.key]
            : e.value.first,
    };
  }

  /// load(command)["skills"] when the profile is "ok" and usable.
  Map<String, dynamic>? skills(String command) {
    if (!_command.hasMatch(command)) return null;
    final data = files.json(
      '$configDir/agents/$command.json',
      limit: 64 * 1024,
      comments: false,
    );
    if (data['status'] != 'ok') return null;
    final raw = data['skills'];
    if (raw is! Map) return null;
    final dirs = raw['dirs'] is List
        ? (raw['dirs'] as List).where(pathOk).take(8).cast<String>().toList()
        : <String>[];
    final own = pathOk(raw['own'])
        ? raw['own'] as String
        : (dirs.isEmpty ? null : dirs.first);
    if (own == null) return null;
    return {
      'dirs': {own, ...dirs}.toList(),
      'own': own,
    };
  }
}

/// Hermes: skills.external_dirs in config.yaml, read as text (its hook).
List<String> hermesSkillDirs(String text) {
  final block = LocalLlm.topBlock(text, 'skills');
  if (block == null) return [];
  final found = RegExp(
    r'^  external_dirs:[ \t]*\n((?:    - .*\n?)*)',
    multiLine: true,
  ).firstMatch(block);
  if (found == null) {
    final inline = RegExp(
      r'^  external_dirs:[ \t]*\[(.*)\]',
      multiLine: true,
    ).firstMatch(block);
    return inline == null
        ? []
        : [
            for (final d in inline[1]!.split(','))
              if (d.trim().isNotEmpty) _strip(d.trim()),
          ];
  }
  return [
    for (final line in found[1]!.split('\n'))
      if (line.trim().isNotEmpty) _strip(line.substring(6).trim()),
  ];
}

String _strip(String text) => text.replaceAll(RegExp('''^['"]+|['"]+\$'''), '');

/// Python skills_ctl.plan and its helpers: give an agent a skill set (links in
/// its own folder, or an entry in Pi's or Hermes's settings list), or take it.
final class SkillPlans {
  SkillPlans(this.files, this.config, this.catalog, this.profiles);
  final ScanFiles files;
  final ConfigFiles config;
  final AgentCatalog catalog;
  final AgentProfiles profiles;
  static const maxSkills = 200;

  String get home => files.identity.home;
  String expand(String path) => path == '~' || path.startsWith('~/')
      ? p.join(home, path.length > 2 ? path.substring(2) : '')
      : path;

  Map<String, dynamic>? _spec(String agent) {
    final a = catalog.adapter(agent);
    return a != null && a.facts.containsKey('skills')
        ? a.table('skills')
        : null;
  }

  List<String> nativeDirs(String agent) {
    final spec = _spec(agent);
    if (spec != null) {
      return [for (final d in spec['dirs'] as List? ?? []) d as String];
    }
    return [
      for (final d in profiles.skills(agent)?['dirs'] as List? ?? [])
        d as String,
    ];
  }

  String? ownDir(String agent) {
    final spec = _spec(agent);
    if (spec != null) return spec['own'] as String?;
    return profiles.skills(agent)?['own'] as String?;
  }

  bool settingsList(String agent) => _spec(agent)?['settings_list'] == true;

  /// skills_ctl.config_dirs: the extra folders the agent's settings list.
  List<String> configDirs(String agent) {
    final spec = _spec(agent);
    final listed = spec?['listed'];
    dynamic found;
    try {
      if (listed == 'hook' && agent == 'hermes') {
        found = hermesSkillDirs(config.read(expand('~/.hermes/config.yaml')));
      } else if (listed is Map) {
        final path = expand(listed['file'] as String);
        final text = config.read(path);
        final data = listed['format'] == 'json'
            ? (text.isEmpty ? {} : jsonDecode(text))
            : TomlDocument.parse(text).toMap();
        found = data is Map ? dig(data, listed['key'] as String) : null;
      }
    } on FileSystemException {
      found = null;
    } on FormatException {
      found = null;
    } on TomlException {
      found = null;
    }
    return found is List
        ? [
            for (final d in found.take(20))
              if (d is String && d.isNotEmpty) d,
          ]
        : [];
  }

  /// Path.resolve(strict=False): links followed as far as the path exists.
  String real(String path) {
    var current = p.normalize(path);
    for (var hop = 0; hop < 40; hop++) {
      final parts = p.split(current);
      var resolved = parts.first;
      var changed = false;
      for (var i = 1; i < parts.length; i++) {
        final next = p.join(resolved, parts[i]);
        if (FileSystemEntity.typeSync(next, followLinks: false) ==
            FileSystemEntityType.link) {
          final target = Link(next).targetSync();
          current = p.normalize(
            p.join(
              p.isAbsolute(target) ? target : p.join(resolved, target),
              p.joinAll(parts.skip(i + 1)),
            ),
          );
          changed = true;
          break;
        }
        resolved = next;
      }
      if (!changed) return current;
    }
    return current;
  }

  bool _isLink(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.link;
  bool _isDir(String path) => FileSystemEntity.isDirectorySync(path);

  List<String> _children(String folder) {
    try {
      return Directory(
        folder,
      ).listSync(followLinks: false).map((e) => e.path).toList();
    } on FileSystemException {
      return [];
    }
  }

  List<String> skillsOf(String folder) {
    final found = <String>[];
    final entries = _children(folder)..sort(pyCompare);
    for (final entry in entries.take(maxSkills)) {
      if (p.basename(entry).startsWith('.') || !_isDir(entry)) continue;
      if (File(p.join(entry, 'SKILL.md')).existsSync()) {
        found.add(entry);
      } else {
        final inner = _children(entry)..sort(pyCompare);
        found.addAll([
          for (final e in inner.take(maxSkills))
            if (!p.basename(e).startsWith('.') &&
                File(p.join(e, 'SKILL.md')).existsSync())
              e,
        ]);
      }
    }
    return found.take(maxSkills).toList();
  }

  /// skills_ctl.reach: (folders that give the set, listed, own links into it).
  (List<String>, bool, List<(String, String)>) reach(
    String agent,
    String folder,
  ) {
    folder = real(folder);
    final mine = ownDir(agent);
    final own = mine == null ? null : expand(mine);
    final native = [for (final d in nativeDirs(agent)) expand(d)];
    final configured = [for (final d in configDirs(agent)) expand(d)];
    final listedFlag =
        settingsList(agent) && configured.any((d) => real(d) == folder);
    final listed = [
      for (final d in configured)
        if (!native.contains(d)) d,
    ];
    final through = <String>[], links = <(String, String)>[];
    for (final path in [...native, ...listed]) {
      if (real(path) == folder) {
        if ((native.contains(path) || !settingsList(agent)) &&
            !through.contains(path)) {
          through.add(path);
        }
        continue;
      }
      for (final entry in _children(path).take(maxSkills)) {
        if (!_isLink(entry)) continue;
        final target = real(entry);
        if (p.dirname(target) != folder && !p.isWithin(folder, target)) {
          continue;
        }
        if (own != null && p.normalize(path) == p.normalize(own)) {
          links.add((entry, Link(entry).targetSync()));
        } else if (!through.contains(path)) {
          through.add(path);
        }
      }
    }
    return (through, listedFlag, links);
  }

  Plan plan(String agent, String folder, {required bool remove}) {
    final mine = ownDir(agent);
    if (mine == null || mine.isEmpty) throw FormatException(agent);
    final path = real(expand(folder));
    final result = Plan(agent, '', config.tilde(path));
    final (through, listed, links) = reach(agent, path);
    if (remove) {
      if (listed) {
        result.changes.addAll(_settingsChange(agent, path, remove: true));
      }
      result.linksRemove.addAll(links);
      return result;
    }
    if (through.isNotEmpty || listed) return result;
    if (settingsList(agent)) {
      result.changes.addAll(_settingsChange(agent, path, remove: false));
      return result;
    }
    final own = expand(mine);
    for (final skill in skillsOf(path)) {
      final link = p.join(own, p.basename(skill));
      if (FileSystemEntity.typeSync(link) == FileSystemEntityType.notFound &&
          !_isLink(link)) {
        result.linksAdd.add((link, skill));
      }
    }
    return result;
  }

  List<Change> _settingsChange(
    String agent,
    String folder, {
    required bool remove,
  }) {
    final file = expand(_spec(agent)!['settings_file'] as String);
    final old = config.read(file);
    final next = switch (agent) {
      'hermes' => hermesSkillsWrite(old, folder, remove),
      'pi' => piSkillsWrite(old, folder, remove),
      _ => throw FormatException('No settings list writer for $agent'),
    };
    return next == old ? [] : [Change(file, old, next)];
  }

  /// adapters/pi.py skills_write: the "skills" list in settings.json.
  String piSkillsWrite(String text, String folder, bool remove) {
    final data = text.trim().isEmpty ? <String, dynamic>{} : jsonDecode(text);
    if (data is! Map) throw const FormatException('not a JSON object');
    final current = data['skills'] is List ? data['skills'] as List : [];
    final dirs = [
      for (final d in current)
        if (!(d is String && expand(d) == folder)) d,
    ];
    if (!remove) dirs.add(folder);
    if (dirs.isNotEmpty) {
      data['skills'] = dirs;
    } else {
      data.remove('skills');
    }
    return '${pyJsonDumps(data, indent: 2, ensureAscii: false)}\n';
  }

  /// adapters/hermes.py skills_write: one `- path` line in skills.external_dirs.
  String hermesSkillsWrite(String text, String folder, bool remove) {
    final item = '    - $folder\n';
    final start = RegExp(r'^skills:.*\n?', multiLine: true).firstMatch(text);
    if (start == null) {
      if (remove) return text;
      return '$text${text.endsWith('\n') || text.isEmpty ? '' : '\n'}skills:\n  external_dirs:\n$item';
    }
    final block = LocalLlm.topBlock(text, 'skills')!;
    final begin = start.start, end = begin + block.length;
    var body = block;
    final listed = RegExp(
      r'^  external_dirs:[ \t]*\n((?:    - .*\n?)*)',
      multiLine: true,
    ).firstMatch(body);
    if (listed == null) {
      if (remove) return text;
      if (RegExp(r'^  external_dirs:', multiLine: true).hasMatch(body)) {
        throw const FormatException(
          'skills.external_dirs is written in a form this cannot edit',
        );
      }
      body =
          '${body.replaceFirst(RegExp(r'\n+$'), '')}\n  external_dirs:\n$item';
      final rest = text.substring(end);
      return '${text.substring(0, begin)}$body${rest.isNotEmpty && !body.endsWith('\n') ? '\n' : ''}$rest';
    }
    final lines = [
      for (final line in _keepEnds(listed[1]!))
        if (line.trim().isNotEmpty) line,
    ];
    final keep = [
      for (final line in lines)
        if (!{
          folder,
          config.tilde(folder),
        }.contains(_strip(line.substring(6).trim())))
          line,
    ];
    if (!remove) keep.add(item);
    final list = keep.isEmpty
        ? ''
        : '  external_dirs:\n${keep.map((l) => l.endsWith('\n') ? l : '$l\n').join()}';
    body = body.substring(0, listed.start) + list + body.substring(listed.end);
    return text.substring(0, begin) + body + text.substring(end);
  }

  static List<String> _keepEnds(String text) {
    final out = <String>[];
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      if (text[i] == '\n') {
        out.add(text.substring(start, i + 1));
        start = i + 1;
      }
    }
    if (start < text.length) out.add(text.substring(start));
    return out;
  }
}
