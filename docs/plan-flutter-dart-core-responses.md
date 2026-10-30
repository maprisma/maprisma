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

### 6b-3 — completed setup actions return to the guide

A step started from the first-agent guide (Providers and models, Connections, an install, a sign-in,
the test question) returns to the guide with Back (or the card's close), and the guide is loaded again,
so the step just done shows as done. Terminals started from the guide (sign-in, test) return to it when
their view is left. The same views opened from the menu keep going back to the map: choosing a view
from the menu ends the guide's return. The manual's "Installing in the Flutter preview" says so in all
eight languages; PDFs rebuilt.

Check: an app-level widget test with the fake service: the guide, an install from a guide step
(review with its build and service switches, then installers.install with the chosen switches, the
guide reloaded), Providers from the guide and Back (reloaded again), Providers from the menu and Back
(no reload).

### 6b-4 — add-ons from a file

New in the core (Dart only; the GTK page's "Install from file…" is `addon_store.install_file`):
- **`addons.file_preview {path}`**: the .zip read never through a link, a regular file of at most 8 MiB;
  unpacked into a temporary folder outside the add-on folders and verified there (its own signature
  decides, as for a catalog download); shown like a catalog entry (name, version, kind, what it reads
  and sends, capabilities, privacy, the version it would replace). Only agent and provider add-ons,
  the kinds the data-only core uses. Nothing is installed by the review.
- **`addons.file_install {preview}`**: the add-on guard, then a private worker under the installers'
  lock reads the file again, requires the reviewed SHA-256 and id, and installs it (`installBytes`:
  verified again, the old copy to the trash). The result is finished like a catalog install.
- **Flutter:** **Install from file…** beside the catalog button in the add-ons group; the review is the
  catalog's `AddonInstallReview`. All texts were already translated; the manual's "Manage add-ons" says
  so in all eight languages; PDFs rebuilt.

Check: `test/addon_files_test.dart` with Uwe's signed `agent-goose-0.11.1.zip`: reviewed without
installing, a preview used once, installed from the same bytes, reviewed again as an update; refused
when the file changed after the review, a link, not a .zip, garbage, over 8 MiB.

### 6b-5 — the settings that work in Flutter

Settings now also offers the two GTK settings whose features the Flutter app has:
- **Start local LLMs with their agents** (`providers_with_agents`): the provider watcher of 4e; the
  description names its user service from `app.identity` (`<short name>-providers.service`), so it
  follows a rename.
- **Agent for AI checks** (`ai_checks_agent`): which installed agent the System Map's AI help and
  Smart Check offer first; the list is the System Map's helpers that can check (`None installed` when
  there are none). A new description, since the GTK one names features Flutter does not have.
- Both are UI settings now on both sides (`UI_SETTINGS`, `uiSettings`), so `settings.get/update` stay
  equal in the differential cases.
- The GTK settings of features the Flutter app does not have yet (the usage box, cost limits and
  warnings, daily AI checks and new-agent look-ups, terminal tabs, the MCP list, GTK looks) are not
  offered: they come with their features.
- One new text in eight languages; the manual's Flutter settings section in all eight; PDFs rebuilt.

Check: a widget test for both settings (the switch, the service name, the agent list, none installed);
the scan-settings test scrolls to the last target it uses, since the longer list builds lazily.

### 6b-6 — the security view

New in the core (`security_plans.dart`, the reference is `agent_security.plan`):
- **`agents.security {command}`**: the agent's security report (settings with every choice and its
  risk, allow/deny rules, risks with what lowers them, settings files, note, level), with the agent's
  MCP server count from the inventory as in GTK.
