# Flutter/Dart core — implementation responses

## Phase 1 — foundation (2026-10-28)

Implemented phase 1 of the [Dart-core plan](plan-flutter-dart-core.md). Stop here
for Claude's review and Uwe's commit decision. Phase 2 and later are not started;
phase 5 still requires Uwe's separate approval for data-only add-ons.

### Package and transport

`packages/asterism_core/` is a pure Dart package, with no Flutter imports. Its
`CoreService`, request types and CLI share protocol version 1. Requests are
bounded to 64 KiB and replies to 1 MiB; malformed frames receive stable error
codes without exception text, paths or diagnostics. The CLI discards an entire
oversized line and resumes at the next record. It deliberately has no worker or
provider-watch subcommands in this phase.

The UI's existing `Backend` facade now delegates to `ServiceTransport`.
`IsolateTransport` runs the core in a background isolate and sends JSON frames
through ports. It handles request timeouts, errors, startup failure, pending
requests and disposal. The original subprocess transport is retained as
`PythonTransport` for the reference path. Existing fake-service UI tests inject
that transport explicitly rather than enabling fallback globally.

The router selects Dart by a named route allowlist. A failure on a ported route
is returned directly: it never retries a write against Python. Unported routes
use Python **only** when the compile-time `ASTERISM_DEVEL` flag is true. The
isolated preview builder sets that flag and the Devel application identity.
A non-Devel router refuses an unported route with `unported_route`. An AOT probe
checks the refusal and verifies that the Python executable path, service script
and reference-startup error markers disappear from the compiled executable.
The Linux CMake gate also rejects production builds while migration is
incomplete; a Devel flag alone without the Devel identity is insufficient.
This gate remains in place until the release phase.

When Dart changes the language after the Devel reference has started, a strict
`app.settings_changed` control call invalidates Python's translation cache. It
never replays the settings write. If invalidation fails, the reference is retired
and recreated on its next request; a successful Dart write is not reported as a
failed write.

### Routes ported

| Route | Dart behavior |
| --- | --- |
| `settings.get` | UI settings, schema validation and fresh defaults |
| `settings.update` | Strict fields/types/choices, language/layer validation, canonical project folders, atomic private writes, bounded history and byte limits |
| `app.theme` | Existing look/desktop gating, bounded Omarchy TOML parsing, only top-level `#RRGGBB` strings returned |
| `app.identity` | Asterism name/app ID/short name and absolute-XDG-or-HOME config/cache paths |
| `desktop.snapshot` | Generic/Omarchy selection and theme-directory identity |
| `i18n.lookup` | Service-message lookup, locale precedence, saved-language refresh, plural rules and Asterism naming |

Settings defaults and retired keys come from the reference schema through the
development-only `tools/core-assets.py`; all seven non-English translation tables
are embedded in Dart, with English fallback. There is no runtime dependency on
Python or repository files for these Dart operations. Migration renames
`animate_lines`, removes retired keys and preserves an explicitly newer value.
Unknown settings survive writes, including arbitrary-size legacy integers;
the Dart decoder avoids silently rounding them. Settings JSON writes retain
Python's indentation, UTF-8, trailing newline and numeric formatting for the
covered cases. The differential cases include small exponential coordinates.

The desktop layer implements the read-only foundation needed by these routes:
selection, theme-directory identity and the Omarchy palette. Generic
`app.theme` stays empty, matching Python; Flutter uses platform brightness.
GTK/libadwaita palette probing, desktop window/process/menu/usage operations and
Omarchy integration are not claimed as migrated.

### POSIX and security

`posix_ffi.dart` is guarded for Linux. It uses libc descriptor primitives:
`openat` with `O_NOFOLLOW`/`O_CLOEXEC`, nonblocking reads checked as regular files,
`statx` on the descriptor (fixed Linux ABI instead of platform-dependent
`struct stat` offsets), `fchmod`, complete writes, file and directory `fsync`,
exclusive temporary creation, `renameat`, `unlinkat`, and pinned parent-directory
walking. New private directories are 0700 and settings files 0600. A final
settings symlink is replaced without reading or changing its target. Trusted
ancestor symlinks are resolved once before the pinned walk; both resolution and
the walk require user/root ownership and refuse group/other-writable directories
unless sticky. Temporary files are cleaned only if this operation created
them. Bounded file reads reject FIFOs, devices and oversized files.

The initial process primitive opens a pidfd before checking the process UID and
`/proc` start time; signaling uses the pinned descriptor, never a bare PID.
Tests use only an owned `sleep` child and cover a mismatched start time, signal 0,
termination and an exited identity. A reused numeric PID cannot redirect that
pidfd to its replacement. PTY/session launching, `forkpty`/`setsid`/`prctl` and
provider processes remain for phase 4; no process route was ported here.
Unsupported descriptor/pidfd operations have no unsafe compatibility fallback.

The Omarchy current-theme directory deliberately allows its managed symlink;
its opened file is still checked as regular and bounded. No credential file was
read, and no UI-supplied command or argv is executed by the new routes.

### Reference corrections made on both sides

Porting exposed three reference problems, now covered by regressions:

1. `ai_core.atomic_write` pinned neither ancestor directories nor the final
   rename directory. It now uses descriptor-relative no-follow traversal,
   exclusive temporary creation and directory fsync, matching Dart. Newly
   created intermediate private directories are also 0700. The initial blanket
   ancestor-symlink refusal was a regression; the review correction below now
   accepts trusted existing layouts without weakening the pinned walk.
2. `desktop_omarchy.theme_colors` could wait indefinitely on a FIFO. It now uses
   the shared bounded, nonblocking regular-file reader, while retaining theme
   symlink support.
3. `ai_core.load_settings` parsed a truncated prefix of an oversized file. Both
   implementations now reject the whole file, even when its prefix is valid JSON.

These fixes are in this repository's reference implementation only. Neither the
frozen GTK repository nor the plugin was synced or modified.

### Differential harness

`tools/diff-core.py` runs fixture scripts against the Python service oracle and
Dart CLI, each with its own temporary HOME and XDG directories. It compares
responses, refusal codes, resulting file bytes, file modes and symlink targets.
The only normalization is each fixture's HOME prefix; handles/times/PIDs are not
blanket-masked. Fixtures are repository-controlled and never clone the real HOME.
The Dart CLI runs directly through the VM so SDK telemetry files do not pollute
the fixture tree. The oracle migrates settings but does not initialize add-ons,
scan installed agents or perform startup installation/config import.

Normal and hostile cases cover defaults, all UI fields, invalid atomic updates,
malformed/oversized requests and recovery, settings symlinks/FIFOs/malformed or
oversized files, trusted ancestor links and unsafe-parent refusal, write overflow, history preservation,
project canonicalization, XDG paths, eight languages/plurals, locale precedence,
theme parsing/filtering/FIFO refusal, settings migration and large integers.

### Initial validation (before the review correction below)

`tools/flutter-dev check` now generates core assets and includes core formatting,
`dart analyze --fatal-infos`, `dart test`, the differential scripts and the AOT
transport check before the existing Flutter checks. The final complete run passes:

- **14 Dart core tests, 34 differential cases and 93 Flutter tests pass**.
  Core and Flutter formatting/analyzers are clean, including fatal informational
  diagnostics for the core. `git diff --check` also passes.
- Python full suite: **1,420 tests pass**, on a separate private Xvfb display with
  Wayland unset. Existing resource warnings remain; the suite exits successfully.
- Python typecheck: **0 errors, 0 warnings, 0 informations**.
- Explicit Devel transport tests: **4 pass**, including lazy fallback,
  ported-route failure without fallback, language-cache invalidation and failed
  isolate startup without a hanging handshake.
- A fresh CMake configure refuses the production identity with the intended
  incomplete-core diagnostic. The AOT transport probe passes without fallback
  markers. These do not claim a finished production app or a phase-7 bundle audit.
- Isolated Devel build succeeds, without launching it:
  `.flutter-previews/preview-z8u83j9s/flutter_app/build/linux/x64/release/bundle/asterism`.
- No new user-facing UI text or feature flow was added in this internal slice;
  existing translations/manuals remain intact.

### Remaining fallback and review stop

**Every route outside the six-route allowlist still falls back in Devel**, notably
`app.snapshot` (agents/projects/setup), maps, activity, sessions, all provider/model
operations, previews/Apply/Undo, installers, add-ons and jobs. The standalone Dart
CLI refuses these routes. The Devel reference still performs its existing
initialization and owns those operations; no claim of Python-free application
parity is made yet. The shipped target remains Dart only, with production builds
blocked until the later release gate can pass.

Nothing committed, pushed, published or synced. No real-desktop app run or
performance measurement. Phase 1 stops here for review.


### Phase 1 review correction — ancestor symlinks (2026-10-28)

**Medium fixed in both Python and Dart.** The first implementation incorrectly
refused every ancestor symlink, breaking symlinked `.config`/`.cache`, `/home`
layouts and project aliases. The old differential fixture locked in that
regression; it now expects a successful settings write through a trusted link.

The parent is resolved once before writing, then its resolved path is walked
with descriptor-relative `openat` and `O_NOFOLLOW`. Resolution itself uses a
checked, descriptor-based realpath rather than unchecked string rewriting: it
checks the directories containing each link and every intermediate target,
including directories later hidden by another symlink. A missing suffix is
allowed so private directories can still be created. Link loops are bounded.

Both passes accept only directories owned by the current UID or root. Any
group/other write bit requires the sticky bit; `/tmp` remains usable. A foreign
owner is refused even with the sticky bit. The final filename is never resolved:
a symlink there is replaced, and its target is untouched. The second walk refuses
a symlink substituted into the resolved chain between resolution and opening;
subsequent writes/rename/fsync stay relative to the pinned parent descriptor.

Tests now cover trusted config and `/home`-like links; unsafe writable ancestors;
an unsafe directory hidden by chained aliases; simulated foreign ownership;
a deterministic swap between resolution and the walk; final-link replacement;
and private modes/temporary cleanup. The isolate-startup failure test now uses
an actually unsafe writable ancestor rather than a legitimate config symlink.
The differential suite includes successful linked config/home layouts and a
refused alias routed through a writable directory.

**Low clarified:** missing glibc `pidfd_open`/`pidfd_send_signal` symbols now raise
an explicit `UnsupportedError` saying that no signal was sent. There is still
no unsafe PID-based fallback. A syscall-based compatibility layer remains a
packaging consideration; an older-libc runtime was not available for validation.
The existing pidfd child-process tests continue to exercise the supported path.

