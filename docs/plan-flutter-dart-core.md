# Plan: a Flutter-only app — the service in Dart, Python only for testing (2026-10-28)

## Decision (Uwe, 2026-10-28)

The shipped Asterism is **Flutter/Dart only**: no Python interpreter, no `.py` file and no Python service in
the bundle or started by it. Python stays in this repository as the **reference implementation and test
oracle**: its 1,415 tests and its behaviour define what the Dart core must do, until each part is ported.
This replaces "Python may remain as the local service" in `plan-flutter.md` (Completion means).

## Why it is possible (facts)

- The service (~30,600 lines in the 129 non-GTK modules, `flutter_*.py` included) uses **only the Python
  standard library**. `gi`/`cairo` appear only in the GTK interface, which is being retired anyway. Dart
  has `dart:io` (processes, files, sockets, HTTP), JSON, and packages for TOML, SQLite (FFI to the system
  libsqlite3), zip archives and Ed25519.
- Agent adapters are already data (`adapters/*.toml`, `docs/adapter-format.md`). Only six have code hooks
  (`adapters/{dsh,hermes,omp,openclaw,opencode,pi}.py`, ~800 lines).
- The UI already talks to the service through one bounded JSON protocol (`flutter_backend.py`,
  `flutter_app/lib/backend.dart` starts `/usr/bin/python3`). That protocol is the seam: the Dart core
  serves the same routes, so the UI barely changes and both implementations can be tested against the
  same requests.

## What is hard (and the answers)

| Problem | Answer |
|---|---|
| AOT Dart cannot load code from an add-on | **Add-ons become data-only** (format v2: `agent.toml`, `provider.toml`, signed). The six hook modules and the provider engines (`provider_*.py`) become **built-in named readers/writers/engines** in Dart, chosen by name from the TOML, like `adapter_data.READERS` today. A new agent needing new code needs an app update. **Uwe confirms this before phase 5.** |
| Low-level calls Dart lacks: `O_NOFOLLOW`/`openat`, `fstat` on a descriptor, `fsync`, `pidfd_open`/`pidfd_send_signal`, `prctl`, `forkpty`/`setsid`, `/proc` start times | One small `posix_ffi.dart` (libc through `dart:ffi`), Linux-only behind the desktop adapter (macOS later gets its own), each call unit-tested, including hostile cases (symlink swap, PID reuse). |
| The Python worker applies plans in a separate process (wire v1–3) | Keep a separate process: a Dart CLI `maprisma-core` (`dart compile exe`) with the **same wire**, so the existing Python worker tests can drive it as well. |
| `provider_watch.py` runs as a systemd user unit | The same `maprisma-core` executable, `maprisma-core provider-watch`. Unit rewritten once with a backup; the old Python unit is migrated, never left half-installed. |
| Heavy scans must not stall the UI | The core runs in a background **isolate** (in-process transport: the same JSON messages over `SendPort`), not on the UI thread. |
| Config edits must stay byte-for-byte what Python writes (comments, order, CRLF) | Port the text transforms as text transforms, not parse-and-reserialize. The differential tests compare **file bytes**. |
| Signed add-ons are verified with `ssh-keygen -Y verify` | Verify the SSHSIG Ed25519 format in pure Dart; test vectors made by `ssh-keygen` (in tests only). Keep the same embedded key. |

## Architecture

- `packages/asterism_core/`: pure Dart (no Flutter import), unit-tested with `dart test`. Contains the
  routes, policies, adapters, plans, backups/Undo, scans, providers, add-ons, jobs. Desktop facts behind a
  `Desktop` interface (`desktop_linux.dart`, `desktop_omarchy.dart`, later macOS).
