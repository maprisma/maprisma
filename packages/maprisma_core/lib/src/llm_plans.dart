import 'dart:convert';
import 'package:path/path.dart' as p;
import 'agent_catalog.dart';
import 'connect_apply.dart';
import 'context.dart';
import 'dsh_profile.dart';
import 'inventory.dart' show chatModels;
import 'local_llm.dart';
import 'provider_scans.dart' show RuntimeRecord;
import 'py_values.dart';
import 'provider_facts.dart';

/// Python connect.plan for a local LLM and the agents' local_llm_transform
/// hooks (Hermes, Oh My Pi, Pi, OpenCode, OpenClaw, DeepSeek Harness): the
/// provider written into the agent's own settings, or taken out again.
String _block(String text, String key) => LocalLlm.topBlock(text, key) ?? '';
int _start(String text, String key) =>
    RegExp(
      '^${RegExp.escape(key)}:.*\\n?',
      multiLine: true,
    ).firstMatch(text)?.start ??
    -1;

Map _json(String text) {
  if (text.trim().isEmpty) return <String, dynamic>{};
  final data = jsonDecode(text);
  if (data is! Map) throw const FormatException('not a JSON object');
  return data;
}

String _dump(Map data) =>
    '${pyJsonDumps(data, indent: 2, ensureAscii: false)}\n';

/// (head, rest) like str.partition('\n').
(String, String) _partition(String body) {
  final cut = body.indexOf('\n');
  return cut < 0
      ? (body, '')
      : (body.substring(0, cut), body.substring(cut + 1));
}

String _entryRemoved(String rest, String provider) => rest.replaceAll(
  RegExp(
    '^  ${RegExp.escape(provider)}:.*\\n(?:(?:    |\\t\\t).*\\n?|\\s*\\n)*',
    multiLine: true,
  ),
  '',
);

String _trimEnd(String s) => s.replaceFirst(RegExp(r'\n+$'), '');

/// The providers-block edit Hermes and Oh My Pi share.
String _providersBlock(
  String text,
  String entryText,
  String provider,
  bool remove,
) {
  final start = _start(text, 'providers');
  if (start < 0) {
    if (remove) return text;
    return '$text${text.endsWith('\n') || text.isEmpty ? '' : '\n'}providers:\n$entryText';
  }
  final body = _block(text, 'providers'), end = start + body.length;
  var (header, rest) = _partition(body);
  rest = _entryRemoved(rest, provider);
  if (!remove) {
    rest = _trimEnd(rest) + (rest.trim().isNotEmpty ? '\n' : '') + entryText;
  }
  if (header.trim() == 'providers: {}' || header.trim() == 'providers:{}') {
    header = 'providers:';
  }
  final newBody = rest.trim().isNotEmpty
      ? '$header\n$rest'
      : (remove ? '' : '$header\n');
  return text.substring(0, start) + newBody + text.substring(end);
}

String hermesLlmText(
  String text,
  String provider,
  String label,
  String url,
  List<String> models,
  Map context,
  String model,
  bool useNow,
  bool remove,
) {
  final entry = [
    '  $provider:',
    '    name: $label',
    '    api: $url',
    '    api_key: local', //
    '    default_model: $model', '    discover_models: false', '    models:',
  ];
  for (final name in models) {
    if (pyTruthy(context[name])) {
      entry.addAll([
        '      $name:',
        '        context_length: ${context[name]}',
      ]);
    } else {
      entry.add('      $name: {}');
    }
  }
  text = _providersBlock(text, '${entry.join('\n')}\n', provider, remove);
  if (remove) text = _hermesModelOff(text, provider);
  if (useNow && !remove) text = hermesModelText(text, provider, model);
  return text;
}

String hermesModelText(String text, String provider, String model) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$').hasMatch(provider) ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,159}$').hasMatch(model)) {
    throw const FormatException('bad provider or model');
  }
  final lines = [
    '  default: ${pyJsonDumps(model)}',
    '  provider: ${pyJsonDumps(provider)}',
    "  base_url: ''",
  ];
  final start = _start(text, 'model');
  if (start < 0) return 'model:\n${lines.join('\n')}\n$text';
  var body = _block(text, 'model');
  final end = start + body.length;
  final header = body.split('\n').first;
  if (header.replaceFirst(RegExp(r'#.*$'), '').trim() != 'model:') {
    throw const FormatException(
      "Hermes's model setting is written inline in config.yaml; change it in Hermes",
    );
  }
  final children = [
    for (final l in body.split('\n').skip(1))
      if (l.trim().isNotEmpty && !l.trimLeft().startsWith('#'))
        l.length - l.replaceFirst(RegExp(r'^ +'), '').length,
  ];
  if (children.any((i) => i != 2) || body.contains('\t')) {
    throw const FormatException(
      "Hermes's model setting in config.yaml is indented in a way the app does not edit; change it in Hermes",
    );
  }
  for (final line in lines) {
    final key = line.split(':').first.trim();
    final pattern = RegExp('^  $key:.*\$', multiLine: true);
    if (RegExp('^  $key:', multiLine: true).hasMatch(body)) {
      body = body.replaceFirst(pattern, line);
    } else {
      body = '${_trimEnd(body)}\n$line\n';
    }
  }
  return text.substring(0, start) + body + text.substring(end);
}

