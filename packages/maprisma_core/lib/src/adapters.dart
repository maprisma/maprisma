import 'dart:convert';
import 'dart:io';
import 'package:toml/toml.dart';
import 'package:path/path.dart' as p;
import 'adapter_assets.g.dart';
import 'posix_ffi.dart';

const adapterMaxBytes = 256 * 1024;

final class AdapterError extends FormatException {
  const AdapterError(super.message);
}

/// Facts only. Hook names select built-in Dart implementations, never loaded code.
final class Adapter {
  Adapter(Map<String, dynamic> facts) : facts = Map.unmodifiable(facts) {
    validate(facts);
  }

  /// An agent the desktop offers without an adapter (Python: harnesses.get() is
  /// None): no facts beyond its name, so every reader treats it as empty.
  Adapter.unknown(String command, String label)
    : facts = Map.unmodifiable({
        'command': command,
        'name': label,
        'label': label,
      });
  final Map<String, dynamic> facts;
  String get command => facts['command'] as String;
  String get name => facts['name'] as String;
  String get label => facts['label'] as String? ?? name;
  String get fullName => facts['full_name'] as String? ?? '';
  String get icon {
    final text = facts['icon'] as String? ?? '';
    if (!text.toUpperCase().startsWith('U+')) return text;
    final point = int.tryParse(text.substring(2), radix: 16);
    if (point == null || point < 0 || point > 0x10ffff) {
      throw const AdapterError('Invalid icon code point');
    }
    return String.fromCharCode(point);
  }

  Map<String, dynamic> table(String key) =>
      facts[key] as Map<String, dynamic>? ?? {};
  factory Adapter.parse(String source) {
    if (utf8.encode(source).length > adapterMaxBytes) {
      throw const AdapterError('Adapter exceeds byte limit');
    }
    try {
      return Adapter(TomlDocument.parse(source).toMap());
    } on TomlException {
      throw const AdapterError('Invalid adapter TOML');
    }
  }
  factory Adapter.load(String path, {Posix? posix}) {
    if ([
      'auth.json',
      '.credentials.json',
      'credentials.json',
    ].contains(p.basename(path))) {
      throw const AdapterError('Credential files are not adapters');
    }
    final io = posix ?? Posix();
    final fd = io.openAt(-100, path, Posix.noFollow | Posix.nonBlock);
    try {
      if (![0, io.uid].contains(io.stat(fd).uid)) {
        throw const FileSystemException('Adapter owner unavailable');
      }
      return Adapter.parse(utf8.decode(io.readDescriptor(fd, adapterMaxBytes)));
    } finally {
      io.close(fd);
    }
  }

  static bool _fits(dynamic value, String kind) => switch (kind) {
    'text' => value is String,
    'true/false' => value is bool,
    'a number' => value is int || value is BigInt,
    'a list of texts' => value is List && value.every((v) => v is String),
    'a table' => value is Map,
    'tables' => value is List && value.every((v) => v is Map),
    'a table or "hook"' => value is Map || value == 'hook',
    '"hook"' => value == 'hook',
    'a list of [manager, name]' =>
      value is List &&
          value.every(
            (v) => v is List && v.length == 2 && v.every((e) => e is String),
          ),
    _ => true,
  };
  static void _check(
    Map table,
    String schema, [
    List<String> required = const [],
  ]) {
    final allowed = adapterSchema[schema] as Map;
    for (final e in table.entries) {
      if (!allowed.containsKey(e.key) ||
          !_fits(e.value, allowed[e.key] as String)) {
        throw AdapterError('Invalid $schema.${e.key}');
      }
    }
    for (final key in required) {
      if (!table.containsKey(key)) throw AdapterError('Missing $schema.$key');
    }
  }

  static List<String> _required(String key) =>
      (adapterSchema['REQUIRED'][key] as List? ?? []).cast<String>();
  static bool configureOk(List argv, String command) =>
      argv.isNotEmpty &&
      argv.every(
        (v) =>
            v is String &&
            v.isNotEmpty &&
            !v.contains('\n') &&
            !v.contains('\x00'),
      ) &&
      argv.first == command &&
      !(adapterSchema['NOT_OWN'] as List).contains(argv.first) &&
      !(argv.first as String).contains('/');
  static void _named(dynamic key, String names, {bool empty = true}) {
    if (!(empty && key == '') &&
        !(adapterSchema[names] as Map).containsKey(key)) {
      throw AdapterError('Unknown $names');
    }
  }

