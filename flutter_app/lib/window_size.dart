import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Size;

/// Maprisma Tiling (the KWin script) sizes the windows it tiles itself, and no tiled state reaches
/// GTK (it only moves the frame), so the runner's "free" can't see it: on Plasma with the script
/// on, only an app it always floats (its `floatingClasses`, by default the Launcher) keeps a size.
/// [environment] and [systemData] are for tests.
bool tiledByMaprismaTiling(
  String appId, {
  Map<String, String>? environment,
  String systemData = '/usr/share',
}) {
  final env = environment ?? Platform.environment;
  final names = (env['XDG_CURRENT_DESKTOP'] ?? '').toUpperCase().split(':');
  if (!names.contains('KDE')) return false;
  final home = env['HOME'] ?? '/';
  String xdg(String key, String fallback) {
    final v = env[key] ?? '';
    return v.startsWith('/') ? v : '$home/$fallback';
  }

  String text;
  try {
    final file = File('${xdg('XDG_CONFIG_HOME', '.config')}/kwinrc');
    text = file.lengthSync() > 1024 * 1024 ? '' : file.readAsStringSync();
  } on Object {
    text = '';
  }
  String? value(String group, String key) {
    String? current, found;
    for (final raw in text.split('\n')) {
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

  final enabled = value('Plugins', 'maprisma-tilingEnabled');
  if (enabled == 'false') return false;
  // Not switched either way: on by default once installed.
  if (enabled != 'true' &&
      !Directory(
        '${xdg('XDG_DATA_HOME', '.local/share')}/kwin/scripts/maprisma-tiling',
      ).existsSync() &&
      !Directory('$systemData/kwin/scripts/maprisma-tiling').existsSync()) {
    return false;
  }
  final floating =
      (value('Script-maprisma-tiling', 'floatingClasses') ??
              'com.maprisma.Launcher')
          .split(',')
          .map((c) => c.trim().toLowerCase());
  return !floating.contains(appId.toLowerCase());
}

/// `<XDG_CONFIG_HOME or ~/.config>/maprisma/window.json` (the core's
/// AppIdentity.configDir).
String windowSizePath(Map<String, String> env) {
  final config = env['XDG_CONFIG_HOME'] ?? '';
  final root = config.startsWith('/')
      ? config
      : '${env['HOME'] ?? '/'}/.config';
  return '$root/maprisma/window.json';
}

/// The main window's size, remembered after the user resizes it (the
/// maprisma-layout rule): `<config>/window.json` `{"width": …, "height": …}`.
/// Saved half a second after the last resize; a missing or broken file, or a
/// size out of bounds, leaves the default size.
class WindowSizeStore {
  WindowSizeStore(this.path, {this.delay = const Duration(milliseconds: 500)});

  final String path;
  final Duration delay;
  Timer? _timer;
  Size? _last;

  static const minSize = Size(480, 360);
  static const maxSide = 8192.0;

  /// A size from the file's JSON, or null when it isn't one.
  static Size? parse(Object? data) {
    if (data is! Map) return null;
    final w = data['width'], h = data['height'];
    if (w is! num || h is! num || !w.isFinite || !h.isFinite) return null;
    if (w < minSize.width || h < minSize.height) return null;
    return Size(
      w.clamp(minSize.width, maxSide).toDouble(),
      h.clamp(minSize.height, maxSide).toDouble(),
    );
  }

  Size? load() {
    try {
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() > 4096) return null;
      return parse(jsonDecode(file.readAsStringSync()));
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// After a resize: saved once the resizing has stopped for [delay].
  void resized(Size size) {
    if (size.width < minSize.width || size.height < minSize.height) return;
    _last = size;
    _timer?.cancel();
    _timer = Timer(delay, flush);
  }

  void flush() {
    _timer?.cancel();
    _timer = null;
    final size = _last;
    if (size == null) return;
    _last = null;
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      final tmp = File('$path.tmp');
      tmp.writeAsStringSync(
        jsonEncode({
          'width': size.width.round(),
          'height': size.height.round(),
        }),
      );
      tmp.renameSync(path);
    } on FileSystemException {
      // Not remembered this time; the window keeps working.
    }
  }

  void dispose() => _timer?.cancel();
}

/// Hyprland marks every window as tiled, floating ones too, so the runner can't tell whether a
/// size is the user's: there `hyprctl -j clients` decides. True when this process's window is
/// tiled or fullscreen (not a size to keep); false on other desktops or when it can't be told.
/// Shared in every Maprisma Flutter app's size code (Uwe, 2026-11-14).
Future<bool> hyprlandSizeNotUsers({
  Map<String, String>? environment,
  int? processId,
  Future<ProcessResult> Function()? clients,
}) async {
  final env = environment ?? Platform.environment;
  if (!_hyprlandDesktop(env)) return false;
  try {
    final result =
        await (clients ?? () => Process.run('hyprctl', ['-j', 'clients']))()
            .timeout(const Duration(seconds: 2));
    if (result.exitCode != 0) return false;
    return hyprNotUsers(result.stdout.toString(), processId ?? pid) ?? false;
  } on Object {
    return false;
  }
}

/// From `hyprctl -j clients`: whether [processId]'s window is tiled or fullscreen; null when the
/// list has no window of it.
bool? hyprNotUsers(String clientsJson, int processId) {
  Object? list;
  try {
    list = jsonDecode(clientsJson);
  } on FormatException {
    return null;
  }
  if (list is! List) return null;
  for (final client in list) {
    if (client is Map && client['pid'] == processId) {
      final fullscreen = client['fullscreen'];
      return client['floating'] != true ||
          (fullscreen is num && fullscreen != 0) ||
          fullscreen == true;
    }
  }
  return null;
}

/// MAPRISMA_DESKTOP, else XDG_CURRENT_DESKTOP; Hyprland's instance signature only when neither
/// is set (a stale one stays in the systemd user environment after a Hyprland session).
bool _hyprlandDesktop(Map<String, String> env) {
  final forced = (env['MAPRISMA_DESKTOP'] ?? '').trim().toLowerCase();
  if (forced.isNotEmpty) return forced == 'hyprland';
  final names = (env['XDG_CURRENT_DESKTOP'] ?? '')
      .toLowerCase()
      .split(':')
      .map((n) => n.trim())
      .where((n) => n.isNotEmpty)
      .toList();
  if (names.isNotEmpty) return names.contains('hyprland');
  return (env['HYPRLAND_INSTANCE_SIGNATURE'] ?? '').isNotEmpty;
}
