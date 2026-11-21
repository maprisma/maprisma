# 082 AI Project Center and feature plugins

Working branch: `task/082-ai-project-center`, based on `64b6554`.
Date: 2026-11-20. Changes are in the isolated checkout; nothing was merged,
installed, signed or published.

## Implementation review (internal independent agents)

Read-only reviews found and the author addressed:

1. Plugin startup could race shutdown. Startup now checks disposal after spawn;
   shutdown waits for startup and prevents later dispatch. A failed transport
   is not treated as a confirmed process exit.
2. Close confirmation could use a stale project count. It now obtains a fresh
   summary and captures the page's active state before unmounting it.
3. Signed executable paths could change after verification. Verified bytes are
   staged as a private executable identified by their digest before launch.
4. EOF, signals and parent loss needed the same cleanup as normal shutdown.
   Common cleanup stops project agents and owned terminal sessions, cancels
   cancellable workers, and waits for worker completion. Commit operations
   finish. Unconfirmed cleanup retains ownership and is not labelled paused.
5. Undo and other domain follow-ups could reach the wrong process. The host
   remembers returned opaque handles; the originating feature checks handle
   provenance before accepting cross-domain follow-ups.
6. Generation initially used the host's older worker. Each feature executable
   now implements its own worker mode. The verified host resource root is
   propagated separately, so bundled adapters/resources still resolve.
7. Agent permissions needed rechecking at each assignment. The injected
   authorizer now checks immediately before every process launch.
8. Equal-folder protection missed nested projects. Canonical equal, parent and
   child working folders now conflict while managed work is active.
9. System event messages needed localization. Stable event text/templates are
   translated; agent output and saved handoffs remain original content.

The reviewers confirmed these corrections within their reviewed scope. This is
not a substitute for the requested Claude and Antigravity reviews.

## Initial targeted verification

The final targeted run passed **91 tests**: 24 AI Project Center tests, seven
feature-host tests, 55 existing Smart Card tests and five adapter tests. Project
fixtures include actual harmless command execution, complete output capture,
stdin EOF, and owned-child termination before a confirmed pause. They also cover
persisted state/recovery, stale approvals, changed capabilities, native subagents,
access choice, nested-folder exclusion, policy changes between assignments and
unconfirmed cleanup retaining the folder claim.

The new project tests inject a filesystem policy that normalizes ownership only
for this sandbox's `/`, `/home` and `/tmp` mount ancestors. Real storage, locks,
atomic writes and permissions are exercised; production uses the unchanged
strict filesystem policy. This is not proof of production startup here.

Two existing add-on tests needed their synthetic renamed agent's new project
argv renamed too, so they still exercise missing updater capability. That fix
and the adapter reference tests passed 12 targeted checks.

## Initial complete end-of-task checks

As requested, complete suites were attempted after implementation, following
affected checks during development. Full failures were compared against an
untouched archive of `main` in the same environment.

| Check | Result |
| --- | --- |
| Core format and analyzer with fatal infos | PASS |
| Flutter format and complete analyzer | PASS |
| Generated protocol check | PASS |
| Python typecheck | 0 errors; five existing missing-yaml-source warnings |
| Complete core suite | 414 pass, 122 fail; the same 122 named failures as baseline (383 pass, 122 fail) |
| Complete Python suite | 1,441 tests; 12 failures, 150 errors, 52 skips; exactly the same failure/error names as baseline |
| Complete Flutter widget suite | No tests executed; all 64 test-file loads fail because loopback sockets are denied |
| Differential parity | Adapter and early foundation cases pass; the Python oracle stops at legacy settings migration with `PermissionError: Unsafe private-write ancestor` |
| AOT release transport check | PASS |
| Linux Devel preview and all three feature executables | PASS |
| Bundle gate (including ELF/glibc and no Python) | PASS |
| Packaged feature handshake/shutdown | PASS for Reports, Ask AI and AI Project Center |
| Packaged features' own worker dispatch | All three refuse an unsupported fixture operation through their own worker entry point |
| Translation JSON, manual sources, whitespace | PASS |

The sandbox represents `/`, `/home` and `/tmp` as owned by UID 65534 while the
test process is UID 1000. Existing private-write and trust guards reject that
environment. Several other existing failures involve denied sockets or the
resulting unavailable records. Exact baseline comparison found no new named
core or Python failures after the add-on fixture correction. The complete suites
are nevertheless **not green**, and widget interaction remains unverified here.

The local build and logs are under `.flutter-previews/`; the final preview path
is recorded in `.flutter-previews/task-082-checks/preview-path.txt`. No live app
was launched or replaced.

## Requested external reviewers

Claude was invoked with a supplied planning brief, no tools, plan permissions,
strict MCP configuration and no persisted session. It returned:

`API Error: Can't reach the API server — check your internet or DNS (EAI_AGAIN)`.

Antigravity was invoked with the same brief, plan mode and sandbox. After
correcting its required explicit `-p` prompt syntax, startup returned:

`Failed to start: listen tcp 127.0.0.1:0: socket: operation not permitted`.

Their reviews are **pending**, not CLEAN. Before merging, run the full checks
and the two read-only reviews in a host session with the required filesystem and
socket access. Review the native page there as well.


## Continuation: runtime and native widgets

