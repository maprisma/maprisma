import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'dsh_profile.dart';
import 'py_time.dart';
import 'adapters.dart';
import 'session_readers.dart';
import 'provider_scans.dart';
import 'agent_catalog.dart';
import 'desktop.dart';
import 'scan_files.dart';
import 'service_i18n.dart';
import 'provider_facts.dart';
import 'posix_ffi.dart';
import 'usage_rpc.dart';

String boundedText(dynamic value, [int limit = 80]) =>
    value is String ? String.fromCharCodes(value.trim().runes.take(limit)) : '';
Map mapOf(dynamic value) => value is Map ? value : {};
dynamic dig(dynamic data, String key) {
  for (final part in key.split('.')) {
    if (data is! Map) return null;
    data = data[part];
  }
  return data;
}

Map yamlMap(String source) {
  try {
    final value = loadYaml(source);
    return value is Map ? value : {};
  } on YamlException {
    return {};
  }
}

final class AgentInfo {
  String plan = '', model = '', configDir = '';
  final providers = <Map<String, dynamic>>[], limits = <Map<String, dynamic>>[];
  int? todayPrompts, todaySessions, todayTokens, totalSessions, activeDays;
  DateTime? lastUsed;
  Map<String, dynamic> toJson() => {
    'plan': plan,
    'model': model,
    'providers': providers
        .map(
          (p) => {
            'name': p['name'],
            'local': p['local'],
            'active': p['active'],
          },
        )
        .toList(),
    'limits': [
      for (final l in limits)
        {
          'label': l['label'],
          'percent': l['percent'],
          'resets_at': l['resets_at'],
        },
    ],
    'today_prompts': todayPrompts,
    'today_sessions': todaySessions,
    'today_tokens': todayTokens,
    'total_sessions': totalSessions,
    'active_days': activeDays,
    'last_used': lastUsed == null ? null : pyIsoLocal(lastUsed!),
  };
  static String? iso(DateTime? date) {
    if (date == null) return null;
    final text = date.toUtc().toIso8601String();
    return '${text.replaceFirst(RegExp(r'\.000Z$'), 'Z').replaceFirst(RegExp(r'Z$'), '')}+00:00';
  }
}

/// agent_details._usage_time: a usage record's time, an ISO text or seconds
/// or milliseconds since 1970 (collectors write both); null when there is none.
DateTime? usageTime(dynamic value) {
  if (value is num && value.isFinite && value > 0) {
    final seconds = value > 1e11 ? value / 1000 : value;
    if (seconds > 8e12) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      (seconds * 1000).round(),
      isUtc: true,
    );
  }
  return value is String && value.isNotEmpty ? DateTime.tryParse(value) : null;
}

/// Where Omarchy's usage records are (desktop_omarchy.USAGE_DIR); another
/// desktop reads them from there too when Omarchy's collector is installed.
String usageDir(Map<String, String> env) {
  final state = (env['XDG_STATE_HOME'] ?? '').startsWith('/')
      ? env['XDG_STATE_HOME']!
      : '${env['HOME'] ?? ''}/.local/state';
  return '$state/omarchy/agents/usage';
}

/// desktop_omarchy.has_usage_collector: Omarchy's collector of this agent's
/// usage (`omarchy-agent-usage-<command>`), in Omarchy's bin folder,
/// /usr/bin or, on another desktop, anywhere on PATH; null without one.
String? usageCollector(String command, Map<String, String> env) {
  if (!RegExp(r'^[a-z0-9-]{1,64}$').hasMatch(command)) return null;
  final root = (env['OMARCHY_PATH'] ?? '').isNotEmpty
      ? env['OMARCHY_PATH']!
      : '/usr/share/omarchy';
  for (final dir in ['$root/bin', '/usr/bin']) {
    final path = '$dir/omarchy-agent-usage-$command';
    if (FileSystemEntity.typeSync(path) == FileSystemEntityType.file) {
      return path;
    }
  }
  return whichIn('omarchy-agent-usage-$command', env['PATH']);
}

bool usageCollectorExists(String command, Map<String, String> env) =>
    usageCollector(command, env) != null;

/// Where Maprisma keeps the usage record it asked an agent's own program for
/// (`[plan_limits]`, agent_details.native_usage_path): only where no Omarchy
/// collector of that agent is.
String nativeUsagePath(String command, Map<String, String> env) {
  final state = (env['XDG_STATE_HOME'] ?? '').startsWith('/')
      ? env['XDG_STATE_HOME']!
      : '${env['HOME'] ?? ''}/.local/state';
  return '$state/maprisma/usage/$command.json';
}

