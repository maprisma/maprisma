# 100 Drag and drop instead of move menus; Settings › Keyboard shortcuts

Author: Claude · Reviewer: Antigravity · Branch: task/100-drag-reorder

Uwe (2026-11-23): make the project cards reorderable by drag and drop instead of a menu, and the
same for the cards on the AI map; show separators while dragging for easier repositioning; the
map's placing rules stay (a box never lands in another category's card, e.g. an agent in the
providers' card). Settings gets its own category for the shortcuts inside the app, each with a
short description.

## Goal
Cards and boxes are moved by dragging them where they should go, with every possible place shown
while dragging; the keyboard keeps its own way; Settings lists every in-app shortcut.

## Routes
None (the board's `move` and the map layout's `order` are unchanged).

## UI
- **Projects board** (`project_board.dart`, `_ReorderCell`): the whole card is dragged, with a
  mouse, pen or trackpad at once (a click on a button stays a click until the pointer moved past the
  slop), by touch after a long press so a swipe still scrolls the board. The Move menu
  (Move up / down / to top / to end) is gone; the grip only shows that a card can be dragged.
  While a card is dragged every other card shows a faint separator in the gaps beside it
  (`card-gap`), the drop place a strong one (`card-drop`). Ctrl+Up/Down/Home/End and the screen
  reader's move actions stay.
- **AI map boxes** (`map_editor.dart`): the grip follows the pointer; while it is dragged a faint
  line marks every place in the box's own card (`box-gap-<i>`), a strong one where it goes
  (`box-drop-line`); places come only from its own card (`MapLayout.boxDrop` / `boxGaps`).
  Move up / Move down left the Actions menu. Boxes are keyed by id, so the keyboard stays with a
  moved box.
- **AI map cards**: the header is dragged inside its column as before; the Move card menu
  (Earlier card / Later card) is gone, a grip shows it; while dragging, a faint line in every gap of
  the column (`card-gap-<i>`, `MapLayout.cardGaps`) under the strong `card-drop-line`.
- **Keyboard**: Ctrl+Up / Ctrl+Down on a box or a card header move it one place in its card or
  column (the menu entries were the keyboard's way before).
- **Settings › Keyboard shortcuts** (`settings_view.dart`): a section of its own before Recent
  changes: Window, AI Map, Projects, Ask AI, Terminal, every key with what it does; texts in all
  8 languages, found by Find in Settings.
- Manual (8 languages): the board, the map editor, keyboard use and the Settings overview.

## Acceptance
- `project_board_order_test.dart`: the whole card is dragged by mouse (and by touch after a long
  press), separators show, a click on Open stays a click; refusals and Ctrl+Home still work.
- `map_editor_test.dart`: card drag shows the gaps and stays in its column, no Move card menu, Ctrl+Up
  by keyboard; box drag shows every place and the strong line; a box dragged over the providers'
  column stays in its own card and makes no connection; Ctrl+Up/Down reorder a box.
- `settings_layout_test.dart`: the Shortcuts section, its keys and descriptions, Find in Settings, German.
