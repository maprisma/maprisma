# Plan: task screens become cards on the map (Flutter app)

Handoff from a Claude Code session (2026-10-28) for Codex. Scope: the Flutter UI in `flutter_app/` and the
Python service replies it needs (`flutter_*.py`). Not the GTK app. Read `docs/plan-flutter.md` and
`AGENTS.md` first; their rules apply.

## Goal (Uwe, 2026-10-28)

What *does* something (connect, update, install, download, remove, add-ons…) should no longer be its own
screen or a modal dialog. It becomes a **big card on the map**:

- **Half card** on the right half of the map area. The left half shows a small map with **the items the
  task is about** (agent, provider, MCP server, model…), joined to the card by lines. The user sees what is
  being changed and, when it is done, the new line.
- **Full card** over the whole map area when the task needs the width (several columns): model search and
  downloads, the add-on/MCP server catalog.

## Decisions (Uwe let the agent decide)

| Question | Decision | Why |
|---|---|---|
| Draw the task's items on the main map or on a new map? | **A new "task map"**: a second `AgentMap` with a focused sub-graph. The main map is not built while a card is in view. | The main map's view state is already outside the widget: `_aiTransform` (zoom/pan), `_aiFocus`, `_focusCategory` live in `_AsterismAppState`, so rebuilding it after the card restores it exactly. Not building it saves its layout of every node; shrinking it to half width would change pan/zoom. |
| What the task map shows | The task's nodes + their direct neighbours, **empty columns dropped** (columns renumbered, their titles kept). | `AgentMap` places nodes by column × row (`agent_map.dart:150–160`), so a small graph compacts by itself. |
| Interactive? | **Read-only**: no tap, menu, drag/drop, groups; no pan/zoom — scaled to fit (`FittedBox`, `BoxFit.scaleDown`, aligned to the right, towards the card). | It is a picture of the task, not a second place to edit. |
| Where the focus ids come from | **From the service**: every preview/task start reply gets `"focus": [node ids]` (graph ids: `agent:`, `runtime:`, `model:`, `mcp:`, `skills:`, `cloud:`; see `graph.py`). | Only the service knows the graph's id scheme and what a plan touches (`flutter_connections.preview` already has kind/command/item). |
| Behind a full card | Nothing (the map area's background). | Same reason: no main map build. |
| Narrow window | Map area < 900 logical px → every half card is shown full, no task map. | Card rows must not be squeezed. |
| Review → run → result | **One card for the whole task**: the review (what the confirm dialog shows today), then progress (what `ProviderTaskDialog` shows), then the result with Undo where there is one. | No dialog chain; the task map stays the same throughout. |

## Facts (checked 2026-10-28, `/mnt/Data/Projects/asterism-flutter`, main, uncommitted work on top of b38f423)

- Map area: `main.dart:1747–1890`, an `IndexedStack` (0 = AI side, 1 = `SystemMapView`). Index 0 is a ternary
  chain: `_showGuide` → `FirstAgentView`, `_visibleTerminal` → `AgentTerminalView`, `_showConnections` →
  `ConnectionsView`, `_showProviders` → `ProvidersView` (with `ModelBrowser`: search/files/download,
  `providers_view.dart:287–490`), `_showSettings` → `SettingsView`, `_showMap` → `AgentMap` or
  `_groupFocus()` (`MapAddonsFocus`: add-on catalog per category, `main.dart:487`), else agent list/details.
- Modal task dialogs, all `showDialog` + `ProviderTaskDialog` (polls `tasks.status`, `tasks.cancel`, pops the
  result; `provider_task_dialog.dart`): `_addonOperation` (`main.dart:701`), connection apply (`:867`),
  `_providerOperation` (`:1147`), `_connectionPreview` (`:1180`, after `confirmConnection`), `_removeModel`
  (`:1259`, after `confirmModelRemoval`). Review dialogs: `confirmConnection` (`connections_view.dart:122`),
  `confirmAgentAction` (`agent_action_dialog.dart:14`, used by `_agentAction` `main.dart:1085`),
  `confirmModelRemoval` (`model_removal_dialog.dart:4`), `confirmAddonInstall` / `confirmAddonRemoval`
  (`addon_details.dart:53, 98`). `_review()` (`main.dart:410`) counts open reviews (`_reviewDepth`).
- `_taskActive` guards the window close (`main.dart:166`); `barrierDismissible: false` + `PopScope(canPop:
  _failed)` stop closing a running task.
- `AgentMap` (`agent_map.dart`) is stateless: fixed grid (290 px columns, 106 px rows, 242×82 cards), edges
  painted by `_Connections`, wrapped in an `InteractiveViewer`.
- Tests live in `flutter_app/test/` (e.g. `agent_map_test.dart`, `providers_view_test.dart`,
  `connections_view_test.dart`). Widget tests need a host terminal (`tools/flutter-dev check`): the sandbox
  denies their loopback socket.

## Which task gets which card

| Task (today) | Card | `focus` from the service |
|---|---|---|
| Connection connect/remove (`connections.preview` → `confirmConnection` → `connections.apply`) | half | `agent:<command>` + `mcp:/skills:/runtime:<item>` (+ the model node for a provider with a model) |
| Agent action install / login / verify / update (`agents.action_preview` → `confirmAgentAction`) | half | `agent:<command>` (+ its provider for login) |
| Model remove (`models.remove_preview` → `confirmModelRemoval` → `models.remove`) | half | the model node + its runtime + agents using it |
| Provider operations from `ProvidersView` (`model.load`, `model.import`, runtime install/update) | half | `runtime:<key>` (+ the model) |
| Add-on install/remove/update (`confirmAddon*` → `_addonOperation`) | half | the add-on's nodes on the map if any, else **full** |
| `system.refresh`, `existing.*`, `guide.snapshot` progress | full | — |
| `ProvidersView` itself (all-runtimes overview) | full | —; individual runtime operations use their service-supplied focus in half cards |
| `ModelBrowser` (search, files, download — several columns) | full | — |
| `MapAddonsFocus` catalog (MCP servers, skills, agents, providers) | full | — |
| `ConnectionsView` (all connections of an agent) | half | `agent:<command>` + everything it is connected to |
| `FirstAgentView` | full | — |
| `SettingsView`, `AgentTerminalView`, usage dialog, subagents dialog | **unchanged** | — |

## Steps

1. **Service: `focus` ids** — `flutter_connections.preview`, `agents.action_preview`,
   `models.remove_preview`, the add-on previews and `providers.run`'s start reply return `"focus": [...]`
   (only ids that exist in the current graph; empty list allowed). Python tests next to the existing
   `tests/test_flutter_*.py`. The core names no agent/provider (`test_the_core_names_no_agent`, `..._llm`).
2. **`lib/task_focus.dart`** (pure Dart, unit-tested): `focusGraph(graph, ids, columns) → (graph, columns)`
   — nodes in `ids` + direct neighbours, the edges among them, empty columns dropped and renumbered, column
   titles kept; unknown ids ignored.
3. **`AgentMap` read-only mode**: `readOnly: true` → no `InteractiveViewer` (a `FittedBox` scaleDown,
   `Alignment.centerRight`), no taps/menus/drag targets/`LongPressDraggable`, no group cards; plus
   `anchors: Set<String>` → `_Connections` also draws, for each anchored node, a curve from its right edge to
   the canvas' right edge at mid-height (primary colour, 2 px). The card shows a matching dot at mid-height on
   its left edge so the lines visibly arrive. Extend `agent_map_test.dart`.
4. **`lib/task_card.dart`**: `TaskCardSpec {title, width: half|full, focus, child, closable}` and `TaskHost`
   (the map area while a card is open): `LayoutBuilder` → full, or `Row[Expanded(task map) |
   SizedBox(width: max(460, w/2), Card)]`; Back/Esc closes when `closable`. The card uses the theme's
   `surfaceContainer`, radius 12 like the map cards, a header row (title, Back) like the other views.
5. **Task runner as a card**: move `ProviderTaskDialog`'s polling into `TaskProgress` (a widget, not a
   dialog; same `tasks.status`/`tasks.cancel` logic, same failed/cancel states) and one state method
   `Future<Map<String, dynamic>?> _runTask({title, operation, params, existingTask, focus, width})` that
   opens the card, awaits the result (a `Completer`), keeps `_taskActive` and the non-closable rule while
   running. Replace every `showDialog(... ProviderTaskDialog ...)` call site with it.
