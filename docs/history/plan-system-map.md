# Plan: System Map (Flutter), 2026-10-28

For Codex. Source of the decisions: `docs/idea-system-map.md` (Uwe, 2026-10-28; all four decisions confirmed
again the same day). Link this plan from `docs/plan-flutter.md` (feature parity / product fit). Work in this tree
only, no commit, push, release or live-plugin sync unless Uwe says so. AGENTS.md rules apply (8 languages,
manual, provider facts in `provider_*.py`, no credential files, tests + typecheck before handing back).

**Before starting:** answer `docs/review-claude-2026-10-28.md` (E1–E6). E1 (red widget test) and E2 (wrapper
pins `b11895` instead of `current`) touch code this plan builds on.

## Decisions (fixed)

1. The System Map also shows non-AI tools AI depends on (Python, Node, mise, Docker/Podman, compilers): read
   only, bounded, no program run during the first-start scan.
2. Smart Check moves completely onto the System Map. There is no separate Smart Check page in Flutter. Its AI-run/token log
   (`smart_check.categories()`) goes to Usage on the AI side.
3. Reconnect writes wrapper + env file + systemd user unit (as now); never enables or starts them.
4. Flutter only. GTK Asterism is not changed for this (it may keep its own Smart Check page until it is retired).

## Today (facts)

- PC overview: `flutter_pc.py` `snapshot()` (columns hardware 0 / disks 1 / runtimes+agents 2 / folders 3,
  notes, helpers, ≤256 nodes), service methods `pc.snapshot`, `pc.help_preview`, `pc.help_apply`
  (`flutter_backend.py:158-170`); UI `pc_overview_dialog.dart` (a dialog, not a page).
- Existing installs: `existing_ai.py` (mounts, bounded scan, validate), `flutter_existing.py` (handles, plans,
  check), service methods `existing.mounts/scan/preview/check/apply` (`flutter_backend.py:172-196`), UI
  `existing_ai_dialog.dart`.
- Smart Check exists only in GTK: `smart_check.py` (snapshot → agent analysis → validated findings cached in
  `~/.cache/ai-agents-map/smart-check.json`, `fix_prompt()`, `categories()`), `smart_check_page.py`.
- PC facts: `health.pc_info()`, `health.check()` (areas "This PC", local LLMs …), `gpu_stack.look()`,
  `disk_usage.py` (bounded size measurement), `model_folders.py` (move plans with preview/backup/Undo).
- Navigation: `main.dart` uses `_showMap/_showSettings/_showAddons/_showSetup/_showGuide/_showProviders/
  _showConnections` booleans; the AI Map is `agent_map.dart` fed by `map.snapshot` (persistent scanner,
  1.3 % idle, `tools/profile-flutter-map.py`).

## Steps

Each step ends with tests green, typecheck 0, Flutter analyze clean, and a short note in `plan-flutter.md`.

### 1. Name and page (UI shell)

- Rename "PC overview" → **System Map** in code and texts: `flutter_pc.py` → `flutter_system_map.py`,
  `pc_overview_dialog.dart` → `system_map_view.dart`, methods `pc.*` → `system.*` (keep no aliases; there
  are no external clients).
- Main navigation: a map switcher **AI Map | System Map** (segmented control in the header, same place for
  both). The System Map is a page, not a dialog; selection and pan/zoom are kept per map while switching.
