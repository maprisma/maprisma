# 020 Ask AI disconnects models

Author: Claude · Reviewer: Antigravity · Branch: task/020-disconnect-models

Uwe, 2026-11-02, screenshot note: Ask AI cannot disconnect any or all models from llama.cpp.

## Goal
In the Models column, `disconnect` takes a runner and models: agents set to those models leave, as a model's hook does on the map, and the models unload where the runner can. One candidate, one preview, one backup, one Undo. No file is deleted. A model no agent uses has nothing to disconnect, and the answer says so. The Providers column sends such a request to the Models column.

## How
`model_users` gives who uses what on every installed local LLM, from `ReadService.modelUsers`: fresh, with no layer hidden and no limit of ten models. `model_disconnect` holds pairs of model and agent. An agent leaves a local LLM whole, so a card holds all its models there, and one refused model keeps that agent. `MapEdits.modelsDisconnect` plans exactly the pairs, refuses when they no longer fit, and unloads a model only when nobody stays on it. `_canLeave` is shared with `models.switch_preview`.

## Manual
smart-card, 8 languages.