/// desktop_omarchy.refresh_usage: fresh usage of this agent (at most a
/// minute); true when it worked. On Omarchy its omarchy-agent-usage-update
/// writes the record; elsewhere the collector is run here and what it prints,
/// one JSON object, becomes the record. Maprisma reads no credentials: the
/// collector, Omarchy's own tool, does what it does on Omarchy. Without a
/// collector, an agent whose adapter names a protocol for its plan limits
/// (`rpc`, `argv`: agent_details.native_usage) is asked itself, and the
/// answer becomes Maprisma's own record of it.
Future<bool> refreshUsage(
  String command,
  Map<String, String> env, {
  String? rpc,
  List<String>? argv,
  String? program,
}) async {
  final collector = usageCollector(command, env);
  if (collector == null) {
    if (rpc == null || argv == null || program == null) return false;
    final record = await askPlanLimits(rpc, argv, env, program: program);
    if (record == null) return false;
    try {
      final path = nativeUsagePath(command, env);
      Directory(p.dirname(path)).createSync(recursive: true);
      Posix().atomicWrite(path, utf8.encode('${jsonEncode(record)}\n'));
      return true;
    } on FileSystemException {
      return false;
    }
  }
  final update = (env['OMARCHY_PATH'] ?? '').isNotEmpty
      ? whichIn('omarchy-agent-usage-update', env['PATH'])
      : null;
  try {
    final process = await Process.start(
      update ?? collector,
      update != null ? [command] : const [],
      environment: env,
      includeParentEnvironment: false,
    );
    final out = <int>[];
    var tooLong = false;
    final reading = process.stdout.listen((chunk) {
      if (out.length + chunk.length > usageRecordLimit) {
        tooLong = true;
      } else {
        out.addAll(chunk);
      }
    }).asFuture<void>();
    unawaited(process.stderr.drain<void>());
    await process.stdin.close();
    final code = await process.exitCode.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    await reading.timeout(const Duration(seconds: 5), onTimeout: () {});
    if (code != 0) return false;
    if (update != null) return true;
    if (tooLong) return false;
    final Object? record;
    try {
      record = jsonDecode(utf8.decode(out));
    } on FormatException {
      return false;
    }
    if (record is! Map) return false;
    Posix().atomicWrite(
      '${usageDir(env)}/$command.json',
      utf8.encode('${jsonEncode(record)}\n'),
    );
    return true;
  } on ProcessException {
    return false;
  } on FileSystemException {
    return false;
  }
}

/// The most a collector may print: a record is a few kilobytes.
const usageRecordLimit = 4 * 1024 * 1024;

final class DetailReaders {
  DetailReaders(this.files, this.desktop, this.i18n);
  final ScanFiles files;
  final Desktop desktop;
  final ServiceI18n i18n;
  Map<String, dynamic> provider(
    String name,
    dynamic url, {
    int models = 0,
    bool active = true,
  }) {
    Uri? uri;
    try {
      if (url is String) uri = Uri.parse(url);
    } on FormatException {
      /* no usable address */
    }
    final local =
        uri != null &&
        ['127.0.0.1', 'localhost', '::1', '0.0.0.0'].contains(uri.host);
    final ports = <int, String>{};
    for (final p in visibleProviderFacts['local'] as List) {
      for (final port in p['ports'] as List) {
        ports.putIfAbsent(port as int, () => p['name'] as String);
      }
    }
    final port = local && uri.hasPort ? uri.port : null;
    final runtime = local ? ports[port] ?? '' : '';
    return {
      'name': boundedText(name, 40),
      'local': local,
      'runtime': runtime,
      // The configured port: the map joins it to the local LLM detected
      // there (localRuntime), the usual ports above only when none is.
      'port': port,
      'models': models,
      'active': active,
    };
  }

  int modelCount(dynamic models) => models is Map
      ? models.length.clamp(0, 9999)
      : models is List
      ? models.length.clamp(0, 9999)
      : 0;
  // agent_readers.claude_session_model: the newest session file is looked
  // for at most every claudeRescan seconds (or when there was none or it is
  // gone), its end read again only when the file changed.
  static const claudeRescan = 30, claudeMaxEntries = 2000;
  static const claudeAliases = ['fable', 'opus', 'sonnet'];
  ({String root, double at, String? file})? _claudeSeen;
  (String, String)? _claudeModel;

  /// No "model" in settings.json: Claude Code runs the model of the last
  /// reply in its newest session file (`projects/<folder>/<session>.jsonl`),
  /// as the alias the map switches between ("claude-opus-5-5" -> "opus")
  /// when it is one; "" when there is none. Only the file's end is read.
  String claudeSessionModel([String root = '~/.claude/projects']) {
    root = files.expand(root);
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    var seen = _claudeSeen;
    if (seen == null ||
        seen.root != root ||
        seen.file == null ||
        now - seen.at >= claudeRescan) {
      seen = _claudeSeen = (root: root, at: now, file: _newestClaude(root));
    }
    final path = seen.file;
    if (path == null) return '';
    final stat = files.posix.lstatFull(path);
    if (stat == null) {
      _claudeSeen = (root: root, at: now, file: null); // gone: look again
      return '';
    }
    final key = '$path\x00${stat.signature.join(',')}';
    final cached = _claudeModel;
    if (cached != null && cached.$1 == key) return cached.$2;
    final found = RegExp(
      r'"model"\s*:\s*"(claude-[A-Za-z0-9._-]{1,80})"',
    ).allMatches(files.text(path, limit: 256 * 1024, portion: 'tail') ?? '');
    var model = found.isEmpty ? '' : found.last[1]!;
    if (model.isNotEmpty) {
      final parts = model.split('-');
      model = claudeAliases.firstWhere(parts.contains, orElse: () => model);
    }
    _claudeModel = (key, model);
    return model;
  }

