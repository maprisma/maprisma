import 'action_rules.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'identity.dart';
import 'posix_ffi.dart';
import 'core_assets.g.dart';
import 'settings_json.dart';

const uiSettings = {
  'flutter_theme_mode',
  'map_light_fps',
  'flutter_map_layout',
  'map_animations',
  'language',
  'look',
  'agent_folder',
  'map_layers',
  'system_map_columns',
  'subagents_minutes',
  'subagents_kept',
  'addons_online',
  'map_scan_interval',
  'map_scan_pause_unfocused',
  'map_scan_targets',
  'providers_with_agents',
  'ai_checks_agent',
  'warn_notify',
  'cost_currency',
  'cost_limit',
  'warn_yellow',
  'warn_red',
  'terminal_tabs',
  'screenshot_key',
  'screenshot_folder',
  'smart_helper',
  'dictation',
  'dictation_engine',
  'action_rules',
  'action_rule_hints',
  'usage_box',
  'usage_box_items',
  'usage_box_size',
  'ai_local_helper',
  'ai_checks',
  'window_mode',
  'corners',
};
const languages = {'en', 'de', 'fr', 'es', 'it', 'pt', 'nl', 'pl'};
const mapLayers = ['agents', 'online', 'local', 'models', 'mcp', 'skills'];
const systemMapColumns = ['pc', 'disks', 'programs', 'tools', 'folders'];
const settingsMaxBytes = 256 * 1024;
bool texts(dynamic v) => v is List && v.every((e) => e is String);
bool subset(dynamic v, List<String> choices) =>
    texts(v) && (v as List).every(choices.contains);

/// `#rrggbb`, or one of the theme's colours.
bool mapColorValue(dynamic v) =>
    v is String &&
    (RegExp(r'^#[0-9a-f]{6}$').hasMatch(v) ||
        RegExp(r'^theme:(primary|secondary|tertiary|outline)$').hasMatch(v));

bool validLayout(dynamic v) {
  if (v is! Map ||
      v.keys.any(
        (k) => ![
          'cards',
          'order',
          'collapsed',
          'pins',
          'card_order',
          'column_widths',
          'column_defaults',
          'card_border',
          'used_only',
          'line_colors',
        ].contains(k),
      )) {
    return false;
  }
  bool ident(dynamic s) =>
      s is String &&
      s.isNotEmpty &&
      s.runes.length <= 8192 &&
      !s.runes.any((r) => r < 32);
  bool ids(dynamic a, int limit) =>
      a is List &&
      a.length <= limit &&
      a.every(ident) &&
      a.toSet().length == a.length;
  for (final key in ['collapsed', 'pins', 'card_order', 'used_only']) {
    if (v.containsKey(key) && !ids(v[key], 100)) return false;
  }
  final border = v.containsKey('card_border')
      ? v['card_border']
      : <String, dynamic>{};
  if (border is! Map ||
      border.keys.any((k) => !['on', 'width', 'color'].contains(k)) ||
      border['on'] is! bool && border.containsKey('on') ||
      border.containsKey('width') &&
          (border['width'] is! int ||
              border['width'] < 1 ||
              border['width'] > 8) ||
      border.containsKey('color') && !mapColorValue(border['color'])) {
    return false;
  }
  final lines = v.containsKey('line_colors')
      ? v['line_colors']
      : <String, dynamic>{};
  if (lines is! Map ||
      lines.entries.any(
        (e) =>
            !['provider', 'model', 'serves', 'mcp', 'skills'].contains(e.key) ||
            !mapColorValue(e.value),
      )) {
    return false;
  }
  for (final key in ['column_widths', 'column_defaults']) {
    final widths = v.containsKey(key) ? v[key] : <String, dynamic>{};
    if (widths is! Map ||
        widths.entries.any(
          (e) =>
              !['mcp', 'agents', 'providers', 'models'].contains(e.key) ||
              e.value is! num ||
              !(e.value as num).isFinite ||
              e.value < 200 ||
              e.value > 900,
        )) {
      return false;
    }
  }
  for (final key in ['cards', 'order']) {
    final mapping = v[key] ?? <String, dynamic>{};
    if (v.containsKey(key) && v[key] == null ||
        mapping is! Map ||
        mapping.length > 100) {
      return false;
    }
    for (final entry in mapping.entries) {
      if (!ident(entry.key)) return false;
      final data = entry.value;
      if (key == 'order') {
        if (!ids(data, 600)) return false;
      } else if (data is! List ||
          data.length != 2 ||
          !data.every((n) => n is num && n.isFinite && n >= 0 && n <= 30000)) {
        return false;
      }
    }
  }
  // Python's ensure_ascii=True representation counts UTF-16 escapes and spaces.
  return pythonJson(v, ascii: true).length <= 128 * 1024;
}

