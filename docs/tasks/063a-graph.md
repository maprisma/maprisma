# 063a The map's agent → provider → model chain

Author: Claude · Reviewer: Codex · Branch: task/063a-graph (part of task/063-codex-review)

## Goal
Fix the chain findings of the Codex coverage review (`docs/reviews/063-codex-coverage.md`, round 1): F1, F2,
F4–F8, F11 and F17. The map must draw each agent → provider → model line the way the agent really uses it, and a
line drawn on the map must do what it shows.

## Routes
`map.snapshot` only (its note in `routes.json` says what is new; no params or result keys changed):
- Agent boxes carry `own_provider`: the id of the agent's own online provider from the provider facts
  (`cloud:openai` for Codex), `""` for none.
- An agent's line to its own online provider is `available` while none of its `[access]` sign-in `files` and
  no `env` key is there (a stat, never a read; an adapter that lists no file counts as signed in), else `uses`.
- A local provider keeps its configured port; `localRuntime` joins it to the installed runtime detected on that
  port (`RuntimeRecord.address`), the facts' usual ports only as the fallback. Map and inventory use it.
- An unqualified model of an agent whose one active provider is local is that runtime's model; a running
  instance's unqualified `--model` keeps the configured provider.
- Models an agent is set to or runs, and each provider's chosen model (Settings › `provider_models`), are drawn
  past the first ten. A model an agent is set to that its runtime no longer lists is a model with
  `status: missing`, served by that runtime, with its default line.
- LM Studio's port comes from `~/.lmstudio/.internal/http-server-config.json`, Jan's from `jan.service` or its
  running router (`--preset … --port N`); 1234 and 6767 stay the defaults.
- MCP servers of one name but another command or address are separate boxes: `mcp:<name>~2`, labelled with the
  name. `details.mcp`, `connections.preview` and a disconnect on the map find them by that id.
- Folders saved by Reuse model folder (`model_folders`) that no installed runtime lists their models from:
  `model:folder:<path>:<model>` boxes in a card named by the folder.
- Python reference in step: `graph.py`, `inventory.py` (`local_runtime`, `add_server`, `reused_folders`),
  `agent_details.Provider.port`.

## UI
- Dropping an agent on an online provider signs in only when it is the agent's own one. Another provider it can
  use through its settings (an `offer` line) says "To switch {0} to {1}, draw the line to one of its models.";
  any other says "{0} cannot use {1}." (both in eight languages).
- A signed-out agent's own provider line is drawn as available; dragging the agent onto it signs in.
- Manual: Editing the Flutter AI Map, one paragraph, eight languages.

## Acceptance
- `packages/maprisma_core/test/map_chain_test.dart`: one test per finding (F2, F4, F5/F7, F6, F8, F11, F17).
- `tests/test_inventory_graph.py` `ReviewChainTest`: the same cases on the Python reference.
- `flutter_app/test/map_layout_test.dart` and `map_editor_test.dart`: an online provider takes only its own
  agent; a refused drop says why.
