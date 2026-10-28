# System Map implementation responses — 2026-10-28

Implemented against Uwe’s approved `plan-system-map.md` in the Flutter development
preview. This is a migration milestone, not a production entrypoint replacement.
E1–E6 were addressed first; see `review-claude-2026-10-28-responses.md`.

## 1. Permanent pages

`system_map_view.dart` replaces the PC overview dialog. The header switches between
AI Map and System Map. Each has its own controller and selection; the System Map
view is also saved privately. Existing navigation flags were retained because a
whole-app navigation rewrite would be larger than this feature.

## 2. Saved map and refresh

`flutter_system_map.py` separates cheap metadata from explicit discovery and size
measurement. `system_map_cache.py` supplies a versioned, size-limited, owner-only,
atomic cache with validation and locked updates. Loading does not scan. Cheap
refresh preserves discoveries, analysis, measured sizes and missing disks.

Look/Refresh searches mounted disks within existing discovery limits. Following
opt-in, a new mount identity triggers its first search. Skip never opts into disk
search. While the System Map is visible, mount metadata is checked at the greater
of 15 seconds or the chosen background interval, respecting Manual-only and focus
pause. System searches do not enter the AI Map scanner. User-triggered visits and
Refresh still work with Manual-only enabled.

## 3. Welcome

Welcome offers Look at this PC / Skip, explains local read-only discovery, and
retains adapter choices and fixed Switch on / Later controls. Look uses the worker
progress dialog and opens What we found. Cached installations remain available
on later starts.

## 4. Supporting tools

`system_tools.py` detects Python/venv/uv, Node, mise, Docker/Podman, Git, GCC,
Clang and CMake from paths, links and metadata. Known catalog prerequisites and
mise installations contribute dependency edges. Explicit Check runs the registered
program’s version command in the existing bounded, cleaned-environment worker.
The scan worker denies executable/network/credential probes during detection;
blocked detectors fall back to static facts and show a notice. This is an audit
barrier inside the scan worker, not an OS sandbox. Internal signed-adapter
verification precedes the barrier and retains its existing verifier.

## 5. Action inventory and cleanup

| Replaced surface | Action on System Map |
|---|---|
| PC overview dialog | Hardware, disks, runtimes, folders, observations and help on a permanent page |
| Existing-install mount picker/scan | Look/Refresh plus selected-folder search |
| Discovery results list | Found nodes connected to their disk; missing disks retained |
| Program test | Confirmed Check program |
| Runtime/model selection | Reconnect preview from node controls or runtime-to-folder drag |
| Use model folder | Existing preview/apply from found model node |
| Connection review/Undo | Existing backend plans, backups and Undo |
| AI explanation/simplification | One guarded AI action group and consent preview |

Removed `existing_ai_dialog.dart`; no parallel legacy PC service routes remain.
Folder-to-AI-Map runtime drag previews declarative configuration changes. Runtime
aliases retain discovery handles. Reconnect creates the reviewed connecting files
without enabling or starting services. Managed wrapper changes take effect on the
next explicit runtime start; running services are not restarted.

## 6. Health, GPU stacks and safe moves

System-related `health.check()` findings attach to hardware/folder/runtime nodes;
controls lead to existing provider or setup flows. GPU stack information uses the
read-only path and existing reviewed package/vendor install recipes. Unknown VRAM
is not treated as measured zero. Search-only sizes use `disk_usage` deadlines.

`system_moves.py` uses existing model-folder and model-move primitives. Preview
identifies source/destination, files, bytes, affected configuration and warnings.
Apply revalidates the plan and mount, refuses running readers, verifies cross-disk
copies, updates supported references and persists a private Undo journal. Partial
failures roll back completed work; Undo refuses to overwrite new source files.
Tests cover interrupted steps, collisions, stale previews and relative links.
No real model files were moved during implementation.

Supported automatic moves are GGUF folders. Ollama blob-store relocation is outside
the existing move primitive. Unknown/custom wrappers are refused for automatic
rewriting and need a reviewed manual/AI plan. GPU device pinning remains deferred:
sysfs identity does not establish runtime-native CUDA/ROCm device identifiers.
Mount suggestions are text only; no fstab changes are made.

## 7. Smart Check and usage

`system_map_analysis.py` reuses `smart_check.analyze()`/validation in an owned,
cancellable worker. Consent shows the exact allowlisted summary and prompt, with
online-provider disclosure. Findings are cached and mapped to known nodes;
unknown references are general findings. Fix uses the app’s `fix_prompt()` and a
registered guarded agent, never an AI answer as shell code. Simplify shares the
same consent flow. No AI call was executed during verification.

Usage on the AI side consumes `categories()` and shows recent run metadata and
token totals without exposing raw prompts, answers or error output. AI summaries
are bounded to 24,000 characters and maps to 256 nodes; oversized summaries require
a smaller map rather than silent transmission of extra data.

## 8. Verification and remaining host checks

- Python: final broader suite **1,307 tests passed** in 44.2 seconds. Five pre-existing host-only modules
  are excluded in this sandbox: `test_add_mcp_test_button`, `test_back_keys`,
  `test_herdr_state`, `test_loopback_stream`, `test_review_fixes`.
- Focused System Map/state/move tests: 22 passed; existing System Map advice tests:
  10 passed. Manual tests: 4 passed; plugin-sync tests: 5 passed.
- Pinned Pyright: zero errors, five existing PyYAML-source warnings.
- Flutter analysis: no issues. Standalone Dart transport checks passed.
- Flutter widget tests were attempted but could not start: sandbox denies binding
  the test server to `127.0.0.1`. Run the full Flutter test suite on the host.
- 60-second AI Map profile: 30 calls, one worker, **1.2% of one CPU core**.
  Cheap System refresh: **0.040 s**. Explicit search: **3.288 s**, 57 nodes and
  12 discovery records on this PC. These are machine-specific measurements;
  depth, ownership and nested-filesystem limits remain visible to users.
- Native Linux release preview built in
  `.flutter-previews/preview-alb9ebe9/flutter_app/build/linux/x64/release/bundle/asterism`.
  It has the development application identity and was not installed or launched.
- New UI text and a full manual chapter exist in all eight languages. Existing
  translation values remain unchanged. The new manual sections are fingerprinted;
  pre-existing `about`/`running-agents` fingerprint drift is not claimed resolved.
- PDF regeneration remains a host check: the sandbox’s Chromium/socket failure
  prevents the existing manual build. Existing PDFs were preserved. On the host:
  `python3 docs/manual/build.py --all --plugin-version <installed-plugin-version>`.
- Host review still needs map switching/selection, first-run Look/Skip, drag targets,
  readable consent/preview sizing and real window/terminal interaction.

No commit, live-plugin sync, push, release, service start, package installation,
credential read or fstab edit was performed.


## Follow-up review

Claude’s S1–S6 findings and their corrections are recorded in
[review-claude-2026-10-28-system-map-responses.md](review-claude-2026-10-28-system-map-responses.md).
That follow-up also clarifies default-cache versus explicit-profile storage and
the durable location of new move-Undo journals.