  /// The most recently written session file, by the file's own time (writing
  /// to a file does not touch its folder's); a project or file that cannot be
  /// read is skipped, not the whole look.
  String? _newestClaude(String root) {
    (int, String)? newest;
    for (final project in files.list(root, limit: claudeMaxEntries)) {
      if (!_isFolder(project)) continue;
      final found = newestFile(project, 0, (n) => n.endsWith('.jsonl'));
      if (found != null && (newest == null || found.$1 > newest.$1)) {
        newest = found;
      }
    }
    return newest?.$2;
  }

  bool _isFolder(String path) {
    final stat = files.posix.lstatFull(path);
    return stat != null && stat.mode & 0xF000 == 0x4000;
  }

  /// agent_readers._newest: (time, path) of the most recently written
  /// regular file [levels] folders below [root] (no links followed) whose
  /// name [wanted] accepts, at most 2000 entries a folder.
  (int, String)? newestFile(
    String root,
    int levels,
    bool Function(String) wanted,
  ) {
    (int, String)? newest;
    final todo = [(files.expand(root), 0)];
    while (todo.isNotEmpty) {
      final (folder, depth) = todo.removeLast();
      for (final path in files.list(folder, limit: 2000)) {
        final stat = files.posix.lstatFull(path);
        if (stat == null) continue;
        final kind = stat.mode & 0xF000;
        if (depth < levels && kind == 0x4000) {
          todo.add((path, depth + 1));
        } else if (depth == levels &&
            kind == 0x8000 &&
            wanted(p.basename(path))) {
          final time = stat.sec * 1000000000 + stat.nsec;
          if (newest == null || time > newest.$1) newest = (time, path);
        }
      }
    }
    return newest;
  }

