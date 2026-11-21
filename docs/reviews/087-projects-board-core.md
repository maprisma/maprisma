# Review: 087 Projects board, part 1 (board projection, core)

Reviewers: Codex and Antigravity (read-only), rounds until both say CLEAN. Artifacts:
`.flutter-previews/task-087-checks/`.

## Deviations from the plan
- The plan's "changed folder" is `folder_changed`: the saved path no longer resolves to itself
  (a symlink now points elsewhere); "missing folder" is `folder_missing`.
- `active` for a `ready` project is the execution's first member as `next`; awaiting review and
  drafts have none.
- The GUI board is task 088; the existing Project Center page keeps reading the old keys (the list
  is now ordered most urgent first).

## Checks
- `dart analyze` clean; `test/ai_project_center_test.dart` group "board projection (task 087)",
  `test/project_stage_test.dart`, the real-worker test in `test/feature_plugins_test.dart`.

## Round 1 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r1.txt`, `agy-review-r1.txt`. Related tests: core 684, widgets 544, 69
differential cases pass (Python: the known environment failures).

- **R1-1 (both): readiness did not use the launch's own checks** (a model of a local provider
  without its runtime; a runtime without a model; a binding's provider; a missing argv). *Fix:*
  member issues run `_memberOptions` and the argv check against the display snapshot and map the
  launch's error codes (`runtime_required`, `provider_unavailable`, …). Test: a local provider
  named after the approval blocks, Run is refused the same way, Ready again without a new approval.
- **R1-2 (both): folder stats on every summary poll and several per list; list and summary could
  disagree.** *Fix:* readiness (project and launch issues) is memoized by revision and snapshot
  version and computed only for approved ready projects in the summary; a list derives each
  project once and its summary from the same facts. Tests: five polls stat no folder, a new
  generation looks again once per project; list and summary counts agree.
- **R1-3 (both): the active assignment ignored stopping on a restored ready project, named a
  never-started member "stopped" and could point past the team.** *Fix:* ready with a held lock
  names none; a restart right after an assignment (`checkpoint_kind` `assignment`) names the next
  one `next`; positions outside the effective team give null. Tests.
- **R1-4 (agy): duplicate issues** for several members on one runtime. *Fix:* each code once. Test.
- **R1-5 (agy): unstable sort above 32 projects.** *Fix:* the id breaks ties. Test over all buckets.
- **R1-6 (agy): the summary note did not mention Approved · blocked**; the task text named a gone
  agent as blocked (it invalidates the approval). *Fix:* both corrected.
- **R1-7 (agy): tests.** Added: launch order of a team saved out of order, planning positions,
  the cases above; the test helper keeps the runner and the profile hook.

## Round 2 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r2.txt`, `agy-review-r2.txt`.

- **R2-1 (both): a member that already ran could show as "next"** (`checkpoint_kind` stays
  `assignment` while the following member runs). *Fix:* the evidence comes from the events: the
  latest of `assignment`, `assignment_done`, `setup_interrupted`; "next" only when an assignment
  ended and nothing was dispatched since. Tests: a real two-member run paused during the second
  member shows it stopped; event sequences for next and stopped; past the team gives null.
- **R2-2 (Codex): a template the dispatch refuses (`--`, `{session}`, a prompt inside a word)
  was approved and shown Ready.** *Fix:* one template check (`_validTemplate`) for approval and
  launch (`_members`), the dispatch and the board (`profile_invalid`). The template test now
  expects `plan` to refuse it at once. Test: such a template on the board.
- **R2-3 (both): one list could mix two snapshots at the 60-second edge.** *Fix:* a list and a
  summary each look at the snapshot once, at their first need, and keep that result to the end
  (at most one scan per answer); the readiness memo is cleared with each new snapshot. Test: the
  clock passing 60 s during a list reads profiles once (fails without).
- **R2-4 (agy): an interrupted team setup's lock named a planning member as stopping.** *Fix:*
  while the latest step is `setup_interrupted`, no member is named. Test.

## Round 3 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r3.txt`, `agy-review-r3.txt`.

- **R3-1 (both): a team setup writes the same `assignment` / `assignment_done` events**, so after
  a setup the event evidence was wrong (a stopped planning member shown as next, or the other way
  round). *Fix:* a field of its own, `assignment_started`: true when a team member is dispatched,
  false when it ended; team setup leaves it alone and saves and restores it with the checkpoint
  (`_setupReturnKeys`); the store accepts it absent or boolean, and a store from before it counts
  as stopped. While stopping, a team setup's own last event names no member. Tests: a real run
  paused at the reviewer, then a successful team setup: still stopped; next, stopped, legacy and
  past-the-team cases from the field.
- **R3-2 (both): `profile_invalid` was missing from the contract.** *Fix:* added to the note.
- **R3-3 (both): sorting tests.** *Fix:* all six buckets incl. Running, two in one bucket by time,
  and 40 projects with equal times ordered by id; a lock in a test is closed in `addTearDown`.

## Round 4 (Codex and agy, 2026-11-21): agy CLEAN, Codex NOT CLEAN

Reports: `codex-review-r4.txt`, `agy-review-r4.txt`.

- **R4-1 (Codex): a fresh attempt did not reset `assignment_started`**, so a restart before its
  first dispatch showed member 0 stopped. *Fix:* every fresh start sets it false (a new project, a
  save that resets the run, a restore without a saved checkpoint, an applied team proposal, a
  fresh plan or run); team setup leaves it alone and Continue keeps the checkpoint's value. Test:
  the state the dispatch sees after a fresh plan following a paused run is planning with no member
  started (fails without).

## Round 5 (Codex and agy, 2026-11-21): CLEAN

Reports: `codex-review-r5.txt`, `agy-review-r5.txt`. Both CLEAN: rounds 1–4 verified against the
code and the tests, no new finding.

**Task 087 review: CLEAN.**
