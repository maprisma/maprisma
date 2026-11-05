# 062 The model Codex and Antigravity start with

Author: Claude · Reviewer: Antigravity · Branch: task/062-default-models

## Goal
From Uwe's screenshot note of 2026-11-05 (`maprisma-2026-11-05-14-09-58`: "after connecting codex and agy the
providers are on the map but not their models"). Neither names a model in its settings: Codex had run no session
yet (its fallback reads the newest session), and Antigravity CLI had no details reader at all. So no line ran from
OpenAI or Google to a model.

## Routes
None. Agent details only:
- Codex, no model set, no provider chosen and no session yet: the listed model with the lowest `priority` in
  `~/.codex/models_cache.json` (the one its picker shows first and a new Codex starts with).
- Antigravity CLI: a new details reader `agy` (`adapters/agy.toml` `[details] reader = "agy"`; `DETAIL_READERS`).
  Its newest `~/.gemini/antigravity-cli/log/cli-*.log` names the selected model
  (`Propagating selected model override to backend: label="Gemini 4 Argon (Medium)"`); the label without its
  effort becomes the model id `gemini-4-argon`, as the price table names it. `details` is a newer fact, so the
  signed agent-agy add-on, which has none, takes it from the app's own adapter: no new signature is needed.
- Python reference: `agent_readers.codex_cache_model`, `agent_readers.agy` and `agy_model_name`; the approved
  adapter snapshot `tests/adapter_snapshots/agy.json` has `details: true`.

## UI
None changed: the map draws Google → gemini-4-argon and OpenAI → gpt-6.1-sol with the agent's default line.

## Acceptance
- `smart_card_test.dart`: with a models cache and an Antigravity log, the map's default lines go
  `agent:codex` → `model:cloud:openai:gpt-6.1-sol` and `agent:agy` → `model:cloud:google:gemini-4-argon`.
- `test_agent_details.py`: the cache fallback skips hidden models and gives way to a session; the newest log
  wins; a label that is only an effort gives no model.
