# Review 083 Handle routing follows each store's expiry

Branch: task/083-handle-expiry-routing (base f7f88a8, task 084). Reviewers: Codex and
Antigravity (read-only, headless). Reports: `.flutter-previews/task-083-checks/`.

## Design

- `HandleMap<V>` (core_tasks.dart): a `Map<String, V>` whose keys a store keeps as
  handles. Adding a key holds the handle; removing it (expiry, bound, use, `clear`)
  releases it. Every store that keeps issued handles uses it instead of a plain map
  (tasks, plans, connection Undo, previews, proposals, drafts, PTY sessions, choices,
  catalog previews …). Stores keep their own bounds and expiry; their API is
  unchanged.
- `newHandle()`: past `maxIssuedHandles` only handles no store holds are forgotten.
  If every handle is still held, the new one is refused (`too_many_handles`) instead
  of breaking a live one.
- A feature backend (`recordReleasedHandles`) reports released handles with each
  answer (`released`, at most 4096 per answer); the host stops routing them. The
  host's oldest-first eviction stays only as a memory bound (`maxOwnedHandles`,
  2 × the registry bound) for backends that do not report.

## Checks

Tests that failed on the 084 code: a kept handle outlives more than 65,536 later
handles; a handle its backend released routes no more. Further: bare/prefixed keys
and double holding; refusal when everything is held; the worker lists releases.
`handle_registry_test.dart` + `feature_plugins_test.dart`: 36 pass.

## Round 1 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r1.txt`, `agy-review-r1.txt`. `tools/test-changed`: core 626 and
widgets 155 pass; Python 7 parity failures: the known environment ones, and
`pty_sessions` only because the run's `&` made Python ignore SIGQUIT (passes in the
foreground).

- **R1-1 (both): a released handle stayed issued,** so a cached result revived its
  routing, sweeps reported it twice and frames could grow. *Fix:* the last release
  ends its provenance at once (a short retired list lets a store move a handle to
  another store). Tests: no revival through a cached result; move keeps it; listed
  once.
- **R1-2 (agy): the sweep scanned everything and could drop a fresh handle.** *Fix:*
  unkept handles are kept in issue order and only the oldest one makes room (O(1));
  refusal is O(1). Test: refusal and room again after a release.
- **R1-3 (Codex): releases only travelled with successful answers.** *Fix:* every
  answer, also an error, carries them, as many as fit under `maxResponse`; the host
  applies them per frame before the caller registers new handles. Test.
- **R1-4 (agy): a non-reporting backend could evict another feature's handles.**
  *Fix:* the host's memory bound evicts the feature's own oldest handle first. A
  backend cannot release another feature's handle (test).
- **R1-5 (agy): `released` with the `core-` prefix was not normalized.** Fixed.
- **R1-6 (agy, tests): shared registry state between tests.** *Fix:* each registry
  test starts from `resetHandlesForTest()`. Clearing stores on `dispose()` is not
  done: in the app a process has one service and ends with it.
- Found by the new test: a malformed `released` list was checked after the caller
  was taken off the pending list, so that call never completed. *Fix:* checked first.

Checks: `handle_registry_test.dart` + `feature_plugins_test.dart` 40 pass.

## Round 2 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r2.txt`, `agy-review-r2.txt`. All confirmed.

- **R2-1 (both): answers arriving together could revive a released handle.** Releases
  were applied in the reader, new handles only after the caller's await. *Fix:* both
  are applied in the reader, in arrival order (`onReleased`, then `onIssued` for
  non-control requests), before the caller resumes. Test: issue and release answers
  in one write.
- **R2-2 (both): a moved handle stayed queued as released, and reviving it could pass
  the bound.** *Fix:* pending releases are an ordered set; holding a handle again
  takes it off; a revival first makes room (oldest unkept handles), and eviction loops
  until one fits. Tests.
- **R2-3 (agy): with three features the host's bound could still evict a third
  feature's live handle, scanning all handles.** *Fix:* the host keeps handles per
  feature (oldest first); at its bound the feature holding the most handles loses its
  oldest one (O(features)).

Each new test that needs no new API failed on the round-1 code. Registry + feature
host tests: 43 pass.

## Round 3 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r3.txt`, `agy-review-r3.txt`. All confirmed.

- **R3-1 (both): a move into a full registry silently lost the handle's provenance,
  and its pending release was cancelled anyway.** *Fix:* reviving is all or nothing:
  room is made first, else `too_many_handles` and the store does not take it; a
  pending release is cancelled only for a handle that counts again. Test with every
  slot kept (failed on the round-2 code).
- **R3-2 (Codex): "evict from the feature with the most handles" could still evict a
  reporting feature's live handles.** *Fix:* the host's bound is per feature
  (`maxOwnedHandles`, twice a backend's own bound, for releases still on their way);
  a feature over it loses only its own oldest handle. Test with a small bound.
- **R3-3 (agy): a late answer after a confirmed stop could still enter handles.**
  *Fix:* `onIssued` takes nothing from a retired process.

Registry + feature host tests: 45 pass.

## Round 4 (Codex and agy, 2026-11-21): CLEAN

Reports: `codex-review-r4.txt`, `agy-review-r4.txt`. Both CLEAN: round 1–3 fixes
verified, all 22 issued-handle stores are `HandleMap`s (secondary indexes mirror a
primary store), no new finding.

**Task 083 review: CLEAN.**

Final `tools/test-changed` on the reviewed state: core 635 and widgets 155 pass;
Python: the known environment failures only (installers and model_removals
`KeyError: 'ollama'`, model_files timeout).
