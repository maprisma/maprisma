# 063i A provider's models, round 3

Author: Claude · Reviewer: Codex · Branch: task/063i-models (part of task/063-codex-review)

## Goal
Fix the model findings of the Codex coverage review (`docs/reviews/063-codex-coverage.md`, round 3): #2, #3,
#6, #7, #8 and #9. A provider's own model that cannot follow its agents' files is said, and the Undo is there
all the same; Undo puts it back only with those files; every local provider whose LLM moved is one broken
line and nothing more; the map offers Repair only where it can work; a reused file a runtime serves by its
own path is not shown twice.

## Routes
`routes.json`: `tasks.status` and `connections.undo` get `choice_failures` (int), both now `manual` with a
note; `map.snapshot`'s note says what a failed agent → runtime line without a recorded failure is.
- `connections.apply` (its task result): `choice_failures` counts the provider choices (`Plan.choices`) not
  changed after the worker wrote the files: changed meanwhile, or the settings could not be saved (any
  exception of `chooseModel`, not only `FormatException`). The Undo handle is registered and returned in
  both cases (before, a save error failed the task without it).
- `connections.undo`: `ConfigFiles.undo(folder, skipped:)` lists what it could not put back. The choice goes
  back only when every file of the backup came back; otherwise it stays with the agent files that kept the
  new model. `choice_failures` counts the choices not put back. Nothing restored keeps the handle and its
  choices, as before for the files.
- `map.snapshot`: a running instance whose provider is a moved local one (or the dangling one) is skipped:
  only the failed runtime line, no online provider or model (#6). Every provider in `stale` gets a failed
  line; the inactive one has `dangling: ""`, no default, and the hint "This local LLM now listens on another
  port. Repair or remove this connection." (#7). An agent without `[local_llm]` (Claude Code, Codex) gets
  `fixed`: "its address is set in its own settings: change it there to {0}" (the address the LLM listens
  on) and no hints, so the map shows that reason instead of a Repair card, and the line has no hook (#8).
- `connections.repair_preview`: a failed runtime line with no recorded failure is the map's own moved line
  (before: only one with `dangling`); with no model it rewrites the address only (`use_now: false`). One
  with `fixed` is refused with that reason.
- Inventory: `RuntimeRecord.modelFiles` (not in `toJson`): the absolute model files a runtime serves outside
  its models folder: llama.cpp `-m`, `LLAMA_ARG_MODEL`, `models.ini` `model =` paths and its cache;
  KoboldCpp `--model` and each `.kcpps`'s `model_param`/`model`; vLLM's served file. `reusedFolders` compares
  them by device and inode with the folder's files (#9).
- Python reference in step: `graph.py`, `flutter_map_payload.py`, `flutter_map_editor.py` (#6–#8),
  `inventory.py` (`Runtime.model_files`, `absolute_files`, `preset_files`, the three scanners,
  `reused_folders`) (#9); `flutter_plan_wire.encode` keeps `model_files` off the wire (as `toJson`). The
  provider choice (#2, #3) has no Python counterpart; `flutter_connections` answers `choice_failures: 0` so
  the worker parity tests see the same results.

## UI
- An apply with `choice_failures` says "Applied, but the local LLM's own model stayed as it was: it changed
  meanwhile or could not be saved." in place of "Succeeded" (its message with Undo, the result card, Ask
  AI); after the slots window of a model switch it is said again with that apply's Undo.
- Undo with `choice_failures` adds "The local LLM's own model was not put back: a file or the model changed
  since." under "Restored files: N".
- Three new texts in eight languages; the core's `fixed` text in the translations too.

## Acceptance
- `packages/maprisma_core/test/model_choice_test.dart` group "review 063 round 3": #2 (choice changed while
  the worker ran; settings that cannot be saved), #3 (an agent file changed since), #7 (Repair of an inactive
  moved provider rewrites the address, not the default), #8 (Claude Code: `fixed`, no hints, Repair refused),
  through the real worker.
- `packages/maprisma_core/test/map_chain_test.dart` group "review 063 round 3": #6, #7, #8, #9.
- `tests/test_inventory_graph.py` `ReviewChainTest.test_r3_*` (#6, #7, #8, #9);
  `tests/test_flutter_map_editor.py` `test_r3_repair_of_a_moved_provider_line`.
- `flutter_app/test/task_cards_app_test.dart`: a provider choice that could not follow its agents is said,
  and on Undo.