- `packages/asterism_core/bin/maprisma-core.dart`: worker and provider-watch entry points (one AOT exe).
- `flutter_app/`: a `ServiceTransport` interface with two implementations: `IsolateTransport` (Dart core,
  the shipped path) and `PythonTransport` (today's subprocess). A **router** sends each route to Dart once
  it is ported; unported routes go to Python **only in Devel builds**. A release build has no
  `PythonTransport` compiled in (const flag) and fails the build if a route is still unported.
- Python files stay where they are as the reference. The GTK UI files are deleted from this tree at the end
  (phase 7); the GTK repo keeps its own copy (frozen).

## Differential tests — how Python keeps testing

`tools/diff-core.py` (dev only) runs the same request script against the Python backend and the Dart core,
each with its own copy of a fixture HOME (fake agent configs, provider replies from a local fake server,
fake `/proc` where needed), and compares: the normalized responses (handles, times and PIDs masked), the
resulting file trees **byte for byte**, file modes, and what was refused. Every ported route gets
scripts for its normal cases and its hostile cases (the existing Python hostile-input tests are the
source list). A route counts as ported only when its differential scripts pass and the Python unit tests
of the same behaviour have Dart counterparts.

## Phases

Each phase is one Codex slice: implement, answer in `plan-flutter-dart-core-responses.md` (one section per
phase), Claude reviews, Uwe decides the commit. Do not start the next phase before the review.

1. **Foundation.** `asterism_core` package, protocol types, `IsolateTransport`, router with Devel fallback,
   `posix_ffi.dart` with tests, `tools/diff-core.py`, CI-style `tools/flutter-dev check` also running
   `dart test` and the differential scripts. Port first: settings (`settings_schema.py`, strict validation,
   atomic 0600 writes), paths/identity/app id, `app.theme` and the Omarchy/generic desktop readers, i18n
   lookup for service messages.
2. **Read-only scans.** Adapter TOML loader (`adapter_data.py`), installed agents (`harnesses.py`,
   `agents.py`, `inventory.py`), status/details/security reports, MCP and skills scans, sessions/usage/cost
   readers (SQLite read-only), activity, subagent readers, `graph.py` → `map.snapshot`, System Map (disks,
   mounts, health, model folders). Hooks needed here become built-in Dart readers.
3. **Write path.** Plans and previews (`connect.py`, `mcp_ctl.py`, `skills_ctl.py`, `context_ctl.py`,
   map editor routes), opaque expiring handles, stale checks, backups and Undo, settings updates, the
   `maprisma-core` worker with wire v1–3 (the Python worker tests pass against it).
4. **Processes and providers.** Terminal sessions (PTY through FFI; the xterm widget stays), agent start,
   owned/external instances with the PID + start-time + pidfd stop guard, own-UID port check, provider
   engines (Ollama, LM Studio, llama.cpp, vLLM, Jan, KoboldCpp, online), `provider-watch` and its unit
   migration, model load/unload/move/folders, Hugging Face search and downloads, jobs.
5. **Installers and add-ons** (after Uwe's OK on data-only add-ons). `install_ctl.py` (pacman/yay, AppImage
   with bubblewrap, mise, recipes, fixed argv only), add-on format v2, Dart signature verification, signed
   catalog/store/update, migration of installed Python add-ons (shown as "needs an update" until the
   catalog has the data version; nothing of them runs).
6. **Remaining parity, written in Dart directly** (the open items of `plan-flutter.md` step 3): online MCP/
   skill catalogs and tool checks, web skill installation, direct API-key entry (stored as the agent
   expects; never read back into the UI), full settings/security/help/notification views, tuning, durable
   jobs, prerequisite/runtime installer UI, completed setup actions returning to the guide, remaining
   subagent readers, add-on file import. New UI text in 8 languages and the manual, as always.
7. **Python out of the app.** Remove `PythonTransport` from release builds, delete the GTK UI modules from
   this tree, add a release gate (`tools/check-bundle.py`: no `.py`, no `python` in the bundle, no Python
   path in Dart sources outside tests/tools). Python reference modules and their tests stay for the
   differential suite; mark them "reference only" in AGENTS.md.

Then `plan-flutter.md` steps 4–8 continue (product fit, Omarchy integration, packaging — now without a
bundled Python — the new `ubruckhaus.asterism` launcher plugin, final review). New features after phase 7
are Dart only.

## Rules

- AGENTS.md applies: nothing pushed or published, never push `main` to `gtk`, never read credential files
  (existence only), no real-desktop runs that move the mouse or grab the keyboard (widget tests, Xvfb,
  isolated Devel builds), 8 languages + manual for new UI text.
- **Keep every security property** of the Python service: no argv from UI data, opaque handles, bounded
  inputs and replies, stale checks before writes, no following symlinks, atomic writes with fsync, 0600
  files, timeouts, own-UID checks. A port that drops one is not done, even if the feature works.
- Same behaviour first, improvements later: where you find a Python bug while porting, fix it on both
  sides in the same slice and say so (the GTK repo gets it as a fix, since it is frozen to fixes).
- Do not touch the AI Agents Map plugin or `tools/sync-plugin.py`; the GTK plugin keeps reading the Python
  reference files.
- Report honestly per phase: routes ported, differential scripts passing, what still falls back to Python.
