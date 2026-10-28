# Claude review of the new Flutter work, 2026-10-28 ~00:30

Covers what was added after `docs/review-claude-2026-10-27-recheck-3.md`: finding existing AI on mounted disks
(`existing_ai.py`, `flutter_existing.py`, `provider_llamacpp.py`/`provider_ollama.py` rules,
`existing_ai_dialog.dart`), the PC overview and AI help (`flutter_pc.py`, `pc_overview_dialog.dart`), and the
welcome guidance. `flutter_first_agent.py`, `flutter_installers.py`, `flutter_agent_actions.py` and their views
were only run through the tests, not read closely.
**This is a read-only review: nothing in this tree was changed except adding this file.** Checks ran on a copy;
generated files went to a scratch home. Nothing was installed, enabled or started.

For Codex: please answer E1–E6 in a responses file.

## Checks run on the host (copy, not this tree)

| Check | Result |
|---|---|
| `python3 -m unittest discover -s tests -q` (all modules, incl. the 5 host-only ones) | **1326 tests OK** |
| `tools/typecheck.sh` | 0 errors, 0 warnings |
| `dart format` / `flutter analyze --no-pub` | 0 changed / No issues |
| `flutter test --no-pub --timeout 60s` | **27 passed, 1 failed**: `setup_view_test.dart` "pending detection prevents applying incomplete recommendations" (E1) |
| `dart tools/check-flutter-transport.dart` | passed |
| Map CPU (`tools/profile-flutter-map.py`, 60 s) | **1.3 % of one core**, 30 calls, 1 worker (unchanged: discovery is never part of the map scan) |

## Real-disk test of the separate-mount feature (Uwe's scenario)

Run on this PC, read only: `existing_ai.scan()`, then `build_plan()` with `HOME` set to a scratch folder.

- `mounts()` → `/home`, `/mnt/Data`, `/mnt/Games` (system mounts excluded, as intended).
- `scan('/mnt/Data')`: 0.1 s, 9252 entries. It found llama.cpp `/mnt/Data/Ai/llama.cpp-rocm/b11895/llama-server`
  with the ROCm runtime, Ollama `/mnt/Data/Ai/ollama/v0.40.11/bin/ollama`, the Ollama store `/mnt/Data/Models/ollama`,
  and 9 GGUF folders. `scan('/mnt/Data/Ai')` found the same (the models are reached through the `Models` link).
- The generated wrappers pass `sh -n`. **Both units pass `systemd-analyze --user verify`.** Run with
  `env -i PATH=/usr/bin:/bin HOME=<scratch>`, the generated `llama-server --version` → `build 11895`, exit 0; the
  generated `ollama --version` → `0.40.11`, exit 0. So the ROCm environment taken from the disk is complete enough
  to start the program.
- Quoting: values are `shlex.quote`d in the wrapper; quotes, backslashes and newlines in paths are refused; unit
  values are quoted with `%`/`$` escaped. Nothing is overwritten (`lexists` → refuse), and there are no symlinked
  parents. A worker re-checks under the install lock. A program runs only after a separate **Check program**
  confirmation (`--version`, 5 s, clean env, temp home, group kill). Good.

## Findings

**E1 – Medium (red test) – `flutter_app/test/setup_view_test.dart:88-122` fails**
`find.widgetWithText(FilledButton, 'Switch on')` finds nothing: the new separate-mount/simplification guidance in
the welcome `ListView` (`setup_view.dart:81`) pushes the button below the 800×600 test surface, and `ListView`
doesn't build children outside the viewport. Verified on a copy: with `tester.binding.setSurfaceSize(Size(1000, 2400))`
the file passes (2/2). Fix the test (`scrollUntilVisible`/`ensureVisible`, or a surface size). Also consider the UI:
on a short window the page's main actions (Switch on / Later) now sit below a long text. A fixed action row at the
bottom would keep them visible.

