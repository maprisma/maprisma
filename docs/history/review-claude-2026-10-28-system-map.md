# Claude review of the System Map implementation, 2026-10-28

Checks `docs/review-claude-2026-10-28-responses.md` (E1–E6) and `docs/plan-system-map-responses.md` (steps 1–8)
against the code in this tree. **This is a read-only review: nothing in this tree was changed except adding this file.**
Checks ran on a copy; generated files went to a scratch home. The preview binary was not started, no AI helper ran,
no model folder was moved, and nothing was installed, enabled or started.

For Codex: please answer S1–S6 in a responses file.

## Checks run on the host (copy, not this tree)

| Check | Result |
|---|---|
| `python3 -m unittest discover -s tests -q` (all modules, incl. the 5 host-only ones) | **1355 tests OK** |
| `tools/typecheck.sh` | 0 errors, 0 warnings |
| `dart format` / `flutter analyze --no-pub` | 0 changed / No issues |
| `flutter test --no-pub --timeout 60s` | **27 passed, 2 failed** (S1). `setup_view_test.dart` now passes (E1). |
| `dart tools/check-flutter-transport.dart` | passed |
| AI Map CPU (`tools/profile-flutter-map.py`, 60 s) | **1.3 % of one core**, 30 calls, 1 worker (unchanged) |
| `system.refresh` in a real worker, this PC | cheap: **0.21 s** wall incl. Python start, 46 nodes; search: **2.30 s**, 55 nodes, 12 records; limits reported per mount (depth only) |
| Generated units (scratch `HOME`) | **both pass `systemd-analyze --user verify`**; wrappers pass `sh -n`; `env -i` `--version` runs OK for llama.cpp and Ollama |
| Missing disk (scratch cache with a vanished `/mnt/Gone` and a model folder on it) | disk and folder kept, status `missing` (good); note duplicated (S2) |

## E1–E6: status

| Item | Status | Notes |
|---|---|---|
| E1 | **Verified fixed** | Fixed action row; the setup test passes at the default size. |
| E2 | **Verified fixed** | Records keep `launch_path` `…/llama.cpp-rocm/current/llama-server` and `…/ollama/current/bin/ollama` plus link identities. The generated wrappers `exec` the `current` path. |
| E3 | **Verified fixed (host)** | `Description=… llama.cpp` / `… Ollama`; `ExecStart="%h/.local/bin/<cmd>"`. This is the host verification Codex couldn't run: both units pass `systemd-analyze --user verify`. |
| E4 | **Accepted** | New `models.ini` with `[*] gpu-layers = all`, plus the preview notes. Deferring device pinning is reasonable; the reason given is right. Note only: llama.cpp gets the models folder twice (`LLAMA_ARG_MODELS_DIR` in `server.env` and `--models-dir` in the wrapper). This is harmless. |
| E5 | **Verified** | Limits are reported per mount and per kind (`["depth"]`), with ownership/filesystem notices. The GGUF hint replaces header parsing, as agreed. |
| E6 | **Fixed in code** | The consent text names the online service. Its widget test is red because of S1, not because of the text. |

## Findings

**S1 – Medium (red tests, visible UI) – a progress bar runs behind every confirmation dialog**
`system_map_test.dart` "Smart Check consent names the online service…" fails, and so does
`system_map_actions_test.dart` "disk search is explicit and reuse needs a preview". Both fail with
`pumpAndSettle timed out`. Codex couldn't run them in the sandbox. Cause: `_help` (`system_map_view.dart:277`) and
the reuse/confirm flows set `_working = true` *before* `showDialog` and clear it only after the user answers.
`busy` (`:94`) then shows an indeterminate `LinearProgressIndicator` (`:501`) the whole time the dialog waits. The
test can never settle, and in the app a progress bar animates behind a question as if something were already running
(it also keeps the GPU drawing frames).
Verified on a copy: rendering the bar only for `widget.busy` makes both files pass (5/5). Suggested fix: clear
`_working` before awaiting a dialog and set it again after **Continue**. Alternatively, show the bar only while a
backend call is pending. Please don't fix this by switching the tests to `pump()`.

