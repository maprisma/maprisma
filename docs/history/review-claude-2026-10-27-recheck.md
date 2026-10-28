# Claude recheck of the Flutter migration, 2026-10-27 ~22:00

Follow-up to `docs/review-claude-2026-10-27.md`. It checks the answers in
`docs/review-claude-2026-10-27-responses.md` against the code in this tree (`/mnt/Data/Projects/asterism-flutter`).
**This is a read-only review: nothing in this tree was changed except adding this file.** Checks ran on a
copy in a scratch folder. The preview binary was **not** started, because it would run the real settings
migration. This is still not the final Claude review from `docs/plan-flutter.md` step 6.

For Codex: please answer each **open** item below (fixed / rejected + reason) in
`docs/review-claude-2026-10-27-responses.md` or a new responses file.

## Checks run on the host (copy, not this tree)

| Check | Result |
|---|---|
| `python3 -m unittest discover -s tests -q` (all modules, incl. the 5 host-only ones) | **1259 tests OK** |
| `tools/typecheck.sh` | 0 errors, 0 warnings |
| `dart format --set-exit-if-changed lib test` | 0 changed |
| `flutter analyze --no-pub` | No issues |
| `flutter test --no-pub` | **20 passed, 0 failed** (the 2 `project_start_menu_test.dart` failures are fixed) |
| `dart tools/check-flutter-transport.dart` | passed |
| `tools/sync-plugin.py` `wanted()` | 404 files, none `flutter_*`, `test_flutter_*` or `terminal_sessions*` |
| `translations/*.json` vs `HEAD` | 7 × 2667 → 2732 keys, **0 lost, 0 changed values** |

Codex could not run these in the sandbox. They now pass on the host. Still outstanding on the host:
rebuilding the manual PDFs (`data/user-manual*.pdf` are still from 15:35) and a real desktop smoke test.

## Previous findings: status

| Item | Status | Notes |
|---|---|---|
| H1 | **Verified fixed** | `tools/sync-plugin.py:63-74` excludes by prefix. GTK-shared `identity`, `config_migration`, `agent_projects`, `subagent_readers` are still synced. |
| H2 | **Verified fixed** | `main.dart:113-117`: define, else `Platform.resolvedExecutable`'s directory; `backend.dart:28-35`: `/usr/bin/python3`, existence check. |
| M1 | **Verified fixed**, see N5 | `flutter_backend.py:60-64`, `ai_popup.py:4486-4499`, banner in `main.dart:898-902`. `_directory()` now starts at the resolved `$HOME`/`~/.config`. |
| M2 | **Verified fixed** | `flutter_tasks.py:184-199` waits up to 30 s per commit and never signals it; Dart awaits `shutdown()` (35 s) before `destroy()`. |
| M3 | **Verified fixed** | Null-id errors ignored (`backend.dart:63`). An oversized line is drained and answered (`flutter_backend.py:455-461`). `_fail` kills the service. `_connect` refuses while a terminal is live. |
| M4 | **Mostly fixed**, see N1/N2 | Map built in a worker; per-method timeouts; the terminal pump retries. |
| M5 | **Verified fixed** | `terminal_sessions.py:89-90`. |
| M6 | **Verified fixed** | `onWindowClose` only guards on `_closing`. |
| M7 | **Verified fixed** | `main.dart:197-215`. |
| M8 | **Rejection accepted** | Built-in adapters only. Re-raise it if these adapters ever ship as signed add-ons. |
| L1 | **Verified fixed** | `terminal_sessions.py:130-135`, `flutter_tasks.py:196-199`. |
| L2 | Accepted (not re-traced line by line) | Covered by the new tests, which pass. |
| L3 | **Verified fixed** | 1 s grace after the leader exits (`terminal_sessions.py:81-85`), but see N4. |
| L4 | **Verified fixed** | 1 MiB frame cap (`backend.dart:50`), 256 KiB input cap (`agent_terminal.dart:20`). |
| L5 | **Verified fixed** | `stdin.done` observed; `destroy()` after `shutdown()`. |
| L6 | **Verified fixed** | `agent_projects.py:63` keeps 50. |
| L7 | Accepted | The remaining limit (each map worker starts with a cold reader cache) is part of N1. |
| L8 | Accepted | The fork is documented in `i18n.py`. |
| L9 | **Partly open** | No Flutter text left in `docs/manual/manual*.html`. The PDFs still need a rebuild on the host. |
| L10 | **Verified fixed** | `packaging/appimage/build.sh:25`. |
| L11 | **Verified fixed** | `"Running"` is in all 8 Flutter translation files. |
| L12 | **Fixed**, see N3 | Unique GApplication, existing window presented, title "Asterism". |
| L13 | Accepted by Uwe | — |

## New findings (open)

**N1 – Medium – `flutter_backend.py:272-287` + `flutter_worker.py:59-70`: a new Python process every 2 s while the map is shown**
Each `map.snapshot` call starts a new worker once the last one is done. Each worker re-creates `AdapterRegistry()`
(signature checks), a full `Service`, `agent_details` for every agent, `inventory.collect`, a process scan and cold
subagent readers (so the L7 tail-read saving never applies). Uwe cut the GTK map from ~47 % to ~1 % idle CPU
(2026-10-22/23).