(String, String)? _hermesFirstProvider(String text) {
  if (_start(text, 'providers') < 0) return null;
  final body = _block(text, 'providers');
  for (final found in RegExp(
    r'^  (\S+):[ \t]*\n((?:(?:    |\t\t).*\n?|\s*\n)*)',
    multiLine: true,
  ).allMatches(body)) {
    final d = RegExp(
      r'^    default_model:\s*(\S.*?)\s*$',
      multiLine: true,
    ).firstMatch(found[2]!);
    if (d != null) return (found[1]!, d[1]!);
  }
  return null;
}

String _hermesModelOff(String text, String provider) {
  final start = _start(text, 'model');
  if (start < 0) return text;
  var body = _block(text, 'model');
  final end = start + body.length;
  if (!RegExp(
    '^  provider:\\s*["\']?${RegExp.escape(provider)}["\']?\\s*\$',
    multiLine: true,
  ).hasMatch(body)) {
    return text;
  }
  final following = _hermesFirstProvider(text);
  if (following != null) {
    body = body
        .replaceFirst(
          RegExp(r'^  default:.*$', multiLine: true),
          '  default: ${following.$2}',
        )
        .replaceFirst(
          RegExp(r'^  provider:.*$', multiLine: true),
          '  provider: ${following.$1}',
        );
  } else {
    body = body.replaceAll(
      RegExp(r'^  (?:default|provider):.*\n?', multiLine: true),
      '',
    );
  }
  return text.substring(0, start) + body + text.substring(end);
}

String _quoted(String value) => pyJsonDumps(value, ensureAscii: false);

String ompModelsText(
  String text,
  String provider,
  String url,
  List<String> models,
  Map context,
  bool remove,
) {
  final entry = [
    '  $provider:',
    '    auth: none',
    '    baseUrl: ${_quoted(url)}',
    '    api: openai-completions',
    '    models:',
  ];
  for (final name in models) {
    entry.addAll([
      '      - id: ${_quoted(name)}',
      '        name: ${_quoted(name)}',
    ]);
    if (pyTruthy(context[name])) {
      entry.add('        contextWindow: ${(context[name] as num).toInt()}');
    }
  }
  if (models.isEmpty) entry[entry.length - 1] = '    models: []';
  return _providersBlock(text, '${entry.join('\n')}\n', provider, remove);
}

String? _ompRole(String text) {
  if (_start(text, 'modelRoles') < 0) return null;
  final found = RegExp(
    r'^  default:\s*(.*?)\s*$',
    multiLine: true,
  ).firstMatch(_block(text, 'modelRoles'));
  return found?[1]!.replaceAll(RegExp('''^['"]+|['"]+\$'''), '');
}

String ompConfigText(
  String text,
  String provider,
  String model,
  bool useNow,
  bool remove,
) {
  final start = _start(text, 'modelRoles');
  if (remove) {
    final value = _ompRole(text);
    if (start < 0 || value == null || !value.startsWith('$provider/')) {
      return text;
    }
    final body = _block(text, 'modelRoles'), end = start + body.length;
    var (header, rest) = _partition(body);
    rest = rest.replaceFirst(RegExp(r'^  default:.*\n?', multiLine: true), '');
    final newBody = rest.trim().isNotEmpty ? '$header\n$rest' : '';
    return text.substring(0, start) + newBody + text.substring(end);
  }
  if (!useNow || model.isEmpty) return text;
  final line = '  default: ${_quoted('$provider/$model')}';
  if (start < 0) {
    return '$text${text.endsWith('\n') || text.isEmpty ? '' : '\n'}modelRoles:\n$line\n';
  }
  final body = _block(text, 'modelRoles'), end = start + body.length;
  var (header, rest) = _partition(body);
  if (header.trim() == 'modelRoles: {}' || header.trim() == 'modelRoles:{}') {
    header = 'modelRoles:';
  }
  if (RegExp(r'^  default:', multiLine: true).hasMatch(rest)) {
    rest = rest.replaceFirst(RegExp(r'^  default:.*$', multiLine: true), line);
  } else {
    rest = '$line\n$rest';
  }
  return '${text.substring(0, start)}$header\n$rest${text.substring(end)}';
}

