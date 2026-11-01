# 017 Disconnect all at once, every action in the window

Author: Claude · Reviewer: Antigravity · Branch: task/017-disconnect-all, on task/016-focus-dimming

Uwe, 2026-11-01, screenshot notes: Ask AI should be able to disconnect all servers at once, and the Preview should open in the overlay window.

## Ask AI
`disconnect` now takes `servers`, a list. The helper's answer is checked against the servers on this PC. The core makes one candidate from the pairs of server and agent that really exist, so several agents or servers give one preview, one backup and one Undo (`chainPlans`). `connect` stays one server. No new route: `map.smart_plan` answers with a normal plan, plus `disconnects` for the review's lines.

## Every action in the window
Uwe: all action windows, terminal included, in the overlay window, and it can be sized. Every `_card` shows in `OverlayWindow`; the half card with its small map is gone, with `task_focus.dart`, `TaskCardWidth` and the map's read-only mode. A window is modal: header buttons and app keys wait. The page behind stays visible and dimmed, without the keyboard. Pages (`_viewHost`) stay pages. Edges and corners drag the size, a double click restores it; the size holds until the app closes, shared by all windows. A change scans at once with the map on screen; otherwise `_mapStale` asks for one scan when the map is back and nothing is busy. `connections.apply` always scans.

## A plain disconnect (Uwe)
Dragging a line to empty space with no notes and no API contexts in the plan: a small dialog with the line, what gets unloaded, Cancel and Apply. Then a message with Undo instead of a result window; Ask AI's apply shows the same message. Disconnect on a failed line's card counts as the answer. With something to warn about, the full Preview. A changed slot count of a local LLM still opens its own Preview afterwards.

## Hook on a clicked line (Uwe)
A click on a line that can move shows its orange hook, without selecting a box. A click on empty space or a box hides it. A failed line still opens its help.

## Manual
Sentences in smart-card, task-cards and flutter-map-editor, 8 languages.
