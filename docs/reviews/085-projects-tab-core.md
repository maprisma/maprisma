# Review 085 Projects tab, part 1: core contract

Branch: task/085-projects-tab-core (base 21b936a). Reviewers: Codex and Antigravity (read-only,
headless). Reports: `.flutter-previews/task-085-checks/`.

## Deviation from the plan (decided while implementing)

The plan raised the protocol to 3 because `attention` would stop counting a store fault. Protocol 2
is hard-coded by many reference and parity tests, so the change is made compatible instead:
`attention` keeps its meaning and the new `attention_projects` counts interrupted and failed
projects only (the Attention bucket), with the store fault in `error`. Same information, no
incompatible change. The AI Project Center backend announces API 2 and the capability `summary2`.

## Checks

New tests: `project_stage_test.dart` (8: every status × phase, setup return and fallback, stopped
setup, stopping precedence, reconciliation as a second line, approval cases, completed stays
finished), summary group in `ai_project_center_test.dart` (3: buckets once each, display cache
within a generation then invalid after it grew, no profile read for drafts),
`feature_plugins_test.dart` API group (6: api 1 without capabilities, api 2 with, out-of-range and
malformed refused, embedded values, refresh grows the generation and is not forwarded, the
no-project summary fields), `main_tab_setting_test.dart` (1).
(Signed updates are tested since round 1 with a temporary key, see R1-9.)

## Round 1 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r1.txt`, `agy-review-r1.txt`. All confirmed.

- **R1-1 (Codex P1): the feature build wrote API 1 into every manifest,** so a signed Project
  Center update would be refused by its own `@hello`. *Fix:* `tools/build-feature-plugins.py`
  reads each feature's API from `featureApiOwn` in the core.
- **R1-2 (both): the project view and later assignment starts bypassed the display cache.**
  *Fix:* `_view` uses the shared display snapshot (memoized by revision and snapshot version);
  every assignment start installs its fresh snapshot as the display snapshot (also when refused).
  Tests: 60-second age with an injected clock; a refused run of one project refreshes another's.
- **R1-3 (both): the discovery generation missed map refreshes, Undo and provider actions, and grew
  before asynchronous work finished.** *Fix:* it grows **after** success for a fixed list of
  changing routes from `routes.json` (Undo, provider and installer actions included) and for a
  forced `map.snapshot`; worker tasks grow it when they end. Tests: the list matches
  `routes.json`; a refused request does not grow it.
- **R1-4 (Codex): `list` lacked `api` and `capabilities`.** *Fix:* the host adds them (process and
  embedded). Tests through an api-1 and an api-2 backend.
- **R1-5 (Codex): an explicit `capabilities: null` passed.** *Fix:* the key's presence is checked
  separately; null and empty names are refused. Tests.
- **R1-6 (agy): a stopping project also counted in `waiting` and `attention`.** *Fix:* both use
  the buckets (stopping only in `pausing`). Test with a held run lock.
- **R1-7 (agy): `main.dart` compared the summary shallowly** (a rebuild every 2 s with
  `by_agent`). *Fix:* `sameMapJson`.
- **R1-8 (agy): the bucket code was `needsYou`.** *Fix:* snake case `needs_you`.
- **R1-9 (agy): acceptance cases untested.** *Fix:* `FeaturePluginHost(trustedKey:)` for tests;
  signed api-1 and api-2 updates, a manifest/`@hello` mismatch, api-1 summary and list meta,
  refresh reaching the Project Center, `by_agent` across both teams, `main_tab` through the routes
  and back to null. Python reference `UI_SETTINGS` gets `main_tab` (the differential check had
  failed on it; 69 cases pass).

Note after round 1: three existing tests (`project views report approval validity…`,
`model catalog and served-model refreshes…`, `renewing approval keeps a paused checkpoint…`)
changed profiles outside Maprisma and expected the project view to see it at once. Since R1-2 the
view follows the shared display snapshot (as the plan says), so the tests now grow the discovery
generation after the outside change, as the host does on F5 or on a change made through Maprisma.
Launches still check a fresh snapshot.

## Round 2 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r2.txt`, `agy-review-r2.txt`. Related tests after round 1: three existing
tests expected the old immediate view (see the note above); fixed.

- **R2-1 (agy): a failing profile or runtime scan escaped the summary and the view.** *Fix:* the
  rebuild is guarded; on an error approval reads as not valid and the old snapshot stays.
- **R2-2 (both): a clock set back kept the snapshot.** *Fix:* a timestamp in the future also forces
  a rebuild.