**E2 – Medium – the wrapper pins the build instead of following `current`**
`existing_ai.safe()` resolves links, so the record path is `/mnt/Data/Ai/llama.cpp-rocm/b11895/llama-server` although
it was found through `current/` (`provider_llamacpp.py` `_discover_existing`). The generated wrapper `exec`s
`…/b11895/…`. When the user (or Asterism's own llama.cpp installer) adds a newer build and moves `current`, the
connected service keeps running the old build, and deleting the old build breaks it. Uwe's own wrapper uses
`…/current/llama-server`. Fix: when the program was found through a `current` link, keep the link path in the
wrapper (validate that the link and its target stay on the mount, and track both in `stamps`). The same applies
to Ollama if a version folder is reached through a link.

**E3 – Low – generated units are anonymous and mix `%h` with absolute paths**
Both units say `Description=Asterism connected local AI`, so `systemctl --user status` can't tell them apart. Use
the provider name (`… llama.cpp`, `… Ollama`). `ExecStart` is an absolute home path while `EnvironmentFile` uses
`%h`; use `%h/.local/bin/<command>` for both, so a restored home on another machine/user still works.
(`unit_arg` would then need to keep the `%h` specifier unescaped.)

**E4 – Low – the generated llama.cpp setup loses GPU selection and tuning**
The wrapper passes `--models-dir … --host 127.0.0.1 --port 8080 --models-max 1` only. Uwe's working wrapper also
pins the GPU (`HIP_VISIBLE_DEVICES=0`, `--device ROCm0`) and uses `--models-preset` (gpu-layers all, context per
model). Not copying old presets is right (they can point into the old home), but with an iGPU + dGPU the router
may pick the wrong device. Suggest: when exactly one ROCm/CUDA dGPU is detected (the GPU-stack code already
knows), offer `--device` in the preview, and create an empty `models.ini` with `[*] gpu-layers = all` that the
existing Performance/context controls then manage. Mention in the preview that tuning starts from defaults.

**E5 – Low – discovery details**
- TTS GGUFs (`Qwen3-TTS-0.6B/1.7B`) are offered as LLM model folders. If a name/metadata check is cheap
  (`general.architecture` in the GGUF header), mark or skip non-LLM architectures, or at least show a hint.
- `scan('/mnt/Data')` reports `limited: true` after 0.1 s and 9252 < 12000 entries, only because some folders are
  deeper than 5. Everything relevant was found, but the UI will say limits were reached. Say which limit
  ("some folders deeper than 5 levels were skipped"), so users don't assume models are missing.
- Ownership: anything whose uid differs from the current user is skipped silently. On a new distro the first user
  is usually 1000 again, but not always (and vfat/exfat/ntfs3 ownership comes from mount options). If the mount has
  candidate names (`llama-server`, `ollama`, `*.gguf`) owned by another uid, report "found but owned by another
  user" instead of nothing.
- btrfs: the `st_dev != device` check skips nested subvolumes, which have their own `st_dev`. That's fine for ext4
  `/mnt/Data`; note it for btrfs data disks.

**E6 – Low – AI-help consent wording**
`pc_overview_dialog.dart`: "The selected AI agent receives this PC overview, including folder paths." When the
agent uses an online model, that data leaves the PC. Add "… and, for an online model, its service". The full
prompt is already shown and must be confirmed. Good.

## Checked and found OK

Mountinfo parsing incl. octal escapes; exclusion of system/network/FUSE mounts; mounted subtrees not traversed;
links leaving the mount ignored; ELF check before anything is called a program; bounded depth/entries/time/
results/response size; opaque 10-minute handles; private plan FD; re-validation of mount identity and file stamps
before writing; settings backup/Undo through `connect.apply`; no service enable/start; `/etc/fstab` never edited;
AI help: guarded agent (`agent_guard.task`), untrusted-data framing, no credential files, prompt shown in full.
Provider facts live in `provider_*.py` (AGENTS.md rule kept).

## Open from before (unchanged)

Manual PDF rebuild; GTK + Devel desktop smoke test; final review at feature parity. Uwe's three open questions in
`docs/idea-detect-existing-ai-installs.md` are not answered in that file. The plan says Uwe approved and expanded
the scenario. Please record his answers (start point, units vs. wrapper only, GTK or Flutter only) in the idea
file, so later reviews can check the feature against them.
