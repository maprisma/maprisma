# Plan: the map editor in Flutter (2026-10-28)

## Decision (Uwe, 2026-10-28)

The Flutter app replaces the GTK app on Linux too; the GTK app is no longer needed once Flutter runs there.
From now on the GTK app (`/mnt/Data/Projects/asterism`, remote `gtk`) gets **fixes only, no new features**.
New work happens here. The GTK app retires at parity (plan-flutter.md, steps 3–6).

The map is the product's core: everything a user connects or disconnects should be doable by drawing or
dragging on the map, with tooltips and Undo. The Flutter map today is a read-only grid (`agent_map.dart`:
fixed 290 × 106 px cells, a long-press drag only for folders and stores). This slice makes it the editor
the GTK map is, and proves it runs well, before the remaining screens are ported.

## What the GTK map does (the reference)

`map_view.py` (module docstring, lines 1–35) and its wiring in `ai_popup.py:966–1013`:

| Gesture | GTK callback | Service in Flutter today |
|---|---|---|
| Drag from an agent to a local LLM, MCP server or skill set (or back) | `on_link(agent, target)` | `connections.preview` kind `provider` / `mcp` / `skills`, `remove: false` |
| Drag an agent line's hook to another LLM, or onto empty space | `on_relink(agent, old, new / None)` | Remove only: `connections.preview remove: true`. **Gap: one plan for "move"** (remove old + add new, one review, one Undo) |
| Click or draw from an agent to a model of a connected provider | `on_pick_model(agent, runtime, model)` | `connections.preview` kind `provider` with `model`, `use_now` |
| Drag a provider's model line (used by agents) onto another model / empty space | `on_remodel(runtime, old, new / None)` | **Gap**: switch the users to another model, or unload |
| Draw from a provider to one of its models | `on_attach(provider, model)` (asks which agents) | **Gap**: give chosen agents the model (several provider plans in one review) |
| Hooks: orange handle on every movable line of the selected box, grabbed at once, tooltip says what dragging does | `draw_hooks`, `hook_at`, `edge_tips` | none |
| Hover lights a box and everything joined to it; click selects, Shift+click adds; one agent at a time; pin keeps a box lit | `related`, `on_click`, `toggle_pin` | `focusedNode` only |
| Cards: fold, move, reorder boxes inside a card; layout saved | `toggle_card`, `make_room`, `reorder`, `on_layout` | **Gap**: layout settings in the service |
| Start / console / stop / halt buttons on boxes; right-click menu | `on_start`, `on_console`, `on_stop`, `on_halt`, `on_context` | `sessions.*`, `agents.action_*`, `_nodeMenu` |
| Lights flowing along the lines of working agents (and lines other programs use); off for reduced motion | `flow_paths`, `flow_marks`, `set_animate` (`all` / `agents` / `off`) | **Gap**: activity per line in `map.snapshot` / `agents.activity` |
| Failed line (red): click shows why, repair or remove | `on_failed_edge` → `show_link_hints` | **Gap**: link hints in the map payload |

## Steps

1. **Service gaps.** Add bounded, reviewed preview routes that reuse `connect`/`mcp_ctl`/`skills_ctl` plans
   and the existing opaque handles, worker apply and Undo: `connections.move_preview` (remove old + add new as
   one merged plan), `models.switch_preview` (users of a model to another model, or unload),
   `models.attach_preview` (a model to chosen agents). The map layout (card order, folded cards, box order,
   pins) goes into settings through `settings.update` with a strict schema. Add per-line activity and link
   hints to the map payload. Python tests, including hostile and stale inputs, as with the earlier slices.
2. **Map model and layout** (`lib/map_layout.dart`, pure Dart, unit-tested): columns, cards and box positions
   from the graph plus saved layout; hit testing for boxes, lines (distance to the bezier), hooks and drop
   targets; which targets fit a drag (port `link_target_ok` from `map_view.py:978`).
3. **Editor widget.** Replace the grid in `AgentMap` with one `CustomPainter` for lines, hooks and lights plus
   widgets for boxes, keeping `InteractiveViewer` pan and zoom. Gestures as in the table: drawing a new line
   with a live rubber band and highlighted valid targets, grabbing hooks, hover/selection/pin, card fold,
   move and reorder. Every change goes through the existing review → progress → result/Undo task card; the
   card's task map shows the affected boxes. Tooltips for every hook and drop target. The read-only task map
   (`readOnly: true`) keeps working.
4. **Lights.** Flowing marks along active lines with one `Ticker` that runs only while something flows and
   the map is visible; honour the `animate` setting and the desktop's reduced-motion preference.
5. **Performance check.** Measure CPU with the lights on and off against the GTK map on a realistic map
   (about 40 boxes): the GTK map is at about 1 % idle and 8–11 % with lights (`tools/profile-map.py` in the
   GTK repo; this tree has `tools/profile-flutter-map.py`). Record numbers from the Devel build in the
   responses file. If Flutter is clearly worse, say so
   and propose the fix; do not hide it.
6. **Tests and docs.** Widget tests for each gesture (drag to connect → review card; hook to empty space →
   remove review; Cancel changes nothing; Undo restores), hit-testing unit tests, keyboard alternatives for
   every gesture (accessibility), 8 languages, the manual chapter on editing the map, and
   `plan-flutter-map-editor-responses.md`.

## Out of scope

The remaining screens (catalogs, installers, settings, help), packaging and the Omarchy thin launcher: they
follow this slice, in the order of plan-flutter.md.

## Rules

AGENTS.md applies. Nothing is pushed or published. No live test that moves the real mouse or opens windows
that grab the keyboard; use widget tests and the isolated Devel build.
