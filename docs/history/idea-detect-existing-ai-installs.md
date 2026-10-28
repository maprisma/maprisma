# Idea: find local LLMs already installed on another partition (2026-10-27)

Uwe's question to Claude: *"This PC already has AI tools like llama.cpp installed on their own partition
(`/mnt/Data`). If I install a Linux distro on another partition with this mount existing, would the installer,
or later Asterism's AI help, detect it?"*

**Short answer: no, neither would find it on its own.** This file records the facts (checked in the code and on
this PC) and a proposed feature. Uwe **approved implementation on 2026-10-27**. The first Flutter implementation is recorded in
`docs/plan-flutter.md`, under “Reuse AI installations on a separate mount”; the proposal below
retains the original scope and open questions for context.
If it is taken up, add it to `docs/plan-flutter.md` (feature parity / product fit) rather than to the GTK app only.

## Facts on this PC

The **large parts** are on the shared data partition (`/mnt/Data`, ext4, `nofail` in `/etc/fstab`; CachyOS
mounts it too):

| Path | What |
|---|---|
| `/mnt/Data/Ai/llama.cpp-rocm/<build>/`, `current` → build | llama.cpp program (`llama-server`) |
| `/mnt/Data/Ai/rocm-runtime/root/…` | ROCm runtime the build needs (`LD_LIBRARY_PATH`) |
| `/mnt/Data/Ai/ollama` | Ollama |
| `/mnt/Data/Ai/Models/llama.cpp-router`, `/mnt/Data/Models` | GGUF models / router folder |

The **small connecting files** are in the home folder on the Omarchy partition, so a new distro does not have them:

| Path | What |
|---|---|
| `~/.local/bin/llama-server` | Bash wrapper: sets `ROCM_PATH`, `HIP_PATH`, `LD_LIBRARY_PATH`, `ROCBLAS_TENSILE_LIBPATH`, then `exec /mnt/Data/Ai/llama.cpp-rocm/current/llama-server` (default args: `--models-dir`, `--models-preset ~/.config/llama.cpp/models.ini`, `--models-max 1`, `--device ROCm0`) |
| `~/.local/bin/llama-models-sync` | `ExecStartPre` of the unit |
| `~/.config/systemd/user/llama-server.service` | `RequiresMountsFor=/mnt/Data`, `EnvironmentFile=~/.config/llama.cpp/server.env` |
| `~/.config/systemd/user/ollama.service` | Ollama service |
| `~/.config/llama.cpp/models.ini`, `server.env` | router presets and environment |

## What the installer does

At most it mounts `/mnt/Data`, if the user assigns a mount point in manual partitioning and leaves "format" off.
Formatting would erase it. Otherwise the user adds an `/etc/fstab` line by hand. No installer knows about AI tools.

## What Asterism detects today (code)

`inventory.llamacpp()` (`inventory.py:231-267`) treats llama.cpp as installed / finds its models only from:
- `shutil.which("llama-server")`;
- `unit_for("llama-server")`, a systemd user unit;
- a running `llama-server` process (argv/env: `--models-dir`, `LLAMA_ARG_MODELS_DIR`, …);
- `llama_presets()` (`~/.config/llama.cpp/models.ini`) and `~/.cache/llama.cpp`.

`inventory.ollama()` (`inventory.py:313`) does the same with `which("ollama")`, `unit_for("ollama")` and its
process. `model_folders.discover()` (`model_folders.py:87-120`) only looks at runtime `models_dir`s and the
hand-added `model_folders` setting (Setup › Models › Add folder). Nothing reads `/proc/mounts` or searches other
disks. The only `/mnt` mentions are examples in docstrings (`install_ctl.py:1582,1591`, `disk_usage.py:85`).

So on a fresh distro: llama.cpp and Ollama show as **not installed**, and the models are not listed. Adding the
models folder by hand makes the models visible, but llama.cpp itself is still missing.

## What works by hand today

1. Mount `/mnt/Data` at the **same path** (every script uses absolute paths).
2. Copy the connecting files above into the new home, then `systemctl --user daemon-reload` and enable/start the
   services wanted.
3. Asterism then detects everything as today.

