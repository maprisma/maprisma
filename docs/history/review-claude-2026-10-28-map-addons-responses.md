# Responses to Claude’s map add-on review — 2026-10-28

Review: `review-claude-2026-10-28-map-addons.md`. A1–A5 are accepted and addressed.

## A1 — External agents no longer block add-on management

`guard_addon_changes()` now checks app-owned sessions and committed installations
only. It does not query or gate on external processes. The frontend’s mutation
guard likewise derives from its owned terminal sessions, not map activity counts.
External agent activity remains visible on the AI Map and continues normally.
No additional external-process notice is required to proceed.

The stricter owned-session guard remains for switches, welcome batch apply,
install, removal and removal Undo: those sessions are owned by this service and
use its registered adapter/lifecycle state. Running installation/move commits
also retain their existing exclusion. Later in welcome remains usable because it
does not change adapter choices. Tests verify both guards and that an external
instance does not cause a process-detector query or block a switch.

## A2 — Immediate group activation

Removed `onDoubleTap` from `MapGroupCard`’s `InkWell`. The card and Expand button
use their normal tap activation without waiting for the double-tap timeout. A
double-click naturally opens the group on its first click. Keyboard activation
and collapse behavior are unchanged.

The existing `pumpAndSettle` regression is retained, with no timed-pump workaround.
Claude verified this precise change on a host copy; the updated tests here still
need a host run because the sandbox cannot create the Flutter test server socket.

## A3 — Shared-folder disclosure and bounded backup retention

The shared user add-on folder is intentionally retained for compatibility while
GTK and Flutter coexist. Removal previews now disclose **“This also removes it
from Asterism (GTK).”** in the confirmation. Catalog install/update confirmation
also states that it changes the add-ons used by GTK. The effect is shown before
the user approves; cancellation does not write, remove or prune anything.

A successful, confirmed removal performs best-effort retention cleanup in the
private `addon-backups/` folder. It examines at most 200 entries per removal and
only removes user-owned directories with the generated 32-hex backup names when
their latest mtime/ctime is older than 30 days. Using the newer metadata timestamp
protects legacy backups whose original folder mtime predates their removal.
Active in-memory Undo backups are always excluded, including the just-created
backup. Links, files, foreign-owned directories and unrelated names are skipped;
cleanup failure does not turn an already-committed removal into a reported error.

The cleanup policy is disclosed in the removal preview, all eight UI languages
and manuals. Undo remains available until the service closes; this change does
not introduce cross-restart restore handles. Tests cover disclosure, no cleanup
on preview, active-backup protection, age eligibility, fresh backups, unrelated
folders and links. All file-operation tests use temporary fixtures: no real user
add-on or backup was removed during this work.

## A4 — `/proc` race in terminal regression

The test now reads `/proc/<pid>/stat` directly and catches `FileNotFoundError` and
`ProcessLookupError`, treating either as the child being gone. It no longer makes
an `exists()` check followed by a racy read. A present process still must be a
zombie for the assertion to pass; unrelated read failures remain test failures.
The regression passed **12 consecutive executions** after this correction.
Production terminal process handling was not changed.

## A5 — Welcome’s Agents entry preserves the fixed footer

Confirmed from production wiring: `MapWelcome.onAgents` calls `_openGroups()` with
the default category 1. That method changes navigation/focus without clearing
`_welcome`. `_groupFocus()` therefore passes `welcome: _welcome && category == 1`,
and `MapAddonsFocus` renders the same fixed Switch on / Later footer. Only
finishing or postponing welcome clears `_welcome`; after that the group is a
normal management focus. Subsequent starts do not auto-enter welcome again.

A new widget regression composes the welcome entry and focus widgets, switches
away and back via Agents, and asserts that both footer controls are hit-testable
at the default test size. Production navigation was also inspected; no new
welcome state machine was introduced for this note.

## Verification

- Broader Python suite: **1,328 tests passed**, 44.4 s. As previously documented,
  five host-only modules are excluded here: `test_add_mcp_test_button`,
  `test_back_keys`, `test_herdr_state`, `test_loopback_stream`, `test_review_fixes`.
- Map add-on backend tests: **13 passed**. The terminal race regression separately
  passed **12/12** repeated executions.
- Pinned Pyright: **0 errors**, five pre-existing PyYAML-source warnings here.
- Flutter analysis: **No issues found**. Dart transport checks passed.
- Manual structure tests: **4 passed**; plugin sync-boundary tests: **5 passed**.
- All eight Flutter language catalogs are complete; existing source translation
  values are unchanged. New manual sections are fingerprinted. Existing
  `about`/`running-agents` fingerprint drift remains outside these corrections.
- Targeted Flutter test execution was attempted for group behavior and add-on
  confirmation. The sandbox denies the runner’s `127.0.0.1` socket before tests
  load. No host-green widget result is claimed from this environment.
- Native Linux preview: **build passed**, at
  `.flutter-previews/preview-cs7h8lf0/flutter_app/build/linux/x64/release/bundle/asterism`.
  Built with the development identity; not installed or launched.
- `git diff --check` passes.

The AI Map scanner and cadence are unchanged. Desktop smoke testing, expanded
idle-CPU measurement, final host widget execution and manual PDF rebuilding remain
host checks under the previously documented sandbox restrictions. Existing PDFs
were preserved. No live plugin sync, agent stop/start, AI request, package install,
credential-file read, commit or publication was performed.
