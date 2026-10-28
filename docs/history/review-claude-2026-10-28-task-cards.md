# Claude review — task cards (2026-10-28)

Scope: Codex's implementation of `docs/plan-task-cards.md` (see `docs/plan-task-cards-responses.md`), diffed against
the preview copy `.flutter-previews/preview-cs7h8lf0` (02:49, the state the plan was written on). Checks re-run
here: `flutter analyze` clean, `flutter test` 43 passed, `tests.test_flutter_task_focus` 5 passed.

The structure matches the plan (service `focus`, `focusGraph`, read-only `AgentMap` with anchors, `TaskHost`,
`TaskProgress` with a GlobalKey, reviews in cards, main map unmounted under a card). Findings, most severe first:

## 1. Medium — forced map scans on every task, twice

`_refresh()` now calls `_freshMap()` (`map.snapshot {'force': true}`, up to 10 s each) whenever a card or view is
open (`main.dart:1758`, `mapVisible || _card != null || _view != null`). `_runTask` awaits `_refresh()` before
it returns (`main.dart:246`), and `_providerOperation` (`:1497`) and `_removeModel` (`:1626`) refresh again.
So every Hugging Face search, file listing, `model.load`, download etc. waits for two forced full scans before
the result shows up. Before, the providers screen did no map scan at all. **Fix:** refresh once (in `_runTask`
or in the caller, not both); skip the forced scan for the data-only operations (`models.search`, `models.files`,
`addons.catalog`); scan only when a half card's task map needs the new graph.

## 2. Medium — two headers in every view card

`_viewHost` gives each view a card header (title + Back). But `ConnectionsView` (`connections_view.dart:36–55`),
`ProvidersView` (`providers_view.dart:54–66`), `FirstAgentView` (`first_agent_view.dart:44–60`) and
`MapFocus`/`MapAddonsFocus` still draw their own Back button and big title. `ModelBrowser` also keeps its own
title and close × and is still a fixed `SizedBox(width: 760, height: 620)` (`providers_view.dart:349`), so the
"full" card doesn't use its width. **Fix:** let the views drop their own header when hosted (a `hosted`/`showHeader`
flag, or move Undo/Refresh into the card's header actions), and let `ModelBrowser` fill the card.

## 3. Medium — the view under a card is unmounted, its state is lost

`main.dart:2161`: the view chain is only built when `_card == null`, so opening a review or progress card from
`ConnectionsView` (search text), `MapAddonsFocus` (the welcome's `selected`/`touched` choices,
`map_addons_focus.dart:57`) or `ProvidersView` throws their state away. After the card closes they come back
fresh. `ModelBrowser` is kept with `Offstage` — do the same for the view under the card (Offstage it while a
card is on top), not for the main map.

## 4. Low — ProvidersView is never a half card

`focus: _focusOf(_providers)` (`main.dart:2239`) reads a top-level `focus`, but `providers.snapshot` only gets
per-runtime `focus` (`flutter_backend.py:220–222`), and `ProvidersView` has no selection. It is always full; the
per-runtime focus is unused. Either use it (e.g. when the view was opened for one runtime) or drop the dead code
and make the table say "full".

## 5. Low — live updates stop while a result card or the model browser stays open

`_refreshLive` returns early when `_card != null || _browser != null` (`main.dart:602`), and the header's
Refresh/Map/Settings buttons are disabled for any card. A "Succeeded" card left open (it waits for Close) or a
long model-browsing session freezes running/working states. Pause only while a task runs or a review waits.

## 6. Low — task map: nodes at the top, lines meet the middle

The read-only canvas keeps the minimum height 650 (`agent_map.dart:169`). For a two-node focus the nodes sit at
y≈64–146, while the anchor curves end at mid-height (325) and the card's dot is at the card's middle. Use the
compact height (`rows * 106 + 170`) when `readOnly`, so the boxes and the dot line up.

## 7. Low — smaller points

- `_cardReview` already wraps itself in `_review` and each call site wraps it again: `_reviewDepth` counts 2 per
  review (harmless, but one wrapper is enough).
- `_installAddon` no longer reloads the catalog after an install or a failed install (the two
  `_loadAddonCatalog()` calls were removed); after success the user sees the "load catalog" state again
  instead of the updated list.
- The result card after `connections.apply` is built twice (in `_runTask`, then again by the caller once
  `_connectionUndo` is set) — the first one briefly shows no Undo. Pass the undo into `_runTask` or let the
  caller alone build the result card.

## Not checked

The look on a real desktop (themes, narrow window, the anchor lines). Only the analyzer, widget tests and the
code were checked; no build was launched.
