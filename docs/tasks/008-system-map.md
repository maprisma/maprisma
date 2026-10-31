# 008 System Map cards, column filters, fewer header symbols

Author: Antigravity, fixes by Claude · Reviewer: Antigravity for Claude's fixes, Claude for Antigravity's work · Branch: task/008-system-map

## Goal
Uwe, 2026-10-31: the System Map works like the AI Map, and the header keeps only what is needed every day.

## Routes
None. Ask AI on the System Map uses the AI Map's `map.smart_*` routes.

## UI
- This PC: the hardware on two cards, CPU & RAM and GPU. The GUI summarises; the core's nodes stay as they are.
- Ask AI on each column: This PC asks Providers, Disks and home and Folders ask Models, Programs asks Agents, Tools
  asks MCP. Move to names this map's columns and opens a hidden one.
- Filter chips for the five columns. Small shows This PC, Disks and home, Folders; medium adds Programs; max shows all.
- Header: refresh, open problems, Help and Settings stay. Your first agent, Agents, Providers and models, Connections
  and Usage are tabs on Help. AI Map leads back from every page: no segment is selected while a page or the list shows.
- Manual: Help, and the new section `system-map-cards`, in all 8 languages, PDFs built.

## Acceptance
- `flutter_app/test/system_map_test.dart`: cards, 3/4/5 columns, filters, Move to a hidden column without a second ask.
- `flutter_app/test/help_view_test.dart`: the tabs and Usage.
- `flutter_app/test/task_cards_app_test.dart`: pages from Help, AI Map leads back from the agent list.

## Open
- System Map filters last until the app closes. Keeping them needs a new setting in the Dart and Python cores.
- Translated manuals: `my-setup`, `system-map-start` and `troubleshooting` are flagged by `translations.py check` from
  before task 007; not looked at here.

## Review
Claude read Antigravity's first version and fixed what it found (36e0059). Antigravity reviewed the whole task at
14e756a, round 1 CLEAN: `docs/reviews/008-system-map.md`.
