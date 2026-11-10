# 067 F12 and Corners as in Maprisma Playground

Author: Claude · Reviewer: Antigravity · Branch: task/067-screenshots-corners

Uwe, 2026-11-10: the Maprisma apps take F12 screenshots and Settings › Corners the way Maprisma
Playground does (its commits 73e9c82 … 37820d8).

## Goal
F12 saves a private picture of the window with an optional note, by the same file rules as the
Playground; Settings › Corners also offers "Slightly rounded (6 px)", and every control follows the
setting in the Playground's three sizes.

## Routes
None. `corners` stays a free string in both validators (a stored "windows", "rounded" or "square"
reads as before; an unknown value means "windows"); "slight" is new. Protocol unchanged.

## F12 (flutter_app/lib/main.dart, test_shots.dart)
Already there: the RepaintBoundary, the global HardwareKeyboard handler, one picture at a time,
the note dialog, `screenshot_key`, `screenshot_folder` with its fallback, the terminal's camera
symbol, recorded tests (TestShots, unchanged).
- F12 alone: with Ctrl, Shift, Alt or Super it is left to others.
- Folder: XDG_PICTURES_DIR from `user-dirs.dirs` (read bounded, no link followed; `$HOME/` alone
  or a relative value is no folder of its own), else `~/Pictures`, then `Maprisma`. Only a real
  folder of yours that group and others cannot write to: made 0700 when missing, a link or file in
  its place refused, every folder on the way trusted (`Posix.privateDirectory`), checked on the
  opened handle and written relative to it.
- Files: O_CREAT|O_EXCL|O_NOFOLLOW, 0600; short writes continued, a write of nothing fails; fsync;
  removed again on failure. A name is free only when neither picture nor note (nor a dangling link)
  has it. The note: at most 4000 characters, through the same checks, never over an existing one.
- Errors: a bar says why the picture or the note could not be saved (before: silent).
- The dialog keeps the note on Esc and on a click beside it (before: lost).

## Corners (flutter_app/lib/app_theme.dart)
`Corners(radius)` with `control` = min(r, 8) and `small` = min(r, 4); "windows" with an unknown
rounding is 12 for every control (before: Material's own dialogs). Full radius: cards, dialogs,
pop-up menus, menus, drop-down menus, bottom sheets, the map's boxes. Control: filled, outlined,
text, elevated, icon and segmented buttons, chips, tooltips, outlined fields (`controlBorder`).
Small: check boxes, progress bars, the legend's swatches, the battery bars. Slider: a square track
and a 14 px square knob with Square (no slider in the app yet). Python reference: `corners.py`
gets "slight" (6).

## UI
Settings › Corners: Like windows, Slightly rounded (6 px), Rounded (12 px), Square; its hint names
every control. New texts in all 8 languages (Playground's translations). Manual: the Corners row
and paragraph, the F12 row. README: Corners, F12 under Privacy.

## Acceptance
- `flutter_app/test/test_shots_test.dart`: 0700/0600, link/file/open folder refused, names taken by
  a note or dangling link, note bounded and never overwritten, failed write leaves nothing,
  user-dirs.dirs.
- `flutter_app/test/task_cards_app_test.dart`: Ctrl+F12 takes nothing; F12 twice opens one dialog;
  Esc keeps the note.
- `flutter_app/test/corners_test.dart`: slight, the three sizes for every themed control, the knob.
