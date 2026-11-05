import 'dart:io';
import 'package:path/path.dart' as p;
import 'adapters.dart';
import 'dsh_profile.dart';
import 'local_llm.dart';
import 'mcp_plans.dart' show libraryKeyPattern, mcpBaseName, mcpIdentityHash;
import 'skill_plans.dart' show hermesSkillDirs;
import 'agent_catalog.dart';
import 'agent_details.dart';
import 'provider_scans.dart';
import 'scan_files.dart';
import 'provider_facts.dart';

final class InventorySnapshot {
  final runtimes = <RuntimeRecord>[],
      mcp = <Map<String, dynamic>>[],
      skillSets = <Map<String, dynamic>>[],
          // Folders saved by "Reuse model folder" that no local LLM lists: each
          // {path, models}, drawn as a model folder of its own.
          modelFolders =
          <Map<String, dynamic>>[];
  final agentMcp = <String, List<String>>{},
      agentSkills = <String, List<String>>{},
      agentTools = <String, List<String>>{};

  /// Not shown: each MCP server's id → its key in the app's list of known
  /// servers (name or name~N), where it is remembered.
  final mcpLibrary = <String, String>{};
  Map<String, dynamic> toJson() => {
    'runtimes': runtimes.map((r) => r.toJson()).toList(),
    'mcp': mcp,
    'skill_sets': skillSets,
    'model_folders': modelFolders,
    'agent_mcp': agentMcp,
    'agent_skills': agentSkills,
    'agent_tools': agentTools,
  };
}

/// connect.chat_models: no speech, tokenizer or embedding models.
List<String> chatModels(List<String> models) => [
  for (final m in models)
    if (!RegExp(
      r'tts|tokenizer|embed|whisper|rerank',
      caseSensitive: false,
    ).hasMatch(m))
      m,
];

final class InventoryReader {
  InventoryReader(this.files, this.catalog, this.details)
    : providers = ProviderScans(files),
      llm = LocalLlm(files);
  final LocalLlm llm;
  final ScanFiles files;
  final AgentCatalog catalog;
  final DetailReaders details;
  final ProviderScans providers;
  Map<String, dynamic> rawMcp(Adapter adapter) {
    final spec = adapter.table('mcp');
    final path = spec['path'];
    if (path is! String || path.isEmpty) return {};
    if (spec['read'] == 'hook') {
      // Built-in readers for formats the app does not know (Python mcp_read hooks).
      final text = files.text(path, limit: 2 * 1024 * 1024) ?? '';
      final found = adapter.command == 'dsh' ? dshMcpServers(text) : const {};
      return {
        for (final e in found.entries)
          if (e.value is Map) e.key: e.value,
      };
    }
    final format = spec['format'] ?? 'json', key = spec['key'] ?? 'mcpServers';
    final data = format == 'toml'
        ? files.toml(path)
        : format == 'yaml'
        ? yamlMap(files.text(path) ?? '')
        : files.json(
            path,
            limit: format == 'claude' ? 8 * 1024 * 1024 : 1024 * 1024,
            comments: false,
          );
    final mapping = dig(data, key as String);
    return mapping is Map
        ? {
            for (final e in mapping.entries)
              if (e.value is Map) '${e.key}': e.value,
          }
        : {};
  }

  (String, String) serverTarget(Map entry) {
    final url = entry['url'] ?? entry['httpUrl'] ?? entry['serverUrl'];
    if (url is String && url.isNotEmpty) {
      try {
        return ('url', Uri.parse(url).host);
      } on FormatException {
        return ('url', '');
      }
    }
    var command = entry['command'];
    var args = entry['args'] is List ? entry['args'] as List : [];
    if (command is List) {
      args = command.skip(1).toList();
      command = command.isEmpty ? '' : command[0];
    }
    if (command is! String || command.isEmpty) return ('', '');
    final name = p.basename(command);
    if ({
      'npx',
      'bunx',
      'uvx',
      'pnpx',
      'pipx',
      'dlx',
      'docker',
      'podman',
      'node',
      'python',
      'python3',
      'uv',
      'bun',
    }.contains(name)) {
      for (final arg in args.take(10)) {
        if (arg is! String || arg.isEmpty) continue;
        if (arg.startsWith('-')) {
          if (!['-y', '--yes', '-m', '--quiet'].contains(arg)) break;
          continue;
        }
        if (arg.contains('=') || arg.contains('://')) break;
        return (
          'command',
          boundedText(
            '$name ${arg.startsWith('/') ? p.basename(arg) : arg}',
            80,
          ),
        );
      }
    }
    return ('command', boundedText(name, 80));
  }

