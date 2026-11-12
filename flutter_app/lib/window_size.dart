import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Size;

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
