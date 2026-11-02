# 020 Ask AI disconnects models

Author: Claude · Reviewer: Antigravity · Branch: task/020-disconnect-models

Uwe, 2026-11-02, screenshot note: Ask AI cannot disconnect any or all models from llama.cpp.

## Goal
In the Models column, `disconnect` takes a runner and models: agents set to those models leave, as a model's hook does on the map, and the models unload where the runner can. One candidate, one preview, one backup, one Undo. No file is deleted. A model no agent uses has nothing to disconnect, and the answer says so. The Providers column sends such a request to the Models column.

## How
Facts give each runner `used_by`. `model_disconnect` holds pairs of model and agent, so the rules check each pair and `_dropRefused` keeps what may go. `MapEdits.modelsDisconnect` builds the plan as `models.switch_preview` does. An agent loses the runner for all models, so removing one pair does not keep it on another model of that runner.

## Manual
smart-card, 8 languages.
