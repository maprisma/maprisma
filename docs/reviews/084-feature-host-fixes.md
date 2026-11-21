# Review 084 Feature host fixes

Branch: task/084-feature-host-fixes (base 8671dab, task 082). Reviewers: Codex and
Antigravity (read-only, headless). Reports: `.flutter-previews/task-084-checks/`.

## Source: local /code-review of task 082 (9 candidates), verified

Codex and agy checked each candidate independently (`codex-verify.txt`,
`agy-verify.txt`); Claude checked them against the code.

| # | Candidate | Codex | agy | Decision |
|---|---|---|---|---|
| 1 | failed backend stays dead | partly (policy) | confirmed | fixed: restart after a pause, no replay, no embedded fallback |
| 2 | Ask AI misses host state | partly, wider | partly, wider | fixed: host context (catalog offers, updates, MCP check); map and add-ons reread |
| 3 | broken update breaks `features.list` | partly | partly | fixed listing and staging; no bundled fallback (plan: a rejected update surfaces) |
| 4 | linked data folder rejects updates | confirmed | confirmed | fixed with descriptor reads (also closes the check/read race) |
| 5 | GUI shutdown timeout too short | confirmed | confirmed | fixed: 180 s for `features.shutdown` and `@close` |
| 6 | `_closing` stays set after shutdown | not a bug | confirmed | kept: a confirmed shutdown is final (existing test); #5 removes the trigger |
| 7 | summary starts the Project Center | not a bug (indicator) | confirmed | agy's variant: not started while nothing is stored |
| 8 | setup request not dirty-tracked | not a bug | not a bug | no change (`onChanged` calls `_edited`) |
| 9 | supervisor crashes on bad input | confirmed | confirmed | fixed: all control reads guarded, lenient UTF-8 |
| + | a failed summary erases the counts (Codex) | | | fixed: last counts kept |
| + | `@close` capped at 60 s (agy) | | | fixed with #5 |

Not changed: Ask AI starts at app start through `map.smart_helpers` (agy, design);
`configCache` TTL vs `config_proposal` (agy) behaves the same when embedded.

## Checks

Each new regression test was run against the original code and failed: crash
restart, start retry, broken update listing, linked data folder (host); malformed
start, invalid UTF-8 after launch (supervisor); failed summary (window). With the
fixes: core `feature_plugins_test.dart` 22 pass, `project_supervisor_test.dart` 12
pass; widgets `feature_shutdown_window_test.dart` + `isolate_transport_test.dart` 9
pass.

## Round 1 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r1.txt`, `agy-review-r1.txt`. All findings confirmed in the code.

- **R1-1 (both, high): a failed backend was replaced before it had exited.** It could
  still be cleaning up (Project Center: holding its store), and shutdown/dispose no
  longer tracked it. *Fix:* the failed process stays tracked until its process
  exited; only then (and after the pause) is it replaced; after 1 min it is killed.
  Test: a backend that exits 1.5 s after SIGTERM is not replaced before.
- **R1-2 (both): handles of a dead process were still routed** and could start a
  replacement. *Fix:* its handles are dropped when it fails; a late result of a
  failed process registers nothing. Test: owner is null right after the crash.
- **R1-3 (Codex): a restart could turn a process-backed feature embedded.** *Fix:*
  a feature that ran as a process stays one (`feature_disconnected`). Test.
- **R1-4 (agy): the summary shortcut hid a failed or closing Project Center.**
  *Fix:* only taken when no process is tracked and the host is not closing. Test.
