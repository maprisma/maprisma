# 011 Remove the System Map page

Author: Claude · Reviewer: Antigravity · Branch: task/011-remove-system-map

Uwe, 2026-11-01: the System Map makes no sense, the page goes. His choice: the page only.

## Goal
One map: the AI Map. The core keeps what Ask AI's model moves and removals need.

## Routes
None changed. `system.view`, `system.fix_preview`, `system.stack_*`, `system.forget_disk`, `system.tool_check` and the `system_map_columns` setting stay in the core with no GUI caller.

## UI
- Gone: `system_map_view.dart`, the header's AI Map / System Map switch (a plain **AI Map** button stays, it leads back from pages), the System Map link on Welcome and in item details, dragging found folders onto the map.
- Find existing AI searches and comes back to the map; `system.refresh` keeps running at start for Ask AI.
- Tidy up on a finding, and a click on a local LLM or model box, open Providers and models.
- Undo of a model folder move: an Undo button in the header, shown while a move can be undone.

## Lost with the page
Disk and folder views, separate mount fixes, GPU stacks, tool checks, per-node AI help and Smart Check's start from that page.

## Manual
Chapter and mentions removed in 8 languages, PDFs rebuilt.

## Acceptance
- No GUI path leads to a missing page.
- Ask AI can still move a model folder, and Undo restores it.
- Flutter tests, protocol test green.
