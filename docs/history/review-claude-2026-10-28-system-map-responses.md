# Responses to Claude’s System Map review — 2026-10-28

Review: `review-claude-2026-10-28-system-map.md`. All six findings are accepted.
Changes are confined to the repository; no live installation, service or model
folder was modified. Scratch move fixtures exercise file operations in tests.

## S1 — Progress animation during confirmation

Fixed in `system_map_view.dart`: the indeterminate indicator follows
`widget.busy` (backend operation state), while the broader `busy` state continues
to disable controls during a local confirmation. Waiting for consent no longer
creates a continuously animating progress bar. No `pumpAndSettle` was replaced
with `pump`; both affected tests explicitly check that the indicator is absent.
The new Forget confirmation has the same assertion.

Claude already verified this indicator change on the host. The updated widget
tests were attempted here but cannot start because the sandbox rejects their
server socket on `127.0.0.1`. Their final host run remains necessary.

## S2 — Duplicate unavailable-folder note

Fixed by deduplicating refresh notes after combining current observations with
missing-mount warnings. A regression fixture covers the case in which the
snapshot already contains the missing-folder note and an old mount is absent.

## S3 — Forget this disk

Missing disk nodes now offer **Forget this disk**, with a tooltip and a
confirmation explaining that files and settings stay. The backend accepts only a
saved missing-disk node ID, refuses present/reconnected disks and refuses the
operation while a System Map refresh or committed installation/move is running.

An atomic cache transaction removes that disk’s saved nodes, records, edges,
scan notices and health references. Independently mounted children remain.
Selection is cleared when necessary; AI findings referring to removed nodes
become general findings. Existing move-Undo references are retained. No scan,
settings write or user-file operation is performed by Forget. Configured missing
folders may reappear at the next metadata refresh, since settings are preserved.
A disk mounted again remains discoverable under the existing opt-in policy.

Tests cover missing/unknown/reconnected disks, nested mount preservation,
record/edge removal, general findings, unchanged settings/model bytes and the
review-before-send UI flow.

## S4 — Attributed sizes and launch paths

Search-only program measurement resolves symlinks and uses the existing bounded
wrapper-target detector before choosing the program folder. Scripts without an
attributable target have no displayed program size; zero program totals caused
by unavailable or already-counted shared files are also hidden. Folder totals
retain their existing behavior and the shared measurement deadline remains 3 s.

Both discovery insertion paths now share one node constructor. A found runtime
shows its `launch_path`, including `current`, as its displayed path/detail; its
resolved build path is separate information. Backend identity and validation
continue to use the resolved `path`, so presentation does not weaken apply checks.
Runtime information containing a build path is no longer suffixed with “Models”.
Tests cover a wrapper through a `current` symlink, an unattributable script and
separate launch/build node fields. No runtime was executed for size detection.

## S5 — Bounded Fix previews

`preview()` and `fix_preview()` now both use `keep_preview()`: expired previews
are discarded, the oldest is evicted when necessary, and at most eight remain
across all topics. The existing single-use and apply-time expiry checks remain.
A regression test mixes simplify and Fix previews, exceeds the limit and then
advances time beyond the TTL.

## S6 — Storage choice and compatibility

The location depends on whether an explicit settings path is supplied. Claude’s
host checks used a scratch profile; that stores `system-map.json` beside the
profile’s `settings.json`. A normal launch without an explicit path instead uses
`identity.cache_dir()/system-map.json`, respecting `XDG_CACHE_HOME`. This
rebuildable-map policy is retained and documented in `plan-flutter.md`.

New move journals are now always durable: `<settings-parent>/model-moves/`, using
the normal identity settings folder for a default launch. Undo still accepts old
default-profile journals in the cache location. Existing journals are not moved;
retain legacy journals until their moves are undone. Tests verify default map
versus journal locations, new-journal Undo after a cache clean and compatibility
with a legacy cache journal. Explicit scratch-profile behavior is unchanged.

## Validation

- Broader Python suite: **1,315 tests passed** in 44.4 s. The five previously
  identified host-only modules remain excluded in this sandbox:
  `test_add_mcp_test_button`, `test_back_keys`, `test_herdr_state`,
  `test_loopback_stream`, `test_review_fixes`. Claude’s previous host result was
  1,355 tests before these eight new Python regressions.
- Focused System Map/state/move/advice tests: **40 passed**.
- Pinned Pyright: **0 errors**, five pre-existing PyYAML-source warnings here.
- Flutter analysis: **No issues found**. Dart transport checks passed.
- Targeted Flutter widget execution: blocked before loading tests by the sandbox
  socket restriction; final host execution remains open.
- New UI strings and manual updates are present in all eight languages;
  existing source translation values are preserved. Manual structural tests pass.
- `git diff --check` passes.
- Fresh native Linux preview build: **passed**. Binary:
  `.flutter-previews/preview-ucny5_ec/flutter_app/build/linux/x64/release/bundle/asterism`.
  Built with the development identity; not installed or launched.

The AI Map scanner and its cadence are unchanged; Claude’s host measurement of
1.3% of one CPU core remains the latest host profile. Desktop smoke testing and
manual PDF regeneration remain host work under the previously documented sandbox
restrictions. The existing `about`/`running-agents` manual fingerprint drift is
outside S1–S6 and is not claimed fixed. No commit, sync, publication or AI call
was made.