- **R1-5 (agy): the backoff count stayed after an answered error.** *Fix:* any
  answer (result or the feature's own error) resets it.
- **R1-6 (agy): the context went with every Ask AI call and had no bound.** *Fix:*
  only for `map.smart_*`; only the fields Ask AI reads; at most 16 KiB (catalog,
  then updates dropped first). Tests: a handle follow-up has no context; the bound.
- **R1-7 (both, tests): new supervisor tests leaked processes on failure;** the
  crash test depended on timing. *Fix:* teardown kills them; an injected clock.

Checks: core `feature_plugins_test.dart` + `project_supervisor_test.dart` 39 pass;
`tools/test-changed` before this round: all passed (core, 337 widget tests, Python).

## Round 2 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r2.txt`, `agy-review-r2.txt`. All confirmed.

- **R2-1 (Codex): an old backend's exit cleared its replacement's handles** (late
  @shutdown reply, replacement started before the old process exited). *Fix:* a
  late-confirmed backend gets EOF and is replaced only after it exited; its failure
  callback clears handles only while it is still the feature's process. Test: the
  replacement's handle survives the old process's later exit.
- **R2-2 (agy): the trimmed update facts lost the updater `command`,** so Ask AI's
  agent update fell back to a recipe. *Fix:* a bounded `command` list travels (the
  backend checks it again with `allowedUpdate`). Test.
- **R2-3 (agy): after a failed restart the feature listed as embedded and the summary
  shortcut applied.** *Fix:* the replacement command is found before the old entry is
  dropped; listing and `tracked` count a feature that ran as a process.
- **R2-4 (agy): local errors reset the backoff.** *Fix:* `request_too_large` and
  `feature_invalid_response` are not answers.
- **R2-5 (Codex, tests): supervisor teardown could leave the tree; the exit-order test
  used a real delay.** *Fix:* teardown closes the control pipe and waits (the
  supervisor stops its tree), then kills; the fixture exits on a release file (and
  when its test folder is gone, at most after 30 s). No fixture process outlives
  the tests.

Noted, not from this task: `ai_project_center_test.dart` "restart marks an active
durable record interrupted" failed once (`project_center_busy`) in the parallel
round-2 run; it passes alone (3/3) and its code is unchanged since 082.

Checks: core `feature_plugins_test.dart` + `project_supervisor_test.dart` 40 pass.

## Round 3 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r3.txt`, `agy-review-r3.txt`. `tools/test-changed`: all
passed (core 618, widgets 337, Python). All findings confirmed.

- **R3-1 (Codex): a late-confirmed backend that hangs on exit blocked the feature
  forever.** *Fix:* the same kill limit as for a failed one (1 min after its
  confirmation), then it is replaced. Test with an injected clock.
- **R3-2 (Codex): handles of a stopped generation could still be routed** before its
  exit was noticed. *Fix:* a confirmed stop drops its handles at once, and `owner()`
  never routes to a stopped, failed or exited process. Test.
- **R3-3 (agy): a late confirmation did not send EOF,** so a retried close failed for
  a backend that exits on EOF. *Fix:* EOF on every confirmation and on the retry path.
  Test with an `eof-exit` fixture.
- **R3-4 (agy): the update's executable (up to 128 MiB) was read before the signature
  check** (a round-1 regression). *Fix:* signature and manifest are checked between
  the reads, still through the pinned folder descriptor. Test with a sparse 130 MiB
  `plugin` and an invalid signature.

Each new test failed on the round-2 code. Core feature host + supervisor: 43 pass.

## Round 4 (Codex and agy, 2026-11-21)

Reports: `codex-review-r4.txt`, `agy-review-r4.txt`. `tools/test-changed`: all passed
(core 621, widgets 337, Python).

- **agy: CLEAN.** All round 1–3 fixes verified; lifecycle, context and supervisor
  re-checked.
- **Codex: no production defect.** One test finding: **R4-1** the two late-shutdown
  tests waited a fixed 2 s for the late confirmation. *Fix:* they wait (bounded,
  20 s) for the observable effect of the confirmation (its handles dropped).

## Round 5 (Codex and agy, 2026-11-21): CLEAN

Reports: `codex-review-r5.txt`, `agy-review-r5.txt`. Both CLEAN: R4-1 fixed, no
production change since round 4, no remaining defect.

**Task 084 review: CLEAN.**