The user requested continued work. A development fallback now compiles the
original widget tests with the cached Flutter frontend and runs each test file in
its own `flutter_tester` process with the VM service disabled. It uses the test
package's actual declarer/invoker, fixtures and assertions; it opens no reporting
socket and changes no production filesystem/network policy. Run
`tools/test-widgets-headless.py <flutter_app/test/file_test.dart>` for affected
files, or `--all` at final validation. Internal SDK/test API coupling is documented;
custom library-level configuration is rejected rather than ignored. Empty name
selections fail, so they cannot produce a false successful check.

The real widget execution exposed a progress animation behind confirmation
modals that prevented settling; the animation is now suppressed while a modal
awaits the user's decision. Additional fixes and regression checks cover:

- Public project calls reject private `@hello`, `@summary` and `@shutdown` worker
  control methods, in both embedded and process mode.
- Embedded/process backend selection remains pinned until restart, including
  when executable updates appear after an embedded feature acquired its store.
- Start policy is checked for assignments actually dispatched, rather than
  rejecting planning because an unused implementer is denied.
- Closing with a disconnected controller remains possible. A reachable worker
  that refuses to confirm cleanup keeps the window open and supports retry.
- An unconfirmed pause exposes Retry pause and targets the same `run_id`.
- The native directory picker holds PopupGuard while it runs and preserves the
  goal draft. The new retry label and manual guidance cover all eight languages.

Two independent internal reviewers checked these continued changes and reported
no remaining actionable findings in the reviewed scope. The requested external
Claude/Antigravity review remains pending for the previously recorded reasons.

| Continued check | Result |
| --- | --- |
| Project/feature core checks | 33 pass (24 project, nine feature-host checks) |
| New native widget checks | 11 pass, covering project workflows, events, feature registry, window shutdown, picker and pause retry |
| Existing Reports page checks | Nine pass |
| Whole headless widget run | 65 files attempted; 380 pass, ten completed-test failures and one timed-out file |
| Same headless run on untouched baseline | 61 files; 369 pass, the same ten completed-test failures and the same timed-out file |
| Large app suite with a 300-second file limit | Branch and baseline each reach 101 passing and three failing checks, then stall at the same existing test; the final two use-case checks pass when selected separately |
| Continued complete core suite | 416 pass, 122 fail; exactly the same 122 named failures as baseline |
| Continued complete Python suite | 1,441 tests; 12 failures, 150 errors, 52 skips; same failure/error names as baseline |
| Format, Dart/Flutter analysis, protocol | PASS |
| Python typecheck | Zero errors, five existing warnings |
| Updated Devel app and three backends | PASS; bundle gate PASS; packaged host rejects private control operations, discovers all three process backends, and each backend passes handshake/shutdown and own-worker smoke checks |

No new named failures were found in the completed baseline comparisons. The
long-running app suite and the existing environment failures are still limits of
this validation; this is not a claim that the entire suite is green. Native
widgets are now exercised, superseding the initial no-widget-execution limit.

The updated preview and all continued logs are recorded beside the initial logs
in `.flutter-previews/task-082-checks/`. Main and the installed app remain unchanged.

## Natural-language Project Setup extension

The current extension adds a helper-drafted team proposal from a natural-language
request, grounded in installed managed profiles, actual agent/runtime connections
and available local models. Review and Apply configure the saved project only;
they do not launch work or replace the separate plan-approval/run steps.

Planning and Execution are configured independently in Setup and Team. Natural
proposals target one phase; optional `plan_team` preserves compatibility by using
the execution team when absent. Approval binds both configurations. Phase
isolation, legacy fallback and invalidation after either configuration changes
must be checked as part of this extension.

The design keeps local runtimes running/connected on the map as a prerequisite,
uses project-scoped model/launch flags, and confines Pi to read/search without
shell or editing tools because that managed profile has no OS sandbox. The
proposal explains why a model suits this project's goal rather than claiming a
universal best model.

The extension is implemented. Setup uses a managed no-tools helper in a private
neutral working directory. It offers the real installed agent profiles and
connected runtime/model IDs, and accepts only a validated proposal. Explicit
exclusions need named warnings; requested local inference cannot silently become
a default/cloud selection. Long provider IDs retain their full command identity
separately from the map's shortened display labels.

Each phase saves its own team and prompt draft. Clearing `plan_team` restores the
execution-team fallback. Planning contributors use read-only argv; execution can
select a different model and runtime. Applying a proposal clears prior approval
and opens the proposal's target phase. It starts no proposed teammate.

Review fixes cover a locked planning fallback that could edit execution text,
local qualified model IDs bypassing runtime binding, empty no-tools argv values,
unavailable runtimes at apply/dispatch, and fresh-run controls after completion.
Reconfiguration, replanning and restart recovery retain the requirement to
review partial execution effects. An acknowledged fresh run receives the saved
handoff rather than losing evidence about earlier work. Setup cannot erase an
active interrupted execution checkpoint.

| Extension validation | Result |
| --- | --- |
| Focused project domain | 43 pass |
| Feature host, inventory, adapters and readers | 28 related checks pass |
| Setup widgets | Five pass; proposal/apply, phase isolation, fallback lock, local binding and ready-only Run |
| Existing project widgets | Six pass; corrected review fixture now returns the core's real `ready` status |
| Final complete native widget sweep | 66 files attempted; 385 pass in completed files, the same ten existing completed-test failures and one existing timed-out file; no new named failures or unsuccessful files against baseline |
| Complete core suite | 444 pass, 122 fail; exactly the same 122 named failures as untouched baseline |
| Complete Python suite | 1,441 tests, 12 failures, 150 errors, 52 skips; exactly the same 162 named failures/errors as baseline |
| Core/Flutter format and complete analysis | PASS |
| Python typecheck and protocol | Zero errors, five existing warnings; protocol PASS |
| Differential checks | 33 cases pass, then the same Python oracle legacy-settings migration fails on its private-write ancestor guard |
| App, core and three independent plugins | Build PASS; no-Python/glibc bundle gate PASS |
| Packaged processes | All three plugin handshakes/shutdowns PASS; host discovers three process backends, rejects private feature operations and shuts down |
| AOT release transport | PASS |