- **`agents.security_preview {command, key, value}`**: one setting changed in the agent's own file —
  JSON (OpenCode's single `permission` string becomes per tool), TOML and YAML edited as text, so
  comments and everything else stay; the TOML and YAML results are read back and refused when the
  value would not come out as chosen. Only editable settings and their own choices; anything else is
  refused. The plan is a connection plan, so `connections.apply` backs up, writes and offers Undo.
- **Flutter:** **Security settings** in an installed agent's details opens `AgentSecurityView`: the risk
  badge, every setting with a choice list (risk dot, `recommended`, "Not set: the agent's own default
  applies."), the rules, the settings file, Risk management with **Lower it…**. A change opens the
  connection preview. All texts were already translated (GTK); the manual's new "Security in the
  Flutter preview" in all eight languages; PDFs rebuilt.

Check: `tests/test_dart_security_plans_parity.py` — every setting and every choice (plus a value that
is not a choice) of the seven agents with security facts, in a HOME whose files hold comments and
other keys: the same file text from Python and Dart, comments kept, the invalid value refused on both
sides. Widget tests for the view (level, settings, rules, risks, choices and Lower it…, not editable,
not set) and an app test with the fake service (details → security → Lower it… → preview → apply).

### 6b-7 — MCP servers from the catalog and the registry

New in the core (`mcp_catalog.dart`; the reference is `mcp_catalog` and `mcp_registry`):
- **`mcp.catalog {}`**: the twelve servers to start with, pinned in the worker to their newest npm/PyPI
  versions (unpinned when offline), their texts translated; it also starts **`mcp.registry_refresh`**
  (the registry's list saved in `~/.cache/ai-agents-map/mcp-registry.json`, at most every 12 hours,
  resumed where a cut-short download stopped) unless one is running.
- **`mcp.search {query, cursor}`**: the saved list when it was downloaded in full once ("#offset"
  cursors, the total known), else the registry's own search.
- Each way to run a shown server (npm/npx, PyPI/uvx, Docker with only `-e` runtime arguments, or a
  https remote) stays in the core behind an opaque, expiring handle. The app gets its label, whether
  its runner is on PATH, the field names (secret defaults not shown), and which secret fields would end
  up on the command line.
- **`mcp.option_preview {option, name, values, agents}`**: only the typed values come from the app;
  they are bounded, `~/` is expanded, required fields are checked, a secret on the command line is
  refused, empty optional fields go with their flag, and the result becomes a new server definition's
  preview (`connections.author_preview`: backup, Undo). A typed value replaces a registry default
  (GTK did that through its free-form lines, which the Flutter card does not have).
- **Python fixes, both sides:** an environment variable's name must be a whole string match (`re.match`
  with `$` let a trailing newline through, and a missing name became `"None"`); a package whose
  `transport` is not an object no longer stops the whole answer from parsing.
- **Flutter:** **Find MCP servers…** in Connections opens `McpCatalogView` with the tabs Recommended and
  MCP registry (paging by cursor), the server page (who made it, about, needs, things to ask, how it
  runs with the recommended way and a missing runner named, fields, name, agents) and Preview. One new
  text in eight languages; the manual's "MCP servers in the Flutter preview" in all eight; PDFs rebuilt.

Check: `tests/test_dart_mcp_catalog_parity.py`. It covers:
- registry answers with odd and hostile entries: bad identifiers, an SSE package, too many arguments,
  Docker `-v`, http remotes, Unicode names, whitespace, statuses;
- filling and dropping fields;
- the saved list searched with order, paging and status filters, and a list never fully downloaded;
- the picks pinned;
- the download: fresh, resumed, up to date, offline.

Python and Dart give equal results in all of these. `test/mcp_options_test.dart` covers the handles
and the filled entry. There are widget tests for the view and an app test with the fake service
(Connections → Find MCP servers… → a pick → preview → apply). The worker ops were also run once for
real: a saved list searched, and the picks pinned against npm and PyPI.

### 6b-8 — an MCP server's tools

New in the core (`mcp_tools.dart`, the reference is `mcp_tools`):
- **Asking, as an agent does:** `initialize`, `notifications/initialized`, `tools/list` page by page
  (at most 20 pages; an odd or huge cursor ends the paging), `prompts/list` when the server offers
  prompts; tool names, descriptions and parameter names cut as in the reference. Two transports:
  - **stdio:** started through `setsid --` in a session of its own, with the agent's environment for
    it and the home folder as working folder, one 90 s deadline for writes and answers, other output
    on stdout skipped, 4 MiB at most; at the end TERM to the group, KILL after 5 s.
  - **Streamable HTTP:** posts through curl (http or https, no redirects, `--include`), headers and
    body on curl's stdin, the session id carried, plain JSON or event-stream answers.
  - SSE servers are not asked.
- **`mcp.tools {name}`**: the entry as the first installed agent that has it reads it. It may hold
  keys, so it goes to a **private** worker; the answer or the failure is kept 0600 in
  `~/.cache/ai-agents-map/mcp-tools/NAME.json`, the reference's file, so GTK reads the same. One
  server is asked at a time.
- **`mcp.tools_cached {name}`**: the kept answer.
- **`mcp.option_test {option, values}`**: a catalog or registry choice, filled in as for its preview,
  asked privately without being kept.
- **Python fix, both sides:** parameter names and the cache file name must match in full (`re.match`'s
  `$` let a trailing newline through).
- **Flutter:**
  - Every MCP card in Connections has **Tools**: the kept answer with its date, and **Ask the server** /
    **Ask again**.
  - The catalog's server page has **Test**, which shows the tools before anything is written.
  - All texts were already translated. The manual's Flutter MCP section says so in all eight languages;
    PDFs rebuilt.

Check: `tests/test_dart_mcp_tools_parity.py` runs fixture servers.
- **Over stdio:** noise on stdout, a wrong id, two pages, prompts, a prompts error, an initialize error,
  a server that dies, a huge cursor, endless pages, its environment and folder.
- **Over HTTP, locally:** a session id, an event-stream answer, a wrong key; and an SSE entry.
- Python and Dart give equal answers, and no fixture process is left.

`test/mcp_tools_test.dart` covers the private worker path and the kept answer. There are widget tests
and an app test (Connections → a server's card → Ask the server).

### 6b-9 — skills from the web

New in the core (`skills_web.dart`, the reference is `skills_web` and the GTK Add skills page):
- **`skills.web_search {query}`**: skills.sh's search in the worker (only the three fixed hosts, no
  redirects); name, repository and installs, 25 shown.
- **`skills.web_fetch {repo, skill_id, name}`**: GitHub's file list and the skill's folder (the
  shortest one named after it, or a repository that is one skill). Plain files only: no links or
  submodules, no `..`, at most 8 levels, 150 files, 5 MiB each, 30 MiB in all. They are fetched into a
  private staging folder (`<cache>/skill-staging/<random>/`, 0600 files, folders older than an hour
  swept). The core keeps them behind a handle; the app gets the description, the file names, the
  scripts an agent may run, the target folders (`~/.agents/skills` and the user's own skill folders)
  and the agents that read skills. Nothing fetched runs.
- **`skills.web_preview {fetched, folder, agents}`**: the files into `<folder>/<skill id>`, refused
  when that is there already, plus each ticked agent's plan for the folder. It is shown as a connection
  preview with the new files listed (`new_files`, only when there are some, so the differential cases
  stay equal).
- **Files staged on the wire:** `Plan.filesStaged` (path, staged file, SHA-256, executable) travels as
  an optional `files_staged` field of wire version 3; only this core's own plans carry it. Before
  writing, the worker reads each file back without following links, as this account's regular file
  inside the staging folder, checks its size and SHA-256 against the review, and creates it with
  `O_EXCL`. The backup's manifest lists it, so Undo removes it. The staging folder goes after the
  apply.
- **Python fixes, both sides:**
  - repository, skill id and file-name parts must match in full (`re.match`'s `$`);
  - `installs` and `size` must be real numbers (`True` counted as 1).
- **Flutter:** **Find skills on the web…** in Connections opens `SkillsWebView`: search, a result, its
  description, file count and scripts, **Into**, **Also for**, Preview. Connection previews list new
  files. Two new texts in eight languages; the manual's "Skills from the web in the Flutter preview" in
  all eight; PDFs rebuilt.

Check: `tests/test_dart_skills_web_parity.py`. It compares Python and Dart on:
- search answers: bad repositories and ids, trailing newlines, a bool count;
- file lists: links, submodules, `..`, too deep, too large, too many, no SKILL.md, a one-skill
  repository, the shortest folder;
- SKILL.md descriptions: folded, quoted, long, CRLF, none.

`test/skills_web_test.dart` fetches into staging with fake hosts, applies through the worker's
`applyPlan`, and checks that Undo removes the files. A changed staged file, a staged file outside the
folder and bad `files_staged` entries are refused. There are widget tests and an app test. It was also
run once for real: skills.sh's search for "pdf" and anthropics/skills' pdf skill (12 files, 5 scripts
named) fetched into staging, then removed.

### 6b-10a — a local LLM's performance

New in the core (`llm_tuning.dart`, the reference is `llm_tuning.collect` and the engines' `tuning_now`
/ `tuning_changes` / `build_now` / `devices` / `context_now` / `model_size`):
- **The engines' tuning facts** (keys with their allowed values and what they do, per model or for
  every model, when a change counts, builds, context effect) are exported from the reference into
  `adapter_assets.g.dart` by `tools/adapter-assets.py`. llama.cpp and Ollama have them.
- **`models.tuning {key}`**, in the worker. It collects:
  - the graphics card and its memory, and the GPU stacks this PC has (files only);
  - the build, from the app's install, else from `llama-server --list-devices` (bounded, 20 s);
  - the settings now: models.ini sections, or Ollama's env file when it is the app's;
  - for each of up to 40 models: its size, its context now, and the context the card holds, its
    trained context and the KV bytes per token from its GGUF header. Models without a KV cache are
    left out.
- **`models.tuning_preview {key, section, setting, value}`**: one setting (an allowed value, per model
  only where the engine has that), or a model's context (`ctx-size`, llama.cpp's models.ini), as a
  connection preview (backup, Undo; it counts after a restart).
- **`providers.snapshot`** gains `tunable` on both sides; the differential cases stay equal.
- **Python fix, both sides:** `provider_llamacpp.model_size` returned 0 when `<name>.gguf` was missing,
  before ever looking for the file whose name differs only in case.
- **Flutter:** **Performance** on a tunable local LLM in Providers and models opens `PerformanceView`:
  - tiles for the build, the GPU stacks and the video memory;
  - **Context per model**, with too-much / room-for-more marks and llama.cpp's **Set to …**;
  - **Settings for every model**, where values from a list are chosen.
  - A change goes through the connection preview. One new text in eight languages; the manual's
    "Performance in the Flutter preview" in all eight; PDFs rebuilt.

Check: `tests/test_dart_llm_tuning_parity.py`. In a HOME with GGUF headers (a 4 GiB sparse model whose
file differs in case, a model that fits, one without a KV cache, a broken one, a missing one), a
models.ini, a fake `llama-server` listing devices, and Ollama with and without its env file, Python and
Dart give the same facts. They also make the same changes: accepted, refused, and unchanged (no change
at all). There are widget tests and an app test (Providers → Performance → a setting → preview →
apply). It was also run once on this PC: the RX 7900 XTX, the ROCm build, models.ini and the contexts.

Next, 6b-10b: tips from an agent (`llm_tuning.prompt` / `validate` with the local helper or the agent for
AI checks, as the System Map's help asks).

### 6b-10b — tips from an agent on a local LLM's performance

New in the core (`llm_tuning.dart`, the reference is `llm_tuning.facts_text` / `prompt` / `validate` /
`ask`):
- **`models.tuning`** keeps the facts it read (ten minutes) and names the agents for AI checks that can
  look them over, the chosen one (`ai_checks_agent`) first.
- **`models.tuning_ask {key, command}`**: a **private** worker runs one look-up by that agent:
  - the reference's prompt built from the kept facts, its schema as `schema-llm-tuning.json`;
  - its research command closed in to the web alone (`guardBackground`), bounded (`runLookUp`, made
    public from `system_help.dart`; the System Map's analysis uses the same);
  - recorded in the shared run log as task `llm-tuning`.
- **The answer is checked against the facts.** A setting must be one of the engine's keys with an
  allowed value that is not set already there, and per model only where the engine has that. A context
  must be digits from 1024 up to what the card holds for that model. A build must be one it knows that
  is not the one now. Notes carry no value. At most 8 are kept; anything else is dropped.
- **`py_values.pyRepr`**: Python's `repr` of JSON values, for answers whose fields are not strings (a
  list as a title), as `str()` makes them.
- **Flutter:** `PerformanceView` adds **Tips from an agent**: the agent (chosen from the list when
  there are several), **Ask …**, its progress, the summary and each tip. **Apply** is offered for a
  setting and for llama.cpp's context, through the same preview; a build gets the reference's hint. The
  last answer is kept per local LLM while the app runs. All texts were already translated; the manual's
  Flutter performance section says so in all eight languages; PDFs rebuilt.

Check: `tests/test_dart_tuning_tips_parity.py`. For llama.cpp and Ollama facts (per model and for every
model only), Python and Dart give the same facts text, the same prompt and the same checked tips, for
answers with:
- settings set already, per model, out of range, unknown, with a newline;
- contexts too big, too small, not digits, for a model with no fit or none;
- builds known, current, unknown; empty titles; unknown models and kinds;
- non-string fields (Python `repr`); more than eight;
- not an object, suggestions not a list.

There are widget tests (ask, the chosen agent, a tip applied, a build hint, no agents, no section) and an
app test (Providers → Performance → Ask → Apply → preview). A real agent was not asked, since it uses
Uwe's tokens.

### 6b-11 — durable jobs

New in the core (`core_jobs.dart`, the reference is `jobs.Jobs`):
- **Kept across restarts:** a model download (`models.download`) or Ollama pull (`models.pull`)
  started through `providers.run` is recorded in `$XDG_STATE_HOME/asterism/jobs.json`
  (`~/.local/state/asterism`). It is written 0600 and atomically. It holds only how to start the
  operation again (its checked parameters, a title, the fraction) and never credentials. It is the
  app's own file: GTK's `ai-agents-map/jobs.json` keeps its own spec shape. The entry goes when its
  task ends; the progress is kept every ten seconds while it is polled.
- **At the next start** the left-over entries are interrupted jobs. The file is not trusted: a link,
  an oversized file, unknown operations and malformed ids are left out, and the fraction is clamped.
  - **`jobs.list`** lists running and interrupted jobs.
  - **`jobs.discard {id}`** forgets one.
  - **`jobs.continue {id}`** checks the saved request again as a new one (`coreProviderRun`,
    `ProviderOps.validate`) and starts it; the download goes on from its `.part` file.
- **Retries, in the worker (`withRetries`):** a download whose connection broke off (curl failed, or
  the file is incomplete: the reference's `DownloadError`), or a pull that lost its connection, is
  tried again after 5, 15, 30, 60 and 120 s, with GTK's countdown text. A refusal or any other error is
  not retried.
- **One download per `.part` file:** `openStaging` takes `flock(LOCK_EX | LOCK_NB)` and refuses a
  second download into the same file, for example an interrupted job continued while an orphaned
  worker still runs.
- **Flutter:** after the first snapshot, a banner lists interrupted downloads with where they stopped,
  **Continue** (its task shown like any download) and **Discard**. All texts were already translated;
  the manual's "Interrupted downloads in the Flutter preview" in all eight languages; PDFs rebuilt.

Check: `test/core_jobs_test.dart` covers:
- recorded, the restart (interrupted), continued (replacing it), ended (the file gone), 0600;
- odd entries, links and discard;
- the `.part` lock;
- retries: three tries, the delays, a refusal and a non-durable operation not retried, a pull given up
  after six.

There are widget tests and an app test (an interrupted download listed at start and continued: its
task polled). No file is written in the real state folder by the suites.

Not durable (as before): installs (`installers.install` runs from a reviewed, expiring plan), which the
GTK app also kept. They come with the Flutter installer jobs, if wanted.

### 6b-12a — Help

- **Core:**
  - `help.snapshot` says whether a user manual came with the app.
  - `help.open_manual` opens it in the desktop's PDF viewer: `xdg-open` in a process of its own, no
    shell, the path never built from text (`desktop.openDocument`). This is the reference's
    `settings_pages.manual_path`: `user-manual.LANG.pdf` in the interface language, else the English
    `user-manual.pdf`. It is looked for in `data/` beside the app, then `ASTERISM_DATA_DIR`
    (development). A link in place of the file is not opened.
- **Packaging:** `tools/build-flutter-preview.py` copies the eight PDFs into `bundle/data/`.
- **Flutter:**
  - **?** in the header and **F1** (app-wide, as GTK) open **Help** as a card: **Open user manual**,
    with a message when no viewer starts.
  - **Where to start** leads to Your first agent, Find existing AI, Providers and models and
    Connections, and closes Help.
  - GTK's "Start here" was not reused: it means starting an agent in the window, and its translations
    say so. The intro sentence is new as well, since the GTK one still says the PDF is in English. Two
    new texts in eight languages; the manual's "Help in the Flutter preview" in all eight; PDFs
    rebuilt.
- **Not taken over:** GTK's other help cards (disk space, the setting-up-by-drawing animation, the
  LLM Monitor promotion) and the Information page (cards for the author's Omarchy plugins). The System
  Map already shows sizes, and the rest belongs to the Omarchy plugin.

Check: `test/help_test.dart` covers the language, the English fallback, no manual, a link refused, no
xdg-open, and unexpected parameters. There are widget tests and an app test (F1 → Help → manual → a
start that closes Help).

Next, 6b-12b: Open problems, and Updates and suggestions (`health.check`, `agent_status`,
`agent_updates`, add-on hints).

### 6b-12b-1 — Health of an agent and of a local LLM

New in the core (`setup_checks.dart`, the reference is `agent_status.agent_checks`, `runtime_checks`,
`summary_line` with `credentials_present`, `sign_in_expired`, `issue_text`, `graph.split_model`,
`link_check.add_model_step`, `agent_details.plan_label`, and `desktop.text` / `install_command`):
- **`agents.health {command}`** checks an agent: installed, start problems
  (`start-issues.json`), sign-in, paused limits, model, its local LLMs, failed connections
  (`failed-links.json`), MCP servers and skills.
  - Sign-in comes from the desktop's usage record, the adapter's `access` table, and credential files
    or variables. These are only checked for existence; files are stat'ed, never read.
- **`providers.health {key}`** checks a local LLM: installed, running or able to start, models,
  connected agents, failed connections.
- Both answer with the state, the summary line and each check (state, title, detail, step, command to
  copy, sign-in).
- **Inputs:** the inventory's runtimes with their agents and the snapshot's `can_control`. The usage
  record reader is now shared (`DetailReaders.usageRecord`).
- **`desktop.installCommand`** is the reference's `install_command`: pacman on Omarchy; generically,
  the first of apt, dnf, zypper and pacman on PATH.
- **Flutter:** `HealthCard` sits in an installed agent's details and on each installed local LLM in
  Providers and models. It shows the badge (Healthy / Needs a look / Not set up), the summary and the
  checks, with Copy for a command, and is open by itself when something needs doing. Five texts were
  already translated; the check texts come translated from the core. The manual's "Health in the
  Flutter preview" in all eight languages; PDFs rebuilt.

Check: `tests/test_dart_setup_checks_parity.py`. Over 150 cases on the generic desktop (dnf on PATH, no
credential file) and the Omarchy one (a credential file and a key):
- every usage-record state, access shape and kind of model and provider;
- local LLMs not installed, without models, server off, stopped, running;
- failed connections, start issues, logged-in true, false and unknown;
- runtimes in every state, with and without start at login.

Python and Dart give the same checks and summaries. The core names the app Asterism in its texts, so
the test maps the reference's "AI Agents Map". There are widget tests and an app test (details →
agents.health → the card). It was also run once on this PC: Claude Code with its plan, MCP servers and
skills, and llama.cpp with its connected agents.

Next, 6b-12b-2: Open problems (the whole report of `health.check`, its use cases, the header's "!").

### 6b-12b-2 — Open problems

New in the core (`health_report.dart`, the reference is `health.check`, `pc_info`, `card_name`,
`fits_text`, `matches`, `first_local_llm`, `graph.idle_folders`):
- **`health.report {}`**: the PC's facts are read in a worker (`health.pc`): the card through lspci, the
  memory, and the free space where each model folder is or would be (statvfs). The report is then
  built from what the core knows: every agent's and local LLM's checks (6b-12b-1), the inventory
  (runtimes, MCP servers, skill sets), each agent's providers, the adapters' `chat_app` / `web_search`,
  the map (idle model folders) and the failed connections.
  - **Areas:** This PC, Agents, Local LLMs and models, Tools. Each finding has an action.
  - **Use cases:** everyday help, vibe coding, images, voice, research and writing, with what is there
    and the next step.
  - Also the counts, the level, the summary and `open_text` (the plural heading, which Flutter cannot
    form).
  - The input gathering of 6b-12b-1 is shared (`_HealthInputs`), so each agent's details are read once.
- **Python fix, both sides:** `health.check` unpacked `link_hints.load()`'s `"source|target"` string keys
  as tuples. With any failed connection it raised, and the GTK window got no report. It now splits
  them (`link_hints.split`).
- **Not ported:** `model_slots`' warnings (agents on different models of one local LLM, too big
  together for the card). The slots feature itself (`slots_kind`, `--models-max`, Ollama's
  `OLLAMA_MAX_LOADED_MODELS`) is not in the core yet; it comes with it.
- **Flutter:**
  - After the first snapshot the report is read quietly. A **!** shows in the header while there are
    problems or tips (red for problems), with the summary as tooltip.
  - `OpenProblemsView` lists the problems, each with the GTK action: Details, Models…, Install…, Map,
    Get started, Add MCP server, Add skills, Tidy up….
  - **What you can do with it** shows the use cases (Ready / Almost / Not yet) with what is there and
    up to two steps. **Check again** reads the report again.
  - All texts were already translated; the manual's "Open problems in the Flutter preview" in all
    eight languages; PDFs rebuilt.

Check: `tests/test_dart_health_report_parity.py`, on both desktops, with fixture programs on PATH
(krita, whisper-cli). It covers:
- a full setup: a big AMD card, full and roomy disks, agents with problems and tips, a chat app, local
  LLMs with coder, vision, image and speech models, idle folders, a model in two local LLMs, failed
  connections, used and unused MCP servers, skills;
- an empty one: no card, no agents;
- a small card with little memory;
- a card without a bracketed name.

Python and Dart give the same report. There are widget tests and an app test (the header's ! → Open
problems → Details opens the agent). It was also run once on this PC: four problems (agents without a
model, LM Studio without models), three doubled models, and all five use cases ready.

Next, 6b-12b-3: Updates and suggestions (`agent_updates`, add-on suggestions and updates, new MCP
servers and skills on this PC).

### 6b-12b-3 — Updates of agents and local LLMs

New in the core (`agent_updates.dart`, the reference is `agent_updates`):
- **`updates.check {}`**, in the worker. Each agent and local LLM is checked the way it was installed:
  - `mise outdated --json` (odd tool names and versions dropped) for mise agents;
  - an agent's own release channel (`update.latest = "claude-channel"`: npm's dist-tags for Claude
    Code's `autoUpdatesChannel`, stable or latest), with its own updater (`update.self`, plain words
    only) or `mise upgrade`;
  - the app's own installs (the installer's newest release for the installed build; Update opens
    the install review).
  - The web is asked at most every six hours. The answer is cached 0600 in the app's own
    `cacheDir/updates.json`; cached entries are checked again (`_usable`: only mise's upgrade or an
    agent's own updater) and dropped once installed (`still_open`).
- **`updates.run {key}`** runs only an update of the last check whose command is allowed and plain
  words. It runs in a terminal of its own with `env MISE_USE_VERSIONS_HOST=0` for mise, as the
  reference does, and the cache is forgotten. An install-page update is refused here; the app opens
  its install review.
- **Flutter:** the check runs quietly after the first snapshot. The header's **!** also counts
  updates. Open problems gains **Updates and suggestions**: "X 2.2.2 is available (you have 2.2.1)"
  with **Update**. **Check again** reads both. All texts were already translated; the manual's Flutter
  Open problems section says so in all eight languages; PDFs rebuilt.
- **Not taken over yet:** GTK's other lines in that area:
  - new MCP servers and skills found on this PC (mcp_scan, not in the core);
  - newer app versions next to the ones in use (fold_versions);
  - add-ons on this PC but switched off, and add-on updates;
  - the daily AI checks' MCP updates.

Check: `tests/test_dart_agent_updates_parity.py` gives the web and mise as sources and uses a real
fixture of the app's own llama.cpp install (link, `current`, marker) and Claude Code's stable channel.
It covers:
- a fresh check;
- the cache within six hours (an update installed since drops out);
- stale caches with the same and an older release;
- a cache with a forbidden command, an unknown kind and a runtime not installed.

Python and Dart give the same updates. `test/agent_updates_test.dart` covers version order and
`updates.run`'s refusals. There are widget and app tests. It was also run once on this PC (cache in
the scratchpad): OpenCode 2.2.1 → 2.2.2 by mise, and the app's Ollama v0.40.11 → v0.40.13.

