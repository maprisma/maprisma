# 052 The map after 0.13.0: no blank map, one chain, atomic provider → model

Author: Claude · Reviewer: Antigravity · Branch: task/052-collab-map-crash (on main 1fb7e91, Maprisma 0.13.0)

## Goal

Uwe's model of the map: skills or MCP → agent → provider → model, one line per step, only real connections.
0.13.0 broke it in three ways: the whole map turned grey whenever one agent called another; an agent's
model was drawn straight from the agent (Pi had two lines); and drawing a provider onto a model asked for
a list of agents in the big preview. Connecting must stay atomic: one short step per line.

## Routes

None. A new setting `provider_models` (provider map id → model map id), a text mapping in both cores
(`settings_schema.py`, `settings.dart`), written with the existing `settings.update`.

## UI

- `map_layout.dart` `withAgentLinks`: the called agent's active lines get a typed map literal (the untyped
  one threw in the layout's cast: blank map).
- The chain: a model an agent uses through its own line to the model's provider is drawn provider → model;
  that agent → model line is not drawn. A provider's chosen model (`provider_models`) is drawn too. Models
  nobody uses and `offer` edges (models an agent's picker could choose online) have no line.
- "Only what is connected or pinned" counts only real connections (not `serves`, not `offer`; a chosen
  model counts).
- Provider → model drop (local provider): the short Connect dialog, then the choice is saved, with a note
  and Undo; speech/embedding/tokenizer models are refused with a note. Online provider: the agents already
  using it get the model; with none, a note says to connect an agent first.
- Agent → local provider: the agent gets the provider's chosen chat model (`connections.preview` with
  `model` and `use_now`).
- Moving or removing a provider → model line: only the choice when no agent uses the model; otherwise the
  existing `models.switch_preview`, and the choice follows when it applied.
- Manual (8 languages): the map paragraph describes the chain, the filter and the one-step provider → model.

## Acceptance

- `flutter_app/test/agent_links_test.dart`, `map_editor_test.dart` (a working agent that calls another one
  keeps the map), `map_layout_test.dart` (chain, unused models, offers, chosen models, filter),
  `task_cards_app_test.dart` (provider to model is one short step; an agent connected later gets the model).
- `tools/test-changed --base main` green except core `test/dictation_test.dart` "Omarchy readiness…", which
  fails on main as well on this machine (depends on the local Omarchy dictation setup).