- Replace the `_show*` booleans touched here with one page enum if that is a small change; otherwise add
  `_showSystemMap` and keep the existing pattern (don't refactor all navigation in this step).
- Texts in 8 languages (`tools/flutter-assets.py`): System Map / Systemkarte / Mapa del sistema / Carte du
  système / Mappa del sistema / Systeemkaart / Mapa systemu / Mapa do sistema.

### 2. Saved map + cheap refresh (service)

- `flutter_system_map.py`: `snapshot()` returns versioned data `{version, checked_at, nodes, edges, notes,
  limited}`. Save it to the cache dir (`identity` paths, private 0600, atomic replace, size cap), load it on
  start so the page opens instantly with "Last checked …".
- Split facts into **cheap** (hardware/GPU, mounts present/missing, services running, free/total space,
  configured folders present) and **search** (disk discovery, sizes, tool versions). On start and on each page
  visit only the cheap part refreshes, in the existing worker (`flutter_tasks`), never in the AI Map's
  2-second scanner. Search runs on Refresh, at first start, or when a new mount identity appears.
- A missing mount keeps its nodes, greyed, with "Check the mount before downloading again"; nothing is dropped
  because a disk is absent.
- Tests: saved map loads without any scan; cheap refresh doesn't call `existing_ai.scan`; missing mount;
  cache corruption → rebuild; size cap. Profile: `tools/profile-flutter-map.py` must stay ≈1 %.

### 3. First start

- In the welcome flow (`setup_view.dart`, `flutter_setup.py`): a short text (only this PC, read only, nothing
  sent, nothing run) and **Look at this PC / Skip**. "Look" builds the System Map with progress (cheap part
  first, then one discovery per mounted data disk within `existing_ai` limits).
- Then show the System Map with a "What we found" summary; the existing adapter switch-on choices stay and
  refer to map nodes. Skip → the System Map page offers the same button later.
- Fix E1 at the same time: keep Switch on / Later in a fixed bottom action row, so long welcome text can't push
  them out of view.
- Tests: first start with Skip; first start with fake mounts (discovery nodes appear, nothing executed:
  assert no `subprocess` call); repeat start does not rescan.

### 4. Non-AI tools (decision 1)

- New read-only detectors for Python (+ venv/uv), Node, mise, Docker/Podman, git, compilers (gcc/clang),
  CMake. Use `PATH` lookup, symlink targets, version files and package metadata only (as `agents.detect`
  does). No `--version` runs in the scan. An explicit per-node **Check version** may run `--version`, using
  the `flutter_existing.check` pattern (clean env, temp home, 5 s, group kill, confirmed).
- Keep tool facts in one small module (`system_tools.py`), not in the core graph; each tool is data
  (name, commands, version-file paths), so adding one is a table row.
- Nodes: a "Tools" column; edges from tools to the runtimes/agents that need them only where that is a known
  fact (e.g. an agent installed with mise → mise).
- Tests: fake `PATH`/files; no process started.

### 5. Existing installs on the map (from `existing_ai_dialog.dart`)

- Discovery results become **found, not connected** nodes (dimmed) under their disk.
- Node actions: **Check program** (existing confirmed check), **Reconnect** (existing preview → apply, decision
  3: wrapper + env + unit, not enabled/started), **Use model folder**.
- Map-first: dragging a found runtime onto a found model folder (or store) opens the same Reconnect preview;
  dragging a model folder onto the AI Map's runtime adds it (`model_folders`). Tooltip on drag targets; Undo via
  the existing connection backup.
- Apply E2–E4 here: wrapper follows `current`, unit description names the provider, `%h` paths, optional
  `--device`/`models.ini` defaults in the preview.
- Remove `existing_ai_dialog.dart` once the map covers all its actions (inventory first).

### 6. Health, GPU stack, disk use, model folders on nodes

- `health.check()` findings that concern the system (This PC, local LLM fit/VRAM, free space, missing folders)
  become badges on the matching nodes (hardware, GPU, disk, folder); finding text + action as today.
- GPU node shows `gpu_stack.look()` (ROCm/CUDA/Vulkan, torch places) and the existing install ways for missing
  parts.
- Disk/folder/runtime nodes show sizes from `disk_usage` (search part only, bounded by its deadline).
- Model folders: drag a folder onto another disk = existing `model_folders.plan` move with preview/backup/Undo.
- Agent-related health findings stay with the AI Map / agent details.

### 7. Smart Check on the System Map (decision 2)

- Port `smart_check.analyze()` to a service task (worker; agent chosen like today via `ai_helper`): action
  **Check this system with AI** on the System Map. The snapshot sent is the System Map + health summary
  (names, versions, counts, findings; never keys, settings values, env, headers; never credential files),
  shown in full before sending, with the consent text from E6 ("… and, for an online model, its service").
- Validated findings (`validate()`) are cached as today and shown as badges on the node they reference
  (add a node id to each finding; unknown references go to a general list on the page).
- **Fix it with …** opens an agent terminal tab with `fix_prompt()` (Asterism's own prompt, guarded agent),
  as in GTK.
- The current "AI help: understand/simplify" (`pc.help_*`) merges into this action group (two topics:
  check / simplify), one consent dialog.
- `categories()` (AI runs and tokens per plugin) moves to a Usage section on the AI side.
- Tests: snapshot contains no secret-shaped values; finding → node mapping; cached result shown on restart;
  fix prompt never contains the model's answer text as a command.

### 8. Manual, cleanup, review

- Manual chapter "System Map" in all 8 languages (first start, cheap vs. full refresh, found installs and
  Reconnect, tools, Smart Check, what is never done: fstab, service start, credential files). Rebuild the PDFs
  on the host.
- Remove the replaced dialogs; update `plan-flutter.md`'s coverage table (Setup, Usage/security/health,
  Smart Check rows).
- Hand back with: Python suite, typecheck, `flutter analyze`, `flutter test --timeout 60s`, the map profile
  (AI Map ≈1 %, and the System Map's cheap refresh time), and a responses file. Claude reviews next.

## Not in this plan

GTK changes; enabling/starting services automatically; editing `/etc/fstab`; network scans or other machines;
package installs outside the existing install flows; any publication.