- **R2-3 (both): worker tasks that ended without a result (crash, oversized output) never
  signalled.** *Fix:* `onEnded` once at the end of every task run. Test with a crashing worker.
- **R2-4 (both): tasks run by the Ask AI backend and `features.call` to Ask AI did not grow the
  host's generation.** *Fix:* the host grows it once when a feature-owned `tasks.status` first
  reports an end, and after a successful Ask AI call of a discovery route. Test.
- **R2-5 (agy): `refresh: true` grew the generation for an invalid call.** *Fix:* only after the
  plugin and operation are valid.
- **R2-6 (Codex, agy): the refresh test did not pass the real worker.** *Fix:* a test through the
  real Project Center worker (`bin/maprisma-feature.dart`); the summary now names the generation
  it was made with, which the test compares.
- **R2-7 (agy): untested store fault and later assignment starts; a cached no-op assertion.**
  *Fix:* tests with a real write failure (fault in `error` only) and with a reviewer's start
  refreshing another project; the catalog test reads a fresh snapshot.
- **R2-8 (agy, small):** setup only computes approval when it started from a state where it
  matters; capability count checked first.

## Round 3 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r3.txt`, `agy-review-r3.txt`.

- **R3-1 (both): a failing scan was retried for every approved project and poll.** *Fix:* a
  failed rebuild is remembered for its generation and retried at most every 10 seconds (a refresh
  grows the generation and retries at once). Test: three approved projects, one scan read, none
  within 10 s, one after.
- **R3-2 (Codex): normal map refreshes did not grow the generation.** *Fix:* every `map.snapshot`
  grows it (the plan pauses map polling while the Projects tab shows).
- **R3-3 (both): the real-worker test only compared a diagnostic number.** *Fix:* the
  `generation` field is gone from the summary and `routes.json` again (it changed on every map
  drag and would rebuild the GUI); the test now goes through the real Project Center worker with
  a stand-in agent on `PATH`: approved and Ready, the agent removed, the cache still says Ready,
  `refresh: true` gives Needs you and `get` reports the approval invalid. (`PATH` holds only the
  stand-in: this PC has a real `/usr/bin/claude`.)
- **R3-4 (agy): the clock guard and the failing-scan path had no tests.** Added (see R3-1; a clock
  set back rebuilds).
- Leftover test folder: none in the tree.

## Round 4 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r4.txt`, `agy-review-r4.txt`.

- **R4-1 (both): a remembered scan failure suppressed the rebuild after an explicit
  invalidation** (an approval right after the failure showed as invalid). *Fix:* dropping or
  installing the display snapshot clears the failure marker. Test: failure, recovery, approval
  within 10 s shows as valid.
- **R4-2 (agy): growing on every `map.snapshot` also grew on polls and no-op ticks**, rebuilding
  the cache every few seconds. *Fix:* removed; a finished agents or inventory scan
  (`reads.onInventory`) grows the generation only when the agents' and runtimes' facts (installed,
  version, running, models) differ from the last scan. Test.
- **R4-3 (Codex): `refresh: null` passed.** *Fix:* the key's presence and type are checked. Test.

## Round 5 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r5.txt`, `agy-review-r5.txt`. Both found the same point.

- **R5-1 (both): the scan's fingerprint missed a runtime's port, its server switched off and its
  bound agents,** which the approval and the runtime facts read. *Fix:* the fingerprint encodes
  each agent's command, installed, version and source and each runtime's key, installed, running,
  server off, address, service, models and bound agents (`jsonEncode`), not what changes while
  agents merely work (active agents). Test: another port, the server off and another bound agent
  each grow the generation (that a grown generation invalidates a cached approval is tested
  since round 1).

## Round 6 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r6.txt`, `agy-review-r6.txt`. Related tests on the round-5 state: core
675, widgets 507 and 69 differential cases pass.

- **R6-1 (both): a renamed local provider alias, or a second alias for the same runtime (which
  makes the binding ambiguous), changed the approval but not the deduplicated `r.agents`.** *Fix:*
  `RuntimeRecord.bindings` (not sent) keeps every `agent=provider id` pair from the inventory
  scan, without deduplication, and is part of the fingerprint.
- **R6-2 (agy): the R5 test changed two fields per step.** *Fix:* every case is measured against
  the same baseline; a repeated scan and an agent merely working (`activeAgents`) do not grow the
  generation; the alias rename and the second alias are cases of their own.

## Round 7 (Codex and agy, 2026-11-21): CLEAN

Reports: `codex-review-r7.txt`, `agy-review-r7.txt`. Both CLEAN: rounds 1–6 verified against the
code and the tests, no new finding.

**Task 085 review: CLEAN.**