String pythonJson(dynamic value, {bool ascii = false, bool pretty = false}) {
  String encode(dynamic v, int depth) {
    if (v is Map || v is List) {
      final entries = v is Map
          ? v.entries
                .map(
                  (e) =>
                      '${encode(e.key, depth + 1)}: ${encode(e.value, depth + 1)}',
                )
                .toList()
          : (v as List).map((e) => encode(e, depth + 1)).toList();
      final open = v is Map ? '{' : '[', close = v is Map ? '}' : ']';
      if (entries.isEmpty) return '$open$close';
      if (!pretty) return '$open${entries.join(', ')}$close';
      return '$open\n${'  ' * (depth + 1)}${entries.join(',\n${'  ' * (depth + 1)}')}\n${'  ' * depth}$close';
    }
    if (v is BigInt) return v.toString();
    if (v is double && v.isFinite && v != 0) {
      final parts = v.toStringAsExponential().split('e');
      final exponent = int.parse(parts[1]);
      if (exponent < -4 || exponent >= 16) {
        return '${parts[0]}e${exponent < 0 ? '-' : '+'}${exponent.abs().toString().padLeft(2, '0')}';
      }
    }
    var text = jsonEncode(v);
    if (v is String) {
      // Dart escapes these JavaScript separators; Python JSON does not.
      text = text
          .replaceAll(r'\u2028', '\u2028')
          .replaceAll(r'\u2029', '\u2029');
      if (ascii) {
        final out = StringBuffer();
        for (final c in text.codeUnits) {
          out.write(
            c >= 127
                ? '\\u${c.toRadixString(16).padLeft(4, '0')}'
                : String.fromCharCode(c),
          );
        }
        text = out.toString();
      }
    }
    return text;
  }

  return encode(value, 0);
}

final class SettingsStore {
  SettingsStore(this.identity, {Posix? posix}) : posix = posix ?? Posix();
  final AppIdentity identity;
  final Posix posix;
  Map<String, dynamic> load() {
    try {
      final data = decodeSettings(
        utf8.decode(posix.readRegular(identity.settingsPath, settingsMaxBytes)),
      );
      return data is Map<String, dynamic> ? data : {};
    } on FileSystemException {
      return {};
    } on FormatException {
      return {};
    }
  }

  bool valid(String key, dynamic v) {
    switch (key) {
      case 'flutter_theme_mode':
        return ['system', 'light', 'dark'].contains(v);
      case 'map_light_fps':
        return v is int && [20, 30, 60].contains(v);
      case 'flutter_map_layout':
        return validLayout(v);
      case 'action_rules':
        return validActionRules(v);
      case 'look':
        return ['omarchy', 'adwaita'].contains(v);
      case 'window_mode':
        return ['auto', 'popup', 'window'].contains(v);
      case 'dictation_engine':
        return ['auto', 'omarchy', 'whisper', 'local', 'online'].contains(v);
      case 'map_animations':
        return ['all', 'agents', 'off'].contains(v);
      case 'choice_text':
        return ['bright', 'dim'].contains(v);
      case 'window_size':
        return v is List &&
            v.length == 2 &&
            v.every((e) => e is int && e > 0 || e == true);
      case 'map_scan_interval':
        return v is int && [0, 6, 15, 30, 60, 120, 300].contains(v);
      case 'map_scan_targets':
        return subset(v, ['activity', 'agents', 'inventory']);
      case 'system_map_columns':
        return subset(v, systemMapColumns);
      case 'usage_box_items':
        return subset(v, ['rate', 'context', 'used']);
      case 'usage_box_size':
        return [7, 8, 9, 10, 12].contains(v);
      case 'subagents_minutes':
        return [10, 30, 60, 120].contains(v);
      case 'subagents_kept':
        return [5, 10, 20, 40].contains(v);
      case 'cost_currency':
        return ['usd', 'eur'].contains(v);
      case 'cost_limit':
        return [10, 25, 50, 100, 200, 500].contains(v);
      case 'warn_yellow':
        return [50, 60, 70, 75, 80, 85].contains(v);
      case 'warn_red':
        return [80, 85, 90, 95, 100].contains(v);
      case 'model_advice_count':
      case 'mcp_advice_count':
        return [5, 10, 15, 20].contains(v);
      case 'map_zoom':
        return v is num;
      case 'agent_projects':
        return v is Map && v.values.every((e) => e is String);
      case 'agent_project_history':
        return v is Map && v.values.every(texts);
    }
    final fallback = defaults[key];
    if (fallback is bool) return v is bool;
    if (fallback is String ||
        [
          'agent_folder',
          'models_root',
          'screenshot_folder',
          'smart_helper',
        ].contains(key)) {
      return v is String;
    }
    if (fallback is List) return texts(v);
    if (fallback is Map) return v is Map;
    return false;
  }

