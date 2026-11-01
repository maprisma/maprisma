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