### 6b-13 — Agents working together

- **Subagent readers:** all five formats the reference allows (`adapter_data.SUBAGENT_FORMATS`) were
  already read by the Dart core: claude-projects, opencode-db, codex-rollouts, copilot-events,
  goose-db. No adapter declares another. "Remaining readers" in plan-flutter.md meant agents with
  subagents but no reader; there are none to port until a new format is added on both sides.
- **Collaboration, the missing part:** `subagents.agents_using_agents`, ported as `agentsUsingAgents`.
  An agent whose running instance was started by another agent's process (directly or through a
  shell, a script, a tool; at most 12 parents up, an agent inside itself not counted) is used by it.
  The activity of each agent gains **`uses`**, on both sides (`flutter_activity.py` and
  `activity_readers.dart`), so `agents.activity` and `map.snapshot` stay equal in the differential
  cases.
- **Flutter:** `withAgentLinks` adds an `agent-link` edge per use. It is lit while either agent works
  (the light layer's agent mode), drawn as a bend along the right of the agents' boxes, and skipped by
  `lineAt` and `movable`: shown, never edited. The geometry only changes when a link comes or goes. The
  manual's "Agents working together in the Flutter preview" in all eight languages; PDFs rebuilt.

Check: Dart `agents_using_agents_test.dart` (a shell between them, an agent inside itself, the depth
limit) and Flutter `agent_links_test.dart` (edges from activity, lit, unknown agents dropped; the bend,
not pickable, not movable). The Python activity tests and the 69 differential cases pass with the new
field.

### 6b-14 — Models at once (slots)

New in the core (`model_slots.dart`, the reference is `model_slots` and the engines' `slots_kind`,
`slots`, `slots_fixed_by`, `slot_changes`):
- **The need:** `modelsInUse(graph)` maps runtime → {model: agents} from the map's `serves`, `default` and
  `uses` lines. `slotPlan` reads each engine:
  - **llama.cpp:** the running router's `--models-max`, else the start lines (the app's unit and a
    user script it starts), else `LLAMA_ARG_MODELS_MAX`, else 4. A number in the user's own script
    fixes it; the app's own unit does not.
  - **Ollama:** `OLLAMA_MAX_LOADED_MODELS` in the app's env file, else 3. Without that file it is not
    the app's to change.
  - **LM Studio:** `developer.unloadPreviousJITModelOnLoad`, one or many.
  - Each model's size: `LlmTuning.modelSize`, now public and with LM Studio's model index.
  - Plus `needChange`, `needSwaps` and `slotHints`: the swapping and too-big-together warnings.