  dynamic value(Map saved, String key) =>
      saved[key] != null && valid(key, saved[key])
      ? saved[key]
      : jsonDecode(jsonEncode(defaults[key]));
  Map<String, dynamic> snapshot() {
    final saved = load();
    return {for (final k in uiSettings) k: value(saved, k)};
  }

  Map<String, dynamic> update(Map params) {
    if (params.length != 1 || params['values'] is! Map) {
      throw const FormatException('Invalid settings');
    }
    final values = Map<String, dynamic>.from(params['values']);
    if (values.isEmpty || values.keys.any((k) => !uiSettings.contains(k))) {
      throw const FormatException('Unknown settings');
    }
    for (final entry in values.entries) {
      if ((entry.value != null ||
              [
                'flutter_theme_mode',
                'map_light_fps',
                'flutter_map_layout',
                'map_animations',
              ].contains(entry.key)) &&
          !valid(entry.key, entry.value)) {
        throw const FormatException('Invalid value');
      }
    }
    if (values.containsKey('language') &&
        !{'auto', ...languages}.contains(values['language'])) {
      throw const FormatException('Unknown language');
    }
    if (values.containsKey('map_layers') &&
        !subset(values['map_layers'], mapLayers)) {
      throw const FormatException('Unknown map layer');
    }
    if (values.containsKey('system_map_columns') &&
        !subset(values['system_map_columns'], systemMapColumns)) {
      throw const FormatException('Unknown system map column');
    }
    if (values['agent_folder'] != null) {
      var folder = values['agent_folder'] as String;
      if (folder == '~') folder = identity.home;
      if (folder.startsWith('~/')) {
        folder = p.join(identity.home, folder.substring(2));
      }
      if (!p.isAbsolute(folder) ||
          folder.contains('\x00') ||
          !Directory(folder).existsSync()) {
        throw const FormatException('Folder unavailable');
      }
      values['agent_folder'] = Directory(folder).resolveSymbolicLinksSync();
    }
    _saveChanges(values);
    return snapshot();
  }

  /// ai_core.update_settings for the service's own values (project history
  /// and pins), each still checked.
  void saveOwn(Map<String, dynamic> values) {
    for (final e in values.entries) {
      if (e.value != null && !valid(e.key, e.value)) {
        throw const FormatException('Invalid value');
      }
    }
    _saveChanges(values);
  }

  void migrate() {
    final saved = load();
    final changes = <String, dynamic>{};
    if (saved.containsKey('animate_lines')) {
      if (!saved.containsKey('map_animations')) {
        changes['map_animations'] = saved['animate_lines'] == false
            ? 'off'
            : 'all';
      }
      changes['animate_lines'] = null;
    }
    for (final key in retiredSettings) {
      if (saved.containsKey(key)) changes[key as String] = null;
    }
    if (changes.isNotEmpty) _saveChanges(changes);
  }

  /// One writer at a time (the app's core, another build of the app, a
  /// worker): an exclusive flock on settings.json.lock beside the settings
  /// around read, change and write, so no save undoes another's. The lock
  /// file is this account's own regular file, never a link.
  T _locked<T>(T Function() body) {
    // Missing folders are made 0700, as the atomic write makes them.
    final missing = <String>[];
    for (
      var folder = p.dirname(identity.settingsPath);
      !Directory(folder).existsSync();
      folder = p.dirname(folder)
    ) {
      missing.add(folder);
    }
    for (final folder in missing.reversed) {
      try {
        Directory(folder).createSync();
        posix.chmodPath(folder, 0x1c0);
      } on FileSystemException {
        // made by another writer meanwhile
      }
    }
    final fd = posix.openAt(
      -100,
      '${identity.settingsPath}.lock',
      0x2 | 0x40 | Posix.noFollow | Posix.cloexec,
      0x180,
    );
    try {
      final info = posix.statFull(fd);
      if (info.mode & 0xf000 != 0x8000 || info.uid != posix.uid) {
        throw const FileSystemException('Untrusted settings lock');
      }
      posix.lockExclusive(fd);
      return body();
    } finally {
      posix.close(fd);
    }
  }

  void _saveChanges(Map<String, dynamic> values) =>
      _locked(() => _saveLocked(values));

  void _saveLocked(Map<String, dynamic> values) {
    final saved = load();
    for (final e in values.entries) {
      if (e.value == null) {
        saved.remove(e.key);
      } else {
        saved[e.key] = e.value;
      }
    }
    final history = saved['agent_project_history'];
    if (history is Map) {
      saved['agent_project_history'] = {
        for (final e in history.entries)
          if (e.value is List) e.key: (e.value as List).take(50).toList(),
      };
    }
    final bytes = utf8.encode('${pythonJson(saved, pretty: true)}\n');
    if (bytes.length > settingsMaxBytes) {
      throw const FileSystemException('Settings exceed limit');
    }
    posix.atomicWrite(identity.settingsPath, bytes);
  }
}