  static void validate(Map<String, dynamic> data) {
    _check(data, 'TOP', _required('top'));
    final command = data['command'] as String;
    Map t(String key) => data[key] as Map? ?? {};
    void check(String key, String schema, [List<String> required = const []]) =>
        _check(t(key), schema, required);
    for (final way in data['install'] as List? ?? []) {
      _check(way as Map, 'WAY', _required('way'));
    }
    check('update', 'UPDATE');
    if (data.containsKey('ask')) {
      check('ask', 'ASK', _required('ask'));
      final argv = t('ask')['argv'] as List;
      if (argv.isEmpty ||
          argv.first != command ||
          argv.where((v) => v == '{prompt}').length != 1 ||
          argv.any(
            (v) => (v as String).contains('{prompt}') && v != '{prompt}',
          ) ||
          argv.where((v) => v == '{effort}').length > 1 ||
          argv.any(
            (v) => (v as String).contains('{effort}') && v != '{effort}',
          )) {
        throw const AdapterError('Invalid ask argv');
      }
      for (final e in (t('ask')['effort'] as Map? ?? {}).entries) {
        if (!['quick', 'normal', 'deep', 'max'].contains(e.key) ||
            !_fits(e.value, 'a list of texts') ||
            (e.value as List).isEmpty ||
            !(e.value[0] as String).startsWith('-') ||
            (e.value as List).any(
              (v) =>
                  (v as String).contains('{prompt}') || v.contains('{effort}'),
            )) {
          throw const AdapterError('Invalid effort');
        }
      }
      if ((t('ask')['games'] as List? ?? []).any((g) => g != 'chess')) {
        throw const AdapterError('Unknown game');
      }
    }
    for (final key in ['research', 'rewrite', 'task']) {
      if (!data.containsKey(key)) continue;
      check(key, key.toUpperCase(), ['argv']);
      if (![
        'text',
        'claude-json',
        'codex-jsonl',
      ].contains(t(key)['output'] ?? 'text')) {
        throw const AdapterError('Unknown output');
      }
      final placeholders = key == 'rewrite'
          ? ['{answer}']
          : key == 'task'
          ? ['{prompt}']
          : ['{prompt}', '{schema}'];
      final argv = t(key)['argv'] as List;
      if (argv.isEmpty ||
          argv.first != command ||
          argv.any(
            (v) => (v as String).contains('{') && !placeholders.contains(v),
          ) ||
          placeholders.any((p) => argv.where((v) => v == p).length > 1) ||
          key == 'task' && !argv.contains('{prompt}')) {
        throw const AdapterError('Invalid prompt argv');
      }
    }
    if (data.containsKey('advise')) {
      check('advise', 'ADVISE', ['argv', 'model']);
      final argv = t('advise')['argv'] as List,
          model = t('advise')['model'] as List;
      if (argv.isEmpty ||
          argv.first != command ||
          argv.any((v) => (v as String).contains('{')) ||
          model.isEmpty ||
          !(model.first as String).startsWith('-') ||
          model.where((v) => v == '{model}').length != 1 ||
          model.where((v) => v == '{provider}').length > 1 ||
          model.any(
            (v) =>
                (v as String).contains('{') &&
                !['{model}', '{provider}'].contains(v),
          ) ||
          !data.containsKey('closed') ||
          ![
            'text',
            'claude-json',
            'codex-jsonl',
          ].contains(t('advise')['output'] ?? 'text')) {
        throw const AdapterError('Invalid advise');
      }
    }
    if (data.containsKey('closed')) {
      check('closed', 'CLOSED');
      for (final key in ['background', 'task', 'mcp_off']) {
        final options = t('closed')[key] as List? ?? [];
        if (options.isNotEmpty && !(options.first as String).startsWith('-') ||
            options.any(
              (v) => RegExp(r'\{[a-z]+\}').hasMatch(
                (v as String).replaceAll(
                  '{name}',
                  key == 'mcp_off' ? '' : '{name}',
                ),
              ),
            )) {
          throw const AdapterError('Invalid closed options');
        }
      }
      if (!RegExp(
        r'^([A-Z_][A-Z0-9_]{0,63})?$',
      ).hasMatch(t('closed')['home_env'] as String? ?? '')) {
        throw const AdapterError('Invalid home env');
      }
      final off = t('closed')['mcp_off'] as List? ?? [];
      if (off.isNotEmpty &&
          off.fold<int>(
                0,
                (n, v) =>
                    n + RegExp(r'\{name\}').allMatches(v as String).length,
              ) !=
              1) {
        throw const AdapterError('Invalid MCP name placeholder');
      }
    }
    for (final key in ['details', 'models']) {
      if (data.containsKey(key)) {
        check(key, key.toUpperCase());
        _named(
          t(key)['reader'] ?? '',
          key == 'details' ? 'DETAIL_READERS' : 'MODEL_READERS',
        );
      }
    }
    if (data.containsKey('tools')) check('tools', 'TOOLS', ['file', 'key']);
    if (data.containsKey('replies')) {
      check('replies', 'REPLIES', ['folder', 'format']);
      final value = t('replies');
      if (![
            'claude-jsonl',
            'codex-jsonl',
            'pi-jsonl',
          ].contains(value['format']) ||
          !(value['folder'] as String).startsWith('~/') ||
          (value['depth'] ?? 1) < 0 ||
          (value['depth'] ?? 1) > 4) {
        throw const AdapterError('Invalid replies');
      }
      for (final e in (value['contexts'] as Map? ?? {}).entries) {
        if ((e.key as String).runes.length > 100 ||
            !_fits(e.value, 'a number') ||
            e.value <= 0 ||
            e.value >= 1000000000) {
          throw const AdapterError('Invalid context');
        }
      }
    }
    if (data.containsKey('subagents')) {
      check('subagents', 'SUBAGENTS', ['format', 'path']);
      if (![
            'claude-projects',
            'opencode-db',
            'codex-rollouts',
            'copilot-events',
            'goose-db',
          ].contains(t('subagents')['format']) ||
          !(t('subagents')['path'] as String).startsWith('~/')) {
        throw const AdapterError('Invalid subagents');
      }
    }
    for (final entry in data['configure'] as List? ?? []) {
      _check(entry as Map, 'CONFIGURE', _required('configure'));
      if (!configureOk(entry['argv'] as List, command)) {
        throw const AdapterError('Invalid configure');
      }
    }
    final start = data['start'] as List? ?? [];
    if (start.isNotEmpty && !configureOk([command, ...start], command)) {
      throw const AdapterError('Invalid start');
    }
    if (data.containsKey('plan_limits')) {
      check('plan_limits', 'PLAN_LIMITS', ['rpc', 'argv']);
      if (!(adapterSchema['LIMIT_RPCS'] as List).contains(
            t('plan_limits')['rpc'],
          ) ||
          !configureOk(t('plan_limits')['argv'] as List, command) ||
          !RegExp(
            r'^([A-Z_][A-Z0-9_]{0,63})?$',
          ).hasMatch(t('plan_limits')['home_env'] as String? ?? '')) {
        throw const AdapterError('Invalid plan_limits');
      }
      if (t('plan_limits').containsKey('store')) {
        final store = t('plan_limits')['store'] as Map;
        _check(store, 'STORE', ['file', 'format', 'key']);
        if (!['json', 'toml'].contains(store['format']) ||
            !(store['file'] as String).startsWith('~/')) {
          throw const AdapterError('Invalid plan_limits store');
        }
      }
    }
    check('sessions', 'SESSIONS');
    if (t('sessions').containsKey('reader')) {
      _named(t('sessions')['reader'], 'READERS', empty: false);
    }
    _named(t('update')['latest'] ?? '', 'LATEST');
    if (data.containsKey('skills')) {
      check('skills', 'SKILLS', _required('skills'));
      final listed = t('skills')['listed'];
      if (listed is Map) {
        _check(listed, 'LISTED', _required('listed'));
        if (!['json', 'toml'].contains(listed['format'])) {
          throw const AdapterError('Invalid listed format');
        }
      }
    }
    check('mcp', 'MCP');
    if (data.containsKey('local_llm')) {
      check('local_llm', 'LOCAL_LLM', ['files']);
    }
    _named(data['usage'] ?? '', 'USAGE');
    if (data.containsKey('login_status')) {
      check('login_status', 'LOGIN_STATUS', _required('login_status'));
    }
    _named(data['installer'] ?? '', 'INSTALLERS');
    if (data.containsKey('access')) {
      check('access', 'ACCESS', _required('access'));
      for (final login in t('access')['logins'] as List? ?? []) {
        _check(login as Map, 'LOGIN', _required('login'));
      }
      if (t('access').containsKey('key')) {
        _check(t('access')['key'] as Map, 'KEY', _required('key'));
      }
    }
    if (data.containsKey('security')) {
      final security = t('security');
      check(
        'security',
        'SECURITY',
        security['hook'] == true ? [] : _required('security'),
      );
      if (security['hook'] != true &&
          !['json', 'toml', 'yaml'].contains(security['format'])) {
        throw const AdapterError('Invalid security format');
      }
      for (final setting in security['settings'] as List? ?? []) {
        _check(setting as Map, 'SETTING', _required('setting'));
        if (setting.containsKey('warn')) {
          _check(setting['warn'] as Map, 'WARN', ['title', 'explain', 'fix']);
        }
        for (final choice in setting['choices'] as List) {
          _check(choice as Map, 'CHOICE', _required('choice'));
          if (choice.containsKey('value') == (choice['unset'] == true) ||
              (choice['risk'] ?? 1) < 0 ||
              (choice['risk'] ?? 1) > 3) {
            throw const AdapterError('Invalid security choice');
          }
        }
      }
      for (final rule in security['rules'] as List? ?? []) {
        _check(rule as Map, 'RULE', _required('rule'));
      }
    }
  }
}

List<Adapter> builtinAdapters() => [
  for (final source in builtinAdapterSources.values)
    Adapter.parse(source as String),
];