- **`models.slots_preview {}`** builds one connection preview for every local LLM whose number should
  change. For llama.cpp the env file is written, and an older `--models-max` is taken out of the app's
  own unit. It returns the notes in the interface language (plurals from the core), the warnings,
  `reload` when a unit changes, and empty when nothing changes. **`models.slots_reload`** runs the
  fixed `systemctl --user daemon-reload`.
- **`health.report`** now adds the slot warnings to Local LLMs and models, as the reference does
  ("X: its agents use N different models").
- **Flutter:** after an applied provider connection, a model switch or attach, a moved line or a
  repaired one, the app asks `models.slots_preview`. A change gets a second preview with its notes and
  warnings, then the apply and, if needed, the reload. Warnings without a change come as messages. The
  manual's "Models at once in the Flutter preview" in all eight languages; PDFs rebuilt.

Check: `tests/test_dart_model_slots_parity.py` runs two HOMEs.
- **The app's own llama.cpp service:** an older flag in the unit, an env file, Ollama with its env
  file, LM Studio settings and model index.
- **The user's own start script fixing the number:** no Ollama env file.

Python and Dart give the same uses, needs, flags and hints, and the same changes, byte for byte. An app
test covers the provider change → the second preview → apply → reload. It was also run once on this
PC, read only: llama.cpp's number is fixed by the user's wrapper `~/.local/bin/llama-server` (left
alone). Ollama already keeps 2 for Hermes and OpenCode; its two models need about 37 GB together for
a 24 GB card, which is now said as a warning.

### 6b-15 — The red-limit notification

New in the core (`red_limits.dart`, the reference is `agent_details.warn_levels` / `red_limits`,
`ai_core.plain_text` and `ai_popup.warn_red`):
- **The limits:** `warnLevels` from Settings › Costs (`warn_yellow`, `warn_red`; red always above
  yellow, else the defaults 75 % / 90 %). `redLimits` keeps the limits still counting (a past reset is
  left out) used up to red, rounded to four places as the reference does.