Independent internal review checked the phase-aware GUI/domain contract and the
inventory/profile/schema bridge. Findings were fixed and regression-tested.
Claude/Antigravity external review is still pending for the environment limitations
recorded above; no new external CLEAN claim is made. Nothing is merged, installed,
signed or published.

The first complete widget sweep caught the old approval mock returning `draft`
after successful review. The backend returns `ready`; correcting that fixture
made the six existing project tests pass. The final complete widget rerun above
includes that correction. It still cannot finish the same pre-existing large app
test within the per-file limit. This is not a claim that the full suites are
green or that real cloud/local inference was exercised in this sandbox.

Latest Devel preview:
`.flutter-previews/preview-cjkz521p/flutter_app/build/linux/x64/release/bundle/maprisma`.
Extension logs and baseline comparisons are in
`.flutter-previews/task-082-checks/maprisma-082-setup-*.txt` and
`setup-widget-comparison.json` in the same directory.

## External review retry (2026-11-20, user requested)

Both actual installed CLIs were retried against the current uncommitted task
working tree (base `64b6554`). The supplied non-generated patch snapshot contains
10,776 lines, SHA-256
`b5ca8e120d96d226debb6a8e132b2b3a14593959aa1e07dd355f375e87bef5b4`.
The instructions requested severity-ordered file/line findings for the project
workflow, phase-specific setup, runtime/model bindings, protocol and feature
lifecycle, with read-only inspection and no credentials or real conversations.

- Claude used safe/restricted mode, plan permissions, Read/Glob/Grep only,
  strict MCP configuration and no persisted session. Exit 1:
  `API Error: Can't reach the API server — check your internet or DNS (EAI_AGAIN)`.
- Antigravity used its documented explicit prompt, plan mode and sandbox.
  Exit 1 before review:
  `Failed to start: listen tcp 127.0.0.1:0: socket: operation not permitted`.

Neither produced a code review or a CLEAN result. Both reviews remain pending.
Raw results are saved as `claude-review-latest.txt` and `agy-review-latest.txt`
under `.flutter-previews/task-082-checks/`. The executable
`run-external-reviews.sh` there regenerates the patch and runs the same read-only
tasks from a normal host terminal, saving each answer and exit status separately.
Its shell syntax was checked. No application source was changed by this retry;
the complete suites were not repeated for these documentation/artifact changes.

### agy command correction

The user observed that agy warns `--mode plan` has no effect when
`--disable-slash-commands` is supplied. The host retry script now omits
`--disable-slash-commands` for agy and retains `--mode plan --sandbox`.
Claude uses separate permission flags; its invocation is unchanged. The earlier
agy retry failed before review and remains pending, with no read-only or CLEAN
review claimed for that attempt. Maprisma's agy project profiles already omit
the conflicting option.

## External reviews completed and Claude handoff (2026-11-21)

The user ran both reviews in normal host terminals. Both completed **NOT CLEAN**.
This supersedes the pending status above. Their complete, unedited reports are
preserved under `.flutter-previews/task-082-checks/` as `claude-review-host.txt`
and `agy-review-host.txt` (also originally `/tmp/maprisma-082-{claude,agy}-host-review.txt`).
Claude reported one high, three medium and five low findings; agy reported four
high, four medium and one low, with substantial overlap. Neither ran tests.

Confirmed work requiring investigation/fixes includes retryable process cleanup,
storage-fault cancellation, descendant ownership across process groups and fast
leader exits, bare opaque-handle routing, approval recovery, stale setup
application, shutdown/disposal behavior, inherited internal launch variables,
agent aliases and missing managed profiles, consistent model catalog bounds,
agy session-setting types and stale access selections. Verify each report against
the source, especially CLI-parser assumptions, rather than accepting every claim
without reproduction.

The user requested a handoff to Claude. All three internal implementation agents
were stopped at safe boundaries. Core and feature-host agents made no mutations
or test runs during this new fix round. No supervisor/subreaper, handle routing
or lifecycle refactor has been implemented.

Only `flutter_app/lib/ai_project_center.dart` received partial review fixes:
optional `approval_valid` consumption with legacy fallback, completed-project
reapproval, a disabled visible unsupported access choice, and protected-checkpoint
Setup controls. These remain incomplete: the core does not yet expose
`approval_valid`; no new regression tests ran; the new keys
`{0} (unavailable for this profile)` and
`Choose a supported access mode before saving.` still need all seven translation
dictionaries. Format passed; targeted analysis reported no errors/warnings and
one style info at the then-current line 954 (`'$mode'` should be `mode`).

All earlier full-suite results predate these partial UI changes. They must not be
presented as validation of the external-review fixes. No merge, installation,
signature, publication or commit was made. Claude should continue in the existing
uncommitted `task/082-ai-project-center` checkout based on `64b6554`.

## Round 2 fixes: external review findings (Claude, 2026-11-21)

