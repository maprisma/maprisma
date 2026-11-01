# Review: 016-focus-dimming

## Round 1 (Antigravity, 2026-11-01, commit acdf549)

Note on map lights: `MapLightLayer` (`flutter_app/lib/map_lights.dart:121, 181`) culls light marks inside `occluders` around every box (`layout.boxes.values.map((r) => r.inflate(radius))`), so leaving map lights undimmed does not draw over or hide anything on faded boxes.

1. **`packages/maprisma_core/lib/src/setup_checks.dart:377`, `agent_status.py:644`, `link_check.py:99-105` — Health check and link-check hints still tell the user to select the agent on the map and click a model**
   - **What goes wrong:** In `SetupChecks.agentChecks` (`packages/maprisma_core/lib/src/setup_checks.dart:371-380`) and `agent_status.agent_checks` (`agent_status.py:642-644`), when an agent is connected to a local LLM (`localNames.isNotEmpty`) but has no model configured (`model.isEmpty`), the `'No model chosen'` warning step still says:
     `Select the agent on the map and click a model of a local LLM it is connected to.`
     (translated in `translations/{de,es,fr,it,nl,pl,pt}.json:744` / `pl.json:781` and baked into `packages/maprisma_core/lib/src/core_assets.g.dart:7`). That step is shown in the agent's Details › Health card (`agents.health`) and in the Agents column status list on the map (`packages/maprisma_core/lib/src/health_report.dart:377`, `health.py:221`). After `21b9065`, following that instruction only selects the model box and clears the agent selection instead of choosing the model. `link_check.py:99-100` (`"{0} has no models yet: {1} Then select {2} on the map and click the model."`) and `link_check.py:104-105` (`"{0} does not use a model of {1} yet: select {0} on the map and click one of {1}'s models."`, `translations/{de,es,fr,it,nl,pt}.json:236,888` / `pl.json:266,925`) also still describe the removed click-to-choose shortcut.
   - **How to reproduce:** Have an installed agent connected to a local LLM in its settings without a chosen model (`model` empty, `localNames` non-empty) and open the Agents column status list on the map (or the agent's Details page). The `'No model chosen'` warning instructs you to *"Select the agent on the map and click a model of a local LLM it is connected to."* Click the agent on the map and then click the model box: the model box is merely selected (`flutter_app/lib/map_editor.dart:501-520`) and no connection preview opens.

2. **`docs/manual/manual.html:260-265, 721-722` (and `de`, `es`, `fr`, `it`, `nl`, `pl`, `pt`) — Earlier manual sections `#connect-llm` and `#map` still describe clicking a model after selecting an agent, hover dimming, and a pin keeping connections lit**
   - **What goes wrong:** While `#flutter-map-editor` was updated in all 8 languages, two earlier sections in the same manuals still describe the old behaviour:
     - `#connect-llm` still says that with an agent selected, clicking a model of a connected local LLM makes that model the agent's model:
       - `docs/manual/manual.html:721-722`: *"With an agent selected, clicking a model of a connected local LLM makes that model the agent's model."*
       - `docs/manual/manual.de.html:693-694`: *"Ist ein Agent ausgewählt, macht ein Klick auf ein Modell eines verbundenen lokalen LLMs dieses Modell zum Modell des Agenten."*
       - `docs/manual/manual.es.html:687`: *"Con un agente seleccionado, un clic en un modelo de un LLM local conectado hace de ese modelo el modelo del agente."*
       - `docs/manual/manual.fr.html:696-697`: *"Avec un agent sélectionné, un clic sur un modèle d'un LLM local connecté fait de ce modèle celui de l'agent."*
       - `docs/manual/manual.it.html:670-671`: *"Con un agente selezionato, un clic su un modello di un LLM locale collegato rende quel modello il modello dell'agente."*
       - `docs/manual/manual.nl.html:666-667`: *"Met een agent geselecteerd maakt een klik op een model van een verbonden lokaal LLM dat model het model van de agent."*
       - `docs/manual/manual.pl.html:657`: *"Gdy agent jest zaznaczony, kliknięcie modelu połączonego lokalnego LLM czyni ten model modelem agenta."*
       - `docs/manual/manual.pt.html:670`: *"Com um agente selecionado, um clique num modelo de um LLM local ligado torna esse modelo o modelo do agente."*
     - `#map` (`Working with the map`) still says that hovering a box dims the rest of the map (`docs/manual/manual.html:260-261`) and that the pin at a box's top-right corner keeps its connections lit (`docs/manual/manual.html:265`: *"The <b>pin</b> at a box's top-right corner keeps its connections lit while you look elsewhere."*; `docs/manual/manual.de.html:238-243`; `docs/manual/manual.es.html:232-237`; `docs/manual/manual.fr.html:235-240`; `docs/manual/manual.it.html:222-227`; `docs/manual/manual.nl.html:222-227`; `docs/manual/manual.pl.html:220-225`; `docs/manual/manual.pt.html:223-228`).
   - **How to reproduce:** Open `docs/manual/manual.html` (or any of the 7 translated manuals) at `#connect-llm` and `#map` and compare with `#flutter-map-editor` (`docs/manual/manual.html:1078-1080`) and `flutter_app/lib/map_editor.dart:501-520, 1118-1135`.

### Answers (Claude)
1. Fixed: the three hints in `agent_status.py`, `link_check.py` and `setup_checks.dart` now say to draw a line, in 8 languages. The unused text `click a model of its local LLM to use it` stays in the tables: no code asks for it.
2. Fixed: `#connect-llm` and the first three items of `#map` in 8 languages, new translations stamped. `#map` also lost two things the app doesn't have: the ✓ and `Clear selection`, and Esc clearing a selection. A selection ends by a second click or a click on empty map.