6. **Reviews in the same card**: turn `confirmConnection`, `confirmAgentAction`, `confirmModelRemoval`,
   `confirmAddonInstall/Removal` into widgets (`…Review`) with `onConfirm`/`onCancel`; the card shows review
   → `TaskProgress` → result (Undo button where `_connectionUndo`/`_moveUndo` apply). Keep `_review`'s
   counting (`_reviewDepth`) or replace it with "a card is open". Keep the old functions only if another caller
   still needs a dialog.
7. **Views in cards**: `ProvidersView`, `ConnectionsView` → half cards; `ModelBrowser`, `MapAddonsFocus`,
   `FirstAgentView` → full cards. Replace the `_show…` booleans for them with one `_card` (spec) in the state;
   the ternary chain gets one branch `_card != null ? TaskHost(...)`. When `_graph` changes (`_refresh`), the
   task map is rebuilt from the new graph with the same `focus` — that is how the new line appears.
8. **Tests**: `task_focus_test.dart`; `agent_map_test.dart` (read-only: no menu/drag widgets, anchors painted);
   a `task_card_test.dart` (half vs full, narrow fallback, not closable while running, result shown);
   update `providers_view_test.dart` / `connections_view_test.dart` for the new hosts. Run
   `tools/flutter-dev check` (format, analyze, tests — host terminal), the Python suite and
   `UV_OFFLINE=1 tools/typecheck.sh`.
9. **Texts and docs**: new strings through `tr()` in all 8 languages; the manual chapter on the map/tasks in
   all 8 languages + PDFs; update `docs/plan-flutter.md`'s checklist (point 3, jobs/progress) and record
   what was done in `docs/plan-task-cards-responses.md`, as with the earlier plans.

## Out of scope (ask Uwe later)

- Editing on the task map (drawing the new line there instead of pressing the card's button).
- Download/install progress drawn along the task map's line.
- Rows of a full card lighting their node on a map.

## Rules

- Nothing outward-facing: no push, release, marketplace or AUR action (Uwe decides).
- Do not touch the GTK app in `/mnt/Data/Projects/asterism` or its plugin copy for this.
- No live tests that move the real mouse or open windows that grab the keyboard; widget tests and the isolated
  development build (`tools/flutter-dev build`, `.flutter-previews/`) only.