Claude took over the uncommitted working tree on base `64b6554`. Each finding was
checked against the source and reproduced where practical. References: Claude
report (C-H1, C-M1…M3, C-L1…L5) and agy report (A1…A9) in
`.flutter-previews/task-082-checks/{claude,agy}-review-host.txt`. Before
implementation, Codex (read-only) reviewed the fix design; its points are D1…D9
below. Each new regression test was checked to fail with its fix reverted.

### Process safety

**C-H1 / A1: a failed stop was cached for ever.** Confirmed in source
(`_stopping ??= _stopOwned()`). *Fix:* the process-group tracker was replaced
(see C-M2). `SupervisedProjectProcess.stop()` caches only a confirmed empty tree.
Every call sends a new stop request and waits again. Pause and shutdown share
`_stopAttempt`, which maps an unconfirmed stop to `project_still_pausing` and keeps
the attempt, folder claim and run lock. `_execute`'s final stop is authoritative,
so an earlier failed stop that later succeeded cannot leave a false `pausing`.
*Tests:* `a failed stop is retried rather than remembered` (real class, stand-in
supervisor that confirms only the second request); `Retry pause asks again after a
refused stop`; the existing unconfirmed-cleanup test.

**C-M1: a storage fault blocked Pause while other agents kept running.** Confirmed:
`call()` refused `pause`, and `_pause` wrote before cancelling. *Fix:* the first
failed write stops every active attempt (`_haltAll`); `pause` stays allowed; Pause
cancels before writing; stop/end states use `_record`, which keeps the state in
memory when it cannot be saved, so stopped work is never shown as running. A restart
still recovers from the last durable record. *Test:* `a storage fault still lets
Pause stop work and halts every other project` (fails without the halt and without
the allowlist).

**C-M2: process-group polling missed escaped descendants and fast leader exits.**
Reproduced: the old tracker, extracted from the review patch, ran
`setsid sleep 60 & echo done`. The leader exited, the escaped child was still alive
after "confirmed" cleanup, and because that child held the output pipe, the result
became a 2-second timeout (exit -1). *Fix (ownership design):* each assignment runs
under a per-run supervisor, the AI Project Center executable in `supervise` mode
(`project_supervisor.dart`). It is a `PR_SET_CHILD_SUBREAPER`, so descendants that
call setsid/setpgid or double-fork re-parent to it. Stop sends SIGTERM, waits, then
sends SIGKILL repeatedly (pidfd, start-time and UID checked). The tree counts as
empty only when the kernel says so: once Dart has reaped the leader, the
supervisor reaps adopted zombies and requires `waitpid(-1)` = ECHILD (D1/D5: a
`/proc` scan alone is not atomic, and the Dart VM does not reap adopted orphans).
Output is complete before the confirmed `stopped` event (D4). Each supervisor holds
a shared lock on `runs/<id>.lock` while its tree lives, also after the feature
process is gone; on control-pipe EOF it stops its tree itself (D2). *Limit,
documented:* processes another service starts on an agent's behalf (systemd-run,
D-Bus activation, container daemons) are not descendants and are not owned.
*Tests (real processes):* fast leader exit with two setsid children, one of which
ignores SIGTERM; stop of a running tree with a double-forked daemon, run lock held
during the run and free afterwards; a lost supervisor never reports stopped.
Manual probes on the JIT supervisor also covered stdin input, controller EOF and a
fork storm of detached children (`while true; do (sleep &); done`); none survived.

**C-M3: internal variables reached agents.** Confirmed. *Fix:*
`AiProjectCenterPlugin.agentEnvironment` removes `MAPRISMA_FEATURE_*`,
`MAPRISMA_CORE_WORKER` and the page markers in addition to session variables.
*Test:* `agents do not inherit Maprisma process variables`.

**D7 (Codex): approval and launch used different snapshots.** Confirmed. *Fix:* one
profile/runtime snapshot per assignment is checked against the approval, used for
options and launched.

### Feature ownership

**A2: bare 32-hex handles were not routed.** Confirmed: Ask AI paths return
`newHandle().substring(5)`, and both host and worker matched only `core-…`.
*Fix:* `newHandle()` records every token in a bounded issued-handle registry
(8192). The worker answers with `"handles"`: the strings in the result that this
process issued. It accepts follow-ups only for its own tokens. The host records
only listed strings that occur in the result (a plugin without the field: prefixed
form only). Arbitrary same-shaped hashes are never recorded. A stopped feature
loses its host entries. D6: the registry outlives any handle store by far; a token
only needs to survive from issuance to its own response for provenance to be
advertised. *Tests:* bare handle routes back while a same-shaped digest does not;
legacy plugin is trusted for prefixed handles only; registry covers bare and
prefixed tokens only for real ones (fails with the old regex behaviour).

### Approval recovery

**A3 / C-L3: approval could not be renewed; catalog refreshes broke approval.**
Confirmed. *Fix:* every project view carries derived `approval_valid` (and
`processes_stopping`). The fingerprint contains launch-affecting facts only: argv
template, stdin, access modes, permission text, model/provider/subagent options,
chosen subagent definitions and the runtime binding's provider. Model catalogs and
served-model lists are no longer part of it; each dispatch still checks model
availability. The UI uses `approval_valid` (with the legacy fallback) and allows
reapproval of completed projects. *Tests:* core: completed project reapproval
after a permission change; catalog/served-model refresh keeps approval, a provider
change does not. Widgets: invalid stored approval enables Approve and disables Run;
completed project reapproval sends `review`.

### Setup lifecycle

