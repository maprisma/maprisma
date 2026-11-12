import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The desktop's colours outside Omarchy, as every Maprisma app reads them
/// (the maprisma-layout rules; Maprisma Manager's desktop_look.dart):
/// COSMIC's theme, Plasma's kdeglobals, or Maprisma Shell's scheme.json on
/// Hyprland (written by Maprisma Theme). `{accent, background, foreground,
/// muted, selection, red, yellow, orange, green}` as `#rrggbb`; empty when
/// the desktop is none of them or nothing could be read.
Map<String, String> desktopPalette(Map<String, String> env) {
  final names = (env['XDG_CURRENT_DESKTOP'] ?? '').toUpperCase().split(':');
  final home = env['HOME'] ?? '';
  String xdg(String key, String fallback) {
    final v = env[key];
    return v != null && p.isAbsolute(v) ? v : p.join(home, fallback);
  }

  final Map<String, String?> colors;
  if (names.contains('COSMIC')) {
    colors = cosmicPalette(xdg('XDG_CONFIG_HOME', '.config'));
  } else if (names.contains('KDE')) {
    colors = kdePalette(
      _read(p.join(xdg('XDG_CONFIG_HOME', '.config'), 'kdeglobals'), 1 << 20) ??
          '',
    );
  } else if (names.contains('HYPRLAND')) {
    colors = shellPalette(
      _read(
            p.join(
              xdg('XDG_STATE_HOME', '.local/state'),
              'maprisma-shell',
              'scheme.json',
            ),
            256 * 1024,
          ) ??
          '',
    );
  } else {
    return {};
  }
  return {
    for (final e in colors.entries)
      if (e.value != null) e.key: e.value!,
  };
}

String? _read(String path, int max) {
  try {
    final f = File(path);
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file ||
        f.lengthSync() > max) {
      return null;
    }
    return utf8.decode(f.readAsBytesSync(), allowMalformed: true);
  } on FileSystemException {
    return null;
  }
}

/// Maprisma Shell's scheme.json: Material names, hex without '#'.
Map<String, String?> shellPalette(String text) {
  Object? data;
  try {
    data = jsonDecode(text);
  } on FormatException {
    return {};
  }
  final colours = data is Map ? data['colours'] : null;
  if (colours is! Map) return {};
  String? c(String key) {
    final v = colours[key];
    return v is String && RegExp(r'^#?[0-9a-fA-F]{6}$').hasMatch(v)
        ? '#${v.replaceFirst('#', '').toLowerCase()}'
        : null;
  }

  return {
    'accent': c('primary'),
    'background': c('surface') ?? c('background'),
    'foreground': c('onSurface'),
    'muted': c('outline'),
    'selection': c('surfaceContainerHighest'),
    'red': c('error') ?? c('red'),
    'yellow': c('yellow'),
    'orange': c('peach'),
    'green': c('green'),
  };
}

String? _ini(String text, String group, String key) {
  String? current, found;
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.startsWith('[') && line.endsWith(']')) {
      current = line.substring(1, line.length - 1);
    } else if (current == group) {
      final eq = line.indexOf('=');
      if (eq > 0 && line.substring(0, eq).trim() == key) {
        found = line.substring(eq + 1).trim();
      }
    }
  }
  return found;
}

String? _rgb(String? value) {
  if (value == null) return null;
  final parts = value.split(',').map((v) => int.tryParse(v.trim())).toList();
  if ((parts.length != 3 && parts.length != 4) ||
      parts.any((v) => v == null || v < 0 || v > 255)) {
    return null;
  }
  return '#${parts.take(3).map((v) => v!.toRadixString(16).padLeft(2, '0')).join()}';
}

/// Plasma's colour scheme from kdeglobals.
Map<String, String?> kdePalette(String text) {
  String? c(String group, String key) => _rgb(_ini(text, group, key));
  return {
    'accent':
        c('General', 'AccentColor') ??
        c('Colors:View', 'DecorationFocus') ??
        c('Colors:Selection', 'BackgroundNormal'),
    'background': c('Colors:Window', 'BackgroundNormal'),
    'foreground': c('Colors:Window', 'ForegroundNormal'),
    'selection': c('Colors:Selection', 'BackgroundNormal'),
    'muted': c('Colors:Window', 'ForegroundInactive'),
    'red': c('Colors:View', 'ForegroundNegative'),
    'yellow': c('Colors:View', 'ForegroundNeutral'),
    'green': c('Colors:View', 'ForegroundPositive'),
  };
}

/// COSMIC's theme (Dark or Light by its Mode), from the user's config, else
/// the system's defaults.
Map<String, String?> cosmicPalette(String configHome) {
  String? config(String component, String key) {
    for (final base in [p.join(configHome, 'cosmic'), '/usr/share/cosmic']) {
      final text = _read(p.join(base, component, 'v1', key), 256 * 1024);
      if (text != null) return text;
    }
    return null;
  }

  final dark =
      (config('com.system76.CosmicTheme.Mode', 'is_dark') ?? 'true').trim() !=
      'false';
  final theme = dark
      ? 'com.system76.CosmicTheme.Dark'
      : 'com.system76.CosmicTheme.Light';
  String? field(String key, String name) {
    final text = config(theme, key);
    return text == null ? null : ronColor(ronField(text, name));
  }

  return {
    'accent': field('accent', 'base') ?? ronColor(config(theme, 'accent')),
    'background': field('background', 'base'),
    'foreground': field('background', 'on'),
    'green': field('success', 'base'),
    'yellow': field('warning', 'base'),
    'red': field('destructive', 'base'),
  };
}

/// The value after `key:` at the first nesting level of a RON struct.
String? ronField(String text, String key) {
  var depth = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '(' || c == '[') {
      depth++;
    } else if (c == ')' || c == ']') {
      depth--;
    } else if (depth == 1 &&
        text.startsWith(key, i) &&
        (i == 0 || !RegExp(r'\w').hasMatch(text[i - 1]))) {
      var j = i + key.length;
      while (j < text.length && text[j] == ' ') {
        j++;
      }
      if (j >= text.length || text[j] != ':') continue;
      final start = ++j;
      var d = 0;
      for (; j < text.length; j++) {
        final cj = text[j];
        if (cj == '(' || cj == '[') d++;
        if (cj == ')' || cj == ']') {
          if (d == 0) break;
          d--;
        }
        if (cj == ',' && d == 0) break;
      }
      return text.substring(start, j).trim();
    }
  }
  return null;
}

/// A RON colour `(red: 0.1, green: …, blue: …)` as #rrggbb.
String? ronColor(String? value) {
  if (value == null) return null;
  int? part(String name) {
    final m = RegExp('$name:\\s*([0-9.eE+-]+)').firstMatch(value);
    final v = m == null ? null : double.tryParse(m[1]!);
    return v == null ? null : (v.clamp(0, 1) * 255).round();
  }

  final r = part('red'), g = part('green'), b = part('blue');
  if (r == null || g == null || b == null) return null;
  return '#${[r, g, b].map((v) => v.toRadixString(16).padLeft(2, '0')).join()}';
}