(String, String) piLlmTexts(
  String modelsText,
  String settingsText,
  String provider,
  String url,
  List<String> models,
  Map context,
  String model,
  bool useNow,
  bool remove,
) {
  final data = _json(modelsText);
  final providers = data.putIfAbsent('providers', () => <String, dynamic>{});
  if (providers is! Map) {
    throw const FormatException('providers is not an object');
  }
  if (remove) {
    providers.remove(provider);
  } else {
    final current = providers[provider];
    final rows = pyTruthy(current) ? (current as Map)['models'] : null;
    final before = <String, Map>{
      for (final e in pyTruthy(rows) ? rows as List : const [])
        if (e is Map && e['id'] is String) e['id'] as String: e,
    };
    providers[provider] = {
      'baseUrl': url,
      'api': 'openai-completions',
      'apiKey': 'local',
      'models': [
        for (final name in models)
          {
            'id': name,
            'name': name,
            for (final e in (before[name] ?? const {}).entries)
              if (const {'input', 'reasoning', 'compat'}.contains(e.key))
                e.key: e.value,
            if (pyTruthy(context[name])) 'contextWindow': context[name],
          },
      ],
    };
  }
  final settings = _json(settingsText);
  if (remove) {
    if (settings['defaultProvider'] != provider) {
      return (_dump(data), settingsText);
    }
    settings
      ..remove('defaultProvider')
      ..remove('defaultModel');
    return (_dump(data), _dump(settings));
  }
  if (useNow) {
    settings['defaultProvider'] = provider;
    settings['defaultModel'] = model;
  }
  return (_dump(data), useNow ? _dump(settings) : settingsText);
}

String opencodeLlmText(
  String text,
  String provider,
  String label,
  String url,
  List<String> models,
  String model,
  bool useNow,
  bool remove,
) {
  final data = _json(text);
  final providers = data.putIfAbsent('provider', () => <String, dynamic>{});
  if (providers is! Map) {
    throw const FormatException('provider is not an object');
  }
  if (remove) {
    providers.remove(provider);
    if (providers.isEmpty) data.remove('provider');
    if (pyStr(data['model'] ?? '').startsWith('$provider/')) {
      data.remove('model');
    }
  } else {
    providers[provider] = {
      'npm': '@ai-sdk/openai-compatible',
      'name': label,
      'options': {'baseURL': url},
      'models': {
        for (final n in models) n: {'name': n},
      },
    };
    if (useNow) data['model'] = '$provider/$model';
  }
  return _dump(data);
}

String openclawLlmText(
  String text,
  String provider,
  String url,
  List<String> models,
  Map context,
  String model,
  bool useNow,
  bool remove,
) {
  final Map data;
  try {
    data = _json(text);
  } on FormatException {
    throw const FormatException(
      '~/.openclaw/openclaw.json is JSON5: use `openclaw configure`',
    );
  }
  final section = data.putIfAbsent('models', () => <String, dynamic>{});
  if (section is! Map) throw const FormatException('models is not an object');
  final providers = section.putIfAbsent('providers', () => <String, dynamic>{});
  if (providers is! Map) {
    throw const FormatException('models.providers is not an object');
  }
  final agents = data.putIfAbsent('agents', () => <String, dynamic>{});
  final defaults = agents is Map
      ? agents.putIfAbsent('defaults', () => <String, dynamic>{})
      : null;
  if (defaults is! Map) {
    throw const FormatException('agents.defaults is not an object');
  }
  String primary() {
    final chosen = defaults['model'];
    final value = chosen is Map ? chosen['primary'] : chosen;
    return value is String ? value : '';
  }

  if (remove) {
    providers.remove(provider);
    if (primary().startsWith('$provider/')) {
      final chosen = defaults['model'];
      if (chosen is Map) {
        chosen.remove('primary');
        if (chosen.isEmpty) defaults.remove('model');
      } else {
        defaults.remove('model');
      }
    }
  } else {
    section.putIfAbsent('mode', () => 'merge');
    final current = providers[provider];
    final rows = pyTruthy(current) ? (current as Map)['models'] : null;
    final before = <dynamic, Map>{
      for (final e in pyTruthy(rows) ? rows as List : const [])
        if (e is Map) e['id']: e,
    };
    providers[provider] = {
      'baseUrl': url,
      'apiKey': 'local',
      'api': 'openai-completions',
      'models': [
        for (final name in models)
          {
            'id': name,
            'name': name,
            for (final e in (before[name] ?? const {}).entries)
              if (e.key != 'id' && e.key != 'name') e.key: e.value,
            if (pyTruthy(context[name])) 'contextWindow': context[name],
          },
      ],
    };
    if (useNow && model.isNotEmpty) {
      final chosen = defaults['model'];
      if (chosen is Map) {
        chosen['primary'] = '$provider/$model';
      } else {
        defaults['model'] = {'primary': '$provider/$model'};
      }
    }
  }
  if (providers.isEmpty) section.remove('providers');
  if (section.keys.every((k) => k == 'mode')) data.remove('models');
  if (defaults.isEmpty) (agents as Map).remove('defaults');
  if ((agents as Map).isEmpty) data.remove('agents');
  return _dump(data);
}