**A4: `setup_apply` bypassed the checkpoint guard.** Reproduced as a test. *Fix:*
`_checkpointUntouched` for setup and setup_apply. *Test:* applying a stale proposal
after a paused run is refused and leaves the record byte-identical.

**C-L1: starting setup cleared approval.** Confirmed. *Fix:* setup saves
phase/status/position/checkpoint/run id in `setup_return` and restores them when it
ends: success, failure, stop or restart recovery. Approval is not touched; failures
are recorded in `setup_error`. Only `setup_apply` changes the team (and so the
approval). *Tests:* a ready approved project stays ready with a valid approval after
a proposal; a failed setup leaves state and approval unchanged; an interrupted setup
is restored after restart. Seven existing tests were updated from the old
"setup failed" status semantics to `setup_error`.

**C-L2: `continue` re-ran setup in any status.** Confirmed. *Fix:* gated to
paused/interrupted/failed. Since setup outcomes are now final (D8: decided
explicitly; re-running uses Setup), this guards only legacy records. *Test:*
continuing a stored setup record in `draft` is refused without launch.

**A8b: a title-only edit kept a proposal that could no longer be applied.**
Confirmed. *Fix:* a title change drops the proposal and keeps the approval (the
title is not part of the approval). *Test:* title-only save.

### Shutdown and disposal

**C-L4 / A5a: a failed Project Center shutdown disconnected its siblings.**
Confirmed. *Fix:* the host stops the AI Project Center first and the other features
only after it confirmed. A feature that stopped is removed and restarts on its next
call. A refused shutdown leaves every feature usable. *Test:* refused Project Center
shutdown, then Reports and the Project Center still answer and a retry succeeds
(fails with the old parallel/no-removal code).

**A5b: deadlines did not align.** Confirmed (20 s host limit vs up to 4 × 13 s
sequential). *Fix:* the Project Center stops all attempts in parallel within about
10 s. The host allows 30 s; a late answer is retryable (`project_still_pausing`)
and no longer kills the backend. *Test:* two refusing projects fail within one
deadline (under 10 s), then shutdown succeeds.

**A5c / D3: embedded disposal and EOF did not await cleanup.** Confirmed (and the
isolate was killed straight after the close message). *Fix:* `CoreService.close()`
retries `shutdownFeatures` a bounded number of times, then disposes. `dispose()`
detaches the Project Center: control pipes close, so supervisors stop their trees
on EOF while holding the run locks. The `maprisma-core` EOF path uses `close()`;
the isolate transport sends `@close` and waits for the acknowledgement or exit
(bounded) before ending the isolate. The feature worker's EOF loop is bounded (30
attempts) and then exits, handing unconfirmed trees to their supervisors instead
of keeping the store lock for ever.

### Configuration consistency

**A6: agy `allowNonWorkspaceAccess: false`.** Not a defect of the project
profile. agy's own settings file on this PC stores the key as a JSON boolean, and
`--settings` takes settings.json keys. The `"off"`/`"on"` values are choices of the
existing `[security.settings]` entry, which is unchanged since `main`. That entry
writes strings to a boolean key and shows the boolean as a custom value. This is
recorded as a pre-existing follow-up outside task 082, not changed here.

**A7a: runtime model bound.** Confirmed. *Fix:* bindings offer only models inside
the runtime's offered bound (`maxRuntimeModels` = 48). *Test:* 60 served models.

**A7b / C-L5: short labels and agents without a project profile.** Confirmed.
*Fix:* profiles carry the adapter label as an alias. Agents without `[project]` are
listed with `project_supported: false`: never candidates, but a request naming one
needs an explained exclusion. The helper prompt lists them as
`unavailable_agents`. *Test:* "Use Fixture agent with Gemini" without an exclusion
is refused (`project_setup_agent_omitted`); with an explained exclusion it is
accepted, and the agent is not offered.

**A8a: stale access selection.** The partial UI fix showed it as a disabled
choice. Its widget test found a real overflow of that long label; the dropdown now
expands and ellipsizes. Keys `{0} (unavailable for this profile)` and `Choose a
supported access mode before saving.` are translated in all seven dictionaries;
the `'$mode'` interpolation was removed. *Test:* stale `project-edit` on a
read-only profile renders without exception and shows the hint (fails without the
layout fix).

**A9: options after `{prompt}`.** Not reproduced. All four declared CLIs parse an
option placed after the prompt: agy, codex and pi each reject an unknown flag
placed there (`flags provided but not defined`, `unexpected argument`, `Unknown
option`), and claude (`unknown option`) too. The probes ran with an empty HOME and
made no agent call. *Hardening:* a template containing `--` is refused, because
appended options would become prompt words. *Test:* `a template that ends option
parsing is refused`.

### Other changes

New UI texts are in all eight languages: still-stopping processes, setup stopped
and setup ended without a proposal. `setup_failed` events are localized through
their error code. The manual got a paragraph on setup without side effects,
renewed approval and stopping processes in all eight languages. `routes.json`
(`features.call` note), `docs/protocol.md`, the generated client, both plan
documents and the core assets were regenerated or updated.

## Round 2 follow-up review (Codex and agy, 2026-11-21): NOT CLEAN

Both reviewed the round-2 working tree read-only (patch SHA-256
`65dad0a7…77`). Codex: one high, three medium; agy: one high, four medium, two
low. Reports: `.flutter-previews/task-082-checks/{codex-review-r2.txt,agy-review-r2.txt}`.
agy confirmed the other round-2 dispositions in the source. Neither ran the suites.

## Round 3 fixes