  AgentInfo read(Adapter adapter) {
    final info = AgentInfo();
    final spec = adapter.table('details');
    final reader =
        spec['reader'] ?? (spec['hook'] == true ? adapter.command : '');
    switch (reader) {
      case 'claude':
        final config = files.json('~/.claude/settings.json');
        info.model = boundedText(config['model']);
        final url = mapOf(config['env'])['ANTHROPIC_BASE_URL'];
        if (url is String && url.isNotEmpty) {
          info.providers.add(provider('Anthropic API', url));
        }
      case 'codex':
        final config = files.toml('~/.codex/config.toml');
        info.model = boundedText(config['model']);
        final chosen = boundedText(config['model_provider'], 40);
        for (final entry in mapOf(config['model_providers']).entries.take(50)) {
          if (entry.value is Map) {
            info.providers.add(
              provider(
                boundedText(entry.value['name'], 40).isNotEmpty
                    ? entry.value['name']
                    : entry.key,
                entry.value['base_url'],
                active: entry.key == chosen,
              ),
            );
          }
        }
        if (chosen.isNotEmpty && info.model.isNotEmpty) {
          info.model = '${info.model} ($chosen)';
        }
      case 'opencode':
        final root = '~/.config/opencode';
        final main = files.json('$root/opencode.json');
        final config = main.isNotEmpty
            ? main
            : files.json('$root/opencode.jsonc');
        info.model = boundedText(config['model']);
        for (final e in mapOf(config['provider']).entries.take(50)) {
          if (e.value is Map) {
            info.providers.add(
              provider(
                e.key,
                mapOf(e.value['options'])['baseURL'],
                models: modelCount(e.value['models']),
                active:
                    info.model.isEmpty || info.model.startsWith('${e.key}/'),
              ),
            );
          }
        }
      case 'pi':
        final root = spec['dir'] as String? ?? '~/.pi/agent';
        final config = files.json('$root/settings.json');
        var model = boundedText(config['defaultModel']),
            chosen = boundedText(config['defaultProvider'], 40);
        final role = mapOf(
          yamlMap(files.text('$root/config.yml') ?? '')['modelRoles'],
        )['default'];
        if (role is String && role.contains('/')) {
          final parts = role.split('/');
          chosen = boundedText(parts.first, 40);
          model = boundedText(parts.skip(1).join('/'));
        }
        info.model = model.isNotEmpty && chosen.isNotEmpty
            ? '$model ($chosen)'
            : model;
        for (final e in mapOf(
          files.json('$root/models.json')['providers'],
        ).entries.take(50)) {
          if (e.value is Map) {
            info.providers.add(
              provider(
                e.key,
                e.value['baseUrl'],
                models: modelCount(e.value['models']),
                active: chosen.isEmpty || e.key == chosen,
              ),
            );
          }
        }
        for (final e in mapOf(
          yamlMap(files.text('$root/models.yml') ?? '')['providers'],
        ).entries.take(50)) {
          if (e.value is Map &&
              !info.providers.any((p) => p['name'] == e.key)) {
            info.providers.add(
              provider(
                e.key,
                e.value['baseUrl'],
                models: modelCount(e.value['models']),
                active: chosen.isEmpty || e.key == chosen,
              ),
            );
          }
        }
      case 'copilot':
        info.model = boundedText(files.json('~/.copilot/config.json')['model']);
      case 'cursor':
        final model = files.json('~/.cursor/cli-config.json')['model'];
        info.model = boundedText(
          model is Map ? model['displayName'] ?? model['modelId'] : model,
        );
      case 'hermes':
        final config = yamlMap(files.text('~/.hermes/config.yaml') ?? '');
        final spec = mapOf(config['model']);
        final model = boundedText(spec['default']),
            chosen = boundedText(spec['provider'], 40);
        info.model = model.isNotEmpty && chosen.isNotEmpty
            ? '$model ($chosen)'
            : model;
        if (boundedText(spec['base_url'], 512).isNotEmpty) {
          info.providers.add(
            provider(chosen.isEmpty ? 'custom' : chosen, spec['base_url']),
          );
        }
        for (final e in mapOf(config['providers']).entries.take(50)) {
          if (e.value is Map &&
              !info.providers.any((p) => p['name'] == e.key)) {
            info.providers.add(
              provider(
                e.key,
                e.value['base_url'] ?? e.value['api'],
                models: modelCount(e.value['models']),
                active: chosen.isEmpty || chosen == e.key,
              ),
            );
          }
        }
      case 'dsh':
        final text = files.text(dshProfile) ?? '';
        if (text.isEmpty) break;
        final (chosen, model) = dshDefaultModel(text);
        info.model = model.isNotEmpty && chosen.isNotEmpty
            ? '${boundedText(model)} (${boundedText(chosen, 40)})'
            : boundedText(model);
        for (final e in dshProviders(text).entries.take(50)) {
          if (e.value is Map) {
            info.providers.add(
              provider(
                '${e.key}',
                e.value['baseURL'],
                models: modelCount(e.value['models']),
                active: chosen.isEmpty || e.key == chosen,
              ),
            );
          }
        }
      case 'goose':
        final config = yamlMap(files.text('~/.config/goose/config.yaml') ?? '');
        final chosen = boundedText(
          config['active_provider'] ?? config['GOOSE_PROVIDER'],
          40,
        );
        final providers = mapOf(config['providers']);
        final model = boundedText(
          mapOf(providers[chosen])['model'] ?? config['GOOSE_MODEL'],
        );
        info.model = model.isNotEmpty && chosen.isNotEmpty
            ? '$model ($chosen)'
            : model;
        final names = providers.entries
            .take(50)
            .where(
              (e) =>
                  e.value is Map &&
                  (e.value['enabled'] == true || e.value['configured'] == true),
            )
            .map((e) => e.key)
            .toList();
        if (names.isEmpty && chosen.isNotEmpty) names.add(chosen);
        for (final name in names) {
          info.providers.add(
            provider(
              name,
              config['${(name as String).toUpperCase()}_HOST'] ??
                  {
                    'ollama': 'http://localhost:11434',
                    'lmstudio': 'http://localhost:1234/v1',
                    'local': 'http://localhost:8080/v1',
                  }[name],
              active: name == chosen,
            ),
          );
        }
      case 'openclaw':
        final config = files.json('~/.openclaw/openclaw.json');
        final selected = dig(config, 'agents.defaults.model');
        final primary = boundedText(
          selected is Map ? selected['primary'] : selected,
          160,
        );
        final parts = primary.split('/');
        final chosen = parts.length > 1 ? boundedText(parts.first, 40) : '';
        final model = boundedText(
          parts.length > 1 ? parts.skip(1).join('/') : primary,
        );
        info.model = model.isNotEmpty && chosen.isNotEmpty
            ? '$model ($chosen)'
            : model;
        final providers = mapOf(dig(config, 'models.providers'));
        for (final e in providers.entries.take(50)) {
          if (e.value is Map) {
            info.providers.add(
              provider(
                e.key,
                e.value['baseUrl'],
                models: modelCount(e.value['models']),
                active: chosen.isEmpty || chosen == e.key,
              ),
            );
          }
        }
        final local = {
          'llama-cpp': 'http://127.0.0.1:8080/v1',
          'ollama': 'http://127.0.0.1:11434',
          'lmstudio': 'http://127.0.0.1:1234/v1',
        };
        if (local.containsKey(chosen) && !providers.containsKey(chosen)) {
          info.providers.add(provider(chosen, local[chosen]));
        }
      case 'gemini':
        // settings.json's model.name (older files: "model" as text), else
        // the last reply in its newest session file (gemini-files).
        final model = files.json('~/.gemini/settings.json')['model'];
        info.model = boundedText(model is Map ? model['name'] : model);
        if (info.model.isNotEmpty) break;
        (int, String)? newest;
        for (final project in files.list('~/.gemini/tmp', limit: 2000)) {
          if (!_isFolder(project)) continue;
          for (final found in [
            newestFile(
              '$project/chats',
              0,
              (n) =>
                  n.startsWith('session-') &&
                  (n.endsWith('.json') || n.endsWith('.jsonl')),
            ),
            newestFile('$project/chats', 1, (n) => n.endsWith('.jsonl')),
          ]) {
            if (found != null && (newest == null || found.$1 > newest.$1)) {
              newest = found;
            }
          }
        }
        if (newest != null) {
          final found = RegExp(r'"model"\s*:\s*"(gemini-[A-Za-z0-9._-]{1,80})"')
              .allMatches(
                files.text(
                      newest.$2,
                      limit: 4 * 1024 * 1024,
                      portion: 'tail',
                    ) ??
                    '',
              );
          if (found.isNotEmpty) info.model = found.last[1]!;
        }
      case 'grok':
        // No model in its settings: its newest session's last finished turn
        // (usage.json's turns[].modelUsage, as omarchy-agent-usage-grok
        // reads it); of several models, the one with the most tokens.
        final path = newestFile(
          '~/.grok/sessions',
          2,
          (n) => n == 'usage.json',
        );
        final turns = path == null ? null : files.json(path.$2)['turns'];
        if (turns is! List) break;
        for (final turn in turns.reversed.take(2000)) {
          final used = turn is Map ? turn['modelUsage'] : null;
          if (used is! Map) continue;
          int tokens(Map bucket, String key) =>
              bucket[key] is int ? bucket[key] as int : 0;
          final sizes = {
            for (final e in used.entries.take(50))
              if (e.key is String && e.value is Map)
                e.key as String:
                    tokens(e.value, 'inputTokens') +
                    tokens(e.value, 'outputTokens'),
          };
          if (sizes.isEmpty) continue;
          var best = sizes.keys.first;
          for (final e in sizes.entries) {
            if (e.value > sizes[best]!) best = e.key;
          }
          info.model = boundedText(best);
          break;
        }
      case 'crush':
        // ~/.config/crush/crush.json: models.large and its own providers.
        // Its data folder's crush.json keeps the API keys: not read.
        final config = files.json('~/.config/crush/crush.json');
        final large = mapOf(mapOf(config['models'])['large']);
        final model = boundedText(large['model']),
            chosen = boundedText(large['provider'], 40);
        info.model = model.isNotEmpty && chosen.isNotEmpty
            ? '$model ($chosen)'
            : model;
        for (final e in mapOf(config['providers']).entries.take(50)) {
          if (e.value is Map) {
            info.providers.add(
              provider(
                '${e.key}',
                e.value['base_url'],
                models: modelCount(e.value['models']),
                active: chosen.isEmpty || e.key == chosen,
              ),
            );
          }
        }
      case 'lmstudio-app':
        info.providers.add(provider('LM Studio', 'http://127.0.0.1:1234/v1'));
      case 'agy':
        // No model in its settings: its newest log names the one it selected.
        const folder = '~/.gemini/antigravity-cli/log';
        final logs = [
          for (final path in files.list(folder, limit: 2000))
            if (p.basename(path).startsWith('cli-') &&
                path.endsWith('.log') &&
                FileSystemEntity.typeSync(path, followLinks: false) ==
                    FileSystemEntityType.file)
              (File(path).statSync().modified, path),
        ]..sort((a, b) => a.$1.compareTo(b.$1));
        if (logs.isNotEmpty) {
          final found =
              RegExp(
                r'selected model override to backend: label="([^"\n]{1,80})"',
              ).allMatches(
                files.text(
                      logs.last.$2,
                      limit: 4 * 1024 * 1024,
                      portion: 'tail',
                    ) ??
                    '',
              );
          if (found.isNotEmpty) info.model = agyModelName(found.last[1]!);
        }
    }
    if (info.model.isEmpty && reader == 'claude') {
      info.model = claudeSessionModel();
    }
    if (info.model.isEmpty && reader == 'codex') {
      final session = SessionReaders(files);
      final paths = session.matching(
        '~/.codex/sessions',
        '*/*/*/rollout-*.jsonl',
      );
      if (paths.isNotEmpty) {
        final source = files.text(paths.first, limit: 64 * 1024 * 1024) ?? '';
        final found = RegExp(
          r'"type"\s*:\s*"turn_context".*?"model"\s*:\s*"([A-Za-z0-9._:-]{1,80})"',
        ).allMatches(source).toList();
        if (found.isNotEmpty) info.model = found.last[1]!;
      }
      // Codex before its first session: the model its models cache lists
      // first (the one a new Codex starts with).
      if (info.model.isEmpty &&
          boundedText(
            files.toml('~/.codex/config.toml')['model_provider'],
            40,
          ).isEmpty) {
        info.model = codexCacheModel(files);
      }
    }
    final usage = usageRecord(adapter.command, adapter);
    final tier = boundedText(usage['tierLabel'], 40);
    info.plan =
        {
          'free': 'Free',
          'go': 'Go',
          'plus': 'Plus',
          'pro': 'Pro',
          'prolite': 'Pro Lite',
          'team': 'Team',
          'business': 'Business',
          'enterprise': 'Enterprise',
          'edu': 'Edu',
        }[tier.toLowerCase()] ??
        tier;
    int? count(dynamic v) => v is int && v >= 0 ? v : null;
    info.todayPrompts = count(usage['todayPrompts']);
    info.todaySessions = count(usage['todaySessions']);
    info.todayTokens = count(usage['todayTotalTokens']);
    info.totalSessions = count(usage['totalSessions']);
    info.activeDays = count(usage['activeDays']);
    if (usage['limits'] is List) {
      // When the numbers were measured (the collector's limitsFetchedAt, else
      // the record's updatedAt, else when the file was written: an age never
      // stays unknown) and whether the collector kept them past a failed
      // probe (limitsStale): agent_badges.currentLimits and limitsStale
      // judge by them.
      final measured =
          usageTime(usage['limitsFetchedAt']) ??
          usageTime(usage['updatedAt']) ??
          recordWritten(usagePath(adapter.command));
      for (final item in (usage['limits'] as List).take(8)) {
        if (item is! Map || item['percent'] is! num) continue;
        final percent = item['percent'] as num;
        final resets = item['resetsAt'] is String
            ? DateTime.tryParse(item['resetsAt'])
            : null;
        info.limits.add({
          'label': boundedText(item['title'] ?? item['label'], 40),
          'percent': percent.clamp(0.0, 1.0),
          'resets_at': AgentInfo.iso(resets),
          'measured_at': AgentInfo.iso(measured),
          'stale': usage['limitsStale'] == true,
        });
      }
    }
    info.lastUsed = newestMtime([
      for (final path in adapter.facts['activity'] as List? ?? [])
        path as String,
    ]);
    final home = adapter.facts['home'] as String? ?? '';
    info.configDir = home.isNotEmpty && files.exists(home) ? home : '';
    return info;
  }