final class LlmPlans {
  LlmPlans(this.config, this.catalog, this.home, [this.contexts]);
  final ContextReader? contexts;
  final ConfigFiles config;
  final AgentCatalog catalog;
  final String home;

  String expand(String path) =>
      path.startsWith('~/') ? p.join(home, path.substring(2)) : path;
  bool supported(String agent) =>
      catalog.adapter(agent)?.facts.containsKey('local_llm') ?? false;
  List<String> files(String agent) => [
    for (final f in catalog.adapter(agent)!.table('local_llm')['files'] as List)
      expand(f as String),
  ];

  static String baseUrl(String address) {
    final text = address.isEmpty ? '127.0.0.1:8080' : address;
    final at = text.lastIndexOf(':');
    var host = at < 0 ? '' : text.substring(0, at);
    final port = at < 0 ? text : text.substring(at + 1);
    if (const {'', '0.0.0.0', '::'}.contains(host)) host = '127.0.0.1';
    return 'http://$host:$port/v1';
  }

  List<String> transform(
    String agent,
    List<String> texts,
    RuntimeRecord rt,
    String model,
    bool useNow,
    bool remove,
    Map context, {
    // An entry of the agent's own name for this LLM (a Repair of Pi's
    // "workstation"): that entry, not the app's usual one.
    String? name,
  }) {
    final provider =
        name ?? (visibleProviderFacts['connect_keys'] as Map)[rt.key] as String;
    final label =
        name ??
        (visibleProviderFacts['connect_labels'] as Map)[rt.key] as String;
    final url = baseUrl(rt.address);
    final chat = chatModels(rt.models);
    final models = chat.isNotEmpty
        ? chat
        : (model.isNotEmpty ? [model] : <String>[]);
    useNow = useNow && model.isNotEmpty;
    return switch (agent) {
      'hermes' => [
        hermesLlmText(
          texts[0],
          provider,
          label,
          url,
          models,
          context,
          model,
          useNow,
          remove,
        ),
      ],
      'omp' => [
        ompModelsText(texts[0], provider, url, models, context, remove),
        ompConfigText(texts[1], provider, model, useNow, remove),
      ],
      'pi' => () {
        final (a, b) = piLlmTexts(
          texts[0],
          texts[1],
          provider,
          url,
          models,
          context,
          model,
          useNow,
          remove,
        );
        return [a, b];
      }(),
      'opencode' => [
        opencodeLlmText(
          texts[0],
          provider,
          label,
          url,
          models,
          model,
          useNow,
          remove,
        ),
      ],
      'openclaw' => [
        openclawLlmText(
          texts[0],
          provider,
          url,
          models,
          context,
          model,
          useNow,
          remove,
        ),
      ],
      'dsh' => [
        dshConnectText(
          texts[0],
          provider,
          label,
          url,
          models,
          context,
          model,
          useNow,
          remove,
        ),
      ],
      _ => throw FormatException('No local LLM writer for $agent'),
    };
  }

  /// connect.plan without the provider's own extras (those come with a
  /// chosen model; previews with one stay with the reference until then).
  Plan plan(
    String agent,
    RuntimeRecord rt,
    String model,
    bool useNow, {
    bool remove = false,
    RuntimeRecord? replaces,
    String? name,
  }) {
    if (!supported(agent)) throw FormatException(agent);
    final result = Plan(
      agent,
      rt.key,
      name ?? (visibleProviderFacts['connect_keys'] as Map)[rt.key] as String,
    );
    var context = const <String, int>{};
    final extra = <Change>[];
    if (model.isNotEmpty && !remove) {
      // What the local LLM brings along: a context for this card, in the same
      // preview, backup and Undo (a file), or set through its API (Ollama).
      if (contexts == null) {
        throw UnsupportedError('No context reader for this core');
      }
      final (more, changes, apiContexts) = contexts!.connectExtra(rt, model);
      context = more;
      extra.addAll(changes);
      result.contexts.addAll(apiContexts);
    }
    final paths = files(agent);
    final old = [for (final path in paths) config.read(path)];
    var texts = [...old];
    if (replaces != null && replaces.key != rt.key) {
      texts = transform(agent, texts, replaces, '', false, true, const {});
    }
    texts = transform(
      agent,
      texts,
      rt,
      model,
      useNow,
      remove,
      context,
      name: name,
    );
    for (var i = 0; i < paths.length; i++) {
      if (texts[i] != old[i]) {
        result.changes.add(Change(paths[i], old[i], texts[i]));
      }
    }
    result.changes.addAll(extra);
    return result;
  }
}
