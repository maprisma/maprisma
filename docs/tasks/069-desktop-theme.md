# 069 The desktop's colours outside Omarchy

Author: Claude · Reviewer: Antigravity · Branch: task/069-desktop-theme

## Goal
Maprisma takes the same colours as its sister apps (Launcher, Manager, Theme, Playground and the
COSMIC applets) on every desktop: COSMIC's theme, Plasma's kdeglobals, and on Hyprland Maprisma
Shell's scheme.json that Maprisma Theme writes. Until now `app.theme` was empty outside Omarchy, so
Maprisma showed its own seed colour while the other apps followed the theme.

## Routes
None changed. `app.theme` (and the snapshot's `theme`) return the desktop's palette on generic
desktops: `accent, background, foreground` (+ `muted, selection, red, yellow, orange, green` where
known). Settings › Look stays Omarchy's.

## UI
None: the GUI already builds its theme from `app.theme` and re-reads it every two seconds.

## Acceptance
- core `desktop_palette.dart`; `foundation_test.dart` "generic desktops: the palette of Maprisma
  Shell, Plasma, COSMIC".
- Python reference `desktop_generic.desktop_palette`, `flutter_backend.theme`;
  `tests/test_desktop.py` test_desktop_palette_of_the_sister_apps.
- On Hyprland, a theme change in Maprisma Theme shows in Maprisma within two seconds.