**R2-C1 (Codex, high): EPIPE killed the supervisor before its tree was empty.**
Confirmed by Codex with the AOT supervisor and reproduced as a test. *Fix:* output
failures are absorbed (`stdout.done`, the writer stream, final flush); cleanup
goes on to ECHILD. *Test:* the controller closes both pipes while a TERM-ignoring
child keeps writing; the child is ended and the supervisor exits (fails without the
fix and left its fixture running, which was then removed by hand).

**R2-A1 (agy, high): exit raced the last output, so a clean stop looked lost.**
Confirmed in source. *Fix:* the controller decides loss only at the end of the
supervisor's output, never at its exit. The feature host waits 2 s after exit
before declaring loss, so a buffered `@shutdown` answer is still read.

**R2-A5 / R2-A7 (agy): early supervisor failures without `stopped`; spin on a
child invisible to /proc.** Confirmed. *Fix:* the `subreaper_unavailable` and
`invalid_start` errors also report `stopped`, since nothing was started. A child
`waitpid` reports but `/proc` does not show is rescanned briefly; if it persists,
it is reported as stuck with the normal delay.

**R2-C2 (Codex): `dispose()` killed the isolate before the store lock was
released.** Confirmed by Codex and reproduced: with the original transport, a
second embedded core got `project_center_busy`. *Fix:* the isolate releases
synchronously (`CoreService.dispose` detaches the Project Center and closes its
store descriptor and supervisor pipes) and acknowledges. The transport ends the
isolate on that acknowledgement or exit, at the latest after 3 s. *Test:*
`disposing an embedded core releases the AI Project Center store lock`.

**R2-C3 (Codex): renewing approval replayed completed assignments.** Confirmed.
*Fix:* approving a paused, interrupted or failed execution keeps that checkpoint,
so Continue resumes at the saved assignment. *Test:* pause after the lead, change
permissions, renew approval: the status stays paused and Continue starts only the
implementer.

**R2-C4 / R2-A2: a setup whose cleanup failed lost its snapshot.** Confirmed.
*Fix:* setup results are recorded with the phase still `setup`; the earlier state
returns only in `finally` once cleanup is confirmed, or in the confirmed Retry
pause/shutdown, or at restart recovery. *Test:* a failed setup with a refused stop
stays in `setup`/`pausing`; the confirmed retry restores `ready` with a valid
approval.

**R2-A3: a late but clean `@shutdown` left the feature disconnected.** Confirmed.
*Fix:* a feature that confirmed `@shutdown`, also after the host's timeout, is
replaced on its next call. The host timeout can be configured for tests. *Test:*
`a feature that confirms shutdown late is started again on use` (fails without the
fix with `feature_disconnected`).

**R2-A4: worker signals and watchdog.** Confirmed. *Fix:* SIGTERM, SIGINT and
parent loss make one bounded cleanup (3 attempts), then dispose and exit: trees go
to their supervisors, which keep the run locks. EOF cancels the watchdog and
signal handlers first and uses the same path. *Check:* a JIT feature worker
answered a request and exited immediately after SIGTERM.

**R2-A6: embedded Project Center stayed closed; concurrent shutdowns.**
Confirmed. *Fix:* `shutdownFeatures` forgets a successfully shut down embedded
Project Center, so an aborted close reopens it. Concurrent `shutdown()` calls share
one attempt. *Test:* `concurrent shutdown calls share one attempt`.

| Round 3 check | Result |
| --- | --- |
| Core format, analysis with fatal infos | PASS |
| Focused core (project center 60, supervisor 7, feature host 14, inventory, adapters, readers) | 101 pass |
| Flutter format and complete analysis | PASS |
| Focused widgets (project center, setup, events, features, shutdown window, isolate transport) | 25 pass |
| Revert checks | each new round-3 test fails with its fix reverted |

## Round 3 follow-up review (Codex and agy, 2026-11-21): NOT CLEAN

Patch SHA-256 `06974b28…7f7f`. Codex: one high, two medium; agy: three medium.
Both confirmed the round-3 dispositions in the source. Reports:
`codex-review-r3.txt`, `agy-review-r3.txt`.

## Round 4 fixes

**R3-C1 (high): the supervisor took its run lock only after start.** Confirmed: a
controller that died after queuing the start left a window in which a
replacement saw the lock free. *Fix:* the start frame names the controller (pid
and start time). The supervisor takes the run lock first, then requires that its
parent is still that controller, and otherwise exits without launching
(`controller_gone`). Either the controller died before the lock was held, and the
late start never launches, or after, and the lock is held. *Test:* a start that
names a controller other than its parent launches nothing and leaves the lock free.

**R3-A1: the run lock outlived a confirmed stop.** Confirmed. *Fix:* the supervisor
releases the lock before it reports `stopped`; `stop()` also waits for the
supervisor's exit on the confirmed path. *Test:* after a natural end the lock is
free at once (fails with both parts reverted).

**R3-C2: isolate disposal timeout or fatal exit leaked the store lock.**
Confirmed. *Fix:* the isolate is ended only after it released (acknowledgement or
exit); it runs with `errorsAreFatal: false`, so an uncaught error also takes the
releasing path. *Residual, honest:* an isolate that can never reach the message
again keeps the store and is reported as busy by a replacement; it is still
alive. Not separately tested (it would need a deliberately wedged core).

**R3-C3 / R3-A2: worker teardown had no time bound; EPIPE in the worker.**
Confirmed. *Fix:* each cleanup attempt has a 15 s deadline (three attempts), then
dispose and exit. The feature worker and the commit worker (`runWorker`) absorb
output-channel errors. A commit therefore finishes in its own worker process
after its reader is gone, and the feature worker's teardown is no longer blocked
by it.