Validation for this correction:

- `tools/flutter-dev check`: clean format and core/Flutter analysis,
  **18 Dart core tests, 36 differential cases and 93 Flutter tests pass**;
  the AOT fallback-exclusion check also passes.
- Explicit Devel transport tests: **4 pass**.
- Full Python suite: **1,425 tests pass**, using a private Xvfb display;
  existing resource warnings remain. Typecheck: **0 errors, 0 warnings,
  0 informations**.
- Isolated, unlaunched Devel build succeeds:
  `.flutter-previews/preview-yx3g2xl9/flutter_app/build/linux/x64/release/bundle/asterism`.
- `git diff --check` passes.

No commit, push, sync, real-desktop run or performance measurement. Phase 1
remains stopped for review.

### Phase 1 tooling follow-up — native SDK and mount guard (2026-10-28)

Fixed the Medium in `tools/diff-core.py`: PATH's Dart can be the AUR shell
wrapper, which mounts the SDK under a fixture's XDG cache. Avoiding Dart's CLI
frontend alone did not avoid that wrapper.

`tools/dart_sdk.py` now locates the native SDK executable without running any
candidate. It prefers `FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart`, then checks SDK
locations inferred from the resolved Flutter/Dart PATH entries. A directly
installed native Dart is also accepted. The selected executable must have an ELF
header and execute permission. An explicitly supplied shell wrapper is refused
before fixture creation; it is never probed by executing it.

`tools/flutter-dev` selects that binary once, uses it for Dart checks and passes
`--dart` explicitly to both the differential harness and AOT transport check.
The AOT helper uses the same native-binary validation when invoked separately.

The differential harness checks `/proc/self/mountinfo` after each subprocess,
including timeout/failure, before comparing the file tree. It decodes mountinfo
path escapes and tests path-component boundaries. A final guard covers the
whole case before temporary-tree cleanup. If an unexpected mount is found, it
reports the mount paths and preserves the fixture without recursing into the
mount or attempting an automatic unmount. Native SDK selection prevents the
reported wrapper side effect; the guard detects regressions rather than hiding
SDK files from the comparison.

Seven regression tests cover SDK discovery, wrapper rejection without execution,
mount-path parsing, guards on subprocess failure and refusal to recurse during
cleanup. No FUSE mount is created by these tests.

Validation: all **36 differential cases pass** with explicit
`--dart /opt/flutter/bin/cache/dart-sdk/bin/dart`. `tools/flutter-dev check`
passes with clean analyzers, **18 Dart tests, 36 differential cases, 93 Flutter
tests**, and the AOT check. All **1,432 Python tests pass**, including the seven
new tooling regressions; typecheck reports **0 errors, 0 warnings, 0 informations**.
`git diff --check` passes. No mounts remain under `/tmp/asterism-diff-*`.
No app build or launch was needed for this tooling-only correction.

Phase 2 is not started;
the `toml ^0.18.0` upgrade remains its first parser task after Uwe's go-ahead.
Nothing committed, pushed or synced.

### Phase 1 follow-up — retired Python provider watcher (2026-10-28)

Uwe removed the GTK app/plugin, its launchers and shortcut, old binaries, and the
Python `asterism-providers.service`. The retained settings/add-ons/agent data and
source repository are not an instruction to restore that unit.

Code trace: the only application callers of `provider_watch.ensure_service` and
`write_config` are in `ai_popup.py`, the frozen GTK UI. Flutter initialization,
provider snapshots/worker operations, map scans and terminal starts do not call
`ensure_service`. Merely starting an agent in Flutter does not schedule automatic
provider startup/shutdown; that remains absent pending the phase-4 Dart watcher.
Manual provider Start/Stop and model Load/Unload operations remain explicit
user-requested actions through the existing fixed-operation worker routes.

Added a guard against future indirect reference calls: `PythonTransport` sets
`ASTERISM_FLUTTER_DEVEL=1` in the subprocess environment, and the Python backend's
entry point sets it before initialization even when launched directly. Workers
inherit that environment. With this marker, `provider_watch.ensure_service`
returns `False` immediately for both on/off: no unit-file access, unit generation,
write, enable/start/restart, disable/stop, removal or daemon reload. The Python
reference's ordinary non-Flutter watcher behavior remains available to tests;
the Flutter reference cannot restore the removed unit through this helper.

Regression coverage mocks unit access and systemctl for both on/off, and uses a
fake reference subprocess plus its child to verify marker inheritance. No real
systemd operation or app launch was used to validate this change.

Validation: `tools/flutter-dev check` passes with **18 Dart core tests,
36 differential cases, the AOT release check, clean analyzers and 94 Flutter
tests**. The full Python suite passes **1,433 tests** on a private Xvfb display;
the focused watcher suite passes 23 tests. Typecheck reports **0 errors,
0 warnings, 0 informations**. `git diff --check` passes.

The tooling follow-up and this guard are uncommitted; no push or sync. Phase 2
still requires Uwe's go and starts with the `toml ^0.18.0` upgrade.

## Phase 2 — read-only scans (2026-10-28, Claude; Codex stopped mid-phase)

Codex wrote most of the Dart readers (catalog, details, inventory, provider scans, activity, sessions/usage,
security, map graph, read-only SQLite) and three fixture files, but switched no route on. Claude finished the
slice, compared it read-only against the Python reference on Uwe's real HOME (Asterism's own config, cache
and data folders redirected to a temporary copy; agent files only read; credential files never opened),
fixed every difference found, and switched the routes on.

### Routes now served by Dart

`app.snapshot`, `map.snapshot`, `agents.details`, `agents.activity`, `connections.snapshot`
(`readOnlyRoutes` in `read_service.dart`, added to `portedRoutes`). On the real HOME all five match Python
byte for byte, except Claude's live "last used" (its session files change during the run).

Still Python fallback in Devel (read-only, ported later in this phase or the next): `usage.snapshot`,
`providers.snapshot`, `guide.snapshot`, `system.view` / `system.cached` / `system.refresh` /
`system.mount_signature`, `existing.scan` / `existing.mounts`, `setup.detect`, `addons.list`. The session,
usage and cost readers exist in Dart with differential fixtures (`numeric_readers.json`), but no route uses
them yet.

### Differences found on the real HOME and fixed

1. **Agent list (25 vs 17):** Dart built the list from the adapters; Python uses Omarchy's agent menu
   (`setup.default.agent.*` in `omarchy-menu.jsonc`, with its icons and font) plus the app's own agents,
   and a generic-desktop fallback. Ported `agents.list_agents`/`detect` exactly; menu agents without an
   adapter (Amp, Kimi, …) use an empty `Adapter.unknown`, as Python's `harnesses.get() is None`. Cause of
   the miss: `ScanFiles.text` dropped `allowRootOwned`, so the root-owned menu was never read.
2. **DeepSeek Harness:** its hooks were not ported. New `dsh_profile.dart` (blocks, providers, default
   model, MCP inserts, built-in model choices) used by details, MCP reading, map model choices and the
   connection check.
3. **"Last used":** ported `newest_mtime` exactly (two levels with one 3,000-entry budget, then along the
   last-named date folders, link entries counted by their own mtime), with nanosecond `statx` and Python's
   float timestamp and half-even microsecond rounding (`py_time.dart`). The activity "just written" check
   uses the same function.
4. **Connections:** provider agents now come from each agent's own settings (`local_llm.dart`, the
   read side of the six `local_llm_connected` hooks), models through `chat_models`, only runtimes with a
   connect key; root-owned system skill sets (Omarchy's, OmaRAW's) are listed.

### Reference changes

- **Python bug fixed:** a DeepSeek Harness profile PyYAML cannot parse made `agents.details`,
  `connections.snapshot` and `map.snapshot` fail. `dsh_ctl.providers/default_model/mcp_servers` now read
  it as empty; writes (`connect_text`) still refuse it. Test in `tests/test_dsh_bionic.py`.
- **Reverted Codex's `remember=False`** in `flutter_backend.py` and `flutter_connections.py`: it stopped
  the MCP server library from growing (servers set up later could not be re-added from it). Only the
  differential oracle disables the write now. The Dart map does not write the library yet: that comes
  with phase 3 (writes) and is a known Devel gap until then.
- **Oracle fix:** `core_scan_oracle` patched `_scan_agents` with a default `proc` that callers override
  positionally, so map fixtures read the real `/proc`. It now always scans the fixture tree.
- Kept from Codex: no credential file reads, own-UID checks, `O_NOFOLLOW` on agent settings reads,
  `readonly_sqlite` (in-memory snapshot with WAL merge; reads up to 512 MB, today ~21 MB per scan for
  OpenCode), the narrower MCP `server_target` labels.

### Reads without the pinned walk

`ScanFiles` now opens a file with one `openat(AT_FDCWD, path, O_NOFOLLOW|O_NONBLOCK)` and checks the
opened descriptor (regular, own UID or allowed root, bounded), like the Python reference. The pinned,
trusted-parent walk from `/` stays for private writes. This also removed a behaviour difference (Python
reads through group-writable folders and folder links) and halved the scan time.

### Map scan time (real HOME, AOT, 4 runs)

| | First | Steady |
|---|---:|---:|
| Python `build_map` | 80 ms | 60 ms |
| Dart `buildMap` (before) | 242 ms | 224 ms |
| Dart `buildMap` (now) | — | 134–136 ms |

The rest is mostly the per-scan re-reading of large session data (Codex rollouts, the OpenCode database
snapshot, Claude transcripts: 12–20 ms each) and the runtime scan (~17 ms), where Python keeps caches. The
scan runs in the core isolate every 6 s, so the UI isolate never waits; other core requests wait up to one
scan. Phase 4 must not put terminal I/O behind scans in the same isolate (scans in their own isolate, or
cached readers). Not yet done: mtime caches for the session readers.

### Remaining gaps (Devel only, documented)

- Add-on agents/providers (signed add-ons) are read only by Python (phase 5); Dart uses the built-in
  adapters. Uwe's enabled add-ons are all built-in agents, so his lists match.
- The one-time settings import from the old plugin (`config_migration`) still runs when the Python
  reference starts; a first `app.snapshot` from Dart can come before it.

### Checks

Dart core: `dart analyze --fatal-infos` clean (191 issues before), 25 tests. **54 differential cases**,
two new map cases (DeepSeek Harness profile with `!!js` and an MCP insert plus failed-line hints; a broken
profile with a linked failed-lines file). Release probe now uses a write route as its unported example.
Flutter: 94 tests, analyzer clean. Python: full suite OK, typecheck 0/0/0. No real-desktop UI run.
Nothing committed or pushed.

