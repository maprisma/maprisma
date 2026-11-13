import 'package:flutter/services.dart';

/// Popup mode (plan-flutter step 5): on Omarchy the window sits floating at
/// the top right under the bar, as the plugins' popups do, and goes away
/// with Esc or a click elsewhere; `maprisma --toggle` (the bar icon) shows
/// and hides it. Elsewhere it stays a normal window.

/// The popup's size on first show (logical pixels; kept inside the monitor).
const popupSize = (width: 1100, height: 760);

/// The window mode in effect: `window_mode` is auto, popup or window; only
/// popup floats, auto is an ordinary window that the desktop tiles. The
/// popup exists on Omarchy only (the core places it there through Hyprland);
/// on COSMIC, Plasma or any other desktop the window stays an ordinary,
/// decorated one that remembers its size.
bool popupWanted(String? mode, String desktop) =>
    mode == 'popup' && popupAvailable(desktop);

/// Whether the desktop can show the popup under the bar.
bool popupAvailable(String desktop) => desktop == 'omarchy';

/// While a dialog of another window runs (the file chooser), the popup loses
/// the focus on purpose and must stay open.
abstract final class PopupGuard {
  static int _depth = 0;
  static bool get busy => _depth > 0;
  static Future<T> around<T>(Future<T> Function() open) async {
    _depth++;
    try {
      return await open();
    } finally {
      _depth--;
    }
  }
}

/// The runner's channel: "shown" when the window is shown again (first
/// frame, a second launch, --toggle).
const windowChannel = MethodChannel('maprisma/window');
