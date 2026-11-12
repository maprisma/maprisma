# 070 Esc closes the main window; the window keeps its size

Author: Claude · Reviewer: Antigravity · Branch: task/070-esc-closes

## Goal
Every Maprisma app closes its main window with Esc and remembers the size the user gave it (the
maprisma-layout rules). Maprisma closed with Esc only as a popup, and always opened at the runner's
default size.

## Routes
None.

## UI
- Esc keeps its order: a closable card, then back from a page; in a focused text field it leaves the
  field; on the main page with nothing open it hides the popup or closes the window as its close
  button does (asking first while agents run). Manual: the shortcut table.
- After a resize (not as a popup, not maximised or full screen) the size is saved half a second
  later to `~/.config/maprisma/window.json` and used at the next start.

## Acceptance
`tools/test-changed` green; `flutter_app/test/window_size_test.dart` (path, parse/clamp, debounced
save, broken file).
