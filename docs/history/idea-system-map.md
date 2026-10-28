# Idea: a permanent System Map next to the AI Map (Uwe, 2026-10-28)

Uwe's words (translated): *"On the app's first start I don't know what is already installed on a PC. Then the
technical map should be created and be permanent like the current map, as its own page: one AI Map and one System Map.
The Setup or AI Smart Check features that make sense can be transferred to the new map."*

Status: **Implemented in the Flutter development preview; host interaction review pending.**
See `docs/plan-system-map.md` and `docs/plan-system-map-responses.md`. It also answers question 1 in
`docs/idea-detect-existing-ai-installs.md` ("where should it start?"): at the first start, as part of the System Map.
Add it to `docs/plan-flutter.md`. Nothing outward-facing without Uwe.

## Goal

The app has two equal map pages:

| Page | Shows | Exists today |
|---|---|---|
| **AI Map** | agents → providers/local LLMs → models, MCP servers, skills, subagents, activity | yes (`graph.py`, `agent_map.dart`) |
| **System Map** | the PC under the AI: hardware/GPU, GPU stack, disks and mounts, runtimes, AI installations (also on other disks), model folders and stores, services, free space | only as a one-off dialog (`flutter_pc.py`, `pc_overview_dialog.dart`) |

Both are permanent pages in the main navigation (map switcher, like the existing map/list switch), remember their
layout and selection, and link to each other: a runtime or model folder on the System Map is the same thing as the
provider/model node on the AI Map (click → "Show on AI Map", and back).

## First start

The user often doesn't know what is installed. So the first start builds the System Map before asking anything:

1. Welcome explains in two sentences what will be looked at (only this PC, read only, nothing sent anywhere,
   nothing executed) and starts the scan in a worker with visible progress. The user can skip it.
2. The fast part runs at once: hardware, GPU and GPU stack (`health.pc_info`, `gpu_stack.look`), mounts
   (`existing_ai.mounts`), agents/runtimes on `PATH` and as user services (`inventory`), configured model folders.
3. The disk part (`existing_ai.scan`) runs per mounted data disk, within its existing limits, and adds what it
   finds as **"found, not connected"** nodes (dimmed, as in the AI Map's style for unused things).
4. The result is a first System Map plus a short "What we found" list. The existing welcome choices (switch on the
   adapters that were found, Later) stay, and they now point at map nodes instead of being a separate list.

No program is run during this scan: the "Check program" (`--version`) step stays a separate, confirmed action.

## Permanent, but cheap

- The System Map is **saved** (cache file with a timestamp, like `smart-check.json`), so it opens instantly on
  every start and shows "last checked …".
- On every start, only the cheap facts refresh (hardware, mounts present/missing, services running, free space).
  The disk search runs again only on request (Refresh on the System Map), or when a new mount appears. Never on the
  2-second AI Map cadence: the AI Map's 1.3 % idle CPU must stay (`tools/profile-flutter-map.py`).
- A missing mount is shown as a missing disk with its folders greyed out, plus the hint "check the mount before
  downloading again". Nothing is removed from the map because a disk is unplugged.

## What moves to the System Map

Move what is about the PC; keep what is about agents on the AI Map / agent pages. Inventory every GTK action
before removing it (plan rule).

| Today | Where | On the System Map |
|---|---|---|
| PC overview dialog | `flutter_pc.py`, `pc_overview_dialog.dart` | becomes the System Map itself; the dialog goes |
| Find existing AI on mounted disks + Reconnect + Check program | `existing_ai.py`, `flutter_existing.py`, `existing_ai_dialog.dart` | "found, not connected" nodes; Reconnect/Check as node actions; connecting = drag the found runtime onto its model folder (map-first rule) with the existing preview/backup/Undo |
| Health check "This PC" area and local-LLM findings (VRAM fit, free space, missing folders) | `health.py` | badges/hints on the hardware, disk and folder nodes |
| GPU stack (ROCm/CUDA/Vulkan, torch places) and its install offers | `gpu_stack.py` | GPU node with its stack; missing parts as hints with the existing install ways |
| Disk usage of agents/runtimes/models | `disk_usage.py` | size per folder/runtime node; free/total per disk |
| Model folders: add, move, reorganize, duplicates | `model_folders.py`, models page | folder nodes; drag a folder onto a disk = the existing move plan with preview |
| Smart Check (AI analysis of this PC) | `smart_check.py` | a "Check this PC with AI" action on the System Map: findings appear as badges on the nodes they are about; "Fix it with …" stays an agent tab with Asterism's own prompt |
| AI help: understand/simplify the PC | `flutter_pc.py` `preview/apply` | same action group as Smart Check; keep the shown prompt and consent |
| Setup › Models/Providers parts about storage and runtimes | `setup_page.py` | links/actions from the System Map; agent-specific setup stays on the AI side |

Smart Check's task log (`categories()`, AI runs and tokens per plugin) is about AI usage, not the PC: it stays
with the AI side (or Usage).

## Rules to keep

- Read only by default; every change has a preview, backup and Undo, as now. No service enable/start, no
  `/etc/fstab` edits (show a line to copy instead), no package installs without the existing install flows.
- Facts about a provider stay in `provider_*.py`; the core names no agent or LLM (AGENTS.md).
- Never read credential files; existence checks only.
- Map-first (Uwe's goal): what can be connected is connectable by drawing/dragging on the map, with tooltips
  and Undo.
- 8 languages for every text; a manual chapter (8 languages + PDFs) before it ships.
- Tests: fake mounts/homes as in `test_existing_ai.py`; a saved System Map that loads without a scan; a missing
  mount; the first-start flow with Skip; no scan on the AI Map cadence (profile stays ~1 %).

## Name

Uwe asked for a better name than "PC Map" (2026-10-28). **System Map** was chosen: it pairs with "AI Map",
covers hardware *and* software (drivers, runtimes, tools), and translates cleanly (de Systemkarte, es Mapa del
sistema, fr Carte du système, it Mappa del sistema, nl Systeemkaart, pl Mapa systemu, pt Mapa do sistema).
Use it in code (`system_map`), UI and manual. Rename the existing "PC overview" strings and files when they
become the System Map.

## Uwe's decisions (2026-10-28)

1. **Non-AI tools too:** the System Map also shows what AI depends on, e.g. Python, Node, mise, Docker/Podman,
   compilers and their versions, as long as detection is read only and bounded (`PATH`, version files, user
   services; no package-manager database dumps, no running `--version` during the first-start scan).
2. **Smart Check moves completely** to the System Map ("Check this system with AI", findings as node badges,
   "Fix it with …" as now). The separate Smart Check page goes. Its AI-run/token log (`categories()`) moves to
   the AI side (Usage), since it is about AI use, not the system.
3. **Reconnect creates the systemd user services** as well as the `~/.local/bin` wrapper and env file (as
   implemented). It still never enables or starts them; that stays a separate, confirmed action.
4. **Flutter only.** GTK Asterism gets none of this; it is being replaced.