  /// (name, kind, short target to show, [mcpIdentityHash]) of each server in use.
  List<(String, String, String, String)> servers(Map mapping) {
    final out = <(String, String, String, String)>[];
    for (final e in mapping.entries.take(100)) {
      if (e.value is! Map ||
          cleanName(e.key).isEmpty ||
          e.value['disabled'] == true ||
          e.value['enabled'] == false) {
        continue;
      }
      final (kind, target) = serverTarget(e.value as Map);
      out.add((cleanName(e.key), kind, target, mcpIdentityHash(e.value)));
    }
    return out;
  }

  List<String> skillDirs(Adapter adapter) {
    final spec = adapter.table('skills'), result = <String>[];
    for (final path in spec['dirs'] as List? ?? []) {
      final expanded = files.expand(path);
      if (!result.contains(expanded)) result.add(expanded);
    }
    final listed = spec['listed'];
    dynamic extras;
    if (listed is Map) {
      extras = dig(
        listed['format'] == 'toml'
            ? files.toml(listed['file'])
            : files.json(listed['file'], comments: false),
        listed['key'],
      );
    } else if (listed == 'hook') {
      if (adapter.command == 'hermes') {
        extras = hermesSkillDirs(
          files.text('~/.hermes/config.yaml', limit: 2 * 1024 * 1024) ?? '',
        );
      }
      if (adapter.command == 'openclaw') {
        extras = dig(
          files.json('~/.openclaw/openclaw.json', comments: false),
          'skills.load.extraDirs',
        );
      }
    }
    if (extras is List) {
      for (final path in extras.take(20)) {
        if (path is String && path.isNotEmpty) {
          final expanded = files.expand(path);
          if (!result.contains(expanded)) result.add(expanded);
        }
      }
    }
    return result;
  }

  List<(String, String)> skills(String folder, {int depth = 0}) {
    // System skill sets (Omarchy's, a package's) are root's: their names are listed too.
    final result = <(String, String)>[],
        entries = files.list(folder, allowRootOwned: true)..sort();
    for (final entry in entries.take(500)) {
      if (p.basename(entry).startsWith('.') || !Directory(entry).existsSync()) {
        continue;
      }
      if (FileSystemEntity.isFileSync(p.join(entry, 'SKILL.md'))) {
        // A symlinked attachment is grouped under its real, user-owned set.
        try {
          final real = Directory(entry).resolveSymbolicLinksSync();
          final owned = files
              .list(real, limit: 500, allowRootOwned: true)
              .any((file) => p.basename(file) == 'SKILL.md');
          if (!owned) continue;
          result.add((
            entry,
            FileSystemEntity.typeSync(entry, followLinks: false) ==
                    FileSystemEntityType.link
                ? p.dirname(real)
                : folder,
          ));
        } on FileSystemException {
          /* unusable attachment */
        }
      } else if (depth == 0) {
        for (final (skill, root) in skills(entry, depth: 1)) {
          result.add((
            skill,
            FileSystemEntity.typeSync(skill, followLinks: false) ==
                    FileSystemEntityType.link
                ? root
                : folder,
          ));
        }
      }
    }
    return result.take(500).toList();
  }

  /// mcp_library: remember(used) and load(), given the servers' agents.
  Map<String, dynamic> Function(
    Map<String, List<String>> serverAgents,
    bool remember,
  )?
  knownServers;