**R3-A3: requests during a pending `@shutdown`; concurrent host shutdowns.**
Confirmed. *Fix:* requests are refused (`feature_closing`) while `@shutdown` is
pending or after it was confirmed. A shutdown retry after a late confirmation
waits for the exit instead of asking again. Concurrent host shutdowns share one
attempt. *Test:* shared future, `feature_closing` while pending, retry succeeds
after the late answer (fails with either part reverted).

The two leftover temporary test folders were from aborted revert runs. They were
removed.

| Round 4 check | Result |
| --- | --- |
| Core format, analysis with fatal infos | PASS |
| Focused core (project center 60, supervisor 9, feature host 15, inventory, adapters, readers) | 104 pass |
| Flutter format and complete analysis | PASS |
| Focused widgets incl. isolate transport | 25 pass |

## Round 4 follow-up review (Codex and agy, 2026-11-21): NOT CLEAN

Patch SHA-256 `5910584c…83d6`. Codex: one high, one medium, two low; agy: one
high, one low. Both high findings are the same startup gap. Reports:
`codex-review-r4.txt`, `agy-review-r4.txt`.

## Round 5 fixes

**R4-C1 / R4-A1 (high): a controller retired in a living process could still
launch.** Confirmed: the parent check covers a dead controller process, not a
disposed embedded core or a worker between dispose and exit. *Fix:* a launch
handshake. The supervisor takes the run lock, checks the parent (now also
requiring a known start time), reports `locked` and waits. The controller
answers `launch` only while it still owns the project store (`_ownsStore`: not
closed, store descriptor held). Otherwise it closes the pipe, and the supervisor
ends without launching (`launch_withdrawn`). At the moment of `launch`, both the
store lock and the run lock are held. A start without a controller identity is
invalid. *Test:* a controller that no longer owns its store gets
`project_center_closed`, nothing is launched and the lock is free (fails without
the check). Stand-in supervisors in two older tests now speak the handshake.

**R4-C2: a full store bypassed the storage-fault handling.** Confirmed. *Fix:* a
write that would exceed the limit while work runs stops all active work and
latches `project_store_full`. Deletion stays allowed, and the fault clears once a
smaller store was written; without running work only that request is refused.
The limit can be configured for tests. *Test:* a result that outgrows the store
makes the other project stop and the first fail visibly with
`project_store_full`; nothing completes silently (fails without the halt).

**R4-C3 (low): handle age vs registry eviction.** Partly accepted. The registries
(issued tokens, host owners) now hold 65,536 entries by issuance order instead of
8,192/4,096. A handle older than that many later handles stops routing across
processes; per-store lifetimes are not tracked. This residual is documented in
the feature-plugin plan.

**R4-C4 (low): unbounded final flush.** Fixed: bounded to 2 s.

**R4-A2 (low): `@closed` could race disposal.** Fixed: disposal also ends on the
close acknowledgement.

| Round 5 check | Result |
| --- | --- |
| Core format, analysis with fatal infos | PASS |
| Focused core (project center 61, supervisor 10, feature host 15, inventory, adapters, readers) | 106 pass |
| Flutter complete analysis | PASS |
| Focused widgets incl. isolate transport | 25 pass |

## Round 5 follow-up review (Codex and agy, 2026-11-21): NOT CLEAN

Patch SHA-256 `89d7df6e…b7b5b7`. Codex: one high, one medium, one low; agy: two
medium. Both confirmed the retired-controller launch gap closed. Reports:
`codex-review-r5.txt`, `agy-review-r5.txt`.

## Round 6 fixes

**R5-C1 (high): a retired controller could write its stale snapshot over the
replacement's store.** Confirmed. *Fix:* `_persist` refuses without the store
descriptor (`project_center_closed`), so no pending progress, error or finally
path of a detached controller writes. *Test:* a controller detached while its
spawn is pending, a replacement saves, the late result arrives: the store file is
unchanged (fails without the check).

**R5-A1: the full-store fault cleared itself.** Confirmed: the halted project's
small failure record was written and cleared the fault. *Fix:* under
`project_store_full` only a deletion writes, and only a deletion clears it. *Test:*
the fault stays visible, a save is refused, and a deletion clears it (fails with
the old clearing).

**R5-A2: the launch handshake ignored a pause/halt/shutdown during startup.**
Confirmed. *Fix:* the runner receives a per-attempt authorization (store owned and
attempt not cancelled). A withdrawn launch closes the control pipe, waits (bounded)
for the supervisor's confirmation and exit so its run lock is free, and reports
`project_launch_withdrawn`. A withdrawal caused by a cancellation ends as a pause,
not a failure. *Test:* Pause during startup gives `paused` with nothing launched
(fails with a store-only check).

**R5-C2: EOF could not reach teardown during a stuck request.** Confirmed. *Fix:*
stdin is read independently of answering; EOF (or an oversized frame) ends the
answer loop and starts the bounded teardown even while a request is unfinished.
Not runtime-tested: there is no practical stuck-request fixture; it is covered by
analysis and the existing worker/handshake checks.

**R5-C3 (low): handle age vs registry eviction.** Not changed in task 082; recorded
as a known limit. Tying routing to each handle store's own expiry would change
every store's API. Within 65,536 later handles, Undo and preview handles route
correctly; after that, a follow-up is refused instead of reaching the wrong
process.

