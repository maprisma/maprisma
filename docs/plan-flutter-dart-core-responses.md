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