Caveat: the ROCm runtime and llama.cpp build on `/mnt/Data` were built against this system's libraries. A distro
with an older glibc or other GPU drivers may not run them; detection should check that, not assume it.

## Proposed feature: "Found on another disk"

Goal: on a new system (first-agent guide, Setup › Models / Providers, or an AI-help run), Asterism finds local LLM
installs on mounted data disks and offers to connect them, with a preview and Undo.

**Find (read only, bounded):**
- Mounted local filesystems from `/proc/self/mountinfo`, excluding system paths (`/`, `/boot*`, `/proc`, `/sys`,
  `/dev`, `/run`, `/tmp`, network and FUSE mounts), plus their top two or three levels only. Time and entry limits,
  as `_ggufs` already has a depth limit; never follow links out of the mount; skip folders not owned by the user.
- Per provider, the *provider module* declares what an install looks like (the core names no LLM, per AGENTS.md).
  For example llama.cpp: an executable `llama-server` at `<x>/llama.cpp*/current/` or `<x>/llama.cpp*/<build>/`;
  Ollama: an executable `ollama` plus `models/manifests*`; GGUF: folders with `.gguf` files (existing `_ggufs`).
- Check that a found program can actually run: `ldd`-style missing-library check or a `--version` run with a
  short timeout and no network, in a worker. A ROCm build also needs its runtime folder found next to it.

**Offer (never automatic):**
- Show what was found, with paths and the reason ("llama.cpp b11895 for ROCm, 23 models").
- On confirmation, write the connecting files: a `~/.local/bin` wrapper (environment from the found runtime), the
  user unit with `RequiresMountsFor=<mount>`, and `models.ini`/`server.env` only if missing. Use the existing
  change/backup/Undo path (`connect.Change`, as `model_folders.plan`/`fix` and MCP connections do), never
  overwrite existing files silently, and don't start services without asking.
- Models only: add the folder to `model_folders` (exists already).
- Suggest an `/etc/fstab` line if the partition is not mounted permanently, as text to copy. Asterism must not
  edit `/etc/fstab` itself.

**Constraints from AGENTS.md / Uwe's rules:**
- Provider facts in `provider_*.py`/adapters, not in the core.
- Scanning runs in a worker (Flutter: `flutter_tasks`), with progress, and doesn't slow the map (see N1).
- New UI texts in all 8 languages; a manual chapter in all 8 languages, with PDFs, before it ships.
- Map-first: a found install could appear on the map as a dimmed "found, not connected" node that the user can
  connect by dragging (Uwe's "map configures everything" goal), with a tooltip and Undo.
- Tests: fake mount table plus temporary trees (llama.cpp build with `current` link, Ollama store, GGUF folders,
  a link out of the mount, an unreadable folder, a too-deep tree), and a wrapper/unit preview with no writes
  before confirmation.

## Decisions and implemented scope (2026-10-28)

- **Entry points:** Uwe explicitly requested separate-mount guidance on first-use
  Welcome, Help and Smart Check, and a second PC overview map. Discovery also
  remains reachable from Providers/models and the first-agent guide. Broad disk
  scans are explicit; ordinary overview construction checks known paths only.
- **Units versus wrappers:** the approved proposal included previewed user units
  and wrappers, and implementation creates both on Apply. This is an implementation
  choice within the approved feature, rather than a separately worded answer to
  the earlier question. Units are neither enabled nor started automatically.
- **Frontend:** Flutter, following Uwe's final-target decision in AGENTS.md. These
  new flows are not also being built in the GTK application being replaced.
- **Simplification help:** Uwe requested hints about reducing duplication and
  complexity and AI help where available. The PC map, Help and focused Smart Check
  now offer this, with a reviewed prompt and the existing agent approval guard.

Map drag-to-adopt, copying old router presets, automatic background hints and
additional providers' discovery rules remain follow-up proposals, not completed
features. See the active Flutter plan and Claude review responses for validation
and the GPU-selection limitation.

## Uwe's answer to question 1 (2026-10-28)

Start at the **app's first start**, as part of a permanent **System Map** page next to the AI Map; see
`docs/idea-system-map.md`. Questions 2 and 3 are answered there too: Reconnect **creates the systemd user
services** (never enables/starts them), and the feature is **Flutter only**.