| Round 6 check | Result |
| --- | --- |
| Core format, analysis with fatal infos | PASS |
| Focused core (project center 63, supervisor 10, feature host 15, inventory, adapters, readers) | 108 pass |
| Flutter complete analysis | PASS |
| Focused widgets incl. isolate transport | 25 pass |

## Round 6 follow-up review (Codex and agy, 2026-11-21): NOT CLEAN

Patch SHA-256 `58ff9b65…e939`. Codex found no new defect; only the known low R5-C3
limit remains. agy confirmed R5-C1, R5-A1 and R5-A2 and reported one medium.
Reports: `codex-review-r6.txt`, `agy-review-r6.txt`.

## Round 7 fixes

**R6-A1: requests could still be dispatched during worker teardown.** Confirmed.
*Fix:* teardown (`end()`, used for EOF, oversized frames, signals and parent
loss) sets `stopping`, completes EOF and closes the request queue. A failing
`@shutdown` no longer reopens the worker during teardown. Input after EOF or an
oversized frame is ignored. A withdrawn launch also cancels its event
subscription (agy's minor note). *Checks:* a JIT feature worker answered a request
and exited within 3 s on EOF; an oversized frame ended it within 3 s; SIGTERM
sent to the worker process exited it with status 0 at once. No stray workers
remained.

**R5-C3 (low), still open by decision:** see round 6; a documented limit of task
082.

| Round 7 check | Result |
| --- | --- |
| Core format, analysis with fatal infos | PASS |
| Focused core | 108 pass |

## Round 7 follow-up review (Codex and agy, 2026-11-21)

Patch SHA-256 `dbff93b5…93e0`. Reports: `codex-review-r7.txt`, `agy-review-r7.txt`.

- **agy: CLEAN.** It verified R6-A1 and the withdrawal clean-up, and re-verified
  all round 2–6 dispositions against the source.
- **Codex: NOT CLEAN, only for the known low R5-C3** (registry eviction can
  invalidate a still-retained handle after 65,536 later handles). It found no new
  regression and confirmed the round-7 fixes and the earlier dispositions.

The review therefore is **not CLEAN** while R5-C3 stays open. Fixing R5-C3 means
tying routing and provenance to each handle store's own expiry, which changes every
store's API; it is left to Uwe whether that belongs in task 082 or a follow-up.

AOT check of the round-7 Devel build (`preview-06q_0w6b`): the compiled
supervisor reports `locked`; with `launch` it runs the agent, ends its escaped
descendants (a setsid one, and one that also ignores SIGTERM) and confirms
`stopped`. On EOF before `launch` it launches nothing (`launch_withdrawn`). No
processes were left (`maprisma-082-r7-aot-handshake.txt`). Build and bundle gate
PASS (`maprisma-082-r7-build.txt`).

## Final complete suites after round 7 (2026-11-21, host session)

Run once at final integration on this host (normal sockets and filesystem, not
the earlier sandbox), against the round-7 working tree.

| Suite | Result |
| --- | --- |
| `MAPRISMA_PUB_OFFLINE=1 tools/flutter-dev check`: core format and analysis (fatal infos) | PASS |
| Core tests (`dart test`) | **603 pass, 0 fail** |
| AOT release transport check | PASS |
| Flutter format and analysis | PASS |
| Flutter widget tests (normal runner) | **505 pass, 0 fail** |
| `UV_OFFLINE=1 tools/typecheck.sh` | 0 errors, 0 warnings |
| `python3 -m unittest discover -s tests -q` | 1,441 tests: 4 failures, 3 errors |

All seven Python non-passes are Dart/Python parity tests that also fail on
untouched `main` under identical conditions. `main` was exported with
`git archive`, with the same `maprisma-addons` sibling, on the same `/home` data
disk; the branch was copied next to it for an equal comparison:

- `installers`, `model_files`, `model_removals` parity: ERROR on both.
- `addons`, `setup_guide` parity: FAIL on both, with identical assertions.
- `system_actions` parity (`$DISK/gguf` not in `server.env`) and `system_moves`
  parity (`KeyError: '$DISK/models/a-Q4.gguf'`): identical on both from the
  same location. In the checkout under `~/Projects`, `system_moves` reports a
  FAIL instead, which is location-dependent.

The temporary baseline copies were removed. Logs: `maprisma-082-final-r7-*.txt`.
The task 082 review stays **not CLEAN** until R5-C3 is fixed or explicitly accepted.

## Decision on R5-C3 (Uwe, 2026-11-21)

R5-C3 is **accepted as a known limit of task 082** and moves to the follow-up task
`docs/tasks/083-handle-expiry-routing.md`. Within 65,536 later handles every handle
routes correctly; after that a follow-up on an older handle is refused and never reaches
the wrong process. With this decision no finding of task 082 stays open.

## Round 8 final review (Codex and agy, 2026-11-21): CLEAN

Only the R5-C3 decision and `docs/tasks/083-handle-expiry-routing.md` changed since
round 7. Reports: `codex-review-r8.txt`, `agy-review-r8.txt`.

- **agy: CLEAN.** All 55 non-review files match the round-7 patch byte for byte; the
  round-7 dispositions hold; the decision and task 083 describe R5-C3 accurately and
  follow the template.
- **Codex: CLEAN.** The round-7 files match their recorded hashes; the lifecycle
  spot-checks support the earlier dispositions; task 083 has testable acceptance.

**Task 082 review: CLEAN** (R5-C3 accepted, follow-up task 083).