  InventorySnapshot collect(
    List<AgentRecord> agents, {
    bool remember = true,
    List<String> modelFolders = const [],
  }) {
    final inv = InventorySnapshot();
    inv.runtimes.addAll(providers.scan());
    // Keyed by id: a server's name, or for another server of the same name
    // (another command, arguments, address or transport, in another agent)
    // name~2, name~3, … ("~" is no part of a name): two servers, two boxes,
    // one label. Told apart by [mcpIdentityHash], shown by their short target.
    final serversByName = <String, Map<String, dynamic>>{},
        identities = <String, String>{},
        sets = <String, Map<String, dynamic>>{};
    void addServers(Map mapping, String command) {
      for (final (name, kind, target, identity) in servers(mapping)) {
        var id = name;
        for (var n = 2; ; n++) {
          if (!serversByName.containsKey(id) || identities[id] == identity) {
            break;
          }
          id = '$name~$n';
        }
        identities[id] = identity;
        final server = serversByName.putIfAbsent(
          id,
          () => {
            'id': id,
            'name': name,
            'kind': kind,
            'target': target,
            'agents': <String>[],
          },
        );
        if (command.isNotEmpty &&
            !(server['agents'] as List).contains(command)) {
          (server['agents'] as List).add(command);
        }
      }
    }

    for (final agent in agents.where((a) => a.installed)) {
      final command = agent.command, info = details.read(agent.adapter);
      for (final provider in info.providers) {
        final rt = localRuntime(provider, inv.runtimes);
        if (rt == null) continue;
        if (!rt.agents.contains(command)) rt.agents.add(command);
        if (provider['active'] == true && !rt.activeAgents.contains(command)) {
          rt.activeAgents.add(command);
        }
      }
      final mcp = rawMcp(agent.adapter);
      addServers(mcp, command);
      inv.agentMcp[command] = servers(mcp).map((e) => e.$1).toList();
      final folders = <String>[];
      for (final folder in skillDirs(agent.adapter)) {
        for (final (skill, root) in skills(folder)) {
          final key = tilde(files, root),
              set = sets.putIfAbsent(
                key,
                () => {'path': key, 'skills': <String>[], 'agents': <String>[]},
              );
          if (!(set['skills'] as List).contains(p.basename(skill))) {
            (set['skills'] as List).add(p.basename(skill));
          }
          if (!(set['agents'] as List).contains(command)) {
            (set['agents'] as List).add(command);
          }
          if (!folders.contains(key)) folders.add(key);
        }
      }
      inv.agentSkills[command] = folders;
      final tools = agent.adapter.table('tools');
      if (tools['file'] is String) {
        final names = files.json(tools['file'])[tools['key']];
        if (names is List) {
          inv.agentTools[command] = names
              .take(50)
              .map(cleanName)
              .where((s) => s.isNotEmpty)
              .toList();
        }
      }
    }
    // Runtime-owned MCP entries share the same strictly redacted DTO.
    addServers(
      mapOf(files.json('~/.lmstudio/mcp.json', comments: false)['mcpServers']),
      'lmstudio',
    );
    // The servers the app knows: remember what is in use (every server of a
    // name), list the rest too.
    final Map library;
    if (knownServers != null) {
      library = knownServers!({
        for (final e in serversByName.entries)
          e.key: [for (final a in e.value['agents'] as List) a as String],
      }, remember);
    } else {
      library = mapOf(
        files.json(
          '${files.identity.configDir}/mcp-servers.json',
          comments: false,
        )['servers'],
      );
    }
    for (final e in library.entries.take(200)) {
      if (e.value is! Map || !libraryKeyPattern.hasMatch('${e.key}')) continue;
      final key = '${e.key}', name = mcpBaseName(key);
      final entry = e.value as Map, transport = entry['transport'];
      if (!(transport == 'stdio' &&
              entry['command'] is String &&
              entry['args'] is List ||
          ['http', 'sse'].contains(transport) && entry['url'] is String)) {
        continue;
      }
      final identity = mcpIdentityHash(entry);
      // Already a box (in use, or listed twice): the server it is kept for.
      final same = serversByName.keys
          .where(
            (id) =>
                serversByName[id]!['name'] == name &&
                identities[id] == identity,
          )
          .firstOrNull;
      if (same != null) {
        inv.mcpLibrary.putIfAbsent(same, () => key);
        continue;
      }
      var id = key;
      for (var n = 2; serversByName.containsKey(id); n++) {
        id = '$name~$n';
      }
      final (kind, target) = serverTarget(
        transport == 'stdio'
            ? {'command': entry['command'], 'args': entry['args']}
            : {'url': entry['url']},
      );
      identities[id] = identity;
      inv.mcpLibrary[id] = key;
      serversByName[id] = {
        'id': id,
        'name': name,
        'kind': kind,
        'target': target,
        'agents': <String>[],
      };
    }
    inv.mcp.addAll(serversByName.values);
    inv.mcp.sort(
      (a, b) => (a['id'] as String).toLowerCase().compareTo(
        (b['id'] as String).toLowerCase(),
      ),
    );
    inv.skillSets.addAll(sets.values);
    inv.skillSets.sort((a, b) {
      final n = (b['agents'] as List).length.compareTo(
        (a['agents'] as List).length,
      );
      return n != 0 ? n : (a['path'] as String).compareTo(b['path'] as String);
    });
    for (final set in inv.skillSets) {
      (set['skills'] as List<String>).sort(
        (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
      );
    }
    inv.modelFolders.addAll(reusedFolders(inv.runtimes, modelFolders));
    return inv;
  }

  /// inventory.reused_folders: the reused model folders (Settings ›
  /// model_folders) with their files, unless a local LLM serves that same
  /// file: its models folder, a file it serves by path, or the same file
  /// reached another way. A file
  /// of the same model name elsewhere (another quantization) stays.
  List<Map<String, dynamic>> reusedFolders(
    List<RuntimeRecord> runtimes,
    List<String> modelFolders,
  ) {
    String real(String path) {
      try {
        return File(path).resolveSymbolicLinksSync();
      } on FileSystemException {
        return path;
      }
    }

    (int, int)? identity(String path) {
      final info = files.posix.statBlocks(path, follow: true);
      return info == null ? null : (info.dev, info.ino);
    }

    final served = {
      for (final rt in runtimes.where((r) => r.installed))
        if (rt.modelsDir.isNotEmpty) real(files.expand(rt.modelsDir)),
    };
    // Its folder's files, and those it serves by their own path (llama.cpp
    // -m, models.ini, KoboldCpp, vLLM), compared by device and inode.
    final servedFiles = {
      for (final dir in served)
        for (final file in providers.ggufFiles(dir)) ?identity(file),
      for (final rt in runtimes.where((r) => r.installed))
        for (final file in rt.modelFiles) ?identity(file),
    };
    final found = <Map<String, dynamic>>[];
    for (final folder in modelFolders.take(50)) {
      final path = files.expand(folder);
      if (served.contains(real(path))) continue;
      final models = {
        for (final file in providers.ggufFiles(path))
          if (!servedFiles.contains(identity(file)))
            ProviderScans.ggufName(file),
      }.take(500).toList();
      if (models.isNotEmpty) {
        found.add({'path': tilde(files, path), 'models': models});
      }
    }
    return found;
  }

  Map<String, dynamic> snapshot(List<AgentRecord> agents) {
    final inv = collect(agents);
    return {
      'agents': [
        for (final a in agents.where((a) => a.installed))
          {
            'command': a.command,
            'name': a.toJson()['name'],
            'provider': a.adapter.facts.containsKey('local_llm'),
            'mcp':
                a.adapter.table('mcp').isNotEmpty &&
                a.adapter.table('mcp')['in_app'] == null,
            'skills': a.adapter.table('skills')['own'] is String,
          },
      ],
      'mcp': [
        for (final s in inv.mcp) {...s, 'id': s['id']},
      ],
      'skills': [
        for (final s in inv.skillSets)
          {
            'id': s['path'],
            'name': s['path'],
            'skills': s['skills'],
            'agents': s['agents'],
          },
      ],
      'providers': [
        for (final rt in inv.runtimes.where(
          (r) =>
              r.installed &&
              (visibleProviderFacts['connect_keys'] as Map).containsKey(r.key),
        ))
          {
            'id': rt.key,
            'name': rt.name,
            'address': rt.address,
            'models': chatModels(rt.models),
            'agents': [
              for (final a in agents.where((a) => a.installed))
                if (a.adapter.facts.containsKey('local_llm') &&
                    llm.connected(a.adapter, rt.key))
                  a.command,
            ],
          },
      ],
    };
  }
}