  /// agent_details.USAGE_MAX_AGE: seconds before details ask Omarchy for fresh
  /// usage.
  static const usageMaxAge = 10 * 60;

  /// desktop_omarchy.has_usage_collector: on Omarchy, or on another desktop
  /// with Omarchy's collector installed (desktop_generic.has_usage_collector).
  bool hasUsageCollector(String command) =>
      usageCollectorExists(command, files.identity.environment);

  /// agent_details.usage_is_stale: Omarchy collects usage for this agent and
  /// its record is missing or old, or older than the agent's sign-in (only
  /// the credential files' times are looked at, never their text).
  bool usageIsStale(
    String command,
    List<String> accessFiles, {
    DateTime? now,
    bool native = false,
  }) {
    if (!hasUsageCollector(command) && !native) return false;
    final record = usagePath(command);
    if (FileSystemEntity.typeSync(record) == FileSystemEntityType.notFound) {
      return true;
    }
    final written = File(record).statSync().modified;
    if ((now ?? DateTime.now()).difference(written).inMilliseconds >
        usageMaxAge * 1000) {
      return true;
    }
    for (final name in accessFiles) {
      final path = name.startsWith('/') ? name : '${files.identity.home}/$name';
      if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) {
        continue;
      }
      if (File(path).statSync().modified.isAfter(written)) return true;
    }
    return false;
  }

  /// agent_details.usage_record: the desktop's usage record of an agent.
  /// Paid usage beyond the plan (access.extra_*): on, off, or null when this
  /// PC cannot tell; only that one value of the file is used.
  Map<String, dynamic> extraUsage(Adapter adapter) {
    final access = adapter.table('access');
    final path = access['extra_file'], key = access['extra_key'];
    final on = path is String && key is String
        ? dig(files.json(path, limit: 8 * 1024 * 1024), key)
        : null;
    return {'on': on is bool ? on : null, 'url': access['extra_url'] ?? ''};
  }

  /// agent_details.record_written: when a usage record was written.
  DateTime? recordWritten(String path) {
    try {
      final stat = File(path).statSync();
      if (stat.type == FileSystemEntityType.notFound) return null;
      return DateTime.fromMillisecondsSinceEpoch(
        stat.modified.millisecondsSinceEpoch ~/ 1000 * 1000, // whole seconds
        isUtc: true,
      );
    } on FileSystemException {
      return null;
    }
  }

  /// The agent's usage record. Maprisma's own, asked of the agent's
  /// program, counts only while it is signed in ([limitsSignedIn] of
  /// [adapter]): after a sign-out it is the old account's plan and limits.
  Map<String, dynamic> usageRecord(String command, [Adapter? adapter]) {
    if (!RegExp(r'^[a-z0-9-]{1,64}$').hasMatch(command)) return {};
    final path = usagePath(command);
    if (adapter != null &&
        path == nativeUsagePath(command, files.identity.environment) &&
        adapter.table('plan_limits').isNotEmpty &&
        !limitsSignedIn(adapter)) {
      return {};
    }
    return Map<String, dynamic>.from(files.json(path));
  }

  /// agent_details.usage_path: Omarchy's record of the agent where its
  /// collector is (on Omarchy also one Omarchy wrote); else Maprisma's own,
  /// asked of the agent's program (`[plan_limits]`), when there is one.
  String usagePath(String command) {
    final omarchy =
        '${files.identity.root('XDG_STATE_HOME', '.local/state')}/omarchy/agents/usage/$command.json';
    if (hasUsageCollector(command)) return omarchy;
    if (desktop.name == 'omarchy' &&
        FileSystemEntity.typeSync(omarchy) != FileSystemEntityType.notFound) {
      return omarchy;
    }
    return nativeUsagePath(command, files.identity.environment);
  }

  /// The folder an agent's plan_limits.home_env moves its home to
  /// (CODEX_HOME), or null while it is not set.
  String? _movedHome(Adapter adapter) {
    final name = adapter.table('plan_limits')['home_env'];
    final moved = name is String && name.isNotEmpty
        ? files.identity.environment[name] ?? ''
        : '';
    return moved.startsWith('/') ? moved : null;
  }

  /// agent_details.access_paths: the agent's access files where it keeps
  /// them, in the folder its plan_limits.home_env names when that is set
  /// (each by its name), else in the home folder.
  List<String> accessPaths(Adapter adapter) {
    final moved = _movedHome(adapter);
    return [
      for (final f in adapter.table('access')['files'] as List? ?? const [])
        if (f is String)
          moved != null
              ? p.join(moved, p.basename(f))
              : '${files.identity.home}/$f',
    ];
  }

  /// agent_details.plan_limits_signed_in: whether the agent's own program
  /// can answer for a sign-in: one of its access files is there (a stat,
  /// never a read; [accessPaths]), or its store setting (plain
  /// configuration, plan_limits.store: Codex's cli_auth_credentials_store)
  /// keeps the sign-in outside the files, a keyring, which only the program
  /// can tell.
  bool limitsSignedIn(Adapter adapter) {
    if (accessPaths(adapter).any(
      (path) => FileSystemEntity.typeSync(path) == FileSystemEntityType.file,
    )) {
      return true;
    }
    final store = adapter.table('plan_limits')['store'];
    if (store is! Map || store['file'] is! String || store['key'] is! String) {
      return false;
    }
    final moved = _movedHome(adapter);
    final path = moved != null
        ? p.join(moved, p.basename(store['file'] as String))
        : files.expand(store['file'] as String);
    final value = dig(
      store['format'] == 'toml'
          ? files.toml(path)
          : files.json(path, comments: false),
      store['key'] as String,
    );
    final inFiles = store['files'] is String && store['files'] != ''
        ? store['files']
        : 'file';
    return value is String && value.isNotEmpty && value != inFiles;
  }

  /// agent_details.plan_limits_rpc: (rpc, argv, program) of an agent whose
  /// plan limits Maprisma may ask its own program for: its adapter names
  /// how, no Omarchy collector of it is found, it is signed in
  /// ([limitsSignedIn]) and its installed program is found offline
  /// (AgentCatalog.realProgram: never a launcher that would install or
  /// update it). Else null.
  (String, List<String>, String)? planLimitsRpc(Adapter adapter) {
    final facts = adapter.table('plan_limits');
    final rpc = facts['rpc'], argv = facts['argv'];
    if (rpc is! String || argv is! List || argv.isEmpty) return null;
    if (hasUsageCollector(adapter.command)) return null;
    if (!limitsSignedIn(adapter)) return null;
    final catalog = AgentCatalog(files, desktop);
    final program = catalog.realProgram(
      adapter.command,
      specs: catalog.miseSpecs(adapter),
    );
    return program == null
        ? null
        : (rpc, [for (final a in argv) '$a'], program);
  }

  static const maxScan = 3000, dateDepth = 2;

  /// Python agent_details.newest_mtime: the newest mtime of these files, or of
  /// the entries two levels deep in these folders, with one shared budget of
  /// [maxScan] entries; then on along the last-named subfolders (YYYY/MM/DD).
  DateTime? newestMtime(List<String> paths) {
    final posix = files.posix;
    var newest = 0.0, seen = 0;
    double? mtime(String path) {
      final info = posix.lstatTime(path);
      return info == null ? null : pyTimestamp(info.sec, info.nsec);
    }

    bool isDir(String path) =>
        (posix.lstatTime(path)?.mode ?? 0) & 0xf000 == 0x4000;
    for (final raw in paths) {
      final path = files.expand(raw);
      final own = mtime(path);
      if (own == null) continue;
      if (own > newest) newest = own;
      if (!isDir(path)) continue;
      final stack = [(path, 0)];
      while (stack.isNotEmpty && seen < maxScan) {
        final (folder, depth) = stack.removeLast();
        for (final entry in files.list(folder, limit: maxScan - seen + 1)) {
          seen++;
          if (seen >= maxScan) break;
          final time = mtime(entry);
          if (time == null) continue;
          if (time > newest) newest = time;
          if (depth < 1 && isDir(entry)) stack.add((entry, depth + 1));
        }
      }
      var folder = path;
      for (var level = 0; level < 1 + dateDepth; level++) {
        final dirs = files.list(folder, limit: 400).where(isDir).toList()
          ..sort();
        if (dirs.isEmpty) break;
        folder = dirs.last;
        if (level == 0) continue;
        for (final entry in files.list(folder, limit: maxScan)) {
          final time = mtime(entry);
          if (time != null && time > newest) newest = time;
        }
      }
    }
    return newest == 0 ? null : pyFromTimestamp(newest);
  }

  Map<String, dynamic> actions(AgentRecord agent) {
    final a = agent.adapter;
    final ways = a.facts['install'] as List? ?? [];
    final tools = ProviderScans(files);
    bool choice(String action) {
      final prefer =
          {
            'mise': ['mise'],
            'package': ['package', 'command'],
            'own': ['installer', 'tool', 'command'],
          }[agent.source] ??
          <String>[];
      final selected = ways
          .where(
            (w) =>
                action == 'install' ||
                prefer.contains(w['kind']) ||
                action == 'uninstall' && w['kind'] == 'manual',
          )
          .toList();
      for (final way in selected) {
        final kind = way['kind'];
        if (kind == 'installer') return false;
        if (kind == 'mise' &&
            (way['spec'] as String? ?? '').isNotEmpty &&
            tools.which('mise')) {
          return true;
        }
        if (kind == 'tool' &&
            ['npm', 'pipx', 'uv'].contains(way['tool']) &&
            (way['spec'] as String? ?? '').isNotEmpty &&
            tools.which(way['tool'])) {
          return true;
        }
        if (kind == 'command') {
          final argv =
              way[action == 'update' ? 'update' : 'argv'] as List? ?? [];
          if (action != 'uninstall' &&
              argv.isNotEmpty &&
              tools.which(argv[0])) {
            return true;
          }
        }
        if (kind == 'manual' && action != 'update') {
          return (way['url'] as String? ?? '').isNotEmpty;
        }
      }
      if (action == 'update') return false;
      return selected.any(
        (w) =>
            w['kind'] == 'mise' && (w['spec'] as String? ?? '').isNotEmpty ||
            w['kind'] == 'tool' &&
                ['npm', 'pipx', 'uv'].contains(w['tool']) &&
                (w['spec'] as String? ?? '').isNotEmpty ||
            w['kind'] == 'package' &&
                (w['packages'] as List? ?? []).any(
                  (p) => [
                    'pacman',
                    'apt',
                    'dnf',
                    'zypper',
                    'apk',
                    'brew',
                  ].contains(p[0]),
                ),
      );
    }

    return {
      'install': choice('install'),
      'update': agent.installed && choice('update'),
      'uninstall': agent.installed && choice('uninstall'),
      'managed_install': !agent.installed && a.facts.containsKey('installer'),
      'login':
          agent.installed &&
          (a.table('access')['logins'] as List? ?? []).isNotEmpty,
      'verify':
          agent.installed && (a.table('ask')['argv'] as List? ?? []).isNotEmpty,
      // An API key the agent reads: handed to its own command, or written to
      // its .env file.
      'key': agent.installed && keyStepOf(a) != null,
    };
  }
}

