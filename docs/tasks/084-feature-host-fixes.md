# 084 Feature host fixes from the 082 code review

Author: Claude · Reviewer: Codex and Antigravity · Branch: task/084-feature-host-fixes

## Goal
Fix the verified findings of the local code review of task 082, so a failing or
updated feature backend, a linked data folder or a slow close cannot leave Reports,
Ask AI or the AI Project Center unusable, and Ask AI sees the same facts in its own
process as built into the app.

## Routes
None. The private host→feature frame gains an optional `context` object (host state
for Ask AI); it is never taken from a client.

## Core
- A crashed, hung or unstartable backend is started again on a later call after a
  pause (1 s, doubling per failure in a row, at most 1 min). The failed call is not
  replayed and its handles are dropped. A broken user update still surfaces its error.
- `features.list` never verifies, hashes or stages an update and never fails because
  of one; only a launch does.
- User updates are read through descriptors: the data folder may be behind a link,
  `feature-plugins/<id>` and its files may not; type and size are checked on what is
  read.
- Ask AI's backend gets the host's catalog offers (without preview tokens), the last
  update check and a manual MCP check, and rereads the saved System Map and add-ons
  for each request.
- `features.summary` does not start the AI Project Center while it has stored nothing.
- The project supervisor answers a malformed start line with `invalid_start` +
  `stopped`, and treats a failing control pipe as a lost controller (stops its tree).

## UI
- The GUI waits up to 180 s for `features.shutdown` and `@close` (the core's worst
  case is about 100 s).
- A failed summary keeps the last counts, so closing still asks before stopping
  running agents.
No new texts.

## Acceptance
Regression tests that fail without their fix: crash restart, start retry, broken
update listing, linked data folder, malformed start line, invalid UTF-8 after launch,
failed summary keeps the close question. Plus: host context reaches only Ask AI
without preview tokens; an empty Project Center is not started by the indicator.
Codex and agy review CLEAN.
