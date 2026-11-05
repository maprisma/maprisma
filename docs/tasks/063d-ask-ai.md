# 063d Ask AI reaches the manual menus

Author: Claude · Reviewer: Codex (review 063) · Branch: task/063d-ask-ai

## Goal
Findings F12 to F16 and F21 of [review 063](../reviews/063-codex-coverage.md): what Ask AI does must be the same
operation as the manual menu, through the same preview, rule check, review card and Undo, and every menu action
should have an Ask AI way there.

## Routes
- New `models.choose_preview {provider, model|null}` → `{preview, empty, old, new, line, focus}`,
  `models.choose_apply {preview}` → `{ok, undo}`, `models.choose_undo {undo}` → `{ok}` (F21). A local LLM's own model
  (Settings `provider_models`, the provider → model line) is checked as `models.switch_preview` checks a model line:
  `actionChecks` gives "disconnect" for the model it uses now and "connect" for the new one (`RuleFacts.providerModel`).
  Only that local LLM's entry is written, only when nothing changed it since; Undo puts back the choice before it and
  nothing else. `models.choose_apply` and `models.choose_undo` are rule-exempt second steps.
- `map.smart_ask`: a download candidate carries `connect [{command, name}]`, the installed agents with a local LLM
  connector (the set `connections.snapshot` marks `provider: true`, F12). New candidate kind `menu_action
  {area, step, key, model}` (F15).
- `map.smart_connect`: refused for an agent not in the candidate's `connect`; `use_now: true`, as a drawn connection
  with the provider's model (`main.dart` drag) and the Providers page's default (F13).

## Core
- F14: a `connections.preview` map edit whose item is an online provider (`cloud:<name>` on the map) becomes the
  agent's own sign-in (`agent_action` login, or logout for remove) through `agents.action_preview`, the route the map
  uses when an agent is dropped onto an online provider. The facts name each agent's own provider (`own_clouds`, from
  `visibleProviderFacts['cloud']`). Another agent's provider: "An agent can only sign in to its own online provider."
  An agent without a sign-in: "This agent has no sign-in that the app can start." (8 languages.)
- F16: `MapEdits.modelsDisconnect` no longer unloads models. It changes configuration only, as the map's disconnect
  of an agent → local LLM line (`connections.preview remove`, same files); Undo restores all of it. The app then offers
  the loaded models as after every line change (`_modelsLeft` → `models.slots_preview`, its own review).
- F15: `menu_action` candidates are checked with the rules of the route they open (`smartMenuChecks` calls
  `actionChecks` of that route), so a refused one never reaches the card (`_dropRefused`), and the route checks again.
  The core has no run of its own for them: `map.smart_review`/`map.smart_run` refuse them.

## Actions covered (F15)
Through the core's own preview route (the card's review, as before):
- Agents: install, update, remove, sign in, sign out (unchanged), **verify** (test question, `agents.action_preview`).

Through the manual menu, opened by the GUI (`_smartMenu` in `main.dart`), with that menu's preview, review and Undo:
- Agents: **API key** (`_apiKey`: the key card; the helper never sees or handles the key), **security settings**
  (`_security` → `agents.security_preview`), **start** (`_start` → `sessions.start`, the default project; details page
  when there is none), **halt** an outside instance (`_haltMapAgent` → `agents.halt_preview`).
- Add-ons (agent add-ons in Agents, local LLM add-ons in Providers): **details** (the add-on sheet), **switch on/off**
  (`_toggleAddon` → `addons.set_enabled`, with Undo), **install/update** (`_installAddon` with the catalog entry),
  **remove** (`_removeAddon` → `addons.remove_preview`). Offered only where the sheet or catalog offers the step now.
- Models: **load** and **unload** (`model.load`/`model.unload` through `providers.run`, after one question as the map's
  Start/Stop), **import** (the GGUF file chooser, then `model.import`), a local LLM's **own model** (F21, the same
  `_setProviderModel` as the map).

Opening the manual page, where the user picks the item and its own preview runs (navigation):
- Agents: **configure** (its Connections page), **details** (its details page).
- Providers: **Find existing AI**, **reconnect** a found local LLM, **reuse a model folder** (`_openExisting`, then
  `existing.preview`).
- MCP: **found-scan**, **unpack**, **update** (Connections › Found on this PC, then `found.unpack` /
  `found.update_preview`).

Not added: a provider (local LLM program) uninstall. The app has no manual one; the helper is told to offer switching
off or removing the add-on, or a look-up. Layout and view actions (fold, filter, card order, zoom, legend, Help) need
no Ask AI equivalent.

## UI
- `MapSmartCard`: after a download, Connect offers the core's `connect` agents, no longer the helper agents (F12).
  A `menu_action` candidate's Review closes Ask AI and hands it to `onMenu`; its step name is translated.
- Choosing a local LLM's model on the map (provider → model line, also moving or removing it) goes through
  `models.choose_*` instead of `settings.update`; the note's Undo calls `models.choose_undo` (F21).
- Manual: Smart cards on the map, one paragraph, 8 languages.

## Acceptance
- `ask_ai_menus_test.dart`: F12/F13 (only Pi is connectable, Claude is refused; the plan moves Pi's default model);
  F14 (own provider is login; another's or none refused with the reason); F15 (each step and its rules, verify,
  add-ons, existing, models, MCP found, a refused one, no core run); F16 (no unload, the same files as the map's
  disconnect); F21 (preview, apply once, Undo of only that entry, a deny rule refuses, a foreign model is refused).
- `action_rules_test.dart`: `models.choose_preview` gives connect models.
- `task_cards_app_test.dart`: provider → model goes through `models.choose_*` with Undo, no `settings.update`; an Ask AI
  menu action opens the manual step; after a download Connect offers Pi from the core, not the helper.
