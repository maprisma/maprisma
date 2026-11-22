# 095 Board order and importance

Author: Claude · Reviewer: Codex and Antigravity · Branch: task/095-board-order

Uwe (2026-11-22): the Projects board shows the user's order only: cards stay where they are
dropped, new projects go on top; urgency stays visible on the cards and in the filter counts but no
longer sorts the board. Importance High / Medium / Low is a mark per project, set on the card and
in the Goal tab; new projects are Medium; importance does not move cards (it can be filtered). The
Phases view stays navigation only. Protocol and core first (this part), the GUI follows.

## Goal
The user arranges the board by hand and marks each project High, Medium or Low; both survive a
restart and the board never reorders itself.

## Routes
No new route; `features.call`'s note in `routes.json` describes the two new AI Project Center
operations (host allow-list in `feature_routes.dart`). Protocol version stays 2. The backend lists
the capability `order` in `@hello` (`summary2`, `board`, `order`); the GUI offers dragging and
the importance mark only when it is there.

- `list`: the projects come in the stored board order (no longer most urgent first). Every card
  and every project view (`get`, every mutation result) has `importance`: `high`, `medium` or `low`.
- `move {id, before?}`: puts the project before the project `before`; absent or null puts it at
  the end; `before` equal to `id`, or the place it already has, changes nothing. Answer:
  `{order: [id, ...]}`, the whole new order. An unknown or deleted `id` or `before` is refused
  `project_unknown` (the GUI reads the board again); another field is invalid params. A position
  relative to a card, not an index: it means the same with a filtered board and after another
  client's change. No revision check; revision, `updated_at` and events stay (the order is not
  project content, so an open editor never turns stale by a drag). Allowed while the project works.
- `set_importance {id, importance}`: answer `{project}`. A mark, not project content: no revision
  check; revision, `updated_at`, events and the approval stay; allowed while the project works (so
  the Goal tab can set it without making its unsaved edits stale). Unknown `id`: `project_unknown`;
  a value other than the three, a missing value or another field: invalid params.
- New projects (`save` without `id`) go on top and read `medium`. `delete` removes the project
  from the order.
- Both writes are refused like every write after a storage fault (`project_store_unavailable`,
  `project_store_full`); a failed write leaves the order and the mark as they were.

## Store
`projects.json` keeps `version: 1`; its `projects` list is the board order and the file carries
`board_order: true`. A store from before this task (no `board_order`) kept creation order while
the board sorted by urgency: its first order is the latest change first, the newest project first
on a tie (the old order within a bucket; the urgency itself needs the display snapshot, which a
load does not read, and would freeze a passing state such as Running at the top). Missing
`importance` reads `medium`; any other stored value, or a `board_order` other than `true`, is
`project_store_corrupt`. An older core reading the new store keeps both (it rewrites unknown
fields unchanged) but adds its new projects at the end.

## UI (next step, GUI task)
- Board cards can be dragged; a drop calls `move` with the card after the drop place as `before`
  (none: the end). Keyboard: Move up / Move down / Move to top / Move to end (`before` = the
  neighbour's id, the one after next, the first card, null).
- A High / Medium / Low mark on each card and in the Goal tab (`set_importance`); a filter by
  importance next to the bucket filters; bucket counts unchanged.
- Texts in 8 languages, manual sentence on ordering and importance; Phases view unchanged.

## Acceptance
Core tests (`ai_project_center_test.dart`, group "board order and importance (task 095)"): new
on top and order across a reopen, move up / down / to the top / to the end with revision and last
change unchanged, unknown ids and fields refused with nothing moved, a deleted project leaves the
order, importance Medium when new, set, validated (invalid value, missing value, extra field,
unknown id), kept across a reopen and not moving the card or the approval, a corrupt stored mark,
a failing store refusing both, a legacy store ordered latest change first (newest first on a tie)
with Medium, urgency not sorting (every bucket in the user's order, counts unchanged). Through
the real worker (`feature_plugins_test.dart`): capability `order`, `move` and `set_importance`
pass the host. Codex and agy CLEAN.