### Phase 2, part 2 — usage and mounts (Claude, 2026-10-28)

New Dart routes: `usage.snapshot` (the shared AI run log of plugin_ai, grouped as Smart Check does),
`existing.mounts` and `system.mount_signature` (local data disks from `/proc/self/mountinfo`, the
signature in `json.dumps` form). Python-exact helpers: `py_values.dart` (`str()`, truthiness, code-point
order, `json.dumps` defaults) and `pyFromIsoformat` (Python 3.11+ calendar forms, any single separator,
basic and extended times, `,`/`.` fractions, offsets converted to local time, `24:00`; week dates are not
accepted). Six new fixture cases (a varied run log; symlink, FIFO, malformed, oversized, wrong shape). On the
real HOME all three match.

**Python bug fixed:** a run logged with an offset (`…+00:00`) made the whole Usage page fail
(`TypeError` comparing naive and aware times). `plugin_ai._when` now converts it to local time and
`smart_check.categories` uses it; test in `tests/test_smart_check.py`. The shared library
`~/Projects/omarchy-plugin-ai/plugin_ai.py` has the same bug and was not changed (its plugins are
published; Uwe decides).

**Not ported in phase 2, because they belong to Python's task or handle state:** `providers.snapshot`
(adds the focus of running tasks), `guide.snapshot` and `setup.detect` (start tasks), `system.cached` and
`system.view` (register handles for later previews), `existing.scan` (a task), `addons.list` (phase 5).
They move with the task runner (phases 3–4).

Checks: 60 differential cases, 25 Dart tests, 94 Flutter tests, AOT release probe, Python suite and
typecheck clean.

### Phase 2, part 3 — subagents ported exactly, and caches (Claude, 2026-10-28)

The Dart subagent readers were a simplification and differed from Python: "running" up to 90 s instead of
`RUNNING` 60 s, the session-reader `epoch` (dividing large numbers by 1000) instead of the subagent one,
no `kept` limit for finished ones, no age sort, a whole-tree glob, no read budget, Copilot's
`agentDisplayName` and folder pre-pass missing. New `subagent_readers.dart` ports `subagents.of`,
`claude_projects` (with `handed_back`), `opencode_db`, `from_files` (Codex rollouts, Copilot events:
bounded newest-first traversal, 32 MB read budget, opened file checked against the listed device/inode,
per-file cache by device/inode/size/mtime/ctime) and `from_db` (Goose). `posix_ffi` gained `lstatFull`,
`readChecked` and `readAt`.

Fixture: Claude subagents (running, handed back, finished, too old, broken meta, invalid names), Codex
rollouts (finished, running, ordinary fork, too old, bad parent) and Copilot events (pre-pass folder,
completed, failed without start, bad timestamp, unfinished last line), with a new per-file `age` in the
harness; the oracle now gives `claude_projects` the fixture `/proc`.

Caches: SQLite images reused while database and WAL are unchanged (up to 64 MB, four databases); JSON
reads with a limit above 1 MiB (LM Studio's model index, `~/.claude.json`, Codex's model cache) parsed
again only when the file changed.

**Map scan on the real HOME: Dart 50–53 ms steady (107 ms cold), Python 60 ms.** Checks: 61 differential
cases, 25 Dart tests, 94 Flutter tests, Python suite and typecheck clean; real HOME matches.

## Phase 3 — write path (Claude, 2026-10-28)

Steps: 3a apply/Undo, worker, task runner and routing by handle; 3b skill links; 3c MCP servers; 3d local
LLM connections (YAML/JSON transforms; DeepSeek Harness needs PyYAML-identical output); 3e map editor
previews, repair and authoring.

**Before 3a, a Devel regression from phase 2 fixed (479ea4f):** with `map.snapshot` in Dart, the Python
reference never got a map, so the map editor's move/switch/attach/repair previews resolved against an
empty graph. `current_map()` builds one when needed (reused 5 s); task focus still never scans.

### 3a, part 1 — apply, Undo and the worker

- `connect_apply.dart`: `Change`, `Plan`, `ConfigFiles.read` (connect._read: missing is "", own regular
  file, no final link, 2 MiB / 8 MiB for `.claude.json`, strict UTF-8), `write` (connect._write: owner
  bits kept, group/other dropped, exclusive temporary, fsync, rename), `apply` (stale checks twice, link
  checks, backup folder `%Y%m%d-%H%M%S-%f`, copies 0600, `manifest.json` in `json.dumps` form, created
  folders recorded) and `undo` (only what was not changed again; links, created files, retired folders,
  created folders deepest first).
- `plan_worker.dart`: `decodePlan` with the checks of `flutter_plan_wire.decode` (v1–3), and
  `asterism-core worker`: `--plan-fd N` as the Python backend passes it (private regular own file, mode
  without group/other bits) or `--plan-stdin` (length-prefixed; Dart's `Process.start` cannot pass an
  extra descriptor). Plans with context sizes or model load/unload are refused before writing: they need
  the provider engines (phase 4).
- `tests/test_dart_worker_parity.py`: one plan (a changed file with 0644 mode, a new file in new nested
  folders with non-ASCII text, a link added, a link removed) applied by the Python and the Dart worker to
  identical homes: **identical trees, manifests byte for byte**; then Python undoes the Dart backup and Dart
  the Python one: identical restored lists and trees. A file changed after the plan is refused with no
  backup and no link.

Not yet: connections routes and the task runner in Dart (3a part 2), plan builders (3b–3e).

### 3a, part 2 — task runner, previews and routing by handle

- `line_diff.dart`: the preview's added/removed line counts as Python computes them
  (`str.splitlines`, `difflib.SequenceMatcher(None, …)` with autojunk; counts are totals minus matched
  lines). 300 random cases (up to 400 lines, CRLF, ` `) match Python exactly.
- `core_tasks.dart`: `CoreTasks` (worker process per commit, progress/result lines, 4 active / 32 kept,
  commits never cancelled, Python's status shape) and `CoreConnections` (plans for 10 minutes, at most 8,
  link de-duplication and limits, 8 MiB preview bound, empty plans without a worker, backup check against
  the backup root, 16 Undo tokens, `restored` in `~` form), `encodePlan` (wire v3).
- Handles made by the core start with `core-`. `connections.apply`, `connections.undo`, `tasks.status`
  and `tasks.cancel` with such a handle are served by the core; the Flutter router sends any other handle
  to the Python reference in Devel and refuses it in release.
- The worker the core starts: `ASTERISM_CORE_WORKER`, the AOT executable itself, the Dart VM with
  `bin/asterism-core.dart`, or `bundle/lib/asterism-core`. `tools/build-flutter-preview.py` now compiles
  it into the bundle; the compiled worker leaves the same tree as the Python worker for the parity plan.
- Tests: preview → apply through a real worker → status → Undo; a file changed after the preview fails the
  task and writes nothing; empty plans; unknown handles; router handle routing.

No route produces a core plan yet: the plan builders follow (3b skill links first).

### 3b — skill sets (Claude, 2026-10-28)