/// An agent's API-key step (its adapter's access.key): the variable, where
/// to get a key, and either its own command that reads it on stdin or the
/// .env file it reads; null when it has none.
({String variable, String url, List<String> stdin, String envFile})? keyStepOf(
  Adapter a,
) {
  final key = a.table('access')['key'];
  if (key is! Map) return null;
  final stdin = [for (final x in (key['stdin'] as List? ?? const [])) '$x'];
  final envFile = '${key['env_file'] ?? ''}';
  if (stdin.isEmpty && envFile.isEmpty) return null;
  return (
    variable: '${key['var'] ?? ''}',
    url: '${key['url'] ?? ''}',
    stdin: stdin,
    envFile: envFile,
  );
}

/// agent_readers.codex_cache_model: the listed model of Codex's models cache
/// with the lowest priority, '' when there is none.
String codexCacheModel(ScanFiles files) {
  final rows = files.json(
    '~/.codex/models_cache.json',
    limit: 4 * 1024 * 1024,
  )['models'];
  (int, String)? best;
  for (final row in rows is List ? rows.take(200) : const []) {
    if (row is Map &&
        row['visibility'] == 'list' &&
        row['slug'] is String &&
        row['priority'] is int &&
        (best == null || (row['priority'] as int) < best.$1)) {
      best = (row['priority'] as int, row['slug'] as String);
    }
  }
  return best == null ? '' : boundedText(best.$2);
}

/// agent_readers.agy_model_name: "Gemini 4 Argon (Medium)" → "gemini-4-argon".
String agyModelName(String label) {
  final name = label
      .replaceFirst(RegExp(r'\s*\([^)]*\)\s*$'), '')
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9.]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return RegExp(r'^[a-z0-9][a-z0-9.-]{0,79}$').hasMatch(name) ? name : '';
}
