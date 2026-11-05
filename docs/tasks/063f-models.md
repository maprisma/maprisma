# 063f A provider's models

Author: Claude · Reviewer: Codex · Branch: task/063f-models (part of task/063-codex-review)

## Goal
Fix the model findings of the Codex coverage review (`docs/reviews/063-codex-coverage.md`, round 2): #6, #7, #8,
#9 and #11. A model the map keeps for its line (missing) can be repaired but not chosen; a provider's own model
and its agents move in one Apply and one Undo; a local LLM that moved to another port is a broken line; a
reused model file is hidden only when a local LLM serves that same file.

## Routes
No params or result keys changed (`routes.json` untouched):
- `models.switch_preview`: the old model may be gone (a missing model's line moves to a model the LLM has); only
  the new one must be served. Nothing is unloaded for a gone model. When the provider's own model
  (Settings › `provider_models`) is the old one, the plan carries it (`Plan.choices`): `connections.apply`
  refuses if the choice changed since the preview, sets it once the worker wrote the files, and
  `connections.undo` puts it back with them (only if nothing changed it since). The GUI's own
  `settings.update` after the switch is gone, so Ask AI and the map behave the same.
- `models.choose_preview` refuses a model marked `missing` or not in the runtime's current inventory
  ("This model is no longer on this PC."); `models.choose_apply` checks the inventory again.
- Ask AI: `map_nodes` facts carry `status: missing` (`smartMapNodes`); the `choose` validator refuses such a
  model (`smartMapChatModel`).
- `localRuntime` falls back to the usual-port runtime only while its address is unknown or that port;
  `movedRuntime` names the one detected elsewhere. The map draws a `failed` line with `dangling` (Repair
  rewrites the endpoint), no `uses`/`default` line and no online provider. Inventory's `rt.agents` uses the same
  matcher.
- `InventoryReader.reusedFolders`: a reused file is hidden when it is in a runtime's models folder (resolved) or
  is the same file (device and inode) as one there; `qwen-Q4_K_M` and `qwen-Q8_0` both show. Folder ids
  stay `model:folder:<path>:<name lowercased>`, so two quantizations never share a node.
- Python reference in step: `flutter_map_editor.py` (#6), `inventory.py` (`local_runtime`, `moved_runtime`,
  `gguf_files`, `reused_folders`), `graph.py` (#9). The provider choice (#8) and the choose routes (#7) have no
  Python counterpart.

## UI
- Moving the provider → model line of a chosen model with agent users calls only `models.switch_preview` and
  `connections.apply`; no `settings.update`. No new texts.

## Acceptance
- `packages/maprisma_core/test/model_choice_test.dart`: #6, #7 (missing, deleted since the map, deleted before
  Apply, Ask AI), #8 (one Undo, a changed choice refuses Apply), through the real worker.
- `packages/maprisma_core/test/map_chain_test.dart`: #9, #11.
- `tests/test_flutter_map_editor.py` `test_switch_away_from_a_missing_model`; `tests/test_inventory_graph.py`
  `ReviewChainTest` #9 and #11 (the F11 case no longer hides a file by its name alone).
- `flutter_app/test/task_cards_app_test.dart`: a provider choice with agent users moves with them in the core.
