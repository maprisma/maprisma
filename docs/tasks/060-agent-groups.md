# 060 Online and local agents; local LLMs to install on the map

Author: Claude · Reviewer: Antigravity · Branch: task/060-agent-groups

## Goal
From Uwe's screenshot notes of 2026-11-05:
- `maprisma-2026-11-05-13-10-47`: "two different agent groups for online (agy, claude, codex) and local agents
  like pi". The map's Agents column becomes two cards, as the Providers column has Online and Providers.
- `maprisma-2026-11-05-13-13-25`: "i switched on vllm and it does not show up under local providers. always when
  switching on an add-on and going back the filter should directly show the switched on card". vLLM was not
  installed, and the map draws only installed local LLMs, so its add-on showed nowhere (task 059 covered agents
  only).

## Routes
No new route and no new field. `map.snapshot`'s agent nodes fill the existing `group`: `"local"` for an agent
whose adapter has `[local_llm]` (it is made to be pointed at a local LLM: Pi, Hermes, OpenClaw, OpenCode, dsh,
omp), `""` for the others. The Python reference (`graph.py`) does the same.

## UI
- `MapLayout`: agent cards are titled **Online agents** (`1:agent:`, the old card id, so its saved order, folding
  and filter stay) and **Local agents** (`1:agent:local`), the local one below unless the cards were moved by
  hand. Programs to install end the online agents card (the local one when there is no other).
- `_missingPrograms` also lists a provider add-on that is on, loaded, has the `installer` capability, and whose
  `provides` key is no `runtime:<key>` box (an installed local LLM always is one): `kind: 'runtime'`. Its row
  ends the local providers card (`2:runtime:`, else `2:cloud:`); Install runs `_installProgram('runtime', key)`.
- Add-ons switched on in this session (`_toggleAddon`): their `agent:`/`runtime:` boxes go into the graph's GUI
  only `fresh` list and count as pinned in a card set to used only. Rows of programs to install now show in
  such a card too (only a folded card leaves them out).
- Texts: "Online agents", "Local agents" (8 languages). Manual, Expand a category: one paragraph (8 languages).

## Acceptance
- `smart_card_test.dart`: with claude and pi on PATH, `agent:pi` has group `local`, `agent:claude` none.
- `map_layout_test.dart`: two agent cards with their titles, local below; saved card order wins; programs to
  install in the online card (local when alone); a `kind: runtime` row ends `2:runtime:`; `fresh` shows a box in
  a used-only card and is part of the geometry; used-only no longer hides the rows.
- `task_cards_app_test.dart`: an enabled provider add-on with an installer and an uninstalled program shows
  `card-missing-vllm`; a click asks `installers.preview` with `kind: runtime, key: vllm`. An installed one and
  one without the installer capability show none.