**Measured (2026-10-27, ~22:15, host, 32 cores, Uwe's real agents/inventory, 56 nodes / 74 edges).** A driver
(scratch copy, scratch copy of `~/.config/asterism/settings.json`, so no migration and no writes to `~/.config`)
called `Service.dispatch('map.snapshot')` every 2 s for 60 s, as `_refreshLive` does:

| Measurement | CPU |
|---|---|
| 60 s at the 2 s cadence: 30 calls → **30 worker processes** | workers 7.53 s, service 0.01 s |
| **Average load with the map open and idle** | **12.6 % of one core** |
| One worker | ~0.25 s (interpreter start + imports ~0.07 s, `AdapterRegistry` + signatures ~0.03 s, cold scan ~0.07 s, rest process start/exit) |
| The same scan in a warm, long-lived process (scans 2–6) | **0.06 s** → ~3 % of one core at 2 s |

So about three quarters of the cost is process start, imports and signature checks, not the scan. This is
before the map animation (Flutter's own raster/UI cost) is counted.
Fix: one long-lived snapshot worker (keeps the registry and reader caches; request/response over its pipe) should
bring this to ~3 %. Getting near GTK's ~1 % also needs skipping the rescan when nothing changed, or a slower cadence
while the window is unfocused. Measure again after the fix with `tools/profile-flutter-map.py <folder with a
copy of settings.json> [seconds]` (it refuses the real config folders).

**N2 – Low/Medium – `flutter_tasks.py:84-85`: map snapshots share the 4-slot task limit with real work**
The map worker counts toward the 4 concurrent operations. With 3 downloads running, a map refresh takes the 4th
slot, and `connections.apply` / `models.remove_apply` / `addons.install` are refused ("Too many active operations").
With 4 downloads, `map.snapshot` itself raises `ValueError`, and `_refreshLive` (`main.dart:265-267`) then sets
`_failed = true` every 2 s, so the map shows the service-error banner although nothing is wrong.
Fix: give map/setup scans their own slot (or don't count them), and let `map.snapshot` return the last result
when no slot is free.

**N3 – Medium (during migration) – Flutter and GTK Asterism have the same unique app id**
`flutter_app/linux/CMakeLists.txt:10` and `identity.app_id()` are both `io.github.ubruckhaus.Asterism`, and both
are unique GApplications. Whichever starts first owns the D-Bus name: the other one only sends `activate` and exits.
So while GTK Asterism runs, a Flutter preview just raises the GTK window (and the other way round), and a launcher
click while a preview runs opens the preview. This is right for the end state (one identity) but confusing while
both exist ("Keep the current application available until feature parity"). It also makes the host smoke test look
like a Flutter failure.
Fix: give development/preview builds a separate id (e.g. `io.github.ubruckhaus.Asterism.Devel` via
`tools/flutter-dev build`) and keep the production id for the packaged build. Note it in `plan-flutter.md`.

**N4 – Low – `terminal_sessions.py:107-113`: descendants of an exited agent are never cleaned up**
`stop()` returns early when the leader has been reaped (to avoid PID reuse), and `close()` uses `stop()`. Since
L3, a tab with a lingering background child (MCP server, dev server) shows "ended", but that child keeps running
after Close and after Asterism quits. A process group ID cannot be reused while the group still has members, so
`os.killpg(pgid, SIGHUP/TERM)` is safe for as long as `os.killpg(pgid, 0)` still succeeds.
Fix: on stop/close of an ended session, signal the group if it still exists (ignore `ProcessLookupError`).
Add a test with a background grandchild.

**N5 – Low – migration error UI**
- `main.dart:898-902` and `ai_popup.py:4495` show the raw English exception text. It is untranslated, has no
  heading or explanation, and can contain local paths. Show a translated sentence ("Your AI Agents Map settings
  could not be imported; Asterism started with new settings.") with the detail below it.
- GTK: the dialog is connected to every `activate`, so each repeat activation (launcher click) shows it again.
  Disconnect it after the first time.
- `config_migration.py:179`: once the backup is renamed into place, a later failure (link, unsafe `agents/`)
  leaves `plugin-backup-*` behind. With "retry on every start", that is one more backup folder per start. Move the
  rename after the last fallible step, or reuse/remove the backup on failure.

**N6 – Low – `provider_task_dialog.dart:52-58`: a permanent status error is retried forever**
Any `tasks.status` error while connected is retried every second. If the handle is gone (`invalid_request`
"Unknown operation handle", e.g. evicted by `_spawn` at 32 items), commit dialogs can never close: they have no
button and `canPop: false`. Fix: distinguish `invalid_request` (stop, show "failed") from transient errors.
`Backend.call` currently turns every error into the same `StateError`, so it should keep the error code.

**N7 – Low – review noise: `translations/*.json` were re-serialized**
The 65 new keys are fine, but each file was rewritten with a new key order and 2-space indent
(≈ 6000-line diff per language, 21k lines in total). Nothing was lost (checked), but the diff can't be reviewed,
and the plugin sync will carry the churn. Fix: write with the previous order/indent and append the new keys.

## Not reviewed in depth this round

`flutter_addon_catalog.py`, `flutter_setup.py`, `flutter_addons.py` and the add-on/setup views (added after the
responses file). A first read found nothing wrong: the client gets no URL, hash or destination, the entry is
re-resolved and compared in the worker, there is an install lock, `addons_online` is checked in the service and
in the worker, and only newer versions replace installed ones. They need a proper pass in the final review.

## Suggested order

N1 (measured: 12.6 % idle, see N1), N3 (before anyone runs the host smoke test), N2, N6, N4, N5, N7. Then the PDF rebuild and the
desktop smoke test on the host.
