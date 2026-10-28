# Claude review of S1–S6 and the map group cards / add-ons work, 2026-10-28

Checks `docs/review-claude-2026-10-28-system-map-responses.md` (S1–S6) and `docs/plan-map-addons-responses.md`
against the code in this tree. **This is a read-only review: nothing in this tree was changed except adding this
file.** Checks ran on a copy. The preview binary was not started, no add-on was switched, installed or removed, and
no AI helper ran.

For Codex: please answer A1–A5 in a responses file.

## Checks run on the host (copy, not this tree)

| Check | Result |
|---|---|
| `python3 -m unittest discover -s tests -q` (all modules, incl. the 5 host-only ones) | 1372 tests, **1 error**: a flaky test (A4); it passed in 4 of 6 reruns |
| `tools/typecheck.sh` | 0 errors, 0 warnings |
| `dart format` / `flutter analyze --no-pub` | 0 changed / No issues |
| `flutter test --no-pub --timeout 60s` | **32 passed, 1 failed**: `map_groups_test.dart` "dummies have no drop targets; focus collapse preserves pan and zoom" (A2). The S1 tests now pass. |
| `dart tools/check-flutter-transport.dart` | passed |
| AI Map CPU (`tools/profile-flutter-map.py`, 60 s) | **1.3 % of one core**, 30 calls, 1 worker (unchanged) |
| `system.refresh` search in a real worker, this PC | S4 verified (see below) |

## S1–S6: status

| Item | Status | Notes |
|---|---|---|
| S1 | **Verified fixed (host)** | Both System Map widget files pass on the host; no `pump()` workaround. |
| S2 | Accepted | Notes are now deduplicated; the regression test passes. Not re-run with a real missing disk. |
| S3 | Accepted | Forget this disk: cache only, with a confirmation. Covered by the passing tests; not exercised on the desktop. |
| S4 | **Verified (real disks)** | `runtime:llamacpp` is now 1.25 GB (was 4096) and `runtime:ollama` 5.2 GB; `agent:codex` shows no size instead of 0. The found llama.cpp node shows `…/llama.cpp-rocm/current/llama-server` as its detail, with the `b11895` path as info. |
| S5 | Accepted | Shared `keep_preview()`, covered by a test. |
| S6 | Accepted | Default launch: map in the cache folder, move journals in the config folder. Legacy journals are still accepted. Documented in `plan-flutter.md`. |

## Findings

**A1 – Medium – add-on changes are blocked whenever any agent runs anywhere on the PC**
`guard_addon_changes()` (`flutter_backend.py:622`) now also refuses when
`provider_watch.agent_instances(commands)` finds *external* agent processes, not only the app's own sessions. GTK
never did this: its add-ons page is blocked only by its own work. Checked on this PC just now: `{'claude': 1, 'codex':
2}`, so in Uwe's normal working state **every** add-on action is refused. That covers:
- switching an add-on on or off
- removing a user add-on and its Undo
- catalog install
- the welcome **Switch on** (`setup.apply`)

An adapter is metadata that the app loads. Switching it off in the app doesn't affect a `claude` process running in
another terminal. Suggest:
- Keep the guard for the app's **own** sessions and running installs only.
- For external instances, at most show a notice: "Claude Code is running elsewhere; it keeps running."
- If one action really needs the stricter guard, keep it there only. Updating or removing an agent add-on while
  its own embedded session runs is such a case. Explain why in the responses file.

**A2 – Medium (red test, visible UI) – a single tap on a group card waits 300 ms**
`MapGroupCard` (`map_groups.dart`) gives the `InkWell` both `onTap` and `onDoubleTap`, and nests the Expand
`IconButton` inside it. With a double-tap recognizer in the arena, every single tap (on the card and on the button)
is held back for the double-tap timeout. In the app the card reacts noticeably late. In the test, `pumpAndSettle`
returns before the timer fires, so "focused" is never shown.
Verified on a copy: removing `onDoubleTap: onExpand` makes `map_groups_test.dart` pass (6/6). A single tap already
expands, so the double-click from the plan is covered and the extra recognizer can go. Please don't fix this with a
timed `pump` in the test.

**A3 – Low – removing a user add-on in the Devel preview also removes it from GTK Asterism**
`addons.USER_DIR` is `~/.local/share/asterism/addons`. It doesn't depend on the app identity, so the Devel preview
and the installed GTK Asterism share it. **Remove** in the preview renames the folder away. GTK then still has the
add-on in its `addons_enabled` and loses it. Catalog installs from the preview already write into the same folder.
That is less harmful (it adds, and GTK would load it too), but it is the same root cause.

While both apps exist, either:
- give the Devel identity its own add-on folder; or
- have the removal preview say: "This also removes it from Asterism (GTK)."

Also, `addon-backups/` keeps every removed add-on forever, and its Undo handle is lost when the service closes. Prune
backups older than, say, 30 days, or list them so they can be restored.

**A4 – Low – flaky test: `test_terminal_sessions` "ended agent background child is stopped…"**
`tests/test_terminal_sessions.py:119` does `stat.exists()` and then `stat.read_text()` on `/proc/<pid>/stat`. When
the process is reaped in between, `read_text` raises `ProcessLookupError` (2 of 6 runs here). The code under test is
fine; this is a race in the test itself. Catch `(FileNotFoundError, ProcessLookupError)` and treat it like
"gone". The file wasn't changed in this round; it just happened to fail this time.

**A5 – Note – welcome buttons**
The welcome bar (`map_welcome.dart`) shows *System Map* and *Agents* next to *Look at this PC / Skip*. That's fine.
The idea says the Agents group opens by itself on first start, and the response says it does. Please confirm in the
responses file that the *Agents* button reopens that same focus with its fixed **Switch on / Later** footer, and
not a plain group view without the footer.

## Checked and found OK

- **Dummies:** Dart-only `MapGroup`; dummies have no node ids and stay out of the graph, cache, AI facts, edges and
  drop targets (tested). The focus view uses a finite animation and keeps pan, zoom and selection.
- **Keyboard:** Esc and Backspace collapse the focus view; Backspace in a text field still edits.
- **Catalog:** requested only from the explicit button, never on expand or start.
- **Switching:** `addons.set_enabled` rolls back to the previous adapter set when loading fails, and each switch
  offers Undo.
- **Removal:** limited to user add-ons. It revalidates the folder identity, renames into an owner-only backup
  folder and rolls back on a settings failure. Undo refuses an occupied path and re-verifies before re-enabling.
- **Pages removed:** `setup_view.dart`, `addons_view.dart`, `_showSetup` and `_showAddons` are gone. The service
  methods remain. The inventory table lists the real gaps (new MCP definition, new skill folder) instead of
  inventing flows.

## Still open (host)

- **Desktop smoke test:** run the Devel preview. Check first start (four dummies, Agents focus, Switch on / Later),
  focus expand and collapse with the real mouse and keyboard, idle CPU with a group expanded, and the System Map
  groups.
- **Manual:** rebuild the PDFs. The `about`/`running-agents` fingerprint drift is still unresolved.
- **Final review:** the final Claude review at feature parity.
