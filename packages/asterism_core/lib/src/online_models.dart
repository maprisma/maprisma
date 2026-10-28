import 'dart:convert';
import 'package:path/path.dart' as p;
import 'adapter_assets.g.dart';
import 'adapters.dart';
import 'connect_apply.dart';
import 'dsh_profile.dart';
import 'llm_plans.dart' show hermesModelText;
import 'local_llm.dart';
import 'protocol.dart';
import 'py_values.dart';
import 'scan_files.dart';

/// online_models: the online models an agent can be switched to on the map,
/// and the switch as a plan (backup, Undo). Only the switchers of the
/// built-in adapters; an add-on's hooks stay with the reference (phase 5).
final class OnlineModels {
  OnlineModels(this.files, this.config, this.home, this.ownFolder);
  final ScanFiles files;
  final ConfigFiles config;
  final String home;
  final String? Function(String command) ownFolder;

  static const maxChoices = 12;
  static final name = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$');
  static final qualified = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}/[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,159}$',
  );
  static const _hooks = {'pi', 'dsh', 'hermes', 'opencode'};

  static (String, String) split(String choice) {
    if (qualified.hasMatch(choice)) {
      final at = choice.indexOf('/');
      return (choice.substring(0, at), choice.substring(at + 1));
    }
    return ('', choice);
  }

  static bool valid(String choice) =>
      name.hasMatch(choice) || qualified.hasMatch(choice);

  String _path(String relative) => p.join(home, relative);

  /// graph.provider_name.
  static String providerName(String raw) =>
      (providerFacts['names'] as Map?)?[raw.trim().toLowerCase()] as String? ??
      raw.trim();

  bool supported(Adapter adapter) {
    final models = adapter.table('models');
    if (models.isEmpty) return false;
    final reader = models['reader'];
    if (reader == 'claude' || reader == 'codex') return true;
    if (models['hook'] == true && _hooks.contains(adapter.command)) return true;
    throw ServiceError('unported_route'); // an add-on's own switcher
  }

  /// connect._json: "" is {}, anything but an object fails.
  static Map _json(String text) {
    if (text.trim().isEmpty) return {};
    final data = jsonDecode(text);
    if (data is! Map) throw const FormatException('not a JSON object');
    return data;
  }

  /// agent_details._read: this account's regular file, not a link; "" else.
  String _agentRead(String path, {int limit = 4 * 1024 * 1024}) =>
      files.text(path, limit: limit) ?? '';

  List _raw(Adapter adapter, String current) {
    final reader = adapter.table('models')['reader'];
    if (reader == 'claude') return ['fable', 'opus', 'sonnet'];
    if (reader == 'codex') {
      final text = _agentRead(_path('.codex/models_cache.json'));
      dynamic data;
      try {
        data = text.isEmpty ? {} : jsonDecode(text);
      } on FormatException {
        return [];
      }
      final rows = data is Map ? data['models'] : null;
      return [
        for (final r in rows is List ? rows : const [])
          if (r is Map &&
              r['visibility'] == 'list' &&
              r['slug'] is String &&
              name.hasMatch(r['slug'] as String))
            r['slug'],
      ].take(maxChoices).toList();
    }
    final found = <String>[];
    switch (adapter.command) {
      case 'pi':
        final data = _json(config.read(_path('.pi/agent/models.json')));
        final providers = pyTruthy(data['providers']) ? data['providers'] : {};
        for (final e in (providers as Map).entries) {
          final rows = e.value is Map ? (e.value as Map)['models'] : null;
          for (final row in rows is List ? rows : const []) {
            if (row is Map && row['id'] is String) {
              found.add('${e.key}/${row['id']}');
            }
          }
        }
      case 'opencode':
        final data = _json(
          config.read(_path('.config/opencode/opencode.json')),
        );
        final providers = pyTruthy(data['provider']) ? data['provider'] : {};
        for (final e in (providers as Map).entries) {
          final models = e.value is Map ? (e.value as Map)['models'] : null;
          final names = !pyTruthy(models)
              ? const []
              : models is Map
              ? models.keys.toList()
              : models is List
              ? models
              : throw const FormatException('not iterable');
          for (final n in names) {
            if (n is String) found.add('${e.key}/$n');
          }
        }
      case 'hermes':
        final text = config.read(_path('.hermes/config.yaml'));
        final body = LocalLlm.topBlock(text, 'providers');
        if (body == null) return [];
        for (final entry in RegExp(
          r'^  (\S+):[ \t]*\n((?:(?:    |\t\t).*\n?|\s*\n)*)',
          multiLine: true,
        ).allMatches(body)) {
          final models = RegExp(
            r'^    models:[ \t]*\n((?:(?:      ).*\n?|\s*\n)*)',
            multiLine: true,
          ).firstMatch(entry[2]!);
          if (models == null) continue;
          for (final n in RegExp(
            r'^      ([^\s#][^\n#]*?):(?=[ \t]|$)',
            multiLine: true,
          ).allMatches(models[1]!)) {
            found.add('${entry[1]}/${n[1]}');
          }
        }
      case 'dsh':
        final String text;
        try {
          text = config.read(_path('.dsh/profiles/web/cordis.patch.yml'));
        } on FormatException {
          return [];
        }
        for (final e in dshProviders(text).entries) {
          final rows = e.value is Map ? (e.value as Map)['models'] : null;
          for (final row in rows is List ? rows : const []) {
            if (row is Map && row['id'] is String) {
              found.add('${e.key}/${row['id']}');
            }
          }
        }
        final folder = ownFolder('dsh');
        if (folder != null) {
          final packages = '$folder/current/node_modules/@deepseek-ai';
          found.addAll(
            dshBuiltinChoices(
              files.text(
                    '$packages/dsh-base/cordis.patch.yml',
                    limit: 2 << 20,
                  ) ??
                  '',
              files.text(
                    '$packages/dsh-llm-deepseek/lib/index.js',
                    limit: 2 << 20,
                  ) ??
                  '',
            ),
          );
        }
    }
    return found;
  }

  /// online_models.choices: the one in use first when it is not listed.
  List<String> choices(Adapter adapter, [String current = '']) {
    if (!supported(adapter)) return [];
    List raw;
    try {
      raw = _raw(adapter, current).take(maxChoices * 4).toList();
    } on ServiceError {
      rethrow;
    } catch (_) {
      raw = const []; // its settings unreadable or malformed: no choices
    }
    final found = [
      for (final c in raw)
        if (c is String && valid(c)) c,
    ];
    if (current.isNotEmpty && !found.contains(current) && valid(current)) {
      found.insert(0, current);
    }
    return found;
  }

  /// online_models.target: the agent's own choice for `model` of the online
  /// service the map shows as `service`; null when it has none.
  String? target(Adapter adapter, String service, String model) {
    final found = choices(adapter);
    for (final choice in found) {
      final (provider, n) = split(choice);
      if (provider.isNotEmpty &&
          n == model &&
          providerName(provider).toLowerCase() == service.toLowerCase()) {
        return choice;
      }
    }
    return found.contains(model) && !found.any((c) => split(c).$1.isNotEmpty)
        ? model
        : null;
  }

  static String codexText(String text, String model) {
    final line = 'model = "$model"';
    final first = RegExp(r'^\s*\[', multiLine: true).firstMatch(text);
    var head = first != null ? text.substring(0, first.start) : text;
    final tail = first != null ? text.substring(first.start) : '';
    final setting = RegExp(r'^model\s*=.*$', multiLine: true);
    head = setting.hasMatch(head)
        ? head.replaceFirst(setting, line)
        : '$line\n$head';
    return head + tail;
  }

  static String _dump(Map data) =>
      '${pyJsonDumps(data, indent: 2, ensureAscii: false)}\n';

  /// online_models.plan: the change that makes `model` the agent's model.
  Plan plan(Adapter adapter, String model) {
    if (!supported(adapter) || !valid(model)) throw FormatException(model);
    if (qualified.hasMatch(model) && !choices(adapter).contains(model)) {
      throw FormatException("$model is not one of the agent's own choices");
    }
    final reader = adapter.table('models')['reader'];
    final String path, old, next, provider;
    if (reader == 'claude') {
      path = _path('.claude/settings.json');
      old = config.read(path);
      final data = old.isNotEmpty ? _json(old) : {};
      data['model'] = model;
      (next, provider) = (_dump(data), 'anthropic');
    } else if (reader == 'codex') {
      path = _path('.codex/config.toml');
      old = config.read(path);
      (next, provider) = (codexText(old, model), 'openai');
    } else {
      final (owner, n) = split(model);
      switch (adapter.command) {
        case 'pi':
          path = _path('.pi/agent/settings.json');
          old = config.read(path);
          final settings = _json(old);
          settings['defaultProvider'] = owner;
          settings['defaultModel'] = n;
          next = _dump(settings);
        case 'opencode':
          path = _path('.config/opencode/opencode.json');
          old = config.read(path);
          final data = _json(old)..['model'] = model;
          next = _dump(data);
        case 'hermes':
          path = _path('.hermes/config.yaml');
          old = config.read(path);
          next = hermesModelText(old, owner, n);
        default:
          path = _path('.dsh/profiles/web/cordis.patch.yml');
          old = config.read(path);
          next = dshModelText(old, owner, n);
      }
      provider = owner;
    }
    final result = Plan(adapter.command, 'online', provider);
    if (next != old) result.changes.add(Change(path, old, next));
    return result;
  }
}
