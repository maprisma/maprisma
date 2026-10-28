# Claude review of the Flutter migration (interim), 2026-10-27 ~21:15

Requested by Uwe while the migration is in progress. **Read-only review: nothing in this tree
was changed except adding this file.** Scope: all uncommitted changes in
`/home/uwe/Work/asterism-project-start` (49 modified files, new `flutter_*.py`, `terminal_sessions.py`,
`config_migration.py`, `identity.py`, `agent_projects.py`, `subagent_readers.py`, `flutter_app/`, tools).
This is not the "final Claude review" from `docs/plan-flutter.md` step 6; that one is still pending.

For each finding: file:line, what goes wrong, suggested fix. Findings marked *(verified)* were
re-checked by hand in the code; the others come from a careful read and are believed correct,
*unverified* ones are explicitly marked. Please answer each item (fixed / rejected + reason) in
your update notes, so the next review can check them off.

## Checks run on the host (on a copy in a scratch folder, not in this tree)

| Check | Result |
|---|---|
| `python3 -m unittest discover -s tests -q` (**all** modules, incl. the 5 the sandbox excluded) | **1219 tests OK** |
| `tools/typecheck.sh` | 0 errors, 0 warnings |
| `dart format --set-exit-if-changed lib test` | 0 changed |
| `flutter analyze --no-pub` | No issues |
| `flutter test --no-pub` (first run on a real host) | **13 passed, 2 failed** |

