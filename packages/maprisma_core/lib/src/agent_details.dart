import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
    'limits': limits,
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

/// desktop_omarchy.refresh_usage: fresh usage of this agent (at most a
/// minute); true when it worked. On Omarchy its omarchy-agent-usage-update
/// writes the record; elsewhere the collector is run here and what it prints,
/// one JSON object, becomes the record. Maprisma reads no credentials: the
/// collector, Omarchy's own tool, does what it does on Omarchy.
Future<bool> refreshUsage(String command, Map<String, String> env) async {
  final collector = usageCollector(command, env);
  if (collector == null) return false;
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
    final runtime = local ? ports[uri.hasPort ? uri.port : null] ?? '' : '';
    return {
      'name': boundedText(name, 40),
      'local': local,
      'runtime': runtime,
      'models': models,
      'active': active,
    };
  }

  int modelCount(dynamic models) => models is Map
      ? models.length.clamp(0, 9999)
      : models is List
      ? models.length.clamp(0, 9999)
      : 0;
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
      case 'lmstudio-app':
        info.providers.add(provider('LM Studio', 'http://127.0.0.1:1234/v1'));
    }
    if (info.model.isEmpty && ['claude', 'codex'].contains(reader)) {
      final session = SessionReaders(files);
      final paths = session.matching(
        reader == 'claude' ? '~/.claude/projects' : '~/.codex/sessions',
        reader == 'claude' ? '*/*.jsonl' : '*/*/*/rollout-*.jsonl',
      );
      if (paths.isNotEmpty) {
        final source = files.text(paths.first, limit: 64 * 1024 * 1024) ?? '';
        final expression = reader == 'claude'
            ? RegExp(r'"model"\s*:\s*"(claude-[A-Za-z0-9._-]{1,80})"')
            : RegExp(
                r'"type"\s*:\s*"turn_context".*?"model"\s*:\s*"([A-Za-z0-9._:-]{1,80})"',
              );
        final found = expression.allMatches(source).toList();
        if (found.isNotEmpty) info.model = found.last[1]!;
      }
    }
    final usage = usageRecord(adapter.command);
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
  bool usageIsStale(String command, List<String> accessFiles, {DateTime? now}) {
    if (!hasUsageCollector(command)) return false;
    final record =
        '${files.identity.root('XDG_STATE_HOME', '.local/state')}/omarchy/agents/usage/$command.json';
    if (FileSystemEntity.typeSync(record) == FileSystemEntityType.notFound) {
      return true;
    }
    final written = File(record).statSync().modified;
    if ((now ?? DateTime.now()).difference(written).inMilliseconds >
        usageMaxAge * 1000) {
      return true;
    }
    for (final name in accessFiles) {
      final path = '${files.identity.home}/$name';
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

  Map<String, dynamic> usageRecord(String command) {
    if (!RegExp(r'^[a-z0-9-]{1,64}$').hasMatch(command)) return {};
    final path = desktop.name == 'omarchy' || hasUsageCollector(command)
        ? '${files.identity.root('XDG_STATE_HOME', '.local/state')}/omarchy/agents/usage/$command.json'
        : '~/.local/state/maprisma/no-usage/$command.json';
    return Map<String, dynamic>.from(files.json(path));
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