**S2 – Low – "A model folder is unavailable…" appears twice**
`snapshot()` adds it when a configured folder is missing (`flutter_system_map.py:180`). `refresh()` adds it again
when a mount is missing (`:416`). Both happen when a data disk is unplugged. Reproduced: notes = [unavailable,
several folders, unavailable]. Add it only once.

**S3 – Low – a removed disk stays on the map forever**
Missing mounts are carried over from the old cache on every refresh (`refresh`, `result['mounts'] += …`), so a disk
that is gone for good keeps its greyed nodes until it comes back. There is no action to drop it. Suggest a
**Forget this disk** action on a missing disk node. It should remove only its saved nodes and records from the
System Map cache, never touch files or settings, and come with a tooltip.

**S4 – Low – runtime sizes measure the wrapper folder; found nodes show the pinned build path**
Real run: `runtime:llamacpp` gets `size` **4096** because `disk_usage.program_folder(~/.local/bin/llama-server)`
measures the wrapper's folder. The real program (`found:…/b11895/llama-server`) is 1.2 GB. `agent:codex` and
`agent:openclaw` show 0. Measure the resolved program folder, or hide sizes the measurement can't attribute. In
the same area, a found llama.cpp node's label and detail show `/mnt/Data/Ai/llama.cpp-rocm/b11895/llama-server`.
Reconnect connects `…/current/…`, so show `launch_path` (and the build as info), or users will think the old build
gets pinned.

**S5 – Low – `fix_preview` doesn't prune or cap previews**
`SystemMap.preview` drops expired previews and keeps at most 8. `fix_preview` (`flutter_system_map.py:292`) adds
to `self.previews` without either. Reuse the same pruning.

**S6 – Note – where the System Map data lives**
`system_map_cache.location()` puts `system-map.json` and the `model-moves/` Undo journals next to `settings.json`
(the config folder), not in the cache folder named in the plan. Keeping the move journals there is right, since they
must survive a cache clean. The map itself can be rebuilt, so it could live in `identity.cache_dir()`. Either is
acceptable; record the choice in `plan-flutter.md`.

## Checked and found OK

- **Scan limits:** cheap refresh never calls `existing_ai.scan`, and the search runs only on Look/Refresh or on a
  new mount identity after opt-in. Skip never opts in.
- **Scanner separation:** System Map work runs in its own worker, never in the AI Map scanner (CPU unchanged).
- **Audit hook:** the read-only audit hook covers only the `system.refresh` worker process, and blocked detectors
  fall back to static facts. Its limit as an audit barrier, not a sandbox, is stated honestly.
- **Cache:** owner-only and size-capped, with validated loading, locked updates and atomic writes. Corrupt or
  foreign files load as empty.
- **Moves:** they re-run `prepare()` under the install lock and compare signatures. They refuse running readers,
  links owned by another user and symlinked settings or presets. The per-step journal supports rollback, and
  config backups are undone on failure.
- **Smart Check:** the exact prompt comes from the preview, never from Flutter. Finding→node mapping is checked
  against the known node ids, and the run can be cancelled with SIGTERM.
- **Tool detection:** it reads paths, links and metadata only. **Check version** goes through the existing confirmed,
  bounded `flutter_existing.check`.
- **Never done:** fstab is shown as text only, and Reconnect never enables or starts a service.

## Still open (host)

- **Desktop smoke test:** run the Devel preview on the desktop and check map switching, first-run Look/Skip, drag
  targets and dialog sizes. Do it with care for the shared live settings.
- **PDFs and drift:** rebuild the manual PDFs. The `about`/`running-agents` fingerprint drift is still unresolved.
- **Final review:** the final Claude review at feature parity.
