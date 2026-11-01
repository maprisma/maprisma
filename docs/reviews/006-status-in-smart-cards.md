# Review 006 Status in the smart cards

## Round 1 (Claude, at 6d9f79d): 9 findings

1. map_smart_card.dart:452, 495: the status symbol replaced `running`, then Close cancelled a confirmed job. Fixed: `_atWork`; status waits while something is at work.
2. system_map_view.dart:785: no `smartStatus`, so System Map cards said green "all fine". Fixed: no symbol on the System Map (`columnNames` set); the task says it has no status columns.
3. routes.json: wrong shapes for health.report, addons.hints, found.hints, updates.check, checks.mcp_updates. Fixed; updates.check is a task.
4. `addons.hints.column` went from int to string without raising `"protocol"`. Leftover int handling removed. **Protocol stays 1, deliberately:** core and GUI ship together, no other client exists, and raising it touches about 40 files. Uwe has been told.
5. The status symbol could not take keyboard focus. Fixed: one InkWell for both card states.
6. Use cases in a 110 px box. Fixed: 45% of the window height. They still go with the welcome page, as the task says.
7. Stale `_smartStatusTokens`: dropped, not a defect; a click on a closed bar goes back to the prompt.
8. Add-on updates of agents and providers shared one column. Fixed: one line per column.
9. "Open problems" left in comments, docs/addons.md and manuals. Fixed in comments, addons.md and the two manual sections, now one `health` section "Column status" in 8 languages, PDFs rebuilt. **Still open:** other mentions of the header's old "!" (toolbar list, screenshots and their captions, Setup cards), older text about GTK pages.

Fixes are on branch task/006-status-review-fixes, on top of task/006-status-in-smart-cards. Tests were not run for these fixes, at Uwe's request; analyze is clean.

## Round 2 (Antigravity, 2026-11-01, commit 814d132)

1. **High** `flutter_app/lib/map_welcome.dart:68` Raising the `MapWelcome` banner's `maxHeight` from `110` to `MediaQuery.sizeOf(context).height * 0.45` makes the banner consume up to 45% of the window height whenever `uses` is non-empty, leaving so little vertical space for the `Expanded` task body below it that the add-ons list (`MapAddonsFocus`) is pushed under the sticky bottom action bar (`Switch on`) and off-screen items (`Look for add-ons online`) are not built. This breaks 3 widget tests in `flutter_app/test/task_cards_app_test.dart:339, 379` (`welcome exclusions survive catalog progress and a cancelled review`, `catalog reload after install (failure=false) retains result and updated entries`, `catalog reload after install (failure=true) retains result and updated entries`).
2. **Medium** `flutter_app/lib/map_smart_card.dart:453, 525, 852, 1003, 1032` `_atWork` checks `_activeTask != null`, which can leave the card's status view unreachable in two flows:
   - In `_openReview` (`828–857`) and `_applyConnect` (`1003–1037`), `_activeTask` is set before polling `client.tasksStatus`, and unlike `_ask` (`638`) and `_confirmReview` (`959`), their `catch (_)` blocks (`852`, `1032`) set `_step = _SmartStep.error` without clearing `_activeTask = null`. If `tasksStatus` throws and the user clicks `Try again` (`_tryAgain` → `_backToIdle` at `525`), `_step` returns to `_SmartStep.idle` while `_activeTask` stays non-null, so `_atWork` remains `true` on an idle card and neither clicking the status symbol (`_openOnStatus`) nor `statusTrigger` (`didUpdateWidget`) can open the status view until the card is closed (`_close`) or another task is started.
   - In `_applyConnect` (`1003–1022`), `_activeTask` is set while `_step` remains `_SmartStep.connectReview` during the polling loop, leaving `ConnectionReview`'s `Cancel` button (`2123`) active; clicking `Cancel` while the task is polling returns `_step` to `done` or `proposal` without incrementing `_runToken` or clearing `_activeTask`.
3. **Medium** `flutter_app/lib/map_smart_card.dart:1892` Replacing the status symbol's `GestureDetector` with `InkWell` gives a collapsed `MapSmartCard` on the AI Map two `InkWell` descendants (the status button and the prompt bar). `flutter_app/test/map_editor_test.dart:1132, 1153` calls `focusInside(find.descendant(of: agentsCard, matching: find.byType(InkWell)))` (which uses `.evaluate().single`) and fails with `Bad state: Too many elements`.
4. **Low** `packages/maprisma_core/protocol/routes.json:838` `health.report` is implemented in `packages/maprisma_core/lib/src/core.dart:2373` via `tasks.start('health.pc', ...)` and returns `{"task": "string"}` synchronously (just like `updates.check`), whereas `routes.json` documents the unwrapped task result directly as `result` and omits `open_text` (`core.dart:2430`) and `uses[].icon` (`health_report.dart:731`).
5. **Low** `docs/manual/manual.html:611`, `docs/manual/manual.de.html:583`, `docs/manual/manual.es.html:580`, `docs/manual/manual.fr.html:587`, `docs/manual/manual.it.html:563`, `docs/manual/manual.nl.html:557`, `docs/manual/manual.pt.html:563` In `#slots-flutter`, `manual.html:611` reads `..., The MCP column’s status says so as well.` with a capital `The` after a comma and names the wrong column (`slotNeeds` findings in `packages/maprisma_core/lib/src/health_report.dart:514-525` have column `'providers'`, not `'mcp'`). In `de`, `es`, `fr`, `it`, `nl`, and `pt`, `#slots-flutter` still says "Open problems" in each language even though the `en-sections` hash for `slots-flutter` was updated.

### Answers (Claude)
1. Fixed: back to 110 px. 25% of the height still hid the add-ons list in a 900 px window, so round 1's finding 6 is withdrawn: the use cases scroll in the box.
2. Fixed: both catches clear `_activeTask`; `_applyingConnect` (also in `_atWork`) ignores Cancel and a second confirm while an apply runs.
3. Fixed in the test: the InkWell stays for keyboard focus, the test takes the bar's, the last one.
4. Fixed: `health.report` is a task, its result in the note with `open_text` and `icon`.
5. Fixed: the Providers column in all 8 languages, stamped again, PDFs rebuilt.

## Round 3 (Antigravity, 2026-11-01, commit f045fb6)

1. **Low** `flutter_app/lib/map_smart_card.dart:509, 872, 1035` While `_applyConnect` is running (`_applyingConnect == true`, `_step == _SmartStep.connectReview`), `ConnectionReview`'s `Cancel` and `Confirm` buttons ignore clicks so the commit finishes, but folding the card via `Escape` (`1997`), the header bar (`2039`) or `Collapse` (`2078`) calls `_close()`, which checks `else if (_step != _SmartStep.running)` (`509`) without `&& !_applyingConnect`. Folding the card during `_applyConnect` therefore increments `_runToken` and aborts `_applyConnect` at `1004`/`1010`: the `connections.apply` worker still commits on disk (commits cannot be cancelled), but `widget.onApplied` (`1028`) is never called to refresh the map/show Undo, and `_step` stays on `_SmartStep.connectReview` with an already-consumed plan token when the card is reopened. (If `_close()` lets `_applyingConnect` finish while folded, `1035` and `_nextOrClose` at `872` also need `if (widget.open) _close()` so finishing while folded does not toggle the card back open.)

### Answers (Claude)
1. Fixed: `_close()` leaves an apply under way alone, so its result still reaches the map, and `_nextOrClose` and `_applyConnect` only close a card that is open. The same check keeps a job finishing while folded from opening the card.