The 2 failures are both in `flutter_app/test/project_start_menu_test.dart` ("Start works without history
or a pin", outside=false/true): `started` is null. Cause: the test, not the app. `MenuItemButton`
calls `onPressed` after the menu-close frame. Adding `await tester.pumpAndSettle();` after the second
`tester.tap(...)` (before `expect`) makes both pass (verified on the copy). The preview binary was
**not** started (it would run the real settings migration on Uwe's config).

## High

**H1 – `tools/sync-plugin.py:34,63-67`: the whole Flutter service would be synced into the Omarchy plugin** *(verified)*
`wanted()` copies every `*.py` not in `ASTERISM_ONLY` (only the 4 add-on modules). So `flutter_backend.py`,
`flutter_worker.py`, `flutter_tasks.py`, `flutter_providers.py`, `flutter_connections.py`, `flutter_removals.py`,
`flutter_addons.py`, `flutter_activity.py`, `flutter_plan_wire.py` and the `tests/test_flutter_*.py` go to the plugin.
`flutter_addons.py:9-10` imports `addon_api`/`addons`, which the plugin does not have → ImportError, and the
copied Flutter tests fail there (they don't match `ADDON_IMPORT`). It would also hand the marketplace reviewer
a large unreviewed surface (stdin service, model removal) on the next plugin update.
Fix: exclude `flutter_*.py` and `tests/test_flutter_*.py` by pattern (also `terminal_sessions.py` etc. if only
Flutter uses them) and add a sync test that imports every synced module without `addons.py` present.

**H2 – `flutter_app/lib/main.dart:105-108` + `backend.dart:28-35`: service script resolved from the current directory** *(verified)*
Without `--dart-define=ASTERISM_SOURCE=…` the root is `Directory.current.parent.path`, and
`python3 <root>/flutter_backend.py` is run. A plain `flutter build linux` (the README's "initial executable")
started from a terminal in `~/Downloads/x/sub` runs `~/Downloads/x/flutter_backend.py`: arbitrary code
from wherever the user happens to be. From a launcher (cwd `$HOME`) it looks for `/home/flutter_backend.py`.
Fix: never use cwd. Use the define, else a path relative to `Platform.resolvedExecutable` (the bundle), else fail.
Also consider an absolute interpreter (`/usr/bin/python3`) rather than PATH lookup.

## Medium

**M1 – a failed settings migration stops both apps from starting, on every start, without a visible message** *(verified for the service)*
`flutter_backend.py:55` calls `config_migration.migrate()` unguarded in `initialize()`. `ai_popup.py:4483-4488`
does the same for GTK and returns 1 (only stderr). `config_migration.py:44-46,66-68,136,224-249,268-272,321-334`
raises when: the plugin's `settings.json` is invalid JSON; source/target is group- or other-writable (umask 002);
a profile in `agents/` is a symlink; a size limit is hit; **any ancestor of `$HOME`/`~/.config` is a symlink**
(`_directory()` walks from `/` with `O_NOFOLLOW`; e.g. `/home -> /var/home` on Fedora Atomic, or dotfile
managers that symlink `~/.config`). `settings.json` is never written, so it fails again forever; Flutter only
shows "Service disconnected". Each failed attempt also leaves another backup folder.
Fix: catch, log and continue without migration (or mark "import failed" once). Show the reason in the UI.
Walk with `O_NOFOLLOW` only below a resolved `$HOME`. Add a test "service starts although migrate() raises".

**M2 – `flutter_tasks.py:164-166` (`Tasks.close`) kills commit workers mid-write on window close** *(verified)*
`close()` calls `_close()` (SIGTERM→SIGKILL to the process group) for every task, including `connections.apply`
and `models.remove`, though `cancel()` correctly refuses those (`:157-158`). `connect.apply` writes several files
in sequence. Removal trashes paths one by one, so the result is half-applied config or a partial removal, and the
Undo handle dies with the service. This contradicts the plan/README ("cannot be cancelled mid-write").
On the Dart side, `provider_task_dialog.dart:66-68` turns one failed `tasks.status` poll into "failed" and
clears `_taskActive` (`main.dart:323-329`), so the close warning disappears while the worker still runs.
Fix: on close, wait (bounded, with a visible "finishing…" state) for commit tasks or let them run detached to
completion. Keep `_taskActive` until a definite final state. Add a shutdown test with a commit task.

**M3 – Refresh after a protocol error silently ends all running agents**
`backend.dart:12,54-56`: any malformed line or invalid UTF-8 calls `_fail` (marks closed, process and PTYs still
alive). Refresh → `_connect` (`main.dart:94-97,114,209-210`) disposes terminals and the old backend; the stdin
EOF ends the service and its agents, with no confirmation. Related: `flutter_backend.py:356-367` replies with
`"id": null` for errors before the id is parsed, and `backend.dart:40-46` treats that as a protocol violation
(→ `_fail`). Also `flutter_backend.py:358,377-381`: one request over 64 KiB makes `serve()` return and the
`finally` kills every PTY session.
Fix: Dart ignores/logs null-id errors. The service discards an oversized line and answers `request_too_large`
instead of exiting. On a real protocol failure, kill the service explicitly and tell the user agents ended.
Ask before reconnecting while terminals are running.

**M4 – single-threaded service + one 20 s timeout + fatal terminal errors**
`map.snapshot` runs every 2 s (`main.dart:82`) and does `inventory.collect`, `agent_details` for every agent, a
process scan and the subagent readers in-process (`flutter_backend.py:230-249`). MCP/skills `connect.apply` is
also in-process (`flutter_connections.py:349`). Each terminal polls `sessions.read` every 40 ms over the same
pipe, so any slow call stalls all terminals. `backend.dart:76` uses one 20 s timeout for all methods.
`agent_terminal.dart:70-75` treats any terminal error as permanent (`failed`, timer cancelled, never retried).
Non-idempotent calls (`sessions.start`, `connections.apply`, `models.remove_apply`) can time out on the client and
still succeed. A late `sessions.start` is never added to `_terminals`, so the close confirmation does not count it.
Fix: move snapshot/activity into a worker or cache it. Use per-method timeouts. Retry/back off in the terminal
pump. Correlate late `sessions.start` results.

**M5 – `terminal_sessions.py:83-85`: input after the agent exits marks the tab "failed"** *(verified)*
`write()` raises `ValueError` once `poll()` is not None → `invalid_request` → Dart pump fatal. The last output
is never read and the tab never shows "ended". Fix: return `{'accepted': 0, 'ended': true}` instead of raising.

**M6 – Close request silently ignored while busy**: `main.dart:129` `if (_closing || (_busy && !_taskActive)) return;`.
`_busy` is true during the Subagents dialog, confirm dialogs and `_refresh` (up to 6 calls × 20 s), so with a hung
service the window can't be closed for minutes. Fix: never drop the close. Confirm, or queue it.

**M7 – Stop ends a running agent without confirmation**: `agent_terminal.dart:134-137`, `main.dart:708`, while
runtime stop / model unload do confirm (`providers_view.dart:111-116,213`). Fix: confirm when `!session.ended`.

**M8 – adapter compatibility (unverified)**: `adapters/codex.toml`, `copilot.toml`, `goose.toml` gain
`[subagents]` formats (`codex-rollouts`, `copilot-events`, `goose-db`) that older Asterism versions reject
(`adapter_data.py:254` raises AdapterError). If these ship as signed add-ons, Codex/Copilot/Goose disappear from
the map on older Asterism. Fix: raise the add-on's minimum app/API version, or make an unknown format a warning.

## Low

- **L1** `terminal_sessions.py:118,126-128` and `flutter_tasks.py:146`: `wait()` after SIGKILL can raise
  `TimeoutExpired` (D-state child). `Sessions.close()`/`Tasks.close()` only catch OSError, so cleanup aborts and
  the remaining sessions are left running. Catch `subprocess.TimeoutExpired` too.
- **L2** Handles popped before the operation (`flutter_removals.py:83`, `flutter_connections.py:340,368`): a queue
  rejection ("Too many active operations") or refused Undo loses the handle/Undo token. Unknown/expired handles
  surface as `operation_failed` instead of `invalid_request`. Pop only after success, or re-insert on failure.
- **L3** `terminal_sessions.py:80`: `ended` requires PTY EOF, so a background grandchild holding the slave
  (e.g. an MCP server) keeps the tab "running" forever although `exit_code` is set. Consider ended = exit_code
  set + short grace period.
- **L4** Dart side is not bounded although README/plan say "bounded": `LineSplitter` (`backend.dart:9`)
  buffers an endless line. `_input` (`agent_terminal.dart:13,29`) grows without limit while the PTY accepts 0
  bytes (big paste into a busy agent). Cap both.
- **L5** Shutdown: `onWindowClose` calls `windowManager.destroy()` right after `dispose` (`main.dart:166-167`), so
  the 2 s kill timer never fires and a busy service can be orphaned (unverified). Writes to a dead child's stdin
  (`backend.dart:68`) give an unhandled `stdin.done` error.
- **L6** `ai_core.py:205-208` / `agent_projects.py:58-64`: project history is never trimmed. Near the 256 KB
  settings limit `update_settings` raises on every save, and `settings_pages.save_setting` swallows it, so settings
  silently stop saving. Keep ~50 entries per agent.
- **L7** `subagent_readers.py:84-87,172-174`: the Copilot reader re-reads up to 4 MB of `events.jsonl` every time
  it changes (i.e. on every 2 s refresh of an active session). Read only the appended tail.
  `subagent_readers.py:53,212` return `[]` when an ancestor of the root is a symlink, which reads as "no activity"
  instead of "unsupported".
- **L8** `i18n.py:33-56` now imports `ai_core`. It was the shared copy from `~/Projects/omarchy-plugin-i18n`, and
  the next copy from the shared tool will silently revert the 64 KiB-truncation fix. Put the fix in the shared
  tool, or document the fork.
- **L9** `docs/manual/*.html`: the 8 languages are consistent, but `data/user-manual*.pdf` were not rebuilt. The
  Flutter preview paragraphs sit in the production manual's About section (plugin edition too) and describe a
  UI no user has. Keep them out until Flutter ships.
- **L10** `packaging/appimage/build.sh:24` copies all `*.py`, so the GTK AppImage now carries every `flutter_*.py`
  (dead weight until Flutter ships).
- **L11** i18n: key `'Running'` (`providers_view.dart:90`) is missing from all 8
  `flutter_app/assets/translations/*.json` *(verified)*.
- **L12** `setState` after `await` without `mounted` (`main.dart:290`, `:442`). The Linux runner uses
  `G_APPLICATION_NON_UNIQUE` (`linux/runner/my_application.cc:147`), so two instances can run on the same
  settings until the singleton exists. The header bar title is lowercase "asterism" (`my_application.cc:48,52`).
- **L13** Behaviour change to note for Uwe: `bin/asterism` and `AppRun` no longer force
  `ASTERISM_DESKTOP=generic`, so GTK Asterism on Omarchy now uses the Omarchy backend (theme, menu, window
  rules) with its own identity. Uwe's installed `~/.local/bin/asterism` is still the old script. The plugin and
  Asterism now have different PID files, so both can run at once.
  **Uwe (2026-10-27): the Omarchy integration is intended, no change needed.** Still open: whether the plugin
  and Asterism may run at the same time on the same machine (the thin-launcher plan makes this moot later).

## Test gaps (risky paths without a test)

Service starts although `migrate()` raises; shutdown while a commit worker runs; `sessions.write` after the
child exited; `TimeoutExpired` during cleanup; queue rejection after a popped handle; symlinked `$HOME`
ancestor (migration + readers); Dart client receiving a null-id error; map pan/zoom (tests only check that
`InteractiveViewer` exists); terminal input-ack/resize/failure; window-close confirmation; reconnect.
`backend_process_test.dart` covers only the dead-service path (correlation/malformed replies are covered by
`tools/check-flutter-transport.dart`).

## Checked and found OK

Bounded JSON-lines framing on the Python side. Single-use, expiring handles. Request/response correlation and
pending cleanup on timeout. stderr drained. No executable path, URL, download destination or argv from UI
data. Plans pass over an inherited private unlinked FD. PTY master/pipes CLOEXEC, only the plan FD inherited.
`auth.json` / `.credentials.json` are never read (migration excludes them explicitly). The migration never
writes the source, writes the private backup first and `settings.json` last, uses flock, and rolls back
created files. Identity/paths are correct for both editions. The new shared modules needed by GTK are synced,
and `test_identity_migration.py` is kept out of the plugin. No new agent/LLM names in core files beyond
reader format ids. All 7 translation JSONs gained the same 61 keys with matching placeholders. Removal goes
through preview + confirmation with "Remove permanently" wording for API deletion. AppImage version/symlink
handling is tested. The Runner keeps `APPLICATION_ID io.github.ubruckhaus.Asterism`. Dependencies are locked
(xterm 4.0.0, window_manager 0.5.2, file_selector 1.1.0, zmodem 0.0.6) from established publishers.

## Suggested order

H1, H2 first (small, and they protect the plugin and the user). Then M1, M2, M5, M3 (data loss, startup and
agent-killing paths). Then the test fix for `project_start_menu_test.dart` and the test gaps above.
