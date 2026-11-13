import 'dart:convert';
import 'dart:io';

import 'desktop.dart' show whichIn;
import 'desktop_palette.dart' show desktopRounding;

/// The app's popup mode on Omarchy (plan-flutter step 5): its own window,
/// floated by Hyprland at the top right under the bar, the way the plugins'
/// popups sit there. Hyprland 0.55+ takes Lua through `hyprctl dispatch`
/// (hl.dsp.window.float / resize / move with an address); window rules
/// cannot be added at runtime, so the window is placed after it maps.

/// The space kept between the bar, the screen's edge and the popup.
const popupGap = 10;
final _address = RegExp(r'^0x[0-9a-f]{1,16}$');

/// Where the popup goes: the window of `pid` among `clients`, on the focused
/// monitor (else the first), its size kept inside the monitor's free area.
/// Logical pixels, as Hyprland's layout uses them. Null when there is no
/// window of `pid` or no monitor.
({String address, int x, int y, int width, int height})? popupGeometry(
  List monitors,
  List clients,
  int pid,
  int width,
  int height,
) {
  final own = clients
      .whereType<Map>()
      .where((c) => c['pid'] == pid && _address.hasMatch('${c['address']}'))
      .firstOrNull;
  final monitor =
      monitors
          .whereType<Map>()
          .where((m) => m['focused'] == true)
          .firstOrNull ??
      monitors.whereType<Map>().firstOrNull;
  if (own == null || monitor == null) return null;
  final scale = monitor['scale'] is num && (monitor['scale'] as num) > 0
      ? (monitor['scale'] as num).toDouble()
      : 1.0;
  int number(dynamic v) => v is num ? v.round() : 0;
  final reserved = monitor['reserved'] is List
      ? [for (final r in monitor['reserved'] as List) number(r)]
      : const [0, 0, 0, 0];
  final pad = [...reserved, 0, 0, 0, 0];
  final left = number(monitor['x']) + pad[0];
  final top = number(monitor['y']) + pad[1];
  final free = (
    (number(monitor['width']) / scale).floor() - pad[0] - pad[2],
    (number(monitor['height']) / scale).floor() - pad[1] - pad[3],
  );
  final w = width.clamp(
    320,
    free.$1 - 2 * popupGap > 320 ? free.$1 - 2 * popupGap : 320,
  );
  final h = height.clamp(
    240,
    free.$2 - 2 * popupGap > 240 ? free.$2 - 2 * popupGap : 240,
  );
  return (
    address: '${own['address']}',
    x: left + free.$1 - w - popupGap,
    y: top + popupGap,
    width: w,
    height: h,
  );
}

/// The dispatches that make the window a popup there (float, size, place).
List<String> popupDispatches(
  ({String address, int x, int y, int width, int height}) g,
) {
  final window = "window='address:${g.address}'";
  return [
    "hl.dsp.window.float({action='enable', $window})",
    'hl.dsp.window.resize({x=${g.width}, y=${g.height}, $window})',
    'hl.dsp.window.move({x=${g.x}, y=${g.y}, $window})',
  ];
}

/// hyprctl with a time limit (coreutils timeout): Hyprland answering slowly
/// never holds the app up. Null when it is missing or fails.
String? _hyprctl(List<String> args, Map<String, String> env) {
  final path = env['PATH'];
  final hyprctl = whichIn('hyprctl', path);
  final timeout = whichIn('timeout', path);
  if (hyprctl == null || timeout == null) return null;
  try {
    final result = Process.runSync(
      timeout,
      ['2', hyprctl, ...args],
      environment: env,
      includeParentEnvironment: false,
      stdoutEncoding: utf8,
    );
    return result.exitCode == 0 ? result.stdout as String : null;
  } on ProcessException {
    return null;
  }
}

/// Whether this is a Hyprland session. XDG_CURRENT_DESKTOP decides when it
/// is set; only without it does HYPRLAND_INSTANCE_SIGNATURE count, and only
/// when that Hyprland's socket is there
/// (`$XDG_RUNTIME_DIR/hypr/<signature>/.socket.sock`): after a Hyprland session the variable stays in the systemd
/// user environment, so a COSMIC or KDE session sees a stale one.
bool hyprlandSession(Map<String, String> env) {
  final names = (env['XDG_CURRENT_DESKTOP'] ?? '')
      .toLowerCase()
      .split(':')
      .where((n) => n.trim().isNotEmpty)
      .toList();
  if (names.isNotEmpty) {
    // hyprctl needs the signature too
    return names.contains('hyprland') &&
        (env['HYPRLAND_INSTANCE_SIGNATURE'] ?? '').isNotEmpty;
  }
  final signature = env['HYPRLAND_INSTANCE_SIGNATURE'] ?? '';
  final runtime = env['XDG_RUNTIME_DIR'] ?? '';
  if (signature.isEmpty ||
      signature.contains('/') ||
      signature.startsWith('.') ||
      !runtime.startsWith('/')) {
    return false;
  }
  return FileSystemEntity.typeSync('$runtime/hypr/$signature/.socket.sock') !=
      FileSystemEntityType.notFound;
}

/// Places this process's window as the popup; what was done.
Map<String, dynamic> placePopup(
  Map<String, String> env,
  int pid,
  int width,
  int height,
) {
  if (!hyprlandSession(env)) {
    return {'placed': false, 'reason': 'not Hyprland'};
  }
  List read(String what) {
    final text = _hyprctl([what, '-j'], env);
    if (text == null) return const [];
    try {
      final data = jsonDecode(text);
      return data is List ? data : const [];
    } on FormatException {
      return const [];
    }
  }

  final g = popupGeometry(
    read('monitors'),
    read('clients'),
    pid,
    width,
    height,
  );
  if (g == null) return {'placed': false, 'reason': 'no window yet'};
  for (final lua in popupDispatches(g)) {
    if (_hyprctl(['dispatch', lua], env)?.trim() != 'ok') {
      return {'placed': false, 'reason': 'dispatch failed'};
    }
  }
  return {
    'placed': true,
    'x': g.x,
    'y': g.y,
    'width': g.width,
    'height': g.height,
  };
}

/// corners.parse_rounding: the windows' rounding from Hyprland's
/// `getoption decoration:rounding -j`, 0–24, null when unknown.
int? parseRounding(String text) {
  try {
    final value = (jsonDecode(text) as Map)['int'];
    return value is int ? value.clamp(0, 24) : null;
  } on Object {
    return null;
  }
}

/// desktop_omarchy.window_rounding, read at most every 30 seconds; off
/// Hyprland the desktop's own corners (desktop_palette.desktopRounding).
final class WindowRounding {
  WindowRounding(this.env);
  final Map<String, String> env;
  DateTime? _read;
  int? _value;

  int? get value {
    final now = DateTime.now();
    if (_read != null && now.difference(_read!).inSeconds < 30) return _value;
    _read = now;
    if (!hyprlandSession(env)) {
      // COSMIC's theme corners, Plasma's 8 (the family's rule), else none.
      return _value = desktopRounding(env);
    }
    final text = _hyprctl(['getoption', 'decoration:rounding', '-j'], env);
    return _value = text == null ? null : parseRounding(text);
  }
}