`connections.preview` with `kind: "skills"` is built by the core (`corePreviewKinds`; the router sends the
other kinds to the Python reference in Devel). `skill_plans.dart` ports `skills_ctl` 1:1: native, listed and
own folders (adapters, or a checked web profile from `agent_profiles` for agents without one), `reach`
(read by itself, listed, own links into the set), `plan` (links per skill in the agent's own folder,
category folders included; Pi's and Hermes's settings lists instead), and both list writers: Hermes's
`config.yaml` as text (`skills.external_dirs`), Pi's `settings.json` through `json.dumps(indent=2,
ensure_ascii=False)`. The reply carries Python's `focus` from the last map. Hermes's listed folders in the
inventory are now read by the same text rules as Python (before: a YAML parser).

New Python-exact helpers: `pyJsonDumps` with `indent`/`ensure_ascii` and `pyFloat` (Python `repr`):
421 random documents match `json.dumps` flat and indented.

Harness: interactive cases (`refs` take a handle from an earlier reply, `until_done` polls a task), handles
masked, backup folders compared by place. The scan oracle now uses the real task runner (commits through
the Python worker) and a settings path (backup root).

Fixture: Claude links (with a category skill, a hidden and a non-skill folder), Undo, Hermes list entry,
Pi removal, an empty removal without a worker, three refusals, Hermes removal, then a map and a preview with
`focus` — same replies, same trees, same backups and manifests. On the real HOME: 100 previews (10 agents ×
5 skill sets × add/remove, 31 with changes) match.

### 3c — MCP servers (Claude, 2026-10-28)

`connections.preview` with `kind: "mcp"` is built by the core. `mcp_plans.dart` ports `mcp_ctl`: every
agent's entries read in its own format (JSON with dotted keys, Claude's `~/.claude.json`, TOML, YAML,
DeepSeek Harness's profile, LM Studio's chat, web profiles), `normal`, `native` for every shape (Claude,
Copilot, Gemini, Codex, OMP, Muse, OpenClaw, Crush, Goose with its name inside, OpenCode, profiles), the
app's server list (`mcp_library.load` with `check_entry`, used when no agent has the server any more) and
every writer: JSON (`_json_text`, `_json_dotted`), Codex/Grok TOML text, Hermes/Goose YAML text, Muse with
its required `schema_version`, OpenClaw, Claude's file, and DeepSeek Harness's inserts.

`py_yaml.dart` is PyYAML's `yaml.dump` (SafeDumper, block style, `allow_unicode`) for str, int, float,
bool, None, lists and maps: scalar analysis, YAML 1.1 implicit types, plain/single/double quoting, the
indentless sequences, 80-column splitting, escapes. 2,900 random documents match PyYAML byte for byte
(keys containing line breaks, which PyYAML writes as complex `? ` keys, are not supported).

Known limit: removing one server from a DeepSeek Harness insert that holds other entries too makes the
reference dump that whole insert again from parsed data, which needs PyYAML's YAML 1.1 reading (dates,
`yes`/`on`, `!!js` tags). The core refuses that edit before writing; the app itself always writes one
insert per server. `!!js` tags are now read like the reference (before, a profile with one showed no MCP
servers in Dart).

`mcp_library.remember` runs in Dart inventory scans too (servers in use added to `mcp-servers.json`,
0600); the oracle no longer disables it, so all fixtures compare the written list.

Fixtures: Claude/Hermes/Goose/Muse/OpenClaw/Codex adds, a removal with Undo, a server from the app's list,
five refusals; DeepSeek Harness add (with a wrapped long value and quoted `'true'`), remote add, removal,
Undo. Real HOME: 252 previews and 448 plans (15 agents × 14 servers × add/remove, all formats including
DeepSeek Harness): 300 planned file texts identical byte for byte, `~/.claude.json` (89 KB) included.

### 3d — local LLM connections (Claude, 2026-10-28)

`connections.preview` with `kind: "provider"` is built by the core when it disconnects, or connects without
a chosen model. `llm_plans.dart` ports `connect.plan` (with `replaces` for moves) and the six agents'
`local_llm_transform` hooks 1:1: Hermes (providers block as text; the model block taken over by the next
provider or removed; `model_text` with its layout checks), Oh My Pi (models.yml and modelRoles), Pi
(models.json keeping input/reasoning/compat; settings.json default), OpenCode, OpenClaw (keeping per-model
settings, empty tables removed) and DeepSeek Harness (`connect_text`). Provider labels come from the
generated provider facts (`connect_labels`).

`pyYamlLoad` reads YAML like PyYAML's SafeLoader for entries that are dumped again (`yes`/`on` booleans,
`0x`/octal/sexagesimal ints, floats only with a dot, `~`/empty as null); dates, explicit tags, anchors,
aliases and merge keys refuse. 716 documents match `yaml.safe_load`. With it, removing one server from a
DeepSeek Harness insert holding others now works as in the reference (the 3c limit is gone; entries with
such values still refuse).

**Not yet:** a connection with a chosen model brings the provider's extras (`connect_extra`: LM Studio's
model context in its settings, llama.cpp/Ollama contexts sized for the graphics card through
`context_ctl` and `gpu_usage`, Ollama's API). Those previews stay with the Python reference until the
provider engines move (phase 4); the router decides by `remove`/`model`.

Fixture: six agents disconnected from llama.cpp (each with its default-model rule, Hermes switching to the
remaining provider, a DeepSeek Harness entry with `yes` and `0x1F` dumped again as `true` and `31`), then
connected to Ollama without a model, Undo, four refusals. Real HOME: 36 plans (6 agents × 3 local LLMs ×
connect/disconnect), 25 new texts identical byte for byte, DeepSeek Harness's real `llm-pi-ai` entry
included. Checks: 65 differential cases, 29 Dart tests, 94 Flutter tests, Python suite and typecheck clean.

### 3e — map edits and authoring (Claude, 2026-10-28)

`map_edits.dart`: `connect.chain` (staged reads in `ConfigFiles`) and `connect.merge`;
`connections.move_preview` (a provider line moved to another local LLM with `replaces`, provider, MCP and
skill lines removed, the dangling-model check, an unapplied failure cleared alone, the failure entry removed
in the same backup and Undo); `connections.author_preview` (a new MCP server for chosen agents through
`check_entry`, or a skill-set folder with the bounded scan; Python's notes; focus from the last map);
`connections.repair_preview` for MCP and skill lines and local LLM lines without a model. The core keeps
Python's `current_map` rule (rebuilt after 5 s).

Routing: move and authoring always go to the core. Repair goes to the core first; a local LLM line that
needs its model back answers `unported_route`, and the Devel router then asks the reference (previews
change nothing). `models.switch_preview` and `models.attach_preview` plan connections with a chosen model,
load/unload actions and cloud model changes: they stay with the reference until phase 4.

Fixture: repair (Claude's file and the failure entry in one Undo), Pi moved from llama.cpp to Ollama, a Codex
MCP line and a Pi skill line removed, an unapplied OpenCode failure cleared, a new MCP server for Claude and
Hermes, a skill folder for Claude, five refusals — a fresh map before each edit. Checks: 66 differential
cases, 29 Dart tests, 94 Flutter tests, Python suite and typecheck clean.

### Phase 3 status

In the core: apply/Undo, the worker, the task runner, routing by handle, and every connection preview
except those that choose a model. Waiting for the provider engines (phase 4): connections with a chosen
model (`connect_extra`/`context_ctl`, Ollama's API), `models.switch_preview`/`models.attach_preview`
(model load/unload, online model plans), and the model actions in plans.

## Phase 4 — processes and providers (Claude, 2026-10-28)

Steps: 4a provider overview; 4b provider operations (start/stop, load/unload) through the worker; 4c
context sizes for the card (`context_ctl`, `gpu_usage`), connections with a model and the model previews;
4d model search, downloads, pulls and imports; 4e `asterism-core provider-watch`; 4f terminals, agent start
and the stop guard.

### 4a — provider overview

`providers.snapshot` is served by the core (it needs only the map for its focus, not Python's tasks; the
phase 2 note was wrong). Engine facts (`can_load`, `download`, `removable`, installer `can_install`, LM
Studio's `lms` control) and the online providers are generated into the provider facts by
`tools/adapter-assets.py`. Fixture: after a map, the overview with focus, model folders from the settings
(non-text entries skipped) and a refusal; the real HOME matches except focus (the comparison script runs
each Dart request in its own process).

### 4b — runtime and model operations

`providers.run` for `runtime.start`, `runtime.stop`, `model.load` and `model.unload` runs in the core's
worker (`asterism-core worker` without a plan, as `flutter_worker.py` does), with Python's checks and focus.
`provider_ops.dart`: `loopback_listeners` (`/proc/net/tcp{,6}`, loopback-reachable addresses only) and the
own-UID check before any request, `http_json` (127.0.0.1 only, 1 MiB replies, one body with its length),
the engines' actions (systemd user units or `lms` for start/stop; llama.cpp and Jan's router API; Ollama's
`keep_alive`; `lms load`/`unload`; engines that cannot unload one model stop the server), and
`runtime_ctl.load` starting the server first and waiting up to 30 s.

`tests/test_dart_provider_ops_parity.py`: a fake llama.cpp router (own socket on 127.0.0.1), a fake
`systemctl` and a user unit; the Python and Dart workers run the same eight operations (load, unload,
unknown and malformed model, stop, start, a provider not installed, an unexpected field): same results,
same HTTP requests and bodies, same `systemctl` calls. Found and fixed on the way: Dart sent request
bodies chunked, Python with a length. A Dart test covers listeners of another account and non-loopback or
non-listening sockets.

Not here: the "installation running" guard of the reference (installs still run in Python's tasks).

### 4c part 1 — connections with a chosen model

A provider preview with a model (agent card, map drag with a model) is planned in the core. New
`context.dart` ports `llm_engine.connect_extra` and the parts of `context_ctl` it uses: GGUF headers
(`read_gguf`, KV layout, size per token), `best_context` against the total VRAM (sysfs, then
`nvidia-smi`), llama.cpp's `models.ini`, Ollama's manifests and `server.env`, LM Studio's model entries,
defaults and `.internal` settings. The agent gets the context size in its config. LM Studio gets a
defaults file change. Ollama gets an API context that is set after the files. The worker applies it
through `/api/create` on the account's own port, counting failures as `context_failures`, the way the
reference does.

Validation as in Python: a model must be a valid name and one of the runtime's chat models. Use now needs
a model. Jan and KoboldCPP contexts are refused with a model (`Unsupported`); they stay in Python until
4c part 2.

Checks:
- Real HOME: 72 plans with models (6 agents × llama.cpp/Ollama × 3 models × use now on/off) give
  identical texts and contexts in Python and Dart.
- 45 context fits on 15 real GGUF files match Python.
- `tests/test_dart_provider_ops_parity.py` has a fake Ollama. Both workers apply a plan with three
  contexts (one accepted, one refused by the server, one on a closed port). Results: same file, same
  requests and bodies, 2 failures on each side.

Found and fixed on the way:
- Dart carried a context as a flat `runtime`/`address`, while `flutter_plan_wire` carries the whole
  runtime record. Dart now uses the record, and `decodePlan` refuses unknown record fields, as
  `Runtime(**record)` does.
- `mergePlans` compared contexts and model actions by identity (Dart maps). It now compares them by
  value, like Python.

Still Python (4c part 2): `models.switch_preview`/`models.attach_preview`, model actions in plans
(`validate_actions`, the model guard), online model plans, repair with a model, Jan/KoboldCPP contexts.

### 4c part 2a — model previews on the map (local LLMs) and model actions

`models.switch_preview` and `models.attach_preview` for local LLMs are built in the core
(`MapEdits.modelPreview`, a port of `flutter_map_editor.preview`). It checks the shown map against a fresh
build for switches. The model's users move to another of its models or lose it; attach gives chosen agents
the model. An engine that can load gets the unload/load actions and the note that Undo does not reverse
them.

Online models answer `unported_route`. The router falls back to the reference in Devel (now in
`coreFirstRoutes`); they follow in 2b.

New pieces:
- `LocalLlm.active`: `connect.is_active` with each adapter's `local_llm_active` reader (Hermes, Oh My Pi,
  Pi, OpenCode, OpenClaw, DeepSeek Harness) and the fixed-provider rule.
- `model_guard.dart`:
  - `gpu_usage` as far as `snapshot(...).generating` needs it: discrete GPU, busy percent, the
    runtimes' processes and their children, DRM `fdinfo` VRAM per process, and each engine's
    `loaded_models` (including `lms ps --json`). The snapshot is taken whole, as the reference takes it.
  - `agent_instances`, `_guard_model` and `validate_actions`.
- The worker validates the model actions before writing. After the files and the contexts it runs each
  action, checking it again first; a failure is counted in `context_failures`, as `flutter_worker` does.
- **The guard in a synchronous service:** the preview asks the worker (`asterism-core worker --guard
  JSON`, answered before stdin is read). The worker reads the GPU and asks the runtime with the
  reference's time limits. A synchronous socket has no timeouts, which is why it isn't used.
- Repair with a model: `use_now` follows the model, as in the reference. Jan and KoboldCPP contexts go to
  the reference through `corePreview`.

Checks:
- New fixture `model_previews.json` (switch, detach, attach, 5 refusals): Python = Dart. The batch path of
  `diff-core.py` now masks plan handles too.
- Real HOME, read-only: 69 previews (all llama.cpp/Ollama models with users, plus attaches for every
  agent) give the same results in Python and Dart: 38 plans and 31 refusals. The guard ran against the
  real GPU and llama.cpp, read-only.
- `tests/test_dart_provider_ops_parity.py`: both workers apply a plan with unload and load against a fake
  llama.cpp router. Results: same file, same requests (the guard's `GET /models` before writing and again
  before the unload), and the same refusal for a model the runtime does not have.
- A Dart test checks process ownership (`runtime_of`) against 13 Python answers.

Still Python (2b): online model plans (`online_models`), Jan/KoboldCPP contexts.

### 4c part 2b — online models on the map, Jan and KoboldCPP contexts

- **Online models:** `online_models.dart` ports `online_models` (`choices`, `target`, `plan`) with the
  switchers of the built-in adapters:
  - Claude Code's aliases, and Codex's `models_cache.json` and `config.toml`.
  - The `models_choices`/`models_plan` hooks of Pi, OpenCode, Hermes and DeepSeek Harness (the new
    `dshModelText` = `dsh_ctl.model_text`).
  - The model previews build online switches and attaches in the core. An add-on agent's own switcher
    (its hooks) answers `unported_route` and stays with the reference until phase 5.
- **Jan and KoboldCPP contexts** are in `connectExtra`:
  - Jan: `jan_ctl.settings` and `context_changes` (its preset and `model.yml` in one backup).
  - KoboldCPP: `kobold_ctl.settings` and `context_text` (the `.kcpps`, ASCII-escaped as Python dumps it).
  - With these, every provider preview is built in the core, and repair no longer falls back.
- **Found and fixed (a 4c part 1 bug):**
  - The VRAM read refused sysfs files, because they report 4096 bytes and the read checked the size
    against its 64-byte limit. So Dart never fitted a context.
  - The 4c-1 real-HOME check didn't show it: every model there already had a context.
  - Reads of sysfs and `/proc` now take the head, as Python does (`vramTotal`; `gpu_usage` busy, uevent,
    fdinfo, stat). Dart now reads the same VRAM (25.7 GB), card and PCI slot as Python.

Checks:
- New fixtures, all Python = Dart:
  - `jan_kobold_contexts.json`: a synthetic GGUF; Jan fit (preset + `model.yml`), kept, missing file;
    KoboldCPP fit, kept, no model file; applied for two agents.
  - `online_models.json`: switches for Claude, Codex, Hermes + Pi together, and OpenCode; an attach;
    four refusals; applied.
- Real HOME, read-only: 155 model previews (local and online providers, every agent) give the same
  results: 50 plans, 105 refusals. The 72 provider plans with models are still identical.

Phase 4c is done. Still Python in phase 4: 4d (model search, downloads, pulls, import), 4e
(`provider-watch`), 4f (terminals, agent start, halt).

### 4d part 1 — Hugging Face search and file lists

`models.search` and `models.files` (`providers.run`) run in the core's worker:
- `model_hub.dart` makes web requests as `netfetch.fetch` does: `curl` with its config and headers on
  stdin (never in argv), https only, at most 3 https redirects, `--fail`, the answer capped in size and
  time (`read_bounded_output`).
- It ports `models_ctl`: `_repo_from`, `capabilities`, `search` (URL with `urllib.parse.quote`, chat and
  vision tasks only) and `files` (split files as one entry, no `mmproj`, a stable sort by size, quant
  tags, `recommend`).
- `ProviderOps.validate` now has all nine shapes and rules of `flutter_providers.validate`. Downloads,
  pulls and imports are validated the same way but still run in the reference (4d part 2).

Checks:
- `tests/test_dart_model_hub_parity.py`: a live Hugging Face answer (50 repos, 34 files), saved trimmed
  in `tests/data/hf_answers.json` with hand-made edge cases (bad IDs, negative/huge/bool counts, odd
  dates, non-chat tasks, split parts, sub-folders, `..`, string and float sizes, size ties, unicode).
  Both sides get it for four searches and two file lists: same results and the same URLs.
- Live, read-only: both workers run search and file list against Hugging Face and give the same results
  (25 repos, 25 files), and the same error for an empty query and a repository that doesn't exist.

### 4d part 2 — downloads, pulls and imports

`models.download`, `models.pull` and `model.import` run in the core's worker, and their progress lines are
written as `flutter_worker` writes them. `model_downloads.dart` ports:
- **Downloads:**
  - `install_ctl.open_staging`: created exclusively and no-follow, or our own regular file with one name
    to resume.
  - `install_ctl.download`: curl writes to the open file (here through a pipe), resumes at our own size,
    is capped by the announced size, and the file is renamed only while the name still points at it.
  - `gguf_target`: LM Studio's publisher layout; a llama.cpp router folder of links gets the file next to
    its link targets, but only into private folders.
  - `_part_sizes` and `download_gguf`.
- **Imports:** `add_local` (a hard link on the same disk, else a symlink; LM Studio's `local/<name>/`
  with its vision projector; split parts) and `ollama create` from a Modelfile.
- **Pulls:** `ollama_pull`, Ollama's progress stream from its own port with the reference's limits
  (headers in 30 s, 120 s of silence at most, 12 h overall, 64 KiB lines, 200000 lines).
- `Posix` gains `truncate`, `statFull` / `lstatOwn` (link count, identity) and `hardLink`
  (`AT_SYMLINK_FOLLOW`, as `os.link`). The provider facts gain each engine's `layout`.

KoboldCPP's downloads and imports stay with the reference (router by `key`): its refresh writes a `.kcpps`
per new file through its installer class (phase 5).

**Found and fixed in the reference too:** `flutter_providers.validate` asked `models.download`'s `file`
to be a `.gguf` path. But the app sends the entry's shown name (`models_ctl.files`: no folder, no
`.gguf`), which `execute` looks up. So every download started from the Flutter app was refused as
"Invalid model filename", and the unit tests hid it with unrealistic names. Both sides now check the
shown name (`ENTRY_NAME_RE`), with a test that real `files()` names pass.

Checks:
- `tests/test_dart_model_files_parity.py`, two identical homes, a fake `ollama` CLI and a fake Ollama
  server on its own port:
  - imports into llama.cpp (a hard link, split parts), LM Studio (`local/a/` with `mmproj`, an odd
    name), Ollama (`ollama create`, Modelfile, `OLLAMA_HOST`), and three refusals;
  - pulls (progress fractions 0, 0.25, 1, a `null` status, an error, a provider without pulls, a bad
    name);
  - result: the same answers and progress lines, the same trees and link counts, the same requests.
- Live, read-only on the network (llama.cpp's own test models from Hugging Face): fresh, resume from
  our own partial file, kept complete file, split file, LM Studio's layout, a router folder of links,
  changed size, missing entry. Both workers give the same answers and trees.
- A Dart test checks the staging file: resumed only when it's ours with one name, never through a link
  or a second name.

Phase 4d is done.

### 4e — the provider watcher

The Flutter app had no "Start local LLMs with their agents" yet: the Python backend never wrote the
watcher's config, and Devel blocks its unit. Now:
- **The service loop:** `asterism-core provider-watch --config FILE` (`provider_watch.dart`) ports the
  watcher:
  - checked config entries (units, ports, the `lms` controller, the stays-up unload request) and the
    `Watcher` loop: start on the first agent, stop after the 5 s grace time, not while another program
    has a connection open (ESTABLISHED, background servers' sockets left out), a failed start tried
    again after 30 s;
  - the saved state (`~/.local/state/ai-agents-map/provider-watch.json`, shared with the reference) and
    shutdown on SIGTERM;
  - LM Studio: `lms server`, and after it the background app we started, every process held by a pidfd
    (engines with SIGTERM, then the program and helpers with SIGKILL, the AppImage last);
  - exit 75 when the binary was updated.
- **The app side:** `WatchService` writes `providers-with-agents.json` after each inventory scan
  (`ReadService.onInventory`). It turns the user unit `asterism-providers.service` on or off when the
  file or the setting changes, the way `sync_provider_watch` / `ensure_service` did. A unit pointing at
  the old Python script is rewritten, which is the unit migration.
  - Only a compiled release core manages the unit: never a Devel build (`ASTERISM_FLUTTER_DEVEL`,
    `ASTERISM_DEVEL`) and never a run from source, because Devel has the same identity and config folder
    as the release.
  - The reference's `build_map` writes the same config (it never manages the unit).
- `Posix` gains `pidfdOpen` / `pidfdSignal` / `pidfdExited`. The provider facts gain the `unload`
  request.

**Found and fixed in the reference:**
- `provider_watch._read` imported `ai_core`, but the service runs with `python3 -I`, where that import
  fails. So every tick ended in "No module named 'ai_core'" and the watcher never started or stopped
  anything. It's now `read_head` in the standard library. The published plugin and the plugin repo
  never had this import.
- The order in which runtimes were stopped came from a set of strings, so it differed per process (hash
  seed). Both sides now sort it.

Checks:
- All 69 differential cases pass with the config written on both sides.
- Real HOME, read-only: the config text is byte-identical in Python and Dart.
- `tests/test_dart_provider_watch_parity.py`:
  - 12 scripted scenarios, built from the reference's tests: the same commands, unloads, LM Studio
    calls and saved state after every step. They hold across hash seeds.
  - Both services as real processes, with a fake `systemctl` and a fake agent process started, ended,
    started again, then SIGTERM: the same `systemctl` calls and the same saved state.
- A Dart test checks that only a compiled release core manages the unit.

### 4f part 1 — terminal sessions, agent start, project folders

`sessions.start`, `sessions.read/write/resize/stop` (handle routes, `core-` handles) and
`projects.pin/forget` are served by the core:
- **`pty_sessions.dart`:** PTYs through FFI. Dart cannot fork, so an agent starts with `posix_spawn`:
  - a new session, all signals back to their defaults and none blocked (the Dart VM ignores `SIGPIPE`);
  - the slave opened as fd 0 (the session leader takes it as its controlling terminal), fd 1 and 2
    copies of it, the project folder as working folder, every other descriptor closed;
  - the size set on the master, non-blocking reads, input accepted only when the PTY is writable,
    resize with the same bounds.
- **A Dart-specific risk, handled:**
  - Dart's process thread `wait()`s for any child while it has processes of its own, so it can reap an
    agent. Each agent is held by a pidfd; its exit code comes from `waitid(P_PIDFD)` when we get it
    first, else -1 (the app reads only `text` and `ended`).
  - The group is never signalled by number (`killpg` after a foreign reap could hit a reused group).
    The leader and the group members, known by their start time, are signalled through pidfds.
  - The group is remembered while the leader runs (on `read`, at most once a second) and at its exit
    while it is still our zombie. So a background child is stopped even when Dart reaped the leader.
- **`agent_start.dart`:** `flutter_backend.start` (the agent's `start` arguments, no chat apps; the
  environment without agent-session variables, with mise's shims and `~/.local/bin`; an outside
  terminal through `env -u …`), `agent_projects` and the project routes. `Desktop.openTerminal` ports
  `xdg-terminal-exec` (Omarchy) and the generic terminal list. `SettingsStore.saveOwn` writes the
  service's own values (still checked).
- The release check and the router test now use `installers.preview` as their example of a route the
  core doesn't serve.

Checks:
- `tests/test_dart_pty_sessions_parity.py`: one scripted program through Python's `Sessions` and the
  Dart sessions gives the same output and exit code: size after a resize, ignored and blocked signals
  (`SIGPIPE` not ignored), session leader, controlling terminal, working folder, environment, echoed
  input, UTF-8.
- `tests/test_dart_agent_start_parity.py`: both services start a fake installed agent, read until it
  ends, start again in another folder, pin, unpin, forget, and refuse an unknown agent and a missing
  folder. Same answers, output and saved project settings.
- A Dart test: stopping a session ends its group (the leader and its background child) and leaves a
  process that moved into its own session alone; after the leader ended, its remaining background
  child is still stopped.

Still Python in phase 4: `agents.halt_preview/apply` (4f part 2). Agent actions (install, update,
uninstall, login) belong to the installers, phase 5.

### 4f part 2 — halting agents

`agents.halt_preview` and `agents.halt_apply` are served by the core (`agent_halt.dart`):
- **Preview** (`flutter_map_instances.preview`, `agent_terminals.instances`): the agent's instances
  that run outside this app's own terminals (the core's PTY sessions and their descendants are left
  out), with a known start time, each with a token valid for 300 s.
- **Apply:** the instance (command, pid, start time) goes to the worker as a private operation.
  `CoreTasks.startPrivate` generalizes `startPlan`, and the worker accepts `agents.halt` by fd or stdin,
  as the reference sends it.
- **Halt** (`agent_terminals.stop`): still an instance of that agent, then SIGTERM and SIGKILL after
  3 s. Only this account's process, only while its start time matches to the tick, every signal through
  a pidfd held before that check.

**Found and fixed in the reference:** `flutter_worker`'s list of allowed private operations didn't
have `agents.halt`, although `execute_private` handles it. So every "stop this agent" from the Flutter
app ended as a failed task.

Checks: `tests/test_dart_agent_halt_parity.py` runs both services with a fake agent outside the app
and the same agent in the app's own terminal:
- only the outside one is listed;
- it ends with SIGTERM (-15), and an agent that ignores SIGTERM ends with SIGKILL (-9);
- a used preview and an unknown agent are refused.

The same answers on both sides.

Phase 4 is done. Still Python: phase 5 (installers, agent actions install/update/uninstall/login,
add-ons, existing-AI import, system moves; data-only add-ons need Uwe's OK) and phase 6 (the remaining
parity).

## Phase 5 — installers and add-ons (Claude, from 2026-10-29)

Uwe, 2026-10-29: add-ons become **data only**. Steps:
- **5a** add-ons: 5a-1 verification, list, switching on and off; 5a-2 catalog, install, update, remove.
- **5b** installers (`install_ctl`): `installers.preview/install`, agent actions (install, update,
  uninstall, login).
- **5c** setup and the first-agent guide.
- **5d** `models.remove`, the phase 4 leftover.

Not in phase 5 (phase 6): `system.*`, `existing.*`, `app.settings_changed`.

### 5a-1 — add-ons as data: verification, list, switching

**`addons.dart`** ports `addons.verify` and `find`, and `flutter_addons.AdapterRegistry`:
- the same checks: folder and files trusted, no links, file count and size limits, only the allowed
  files, the manifest's hashes, the `addon.json` rules (id, version, API, privacy, kind, needs,
  detect, provides, extends, capabilities, a shapes-only `icon.svg`);
- the user folder (`$XDG_DATA_HOME/asterism/addons`) wins over the system folder, an `addons/`
  folder next to the app executable, which packaging fills in phase 7.

**Data only:** nothing of an add-on runs.
- An agent add-on's `agent.toml` is read from its verified bytes. Facts newer than its API come from
  the app's own adapter (`harnesses._with_newer_facts`, including the research rule).
- The code the app's own signed add-ons carry is built into this core, which uses its own: the
  `llm-*` providers, `providers-online`, and the `hooks.py` of the six built-in agents (dsh, hermes,
  omp, openclaw, opencode, pi).
- Any other code is refused with "needs an update": an `addon.py` / `hooks.py` the core doesn't have,
  and a feature add-on with code (Insights). Python's backend listed Insights as verified-unsupported,
  but it never ran there either.

**Signatures:** `sshsig.dart` verifies OpenSSH's SSHSIG format natively (ed25519 per RFC 8032,
SHA-512/256, namespace `asterism-addon`, only Uwe's key). It replaces `ssh-keygen -Y verify`, because
the synchronous service can't hand the manifest to it on stdin, and it removes the OpenSSH dependency
for macOS. All 25 signed add-ons verify in about 3 ms each; tampered manifests, other namespaces,
other keys and changed signature bytes are refused.

**Hidden and shown, as the reference does:**
- A built-in agent or provider that comes as a verified add-on is shown only while that add-on is on.
- `provider_facts.dart`: `visibleProviderFacts` gives the local list, connect keys and labels, the
  online list, cloud boxes and provider names without the hidden providers. Loaded ones come after the
  visible built-ins (local LLMs in `LOCAL_ORDER`, online ones in the order they were added), as
  `providers.local` / `online` order them.
- Every reader of those facts uses it. The generated provider facts now carry each online provider's
  agents and IDs.

**Routes:** `addons.list` (including sign-ins for provider add-ons) and `addons.set_enabled`
(reload, rollback when a switched-on add-on doesn't load, `addons_enabled` saved). The registry loads
when the core starts, as `initialize` does.

Checks:
- All 69 differential cases still pass (no add-on folders there, so nothing hidden).
- `tests/test_dart_addons_parity.py`, with Uwe's real signed add-ons and tampered copies (a changed
  `agent.toml`, an extra file): same listing, states, switching results, visible agents, local and
  online providers, and saved setting. The one intended difference is Insights.
- Real HOME (add-on folder and enabled list as they are, settings copied): same listing and same
  visible agents and providers.
- A Dart test for the signature check (good, changed message, other namespace, other key, changed
  signature byte, garbage).

### 5a-2 — add-on catalog, install, update, removal

**`addon_store.dart`** ports `addon_store` and `flutter_addon_catalog`:
- **Catalog:** checked catalog entries (`entry_from`: IDs, versions, the download address on the
  add-ons repo's releases, sizes, hashes, needs, detect hints). `parse_catalog` gives the newest
  version this Asterism can load per add-on, and only when `catalog.sig` verifies with Uwe's key (the
  native SSHSIG check). The catalog is fetched with `curl` as `netfetch` does, cached for 6 h in
  `~/.cache/asterism/catalog.json`, and kept from the cache when looking online is off.
- **Install:**
  - the zip is downloaded, its size and SHA-256 compared with the signed catalog;
  - it is unpacked with a small zip reader (stored and deflated entries; only `<id>/…` names, no
    `..`, no links, one ID, file count and size caps; files created exclusively, folders 0755);
  - the add-on's own signature and hashes are checked;
  - only then does it replace the installed copy, whose old folder goes to the trash
    (freedesktop layout, as Gio puts it).
- **Worker steps:** `addons.catalog` (records with the installed versions, size-bounded) and the
  private `addons.install`. Under the same `flock` as the reference, the worker resolves the signed
  catalog again, requires the reviewed entry to match, the installed version unchanged and only a
  newer one to replace it.
- **Core routes:** `addons.catalog` (previews: only the ID, texts and a token reach the app),
  `addons.install` (the guard: no running agent, no other install, looking online on;
  `finish_addon_install` reloads the registry), and `addons.remove_preview/apply/undo`
  (`flutter_addon_actions`: only user add-ons, the folder's identity checked again, moved into
  `addon-backups` with Undo, backups older than 30 days pruned).
- `Posix` gains `flock`. `CoreTasks.start` takes an optional result handler.

Checks:
- `tests/test_dart_addon_store_parity.py`:
  - Uwe's signed `catalog.json` gives the same entries; a changed catalog is refused on both sides.
  - Real signed zips from `dist/` and seven tampered ones (wrong ID, changed file, extra file, link,
    `..` name, two IDs, garbage) give the same results and the same folder tree: first install,
    update, and an add-on with built-in code.
- Live, read-only on the network: both services fetch the real catalog (25 entries) and install
  agent-goose 0.11.1 from its GitHub release. Then list, remove, list, Undo, list, a refused second
  Undo, and the catalog again ("installed", no action). Every step's answer is the same.

### 5b-1 — agent actions

`agents.action_preview` / `agents.action_apply` are served by the core (`agent_actions.dart`):
- **`install_recipes`:** the agent's ways (mise, npm/pipx/uv, commands, system packages, manual,
  the app's installer page) as the step for this PC. It picks the package manager, starts only plain
  words, and updates and removes through the way the agent is installed now. When nothing works here,
  every command is still offered to copy.
- **`flutter_agent_actions.resolve`:**
  - install, update and uninstall from the recipe (uninstall names the data folders that stay);
  - sign-in (the adapter's `access.logins`, translated labels and notes) and sign-out;
  - the first-agent test (the adapter's `ask` with the fixed prompt);
  - Node.js through mise as a prerequisite.
  No command, argv or URL comes from the app.
- **Apply:** resolves again and requires the same plan, and refuses an update or removal while the
  agent runs in the app. External steps run in one terminal window. Sign-in, sign-out and the test run
  in a PTY session without agent-session variables and without the agent's providers
  (`AI_AGENTS_MAP_NO_PROVIDERS=1`); the test runs in a temporary folder.
- **The test's result:** the session's reads are watched (`observe`, the last 4 KiB without escape
  codes), and an answer marks the agent as working in `first_agent.verified`.
- `Desktop.runStepsInTerminal`: Omarchy's floating terminal or `xdg-terminal-exec`; generic: `bash -c`
  with the "press Enter" prompt. `shellQuote` / `shellJoin` port `shlex`.

Check: `tests/test_dart_agent_actions_parity.py` runs both services with a fake agent, a fake mise and
a fake terminal that only logs:
- previews for install, update, uninstall, both sign-ins, an invalid sign-in, sign-out and the test,
  an unknown agent and Node.js;
- install through the terminal, a reused preview, the test session (its answer saved) and a sign-in
  session.

The same answers, terminal commands, session output and `first_agent` on both sides.

### 5b-2 — program installers

`installers.preview` / `installers.install` are served by the core (`installers.dart`, `tar_check.dart`):
- **Releases:** the newest GitHub release, every asset with the SHA-256 GitHub lists for it
  (`github_release`), checked again as a kept release (`Release.from_json`). A preview without a
  complete checksummed release is refused.
- **What installs:** Ollama, llama.cpp, KoboldCpp and Jan (local LLMs shown on the map) and mise (the
  first-agent guide's tool). They never install from here, in the reference too, and are refused:
  - LM Studio and Bionic: no published checksum;
  - vLLM and dsh: pip/npm, no release files;
  - agy: its manifest names no size.
  Adapters cannot declare a `download`, so the reference's `Declared` installer has no use here.
- **The checks of `flutter_installers.installer`:**
  - only a program that is missing;
  - not installed another way (the provider scan, or the tool on PATH or in `~/.local/bin`);
  - no existing `~/.local/bin` link, settings file or user unit is replaced.
- **Install (worker, private plan):**
  - under the add-on installers' lock, with the add-ons of the chosen settings;
  - the preview prepared again and required to be the same;
  - downloads checked against their checksum (`ModelFiles.download` gained `sha256`; SHA-512 for
    128 hex digits);
  - archives checked before unpacking (`checkArchive`, below), then `tar` without owners or modes;
  - one top folder flattened; version folder, `current`, the marker and the `~/.local/bin` link;
  - the settings file (0600), `configure` (llama.cpp's `models.ini`; KoboldCpp's `.kcpps`; Jan's data
    folder, preset and desktop entry), the user unit and `systemctl --user`.
  - Jan's AppImage unpacks itself closed in by bubblewrap, stopped when it grows past 20 GiB
    (`runWithDiskBudget`).
- **`checkArchive`** ports `install_ctl.check_archive` with its own tar reader (ustar prefix, GNU long
  names, pax, base-256 sizes; zstd through `zstd -dc`, gzip by `dart:io`). It ends the archive where
  `tarfile` does: an empty file, a bad first header or a short body is an error; a later bad header
  ends the archive.
- **KoboldCpp models:** `kobold_ctl.sync` is ported (`koboldSync`), so `models.download` and
  `model.import` for KoboldCpp now run in the core too (`engine.refresh` after the file is added).
- Installs count as commits (never cancelled) and as running installations for the add-on guard.

Check: `tests/test_dart_installers_parity.py`:
- 22 crafted archives through `check_archive` and `checkArchive`: good links, absolute and `..` names,
  links out and through links, devices, size and entry limits, long names, zstd, truncated and garbage;
- `kobold_ctl.sync` with split models, projectors and stale entries;
- both services with a fake `curl` serving release lists and assets, and a fake `systemctl`:
  - previews of all five, a wrong build, LM Studio, vLLM, an agent, an unknown key and bad shapes;
  - installing mise, llama.cpp (start now and at login), KoboldCpp and Ollama (two zstd assets);
  - a used preview and a preview of an installed program.

The same answers, files (contents and modes) and service calls on both sides.

### 5c — setup and the first-agent guide

The core serves `setup.detect`, `setup.apply`, `setup.later`, `guide.snapshot` and `guide.choose`
(`first_agent.dart`):
- **The routes:** `first_agent.load`/`parse`. A loaded add-on's `first-agent.json` comes first (its
  verified bytes), else the app's own, now embedded by `tools/core-assets.py`. Only entries that hold
  up are kept.
- **`guide.snapshot`** (worker, with the add-ons of the chosen settings): each route's checklist as in
  `flutter_first_agent.snapshot`:
  - its add-on, mise and Node, the agent (`install-agent` for an adapter with an installer);
  - online: sign-in or key (`credentials_present`: a variable or a file that exists, never read);
  - local: the local LLM (`install-runtime` when `installers.dart` can install it), a model and the
    connection (`LocalLlm.connected` and `active`);
  - the test question.
  Texts are translated by the service tables.
- **`setup.detect`** (worker): `AdapterRegistry.installed`. Every agent and provider add-on is switched
  on for the look (the agent detected, the local LLM scanned), then the choice is put back.
- **`setup.apply`:** the add-on guard; the selection checked (no duplicates, only verified add-ons);
  other add-on choices kept; reloaded and put back on failure; `addons_enabled` and `setup_done` saved.
  Returns the add-on list.
- **`setup.later`** saves `setup_done`. **`guide.choose`** saves the route in `first_agent`
  (`later: false`).

Check: `tests/test_dart_setup_guide_parity.py` installs seven of Uwe's signed add-ons in a temporary
HOME with a fake Claude (signed in, already tested) and a fake llama.cpp:
- detection, the guide with the add-ons off and on, choosing a route;
- setup with duplicates, an unknown add-on and a valid choice; later, and refused shapes.

The same answers and saved settings on both sides. (The reference needs `initialize()` and `ssh-keygen`
on PATH for its add-on registry; the Dart core verifies natively.)

### 5d — removing models

`models.remove_preview` / `models.remove_apply` are served by the core (`model_removals.dart`):
- **The record** (`flutter_removals._record`):
  - the runtime, its model and its engine's `removable` (`file` or `api`);
  - the model folder's identity;
  - for `file`, `models_ctl.removal`: llama.cpp and KoboldCpp the `.gguf` (all parts of a split one, or
    only the link); LM Studio the model's files with the vision projector when nothing else is left.
    Only this account's own entries inside the folder count.
  - other local LLMs that read a file that goes through a link (`links_into`, four levels) are named;
  - each file's lstat identity, so a change after the preview is caught.
- **Preview:** an opaque handle for five minutes, eight at most, with the task focus.
- **Apply** (worker, private, a commit):
  - the record built again and required to be the same;
  - files go to the desktop's trash through `gio trash` (the same `g_file_trash` the reference calls,
    so they can be restored); Ollama's models through its own `DELETE /api/delete`, only to this
    account's listener;
  - then KoboldCpp's `.kcpps` follow the files.

Check: `tests/test_dart_model_removals_parity.py`, both services with a llama.cpp model folder, LM Studio
linking to one of its models, and a fake Ollama server:
- previews: a shared model, a split part, a link, an Ollama model, a missing model, an unknown
  provider, a bad shape;
- apply: the shared model (then its handle again), a split part, a part changed after its preview
  (refused), the link (the target stays), Ollama's delete; unknown and bad handles.

The same answers, files and trash on both sides.

Phase 5 is done. Still Python: phase 6 (`system.*`, `existing.*`, `app.settings_changed`, Insights).

## Phase 6 — remaining parity (Claude, from 2026-10-29)

Two parts:
- **6a:** the routes the Python service still serves, so the core is complete:
  - 6a-1 `app.settings_changed` and the existing-AI import (`existing.*`);
  - 6a-2 the System Map views; 6a-3 folder moves, tool checks and the GPU stack; 6a-4 AI help and fixes;
  - Insights.
- **6b:** the new features of `plan-flutter.md` step 3 (catalogs, API-key entry, settings views, …),
  written in Dart directly.

### 6a-1 — `app.settings_changed` and existing AI

- `app.settings_changed`: the core reads the language from the settings on every lookup, so it only
  checks the shape.
- **Existing AI** (`existing_ai.dart`, `system_map_cache.dart`), on a mounted data disk the user chose:
  - `existing.scan` (worker): the bounded breadth-first walk of `existing_ai.scan` (12 000 entries,
    depth 5, 128 results, five seconds), GGUF folders, and Ollama's and llama.cpp's own installs
    (`discover_existing`: programs reached through links that stay on the disk and are this account's,
    native ELF only; Ollama's model store; a portable ROCm tree beside llama.cpp). Each record carries
    its mount and stamps (`st_dev` made as glibc does).
  - When it ends, the records are merged into the saved System Map (`system_map_cache`: load with all
    its checks, locked `transact`, `save`, `update`; `register`, `bounded`, `discovery_node`), then
    become discovery handles.
  - `existing.preview`: every record validated again (mount, program, links, environment, stamps), then
    the plan:
    - a GGUF folder goes into `model_folders`;
    - a runtime gets new connecting files only (a wrapper script, a user unit with
      `RequiresMountsFor`, its settings). Nothing is enabled or started.
  - `existing.check` (worker, private): the program's own `--version` in an empty home with a clean
    environment, five seconds, its whole group ended after.
  - `existing.apply` (worker, private, under the installers' lock): the plan built twice more and
    required to be the same, then `connect.apply` with a backup; the backup is registered for Undo.
- `connect_apply.dart` gained the reference's `files_add`: new files created exclusively (never through
  a link), listed in the manifest with their SHA-256 so Undo removes only them.

Check: `tests/test_dart_existing_ai_parity.py` builds an "other distro" in a temporary folder on the
data disk of this checkout (`/tmp` is not a data disk by design):
- an Ollama install with a `current` link and its model store, a llama.cpp program and a GGUF folder;
- scans (`/tmp` and a missing folder refused), six previews, the program check, two reconnects, a used
  plan and a store changed after the scan.

The same answers, reconnect files (modes too) and backup manifests on both sides. The reference's
production service keeps connection backups in `~/.local/state/ai-agents-map/backups`; the core keeps
them in its config folder since phase 3, so the test compares their manifests, not their place.

### 6a-2 — the System Map views

`system.view`, `system.cached`, `system.refresh` and `system.forget_disk` are served by the core
(`system_map.dart`):
- **The snapshot** (`flutter_system_map.snapshot`), from files only:
  - hardware (`system_tools.hardware`: `/proc/meminfo`, the DRM cards), the home folder and the
    mounted data disks with free and total space (`statvfs`, new in `posix_ffi.dart`) and their fstab
    hint;
  - every built-in and added local LLM with its program, model folder and user service;
  - every built-in and added agent the PC has, with its install source and configuration folder;
  - supporting tools (`system_tools.detect`; versions from names and folders only, with the search);
  - the GPU stack read only (`gpu_stack.look`: ROCm, Vulkan, CUDA, the PyTorch builds and what an AMD
    card would want);
  - the saved model folders, notes, the "ask AI" helpers (`ai_helper.helpers` / `task_agents`);
  - the health rows: `health.check`'s "This PC" and local LLM areas, as the map calls it (no graph,
    no runtime checks).
- **Refresh** (worker): the saved map's disks searched again when asked (or a new disk after the first
  search), offline disks and what depends on them kept as missing, cached discoveries as nodes, the
  analysis and a move's Undo kept. With the search, sizes are space on disk, each file once, three
  seconds in all (`disk_usage.measure`; `st_blocks` through `statx`).
- **Never run during a refresh:** the reference runs it under an audit hook that blocks every process,
  socket and credential file; the Dart refresh starts none and opens none, so its "blocked probes" note
  cannot occur (on this PC the reference blocks none either).
- `system.view` saves the zoom and the selected node; `system.forget_disk` drops one missing disk's
  saved facts; the public map (`system_public`) hands cached discoveries out as fresh handles only.
- `ProviderScans.scan(facts:)` also looks at built-in local LLMs an add-on hides, as the map does.

Check:
- `tests/test_dart_system_map_parity.py`, both services in a temporary HOME:
  - the empty cache and a view on it;
  - refresh, the saved map, a view and refused views;
  - a missing disk (made by editing the saved map), refused and real forgetting;
  - a disk scan merged into the saved map, and the size search.
  The same answers on both sides.
- On the real HOME (read only, both against the real saved map):
  - without the search the maps are identical;
  - with it, only sizes that hit the three-second deadline differ (the Dart walk gets further in the
    same time).

### 6a-3a — tool checks, the GPU stack and connecting a found model folder

Served by the core (`system_actions.dart`):
- **`system.tool_check`:** a supporting tool of the map (`system_tools.check_record`: its real path and
  stamp) checked in the worker: unchanged since the preview, then its own `--version` as the
  existing-AI check runs programs (empty home, clean environment, five seconds, its group ended).
  `existing_ai.checkProgram` takes the validator.
- **`system.stack_preview` / `system.stack_apply`:** only a part the GPU stack misses on this PC
  (`gpu_stack.wanted`), its way (`gpu_stack.ways`: the pacman package, else the vendor's page) chosen by
  the agent recipes, shown with its commands; apply resolves again, requires the same step and runs it
  in one terminal window the user watches.
- **`system.folder_preview`:** a found GGUF folder or Ollama store given to a local LLM: its settings file
  (`llm_engine.env_with`) and a wrapper the app connected (only one marked "Connected by Asterism",
  only when its model path is still the old one), plus the folder in `model_folders`; reviewed as a
  connection preview (backup, Undo). Ollama and llama.cpp, as in the reference.

Check: `tests/test_dart_system_actions_parity.py`, both services in a temporary HOME with a llama.cpp
wrapper connected earlier and a fake terminal that only logs:
- tool checks (a real one, an unknown one, not a tool);
- the GPU stack: preview, apply (in the fake terminal: `sudo pacman -S rocm-hip-runtime` is logged,
  never run), a used preview, a part not wanted;
- a found GGUF folder connected to llama.cpp (preview, refused for Ollama, bad shape, applied).

The same answers, terminal log, settings and rewritten files on both sides.

### 6a-3b — moving a model folder

`system.move_preview`, `system.move_apply` and `system.move_undo` are served by the core
(`model_moves.dart`, ports of `system_moves`, `model_folders` and `model_move`):
- **Preview** (worker, private): the folder's own GGUF files (`model_folders.discover`), refused while a
  runtime reading it runs; the plan (`model_folders.plan`): every step never over an existing name,
  each file's identity and both folders' anchors; what follows the files: the app's `model_folders`,
  llama.cpp's `models.ini` (also through a same-disk alias), the links of a router folder, a runtime
  whose own model folder it was (Ollama and llama.cpp through their `model_folder_changes`), else named
  as losing the models. A signature over all of it.
- **Apply** (worker, private, under the installers' lock): prepared again and the same; a private journal
  (`<config>/model-moves/<token>/journal.json`, 0600) records every file moved; the files move one by
  one (`FileMover`):
  - both folders reached by walking from / one name at a time, never through a link, the anchors as in
    the preview, every folder below them this account's alone;
  - the file opened once and required to be the preview's;
  - on one disk a hard link of the open file (through `/proc/self/fd`) to its new name; to another a
    copy into an owner-only `.part` file (fsync, size, times and mode), linked into place;
  - never over an existing name; the old name removed only while it is still that file.
  Then the settings with a backup; the saved map's discoveries follow the files. A failure undoes what
  was done and keeps an Undo for what could not be.
- **Undo** (worker, private): the journal's files back (last first), then the settings' backup.
- `posix_ffi.dart` gained `mkdirAt`, `statAt` (relative, no-follow), `linkAt`, `unlinkAt`, `setTimes`.
- Found on the way: the add-on lock's folder (`~/.local/share/asterism`) is now made 0700 when the
  core creates it, as the reference does (it was 0755 since 5a-2).

Check:
- `tests/test_dart_system_moves_parity.py` runs both workers on their own copy of the same layout:
  - a model folder with its own files (a split model, a vision file), a llama.cpp router folder of links
    to them, a `models.ini` naming one, the app's settings;
  - moved on one disk (hard links) and to another (from `/tmp`, a copy), the same preview refused once
    the files are gone, then undone.
  The same previews, files (contents, modes, link counts), links and settings on both sides, after the
  move and after Undo.
- `tests/test_dart_system_map_parity.py` also checks the routes: a move before any refresh, a preview
  from the map onto `/mnt/Data` (never applied), refused targets and handles.

### 6a-4 — the System Map's AI help

`system.help_preview`, `system.fix_preview` and `system.help_apply` are served by the core
(`system_help.dart`):
- **The preview** shows the exact prompt before anything starts: the map's facts as untrusted JSON (no
  settings values), the task (explain, simplify, check), or a Smart Check finding to verify and fix.
  Only an installed agent that can do it is offered (`ai_helper.helpers` / `task_agents`), only for a map
  refreshed in the last ten minutes.
- **A task tab** (explain, simplify, fix): the agent closed in by its adapter's `[closed]` task options
  (`agent_guard.task`: it asks before each change; its MCP servers off one by one where it needs that,
  their names read from its own settings, a name it cannot spell refuses the run). Apply builds the argv
  again and requires the reviewed one; the session runs without agent-session variables and without
  the agent's providers. The run goes into the shared log (`plugin_ai`, owner-only, locked).
- **The Smart Check** (worker, private): one web look-up closed in to the web alone
  (`agent_guard.background`), the reviewed prompt on stdin, ten minutes, 512 KiB, SIGTERM stops it;
  the agent's output parsed (`claude-json`, `codex-jsonl`, text), the first JSON with findings checked
  (`smart_check.validate`: printable one-line texts, known levels, no repeated titles, at most 15),
  each finding tied to a node of the map when the agent named one, saved in the map. The run, its
  tokens and its result go into the shared log.
- Inputs the reference refuses are refused here too (an unknown connection kind or provider operation),
  instead of being handed to the reference; an add-on agent's own model switcher (code) is not offered.
- With this, every route of the reference is served by the core. "Insights" is the add-on with code
  that the data-only core refuses on purpose (5a), not a route.

Check: `tests/test_dart_system_help_parity.py`, both services in a temporary HOME with a fake Claude Code
(its look-up answers in Claude's JSON format with prose around the findings; its task tab prints how it
was started):
- previews: before a refresh, explain, check, an agent not installed, a bad topic;
- the explain tab (its guard options in its argv), a used preview, the Smart Check (findings checked,
  bad levels and a repeated title dropped, nodes tied), a fix preview from a finding and its tab;
- the shared run log (setup-help, setup-analysis with tokens and cost, smart-fix).
The same answers, argv, stdin and log on both sides.

Codex reviewed this step (2026-10-29): CLEAN; its one Low (a malformed cached finding list) is fixed.

### 6b-1 — installing programs from the Flutter app

The Flutter app now uses the installer routes (5b-2):
- **Where:** the first-agent guide's steps `install-tool` (mise), `install-runtime` (the route's local
  LLM, named by the step's target) and `install-node` (Node.js through mise, the agent action of kind
  `tool`), and **Install** under Providers and models for a local LLM that is not installed yet.
  `install-agent` (an agent the app installs itself) shows its recipe, since no such agent has a
  checksummed release to take.
- **The review card** (`installer_review.dart`): the release and its files with their size, the program
  and model folders, the graphics card, the build (llama.cpp, KoboldCpp: Vulkan, ROCm, CUDA, CPU) and,
  for a local LLM with a user service, Start now and Start at login. Choosing another build looks its
  release up again before anything is installed. The install runs as a task card with progress.
- `installers.preview` now also returns the installer's `builds` (both the reference and the core).
- One new UI text, translated into the seven other languages; the other texts reuse the GTK
  installer page's translations. The manual has a new section "Installing in the Flutter preview" in
  all eight languages; the PDFs are rebuilt.

Check: two new widget tests (the guide names the tool or local LLM; the review keeps build and service
choices and offers Change for another build). The installer parity test passes with the builds.

### 6b-2 — API keys

New in the core (Dart only; the reference's GTK dialog is `install_dialog.ask_key` with `signin.save_key`):
- `agents.details` tells whether an agent takes an API key (`actions.key`: installed, and its adapter's
  `access.key` names its own command that reads the key on stdin, or the `.env` file it reads); the
  reference gets the same flag, so the differential cases stay equal.
- **`agents.key_preview {command}`**: what happens to the key, before it is typed (the variable, where to
  get one, the agent's own command or the file). A handle for ten minutes.
- **`agents.key_apply {preview, key}`**: the key checked (one word of plain characters, 8–512), the step
  required to be the reviewed one, then a private worker (`agents.key`, the key on its stdin):
  - the agent's own command with the key on stdin, without agent-session variables, 30 seconds; its
    last line returned with the key cut out;
  - or `signin.write_env`: other lines kept, an earlier value replaced, a new owner-only file renamed
    over the path (a link there is replaced, its target left alone), new folders 0700.
  The key never goes into an argv, a file of the app, a log, a backup or a task result.
- **Flutter:** **API key…** in the agent's details opens a card (`api_key_review.dart`) that says where
  the key goes, hides the field and enables Save only for a key; the field is cleared right after.
- One new text in eight languages; a manual section "API keys in the Flutter preview" in all eight
  manuals (the bold labels match the app's translations; also corrected for 6b-1); PDFs rebuilt.

Check: `test/agent_keys_test.dart` (the `.env` file, a link at its path, private new folders, the
agent's own command on stdin without session variables and with the key hidden in its answer, refused
keys and steps, a preview used once and checked again); a widget test for the card.
