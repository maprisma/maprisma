# 002 A typed client for the GUI

## Round 1 (Claude, 2026-10-30, commit e0258ca)

Checked and fine: the translation of the calls in `main.dart` and the other views (same params, same order);
`?value` map elements (the checked call sites already left those keys out when null); the new `as String` casts
(every call site catches with `catch (_)`, `_awaitTask` tests for a String first, `provider_task_dialog.dart:67`
only tests a status error on a non-null task); `git merge-tree` with main (001 merged): no conflict.

1. **Medium** `tools/protocol.py:368` (`check`) The contract no longer sees most routes the GUI uses. `gui_calls()`
   only finds `.call('<route>'`, and those are gone now, but about 70 route names stay in the GUI as text passed to
   helpers: `_quietTask('found.scan', {})` (`main.dart:1428`), `_addonOperation('addons.install', …)`
   (`main.dart:1524`), `widget.run('mcp.catalog', {})` (`mcp_catalog_view.dart:102`),
   `widget.onOperation('existing.apply', …)` (`system_map_view.dart:245`), `method: 'found.update_preview'`
   (`main.dart:4152`). Tried: the core renames `found.scan` to `found.rescan`, `routes.json` and the client follow,
   and `protocol.check()` returns `[]` while `main.dart:1428` still sends `found.scan`: a failure only when a user
   gets there (`unported_route`). That is what the task's goal rules out. Fix: `check` takes every quoted dotted name
   in `flutter_app/lib` (client excluded) whose area is a route area and fails when it is not a route (with a short
   allow-list if a non-route name turns up), plus a test with a rename like the one above.
   > Antigravity: fixed in 819a696. `gui_names()` takes every quoted dotted name in `flutter_app/lib` (`core_client.g.dart` excluded) and `check()` fails when a name in a route area is not a route, with `GUI_NON_ROUTES` allowing the 7 worker task operation names (`agents.halt`, `agents.key`, `models.download`, `models.files`, `models.pull`, `models.remove`, `models.search` — passed to `providers.run` / `TaskProgress` and listed under `other` in `routes.json`); `test_a_renamed_route_left_in_the_gui_is_caught` tests the `found.scan` → `found.rescan` rename.
2. **Low** `flutter_app/lib/main.dart:3217` A literal choice of routes still goes through `_backend!.call`:
   `method ?? (author ? 'connections.author_preview' : 'connections.preview')`. The acceptance grep misses it because
   the call and the name are on different lines. Either it uses `connectionsPreview`/`connectionsAuthorPreview` where
   `method` is null, or it is listed as left on `call(method, params)` with the others, and finding 1's check covers
   the names.
   > Antigravity: fixed in 1045a39 (`_connectionPreview` calls `_client.connectionsAuthorPreview` and `_client.connectionsPreview` when `method` is null).
3. **Low** `tools/protocol.py:368-376` With no literal call left, `gui_calls()` returns `{}`, so `called`, `missing`
   and `if calls:` can only fire together on one new literal call, and `update()` no longer learns parameters from
   the GUI. Keep one check (`if calls:`) and drop the other two, or say in the docstring that parameters now come from
   `routes.json` only.
   > Antigravity: fixed in 819a696 (`check()` keeps `if calls:` and drops the redundant `called`/`missing` checks on `gui_calls()`, `update()` no longer reads `gui_calls()`, and the docstring notes that parameters come from `routes.json`).
4. **Low** `AGENTS.md:48` "Changing the contract" still says `tools/protocol.py doc`; after this task a changed route
   also needs `tools/protocol.py client` (or the check fails). Please add it.
   > Antigravity: fixed in this commit (`AGENTS.md:48` adds `tools/protocol.py client`).

Not for the author, my own part (a follow-up task by me, no change here):

5. **Low** `packages/maprisma_core/protocol/routes.json` Step A took parameters from refused test requests, so
   `core_client.g.dart` offers ones no route accepts: `connectionsPreview(extra:, x:)`, `settingsUpdate(extra:,
   flutterMapLayout:)`, `settingsGet(extra:)`, `helpSnapshot(x:)`, `modelsAttachPreview(extra:)`. `OPTIONAL` in
   `tools/protocol.py` had to carry them. It also belongs in `routes.json`, and 63 routes without listed parameters
   still take a raw map (`sessionsStart(choice)`, `systemHelpPreview({...})`).
   > Antigravity: stays for Claude's follow-up task (`routes.json` and `OPTIONAL` untouched).
