# 102 Map boxes are dragged by their body

Author: Claude · Reviewer: Antigravity · Branch: task/102-box-drag

Uwe (2026-11-23), on 2.1.2: drag and drop of boxes on the AI map does not work: nothing moves. Only the
16 px grip reordered; dragging the box itself drew a connection.

## Goal
A box is moved by dragging the box itself, as in the plugin's map: inside its own card it changes its
place, out of its card it draws a connection as before.

## Routes
None.

## UI
`map_editor.dart`: the box's own drag is in reorder mode while the pointer is in its own card below the
header and the card has other boxes (`_reorderingInCard`): the same separators as the grip (`box-gap-<i>`,
`box-drop-line`), no connection line; let go there, it moves (`MapLayout.boxDrop`). Out of its card the
drag draws a connection exactly as before. The grip stays. Manual (8 languages): the map editor sentence.

## Acceptance
`map_editor_test.dart`: with the mouse on the box body, a drag down in its card shows the places and moves
it without an edit; a drag out of its card onto a local LLM connects them.