- **`limits.notify {}`** reads each installed agent's usage record (`reads.details`), and for every red
  limit not shown yet sends one desktop notification ("{0} is in the red", "{0}: {1} % used, resets
  Mon 14:00") through `notify-send --app-name=Asterism`. What was shown is kept in
  `$XDG_STATE_HOME/asterism/red-notified.json` (atomic write, entries older than eight days pruned),
  so a restart does not show it again; if that file cannot be written, nothing is sent. Title and body
  are plain text (markup and control characters out, length capped). It does nothing when
  `warn_notify` is off.
- **Settings:** `warn_notify` joins the UI settings on both sides; Flutter shows **Notify when red**
  (on by default) in Settings.
- **Flutter:** a one-minute timer after the first snapshot calls `limits.notify`.
- The manual's "Red limits in the Flutter preview" in all eight languages; PDFs rebuilt.

Not yet: the once-a-day cost notification of an agent paid per token, since costs are not in the
Flutter preview yet.

Check: `test/red_limits_test.dart` (levels, past resets, rounding, plain text; one notification per
limit and reset, kept across a second check, pruning, nothing sent when the file can't be written) and
a Flutter settings test for the switch. Not run for real on this PC: it would send a real desktop
notification.

### 6b-16 — Add-on suggestions and updates

New in the core (`addon_hints.dart`, the reference is `ai_popup.look_for_addons`, its hint lines in
`overview_hints`, `addon_store.present` and `addons_page.addon_update_items`):
- **`present`:** each catalog row now says whether its detect hints find the program on PATH or its
  folder in the home (read-only), on both sides (`flutter_addon_catalog.register` too). Only the
  yes/no leaves the core, never the commands or paths.
- **`addons.hints {}`:** from the last catalog read. Agents and local LLMs on this PC whose add-on is
  off (installed, verified) or not installed yet, one line each ("{0} is on this PC but not on the
  map", plurals from the core), and "Add-on updates ready: {0}" with the updates' catalog previews.
- **Flutter:** after the first snapshot (not during the welcome, which asks first), the catalog is read
  quietly: from the cache, online only when looking for add-ons online is on. It feeds only the hints;
  the Add-ons list still waits for the user's own look, and that look waits for the quiet one, since a
  catalog read makes new install previews. The lines are under **Updates and suggestions** in Open
  problems and count for the header's "!". **Get add-ons** / **Add-ons** opens the add-ons focus;
  **Update all** shows the updates with their versions, then installs them one after the other
  through the reviewed catalog previews, with one message for what was and was not updated.
- The manual's "Add-on suggestions in the Flutter preview" in all eight languages; PDFs rebuilt.

Check: `test/addon_hints_test.dart` (PATH and home folders, off/new/updates, plurals, no preview no
update) and a Python test for `present`. An app test goes Open problems → Update all → the review →
`addons.install` with the preview → the message, then Get add-ons → the add-ons focus. Not run for real
on this PC: it would read the catalog online.

### 6b-17 — Found on this PC (new MCP servers and skill sets)

New in the core (`found_scan.dart`, the reference is `mcp_scan` with `fold_versions`, `skills_scan`,
`mcp_pages.configured_programs` / `installed_mcp`, and `ai_popup.new_found` / `mark_seen`):
- **The scan (worker op `found.scan`, read only):**
  - The user's programs (`~/.local/bin`, `~/bin`, `~/Applications/<app>/usr/bin`, `/opt/*/bin`,
    Setup's added folders), anything on PATH named for MCP, and AppImages from what an earlier look
    inside them kept.
  - A program counts when its bytes hold two of the protocol's own words, or one with an `mcp` usage
    text or name. The start command comes from that usage (`--headless`, read/write roots get a folder
    that fits the app). Clients (agents, local LLMs, runtimes like node or uvx) are left out.
  - Files are read in 8 MiB chunks with an overlap, never mapped; results are cached per file (size,
    time) in `$XDG_CACHE_HOME/asterism/mcp-scan-3.json`. The usage block is found by its literal
    part, since a regular expression over megabytes made the Dart side four times slower than the
    reference.
  - `fold_versions` keeps the newest version of an app's program, with the version it updates and the
    agents that start an older one. Plus AppImages not looked into and newer versions of known apps.
  - Skill sets that apps brought along (a few levels under `/usr/share`, `/opt`, `~/Applications`,
    `~/.local/share`, npm, Claude plugins, Setup's folders), without the agents' own skill folders.
- **`found.hints {}`:** "New on this PC: {0}" for programs not set up (or an update of one that is
  used) and skill sets that the add pages have not shown yet (`seen_found`).
- **`found.list {kind}`** lists them for the add pages: the new ones first with a mark, what is set up
  counted, a program inside an AppImage marked as not ready. **`found.seen {kind}`** remembers what
  was shown (500 at most, as the reference).
- **Flutter:** at start the scan runs quietly. Open problems shows the line with **Add MCP server…** /
  **Add skills…**; they and **Found on this PC** in Connections open the list (and mark it seen).
  **Add…** opens the existing form filled in with the name and the start command, or the folder; it
  still goes through the preview.
- The manual's "Found on this PC in the Flutter preview" in all eight languages; PDFs rebuilt.

Not yet (6b-18): looking inside AppImages and unpacking one for a server in it (bubblewrap), the
"New version found" line, and moving agents from an older app version to the newer one
(`mcp_update`).

Check: `tests/test_dart_found_scan_parity.py` runs one HOME.
- **MCP finds:** a usage text with roots and `--headless`, a marker across the 8 MiB seam, a program
  only named for MCP, a client left out, two unpacked versions with the older one used, an AppImage
  from the cache and a newer one not looked into, PATH, `/opt` and an added folder.
- **Skill sets:** known, skipped, nested and added ones.

Python and Dart give the same results, and the same again from the cache. An app test goes Open
problems → Add MCP server… → the list (an AppImage one disabled, seen marked) → Add… → the filled-in
form. It was also run once on this PC, read only, with both caches in a scratch folder. Python and Dart
gave the same results: 2 programs (cua-driver, photocraft), 13 AppImages not looked into, and 2 skill
sets. It took 16 s against the reference's 12 s; later looks come from the cache.

### 6b-18a — Looking inside AppImages, unpacking one for its server

New in the core (`found_scan.dart`, the reference is `mcp_scan.extract_argv`, `unpack_bin`,
`look_inside`, `unpack`, and `ai_popup.overview_hints`' "New version found" line):
- **The sandbox:** `--appimage-extract` runs the AppImage's own program, so it always runs in
  bubblewrap. That means no network, no home folder, `/usr` read-only, the AppImage read-only, and only
  the work folder writable. The argv is the reference's, and the installer's AppImage unpack uses the
  same one. Without bwrap nothing is unpacked. Output size and time are capped
  (`runWithDiskBudget`, shared with the installers; its whole group is ended).
- **`found.look_inside {}` (worker task):** for the AppImages not looked into yet (the worker takes
  only paths the scan itself lists). Each one's `usr/bin` goes into a private temporary folder under
  `$XDG_CACHE_HOME/asterism/tmp`; its programs are read and the folder is removed again. What was
  found is kept per file in the scan cache, and an AppImage that cannot be opened is kept as empty.
- **`found.unpack {program}` (worker task):** a program the last scan found inside an AppImage. The
  whole AppImage is unpacked into `~/Applications/<app>-<version>/` (into a hidden work folder, then
  renamed; 10 GB and 10 minutes at most). It is not unpacked again when the folder is there.
- **`found.hints`** adds "New version found: {0} · Add MCP server › Look inside… to use it". The newer
  AppImage is only named: a newer name is no proof of an authentic update.
- **`found.list`** carries the "{0} AppImages not looked into yet ({1})." text (plurals from the core)
  and, for a program inside an AppImage, the "Unpacks {0} into {1} first" note.
- **Flutter:** the found panel has a **Look inside…** row (progress while it runs, then a new scan).
  **Add…** on a program inside an AppImage asks first with that note (**Unpack**), unpacks, scans
  again, then opens the filled-in form; the hints follow. New string: "Unpack" in all eight
  languages; the manual's found section rewritten for it; PDFs rebuilt.

Check: `tests/test_dart_found_look_parity.py` uses real bubblewrap and a stand-in AppImage (a script
that unpacks itself), in two HOMEs. Python and Dart agree on what is looked into, the offer from the
cache (command into the folder it will be unpacked to), the unpack, and the program found in the
unpacked folder afterwards. Nothing stays in the temporary folder. The app test goes Look inside… →
the look and a new scan → Add… on an AppImage program → the note → Unpack → `found.unpack` → the
filled-in form. Not run on this PC's real AppImages: that is the user's click.

Next, 6b-18b: moving agents from an older app version to the newer one (`mcp_update`: entries, the
list, links in `~/.local/bin`, old folders retired with Undo).

### 6b-18b — An app's users moved to its newer version

New in the core (`mcp_update.dart`, the reference is `mcp_update`, `connect.apply`'s `retire`, and
`connect.prune_retired`):
- **The plan:** for a found program in a newer version (`update_from`) whose older one is still started
  by an agent, the list or a link in `~/.local/bin` / `~/bin`:
  - each agent's entry and the list's entry that starts an older program gets the new one, and
    arguments into the old folder move along; an entry that starts a link that moves stays as it is;
  - the links into the old folder point into the new one;
  - the old folders are retired.

  Several apps are chained on top of each other, as one plan.
- **`retire` in plans:** the Plan has `retire`, merged without doubles. The preview lists it, the wire
  carries it (only when there is something to retire), and `apply` moves each folder into the backup
  (`retired-<n>-<name>`, in the manifest). Undo already brought them back. The worker accepts only real
  folders right in `~/Applications` (no link, no dot folder, normalized), so a plan can never move
  anything else.
- **`pruneRetired`:** retired folders of backups older than seven days are deleted (the backup itself
  stays). It runs with each `found.scan`, as the reference does with each look for new apps.
- **`found.update_preview {program?}`:** the connection preview for one app, or for all of them, with
  the "kept with the backup for 7 days" note. An AppImage has to be unpacked first. `found.hints` and
  `found.list` now count an update whose old version is only started through a link, as the reference
  does. `found.list` carries the updates with "Update · used by …" (agents, the list, or the links).
- **Flutter:** the found panel lists the updates (`gridcraft  0.7.0 → 0.8.0`) with **Update…**. Inside
  an AppImage it asks to unpack first. Then comes the usual preview, which now lists the retired
  folders, then Apply and Undo; afterwards the app looks again. The manual's found section has a
  paragraph on it in all eight languages; PDFs rebuilt.

Not ported: testing the updated servers right after (`updated_entries`); a test is one click on the
server.

Check:
- `tests/test_dart_mcp_update_parity.py`: both sides plan from the reference scan's own candidates.
  The fixture has Claude Code's and Codex's entries (an arg into the old folder, an entry starting a
  moved link, an unrelated one), the list, an absolute and a relative link, and the old folder
  retired. Python and Dart give the same changes byte for byte, and the same links and retired
  folders.
- `test/retire_test.dart`: apply moves the folder into the backup and writes the manifest, Undo
  brings it and the file back; the prune keeps recent ones and other folders; the worker refuses a
  folder outside `~/Applications`, `/etc`, a `..` path and a dot folder.
- An app test: Update… → the preview with the retired folder and the note → Apply → a new look.

### 6b-19a — The cost card, Settings › Costs, and Claude Code's sessions read whole

"Richer details" (the last 6b item) is four gaps against the GTK details pages: costs (the card, today's
cost on the map, the daily cost notification), projects of the last 30 days, a local LLM's details page,
and MCP server and skill details pages. This part is the cost card.

New in the core (`costs.dart`, the reference is `plugin_costs`, `agent_status.pays_per_token` and
`details_pages.fill_cost_card`):
- **Texts and numbers:**
  - `costText` ($3.40, $123, <$0.01; 3.03 €, 110 €), `inCurrency`, `shortNumber`;
  - `pyFixedExact` (in `py_values`): Python's exact rounding of the double, ties to even, since
    `toStringAsFixed` rounds ties away and the existing `pyFixed` multiplies first.
- **The euro rate:** `parseEcb` (only a plausible USD rate), and `keptRate` / `usdPerEur` with the rate
  kept a day in the shared `~/.local/state/omarchy-plugin-ai/exchange-rate.json`. The fetch runs in the
  worker (`costs.rate`, only that file, no redirects), and the last kept rate is used when offline.
- **`paysPerToken`:** no limits and no sign-in that ran out; then a key in the environment, an
  API-key-only agent signed in (its file only checked for existence), or a usage record without a
  plan.
- **`agents.costs {command}`:** the card with its texts in the interface language: title, summary,
  the three tiles (with the share of the day's limit, or "covered by your … plan"), up to six models
  by kind, the notes (reported costs, models without a price, the price dates). Also `rate_due` when
  euros need today's rate. The price dates come into the adapter assets as `prices_as_of`.
- **Settings:** `cost_currency`, `cost_limit`, `warn_yellow` and `warn_red` join the UI settings on both
  sides. Flutter's Settings › Costs has Currency, A day's limit, Yellow from and Red from, and red
  stays above yellow as in the reference. **Notify when red** moved into that section.
- **Flutter:** `CostCard` in the agent details asks for the card, fetches the rate once when it is due,
  and asks again.

**Claude Code's session reader (`claude_sessions.dart`):** the real-data check showed the Dart reader
diverging from the reference (`claude_sessions.collect_by_id`). It read whole files, skipped any over
64 MiB (this session's own was 68 MB), and only read files changed in 30 days. It also kept sessions
without replies and did not count older `agent-*.jsonl` runs. It is now a port of the reference:
- files are read line by line, a line over 8 MiB is skipped, and a last line still being written is
  read next time;
- the budget is 2 GiB per run, with 5000 files and 500 folders at most, in the reference's order;
- each file is read on from its offset (same inode, grown) and cached per file owner-only in
  `$XDG_CACHE_HOME/asterism/claude-sessions.json` (version 2);
- sessions need replies, and subagent runs (`<session>/subagents/`, depth 3, the type from the meta
  file only, and the older ones next to the sessions) are counted for their parent.

diff-core leaves this cache out of its file comparison, since the oracle reads deliberately without
one.

Check:
- `tests/test_dart_costs_parity.py`: cost texts in both currencies at the edges (ties, thousands,
  <0.01), short numbers, the ECB file and odd ones, the kept rate fresh/stale/offline/none/bad (the
  written file compared too), and `pays_per_token` for seven agent states.
- `tests/test_dart_claude_sessions_parity.py`: two runs with each side's cache. The fixture has a
  66 MB file, a 9 MB line, a half-written last line finished between the runs, a session with only a
  cost summary, a link, a subagent folder and an older `agent-*.jsonl`. Python and Dart agree on both
  runs.
- `test/cost_card_test.dart` (core): card texts paid per token in euros and on a plan, and unknown.
- Flutter `cost_card_test.dart`: the rate asked once then the card in euros; Settings › Costs keeps red
  above yellow.
- On this PC, read only, with Dart's cache in a scratch folder: the Claude sessions agree with the
  reference on the first run (123, budget-limited on both sides) and the second (173). The cost card
  agrees with the reference after two runs ($753 today, $1,238 in 7 days, $6,244 in 30 days, Max 5x
  plan: API value).

Next, 6b-19b: today's cost where the battery would be for agents paid per token, and the once-a-day
cost notification.

### 6b-19b — Batteries and today's costs on the map, the cost notification

New in the core (`agent_badges.dart`, the reference is `agent_details.battery`, `battery_tip`,
`current_limits`, `_charge`, `plugin_costs.cost_colour`, and `ai_popup.refresh_map` /
`update_costs` / `warn_red`):
- **`map.badges {}`:** each installed agent's box gets one badge:
  - **A battery** for an agent with plan limits: the tightest limit still counting (a past reset left
    out), rounded to four places (a tenth left is red), green, yellow or red at Settings › Costs'
    levels, with a tooltip line per limit and its reset in the local clock.
  - **Today's cost** for an agent paid per token (`paysPerToken`): "$1.50 today", coloured against a
    day's limit in the chosen currency, with the reference's tooltip.

  It also returns `rate_due` for euros.
- **`limits.notify`** also sends the red cost, once a day per agent ("About {0} today, {1} % of the
  day's limit ({2})."). `RedLimits` got `once(key, title, body)`, shared by limits and costs, and
  the same `red-notified.json` keeps both.
- **`pyRound`** (Python's round, a tie to even) is now used for every shown percentage: battery,
  card, red limits and costs.
- **Flutter:** `AgentBadge` in the agent box's title is a small battery bar or the cost label, with
  the tooltip. The app loads the badges after the first snapshot and every minute with the
  notifications (the reference's COST_EVERY), and fetches the euro rate once when it is due.
- The manual's costs section has a paragraph on it in all eight languages; PDFs rebuilt.

Not yet: the GPU battery of running local LLMs (`gpu_battery`).

Check:
- `tests/test_dart_badges_parity.py`: batteries (none, two limits with resets in Europe/Berlin, a tenth
  left, past reset, a tie, over 100 %) and cost labels (dollars, euros with and without a rate, at and
  above the levels, custom levels) with the red notification text. Python and Dart give the same.
- The red-limit tests still pass on top of `once`, and an AgentMap test covers the battery, the cost
  label and their tooltips.
- On this PC, read only: Codex shows "Weekly (7-day): 96 % left, resets Wed 09:48", green. Claude
  Code, OpenCode, DeepSeek Harness and Pi have no badge, as in the reference (no limits in their usage
  records, not paid per token).

### 6b-20 — The last details: projects, a local LLM's page, MCP server and skill set details

New in the core:
- **`agents.projects {command}`** (`projects.dart`, the reference is `claude_sessions.projects`,
  `subagents`, `busiest` and `details_pages.fill_session_projects`): per project folder of the last 30
  days the working time, sessions, tokens (subagent runs counted in), lines changed and API value; the
  subagent runs per type; the busiest hour; and the agent's own note on where the numbers come from
  (`[sessions] note` in its adapter).
- **`providers.details {key}`** (`runtime_details.dart`, the reference is `open_runtime_status`,
  `fill_usage_card`, `agent_status.runtime_usage` and `agent_security.runtime_report`):
  - whether it runs, the GPU memory it holds and its loaded models (from the last GPU snapshot);
  - tiles for its models (folder), agents and address;
  - "Usage and tokens through …": what agents sent through it, matched by model name, with a provider
    prefix counting only for this LLM's connect key;
  - its risks: who can reach it, no password on the local API, models from the web.
- **`gpu.snapshot`** (worker, read only): `GpuUsage` (`model_guard.dart`) gained `totals()` (sysfs,
  else nvidia-smi) and `snapshot()`: per local LLM whether it runs, the GPU memory its processes hold
  (DRM fdinfo), and its loaded models asked of it on loopback. A running local LLM shows the GPU memory
  still free as a battery in its box (`gpuBattery`, the limits' colours).
- **`details.mcp {name}`** and **`details.skills {path}`** (the reference is `mcp_pages.open_mcp_details`,
  `mcp_rows` and `open_skills_details`). An MCP server shows, per agent that has it, the settings file,
  its type, and its command and arguments, or its address and headers. Values of environment
  variables, headers and query parameters are never shown. Also who has not got it, and its tools as
  last asked. A skill set shows how each agent reads it (by itself, in its settings, links in its own
  folder) and each skill's description, read from SKILL.md like the reference (also a system folder's).
  The routes are named `details.*`: `mcp.*` and `skills.*` go to the catalogs first.
- **Flutter:** `ProjectsCard` in the agent details, `RuntimeDetailsCard` in the local LLM card
  (status, tiles, usage, Risk management), the GPU battery refreshed every minute, and
  `ItemDetailsView` when an MCP or skills box is clicked (**System Map** still opens the System Map).
  The cards show nothing for an answer without their fields. `_quietTask` refuses an answer without a
  task. The manual's "Details in the Flutter preview" in all eight languages; PDFs rebuilt.

Check:
- **Parity tests:**
  - `tests/test_dart_projects_parity.py`: English and German, old sessions, an unknown folder,
    subagents, lines, API value, the busiest hour.
  - `tests/test_dart_runtime_details_parity.py`: model-name matching with tags, file endings and
    prefixes; the risks for loopback, network, no address and not installed; GPU batteries.
  - `tests/test_dart_item_details_parity.py`: stdio and HTTP entries in Claude Code's and Codex's
    settings, with environment, query and header values that never appear; a skill set through
    links, with folded and plain descriptions.
- **Widget tests** for the three views.
- **On this PC, read only:** projects for Claude Code and Codex; Ollama's and llama.cpp's pages
  (models, agents, address, risks); chrome-devtools in Claude Code and Hermes; the omaraw skill's
  description, as the reference reads it. The GPU totals agree with the reference's (24 GB card,
  1.6 GB used).

## Phase 6 — final test (2026-10-30)

Phase 6 is complete as planned: 6a (every route in Dart) and 6b-1 to 6b-20. That covers the online
MCP and skill catalogs and tool checks, web skills, API keys, settings, security, help and
notifications, tuning, durable jobs, the installer UI, the guide return, the subagent readers and
add-on file import, and with them the found-on-this-PC, AppImage, app-update, cost, badge and
details work.

The final test on this PC:
- **`tools/flutter-dev check`:** `dart analyze --fatal-infos` clean, 74 Dart tests, 69 differential
  cases, the AOT release transport check (no Python fallback code), Flutter analyze clean and 148
  Flutter tests.
- **`tools/flutter-dev build`:** a release bundle with the AOT `asterism-core`.
- **`python3 -m unittest discover -s tests`:** 1482 tests, among them every Python ↔ Dart parity test
  of phase 6.
- **`tools/typecheck.sh`:** 0 errors.
- **End to end, read only, on the bundle's compiled `asterism-core` against this PC's real data**
  (caches in a scratch folder): `map.badges`, `agents.costs`, `agents.projects`, `providers.details`,
  `details.mcp`, `details.skills`, `found.hints` and `addons.hints` all answer.

The test found three faults, all fixed before this checkpoint:
- **`addons.hints` (6b-16) never reached its branch:** the `addons.*` prefix route answered first.
  The unit tests and the app test (fake service) hid it. `test/route_reach_test.dart` now sends every
  6b route through `CoreService.dispatch` and fails when another branch answers. It was checked to
  catch the earlier `mcp.details` case.
- **The app could not start against a service without the new routes:** a quiet task without a task
  id made the test service fail, and every app test with it.
- **A lint info** that only `--fatal-infos` reports.

Not part of the phase-6 list and not in Flutter yet (GTK features for later):
- the local helper, starter-model guidance, the map's usage box, daily AI checks and terminal tabs;
- feature/extension add-ons, which data-only add-ons cannot carry by design;
- the step 4 work of `plan-flutter.md` (host interaction checks, layout, keyboard/accessibility,
  clean-VM scenarios).

Next: phase 7, Python out of the app.

## Phase 7 — Python out of the app (2026-10-30)

**Part 1 (57fa170): the app's service is the Dart core alone.**
- `Backend.start()` is the core in its background isolate. The router with its Devel Python fallback
  (`service_router.dart`) is gone; a route the core does not know is refused (`unported_route`), as the
  release probe of `tools/check-dart-core-release.py` checks.
- `PythonTransport` moved to `flutter_app/test/support/`: it only drives the widget tests' fake service
  scripts. `ASTERISM_SOURCE` and the unused `tools/check-flutter-transport.dart` are gone.
- **Release gate `tools/check-bundle.py`**, run by `tools/flutter-dev build`, fails on any of these:
  - a `.py`/`.pyc` file, a Python executable or a Python environment folder in the bundle;
  - the markers of a Python service in its binaries (`/usr/bin/python3`, `flutter_backend`,
    `PythonTransport`, `ASTERISM_SOURCE`);
  - one of them in the code of the app's or the core's Dart sources. Comments naming the reference a
    port follows are allowed, and so are process names like `python3` in the core's data.

  The bundle built before part 1 failed it (its UI still had the transport); every bundle since
  passes.
- **Safety fix: a Devel build must never install the real asterism-providers.service.**
  - **What happened:** the core installed the user service for whatever compiled core it ran as. A
    scratch copy run against the real home had written and enabled
    `~/.config/systemd/user/asterism-providers.service` on 2026-10-29. It is removed.
  - **Layer 1:** the core now never manages the unit for a binary in `/tmp`, `/var/tmp`, `$TMPDIR`,
    a `.flutter-previews` bundle or `build/linux` output (tests in `write_path_test.dart`).
  - **Layer 2:** a Devel build of the app marks its core `ASTERISM_FLUTTER_DEVEL=1`, as the Python
    service did.

**Part 2: the GTK UI is gone from this tree** (its frozen copy is `/mnt/Data/Projects/omarchy-ai-agents-map`,
synced last on 2026-10-28; git history keeps everything).
- **Removed:**
  - the 28 GTK modules (`ai_popup`, `map_view`, the pages and dialogs, `ui_helpers`, `text_guard`,
    `theme_css`, …) and `plugin_catalog.py` (only for the GTK info page);
  - `tools/profile-map.py` (GTK profiler), `bin/asterism` (the GTK launcher), and the GTK app's
    AppImage builder and AUR `PKGBUILD`.

  `desktop_generic.py` and `models_ctl.py` stay: they are reference logic that only loads GTK lazily
  in a function, and other reference modules import them.
- **Reference texts:** what the parity tests need from the deleted pages is in the new
  `reference_texts.py`, copied unchanged: `short_number`, `duration_text`, `mcp_rows`.
- **Tests:** every test that used a deleted module was removed, line-exact, with an AST tool. Tests of
  reference modules in the same files were kept.
  - 14 files are gone completely: the GTK map, terminal, add-ons page, previews, window and
    launcher tests, and the plugin catalog.
  - 10 files lost their GTK tests and kept the rest.
  - `test_packaging.py` keeps its data tests (manual PDFs, versions, the add-on unpacker).
  - `test_sync_plugin.py` checks a shared module that still exists. The tool itself is untouched, as
    the plan's rules say; it is retired (`plan-naming.md`).
  - One flaky reference test (a process seen as `X`, dead, while it is reaped) accepts that state.
- `AGENTS.md` says every `*.py` is reference only and names the gate; `README.md` no longer describes
  the GTK app's install, plugin sync or code add-ons; `pyrightconfig.json` lost the deleted files.

Check: `tools/flutter-dev check`, with 74 Dart tests, 69 differential cases, the release probe and 148
Flutter tests. `tools/flutter-dev build` passes the gate. 1324 Python tests run (1482 before: 158 GTK
tests went with their modules), and `tools/typecheck.sh` reports 0 errors. Read only against this PC's
real data, the bundle's AOT `asterism-core` answered the routes I tried, and no user unit appeared.

Phase 7 is done. Next: `plan-flutter.md` steps 4–8 (product fit, Omarchy integration, packaging without
Python, the `ubruckhaus.asterism` launcher plugin, final review) and the rename to Maprisma. The GTK
features not in Flutter yet (local helper, starter models, usage box, daily AI checks, terminal-tab
states) are open for step 4.

## plan-flutter.md step 4 — the GTK features still missing (from 2026-10-30)

### Part 1: terminal tabs, the usage statistics box, the starter model

- **Terminal tabs** (`terminal_tabs.dart`, the reference is `ai_popup.build_terminal_tabs`):
  - a legend (TERMINALS · ● working · ● running · ● ended) over a tab per terminal;
  - the state comes from the terminal (ended) and the core's activity (`working`);
  - the tab in view is marked, and a click shows its terminal;
  - the setting `terminal_tabs` joins the UI settings on both sides ("Terminal tabs above the map").
- **Usage statistics box** (`usage_box.dart`, a port of `usage_box.py`):
  - the newest session file of the agent's `[replies]` written in the last 60 s, its last 256 KiB
    (own regular files, no links, lines up to 64 KiB);
  - Claude Code's, Codex's and Pi's line formats;
  - the speed of the latest reply, from its input to its last line;
  - the context size from the file, else the adapter's `contexts`, and the share in use.

  The route is `map.usage {commands}`: the app sends its working agents every 2 s (the reference's
  checks), and the core answers with the box parts as the settings say (`usage_box`,
  `usage_box_items`, `usage_box_size`, now UI settings on both sides). Flutter shows it in the
  working agent's box title (`UsageBoxLabel`, shortened when the box is narrow), since lines carry
  no labels in the Flutter map; Settings has its switch, its three items and its text size.
  Not yet: the context size from the local LLM the agent uses.
- **The starter model in the guide** (`first_agent.dart`, the reference is `first_agent.parse`'s models,
  `fit` and `suggested`, and `first_agent_page.first_local_steps`):
  - the catalog's starter models are parsed in Dart too, with the same checks;
  - the worker passes the card's video memory (`detectGpu`);
  - a local route's **A model** step, while its LLM has no model, names the suggestion ("Suggested:
    Gemma 4 12B, 7.0 GB (fits your graphics card: yes)"), and **Download it** starts the Models
    page's durable download, or Ollama's pull of `hf.co/<repo>`.

  The Python reference (`flutter_first_agent.py`) gives the same step, and `reference_texts.size_text`
  keeps the GTK size text.
- The manual's "Terminal tabs, the usage box and the starter model in the Flutter preview" in all
  eight languages; PDFs rebuilt.

Check:
- `tests/test_dart_usage_box_parity.py`: the three formats, a reply over several lines, a tool
  result, a too-long line, a file cut at 256 KiB, context sizes from the file, the adapter and none,
  the newest file at a depth, a link. Python and Dart agree.
- `tests/test_dart_setup_guide_parity.py` now also checks the starter step; Python and Dart agree.
- Widget tests for the tabs, the box, the box settings and the guide's download.
- **On this PC, read only:** this Claude Code session's box reads "98 t/s · 1M · 88%", the same as
  the reference.


### Part 2: the local helper, the daily AI checks

- **The local helper** (`local_helper.dart`, a port of `local_helper.py`):
  - the candidates: installed agents whose adapter has `advise` and `closed`, each local LLM they
    are connected to, each of its chat models (speech, embedding, reranker, tokenizer and vision
    names are left out);
  - the suggestion: the largest model of at least 2 GB that fits 85 % of the card's video memory
    (without sizes, the first one);
  - the chosen one: Settings' `ai_local_helper`, while it is still there (now a UI setting on both
    sides);
  - its argv: the adapter's `advise` argv with the model and provider, closed in like a look-up,
    the prompt on stdin.

  `helper.snapshot` gives the candidates, the suggestion and the choice; Settings › AI features ›
  **Local helper** shows them, the suggestion marked, with **Off**. A chosen helper is offered first
  under **Ask** on a local LLM's Performance card (`models.tuning_ask` with `local-helper`, its
  fields checked again in the worker).
- **The daily AI checks** (`mcp_updates.dart`, a port of `mcp_updates.py`):
  - the servers of the map's list whose version is known: an app unpacked in
    `~/Applications/<app>-<version>/` or, beyond the GTK app, as an unpacked AppImage in any other
    folder (`<folder>/<app>-<version>/usr/bin/<program>`, such as `/mnt/Data/Ai/McpServers`; the
    reference was changed the same way), also through a link; npm packages pinned to a version (npx,
    bunx, pnpx), PyPI packages pinned to a version (uvx, `pipx run`); at most 40;
  - one prompt for all of them, one look-up by the agent for AI checks (the private worker op
    `checks.mcp`, the agent checked again there), its answer checked as in the reference: a known
    server, a plain newer version, an https link without spaces or quotes, notes cut to one line;
  - the cache `$XDG_CACHE_HOME/asterism/mcp-updates.json`: asked again after a day, or after six
    hours when the look-up failed (the old finds are kept then); the run goes into the shared
    token log as `mcp-updates`;
  - a find is shown while the server still starts the version it was about; **Use it…** instead of
    the download once the newer version is unpacked (in `~/Applications` or beside the installed one)
    or there as an AppImage; the task "Do it with …" names the installed version's real folder.

  The routes: `checks.mcp_updates` (the finds, their texts, the summary and the agents; nothing is
  asked), `checks.mcp_check {force}` (the daily check, only while `ai_checks` is on and a check is
  due, or Check now), `checks.mcp_task {name}` (the task "Do it with …" as a preview, applied
  through `system.help_apply` into a terminal tab) and `checks.mcp_release {name}` (the find's https
  link with `xdg-open`). The app asks `checks.mcp_check` at start and every hour, and again when the
  switch changes; the finds join Open problems' **Updates and suggestions** and the header's
  **!**. Settings › AI features has the switch `ai_checks` (now a UI setting on both sides), the
  last result and **Check now**.
- The manual's "AI checks and the local helper in the Flutter preview" in all eight languages;
  PDFs rebuilt.

Check:
- `tests/test_dart_local_helper_parity.py`: suggestions for several cards, without a card, without
  sizes, too small models; the choice kept and gone; the non-chat names; Pi's advise argv. Python
  and Dart agree.
- `tests/test_dart_mcp_updates_parity.py`: apps direct and through a link, pinned and unpinned npm
  and PyPI packages, `pipx run`, remote servers; answers with prose around the JSON, an unknown or
  repeated server, older and unparsable versions, http and spaced links, long notes, no JSON; the
  cache fresh, failed and old; `on_pc` for an unpacked folder and an AppImage; the task prompts.
  Python and Dart agree.
- `test/mcp_updates_test.dart`: the look-up with a fake agent (the prompt on stdin, the answer
  checked and cached, the token log), and a failing agent that keeps the old finds.
- Widget tests: the switch and Check now in Settings, the finds in Open problems with
  **Release page** and **Do it with …** (nothing starts without Continue).
- **On this PC, read only:** both sides find the same 13 Craft servers in `/mnt/Data/Ai/McpServers`
  (photocraft through its link in `~/.local/bin`); nothing was asked, since the daily checks are
  off here. The local helper's four candidates and the suggestion are the same as
  the reference's.

### Part 3: keyboard and accessibility

- **Shortcuts as in the manual's table** (`main.dart`):
  - **F1** Help, **Ctrl+,** Settings, **F5** Refresh;
  - **Ctrl+Plus / Ctrl+Minus / Ctrl+0** zoom the map in view (AI or System Map) by 1.25 / 0.8 /
    back to 100 %, within the map's 30–200 %;
  - **Esc** and **Backspace** go back from a page (Settings, Providers, Connections, guide, System
    Map) to the map.

  Text fields keep Backspace, dialogs keep Esc (they are routes of their own; Backspace has its
  own intent, so it never closes one), and cards, the map editor and terminals take their keys
  before they reach the app. The page holds the focus when nothing in it does (an autofocus
  `Focus` outside Tab's order); without it, Esc stopped at the page route's own disabled dismiss
  action.
- **The map by keyboard**: Tab reaches each box (Enter opens it) and its ⋮ Actions button; in the
  map editor every drag has a keyboard way in the box's Actions menu (Connect, then Tab to the
  target and Enter; Move connection, Move up, Move down); Esc cancels.
- **Guideline checks** in light and dark (`test/accessibility_test.dart`, and the whole window
  with the fake service in `task_cards_app_test.dart`: map, Open problems, Settings, Help, System
  Map):
  - every tappable control has a label;
  - targets are at least 24 × 24 (WCAG 2.2 AA 2.5.8; the 44/48 of the mobile guidelines are for
    touch);
  - text contrast is at least 4.5:1.

  Found and fixed: the map box's ⋮ button had a 28 × 28 target, now 44 × 44 in the box's corner
  (same place, the box no higher). Not a finding: the header's AI Map / System Map switch, which
  the guideline measures as 2.34 while its pixels give 7.5:1 and 16:1. The whole-window check
  measures each text on its own and leaves those two out, with the reason in the test.
- The manual's "Keyboard use in the Flutter preview" in all eight languages; PDFs rebuilt.

Check: widget tests for each shortcut (including that Backspace in Settings goes back and Esc
does too), the map by Tab/Enter/Space, connecting in the editor by keyboard alone, and the
guidelines; all 166 Flutter tests pass.

### Part 4: recovery — recent changes with Undo after a restart

Every connection change already writes its backup and `manifest.json` before it touches a file, and
`ConfigFiles.undo` puts back only what still reads as written. But the app's Undo knew only the last
change and only until the app closed: after a crash or a restart the backups could not be reached
from the app.

- `change_history.dart`: the backup folders in the app's backup root (named by their time, own
  folders, `manifest.json` at most 1 MiB, no links), newest first, at most 20; for each its time,
  the files and links it changed and what Undo would put back now (the same checks as
  `ConfigFiles.undo`, nothing changed). `undoChange` takes only a backup's name, directly in the
  root.
- Routes `changes.history` and `changes.undo {id}` (refused while an add-on installs).
- Settings › **Recent changes**: each change with its time and files, **Undo** while there is
  something to put back, else a mark "changed again since"; a message says what was put back.
- An apply that stopped half way (the app closed while writing) left its manifest first: its
  written files are undone, the others are rightly seen as unchanged.
- Translations in all eight languages; the manual's "Recent changes and Undo after a restart";
  PDFs rebuilt.

Check: `test/change_history_test.dart` (order, Undo by id, a file edited again since, the
half-done apply, folders and ids that are not changes), an app test with the fake service.
On this PC, read only: the list is empty, since this app has not written a change here yet. The
GTK app's 144 backups live in `~/.local/state/ai-agents-map/backups` and are not listed (the known
difference in backup places, still to decide).

### Part 5: safe updates of running agents

The GTK app started an agent's update in a terminal even while the agent worked, so its program
was replaced under running sessions. Now `updates.run` for an agent first counts its open
instances (`agentInstancePids`: in this app's terminal tabs and in terminals of their own,
background servers and the app's own look-ups left out). While any run it starts nothing and
answers `{started: false, running, here}`; the app says "<agent> is running right now", why an
update then is risky, and offers **Cancel** or **Update anyway** (`updates.run` again with
`running_ok: true`). Local LLM updates go through their install review as before.

- Translations in all eight languages; the manual's "Updating a running agent in the Flutter
  preview"; PDFs rebuilt.

Check: the app test of Open problems' Update now goes through the dialog (nothing starts before
**Update anyway**); the instance detection itself is covered by
`tests/test_dart_agent_halt_parity.py`.

### Part 6: the desktop theme during operations

The app read the desktop theme in its two-second live refresh, which stops while the app is busy
(a download, an install, a change being written) — so a new Omarchy theme showed only after the
operation. The theme now has its own read every two seconds (`app.theme` only reads the theme
files), with its own pending flag, whatever the app is doing; the live map refresh keeps its
pauses.

- The manual's Flutter themes section says so, in all eight languages; PDFs rebuilt.

Check: an app test keeps the app busy (the fake core answers an Undo only later), changes the
desktop accent meanwhile and sees the app's colours follow before the answer; with the theme read
taken out again, the same test fails.

### Part 7: settings across processes

`settings.json` has more than one writer: the app's core (the user's changes and its own saves of
project history and add-ons) and, at the same time, another build of the app (a Devel build next
to an installed one; the app itself is a unique GApplication, so a second launch of the same build
only raises the first window). Each save read, changed and wrote the whole file without a lock, so
two saves at once could undo each other. The Python reference had no lock either.

- `SettingsStore._saveChanges` now runs under an exclusive `flock` on `settings.json.lock` beside
  the settings (this account's own regular file, opened without following links); read, change
  and atomic write happen inside it. Missing folders are made 0700 first, as the atomic write
  makes them. The Python reference (`ai_core.update_settings`) takes the same lock on the same
  file, so the differential cases see the same files on both sides (they had caught the lock
  file as a Dart-only difference).
- The app reads the UI settings every two seconds with the theme (`settings.get`, skipped while it
  writes a change of its own) and shows a change made elsewhere without a refresh; an answer
  without the settings' `language` is ignored.

Check: `test/settings_lock_test.dart` has two isolates save different keys 150 times each at
once; before the lock, saves were lost in each of three runs (a key ended at 117, 136 or 148 of
149), with it none are. An app test changes a setting from "another process" and sees Settings
follow within one check.

### Part 8: clean-VM scenarios

`tools/vm-scenarios` runs the newest built bundle (the release preview `tools/flutter-dev build`
makes, 66 MB, gate passed) in a throwaway Omarchy VM (`~/VMs/omarchy-edge`, the edge image of
2026-10-13), headless (`-display none`, a copy-on-write overlay deleted on exit; nothing touches
the host's desktop). The bundle is shared read-only over 9p; `tools/vm-scenarios.sh` runs inside
over ssh.

Results on 2026-10-30, all as they should be:
- **Libraries:** the app needs nothing the clean system lacks (the plugins find
  `libflutter_linux_gtk.so` through the app's own search path).
- **The core on a fresh home** (the bundle's `asterism-core`, no agents, no add-ons):
  `app.snapshot` with every default; `settings.update` to German makes `settings.json` and
  `settings.json.lock` (0600, folder 0700) and every later answer German; Recent changes, the
  local helper and the MCP checks empty and worded so ("tägliche Prüfungen aus"); Open problems
  sees the VM right (no graphics card for local models, 3.8 GB memory, no agent yet); the guide
  offers its routes with mise already there; the scan finds the skill sets Omarchy and
  Superwhisper ship; the map's first build is pending; nothing on stderr; no user unit installed.
- **The app in the VM's Hyprland session:** starts (Impeller over OpenGL ES in software), window
  `io.github.ubruckhaus.Asterism.Devel` titled Asterism; the first start shows the welcome and
  the Agents focus with no add-ons yet, Look for add-ons online and Install from file.

Not covered here: anything that needs the network beyond the catalog (installing agents, models),
or input in the VM's session; those stay with the step-8 review.

With this, plan-flutter step 4 is done.

## plan-flutter.md step 5 — Omarchy integration (from 2026-10-30)

### Part 1: the popup under the bar (a floating window)

Uwe chose a floating window over a layer-shell surface (2026-10-30): no new library (the GTK3
`gtk-layer-shell` is not installed on his PC), and drag and drop and the keyboard behave as in any
window — the map editor relies on dragging.

- **Placement** (`hyprland.dart`): the core runs in the app's process, so it finds its own window in
  `hyprctl clients -j` by its pid, takes the focused monitor from `hyprctl monitors -j` (logical
  size = pixels / scale, the bar from `reserved`) and dispatches Lua: `hl.dsp.window.float`,
  `.resize`, `.move` (tried in the edge VM, Hyprland 0.56.2 as on Uwe's PC). 1100 × 760, top right,
  10 px from the bar and the edge, kept inside the free area; only a plain `0x…` address goes into
  the Lua; `hyprctl` runs under `timeout 2`. Route `window.popup {width, height}` (only on
  Omarchy). Window rules cannot be added at runtime, so the window is placed right after it maps.
- **Runner** (`my_application.cc`): a `toggle` action; `asterism --toggle` hands it to the running
  instance over D-Bus (GApplication; flushed before the second process ends) — it hides the window
  when shown and focused, else shows and focuses it. Every show (first frame, toggle, a second
  plain start) tells the app on the channel `asterism/window`, and the app has the core place the
  window again. This replaces the GTK toggle's PID file and SIGUSR1: the launcher plugin of step 7
  only runs `asterism --toggle`.
- **App:** `window_mode` (auto, popup, window; a UI setting on both sides, the reference's schema
  too): auto is a popup on Omarchy (`desktop.snapshot`), else a window. In popup mode the GTK title
  bar is hidden (Hyprland draws the border); Esc on the main page closes it (Backspace never;
  Esc on a page still goes back); losing the focus closes it after 250 ms unless the focus comes
  back or a file chooser of the app runs (`PopupGuard` around all six choosers). Settings ›
  Window chooses the mode.
- Translations in all eight languages; the manual's "The popup under the bar on Omarchy"; PDFs
  rebuilt.

Check: `test/hyprland_test.dart` (a 4K monitor at scale 2 with a 30 px bar as on Uwe's PC, a size
too big for the VM's monitor, no own window, an address that is not plain, the Lua); widget tests
(placed at start on Omarchy, Esc closes and Backspace does not, nothing of it elsewhere, the mode
and the guard). **In the edge VM** (headless, the built bundle): the first start floats at
(170, 36) 1100 × 754 under the 26 px bar; `--toggle` hides it and shows it again in place; when
foot takes the focus it hides; a second plain start brings it back; no title bar.
Not yet: Omarchy's agent menu entries and usage records, the floating terminal for external
starts, rounding from `window_rounding()`.
