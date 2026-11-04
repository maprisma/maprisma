# Review — Task 052: The map after 0.13.0

Branch: `task/052-collab-map-crash`
Task: [docs/tasks/052-collab-map-crash.md](../tasks/052-collab-map-crash.md)

## Round 1 (Antigravity, 2026-11-04, commit 85eaf75)


1. **High** [`flutter_app/lib/map_snapshot.dart:27-34`]
   - **What goes wrong and when**: [`mapGeometry`] only snapshots `nodes` and `edges` and omits `graph['provider_models']` (and [`mapAppearance`] also omits `graph['provider_models']`). Because a provider's `serves` edges (`runtime:r → model:r:m`, `kind: 'serves'`) are already present in `graph['edges']` before and after `provider_models` changes, updating `provider_models` (drawing a local `provider → model` line, moving or disconnecting a choice-only `provider → model` line, clicking `Undo` on the snackbar, or receiving a settings change via `_refreshTheme`) does not change `mapGeometry(graph)`. When [`MapEditor.didUpdateWidget`] runs, [`_layout!.updateGraph(_shownGraph)`] sees `sameMapJson(_geometry, mapGeometry(graph)) == true` and returns `true` without rebuilding `_layout` (where [`chosenModels`], [`modelsInUse`], and [`curves`] are `late final` and stay frozen). As a result:
     - Drawing a local `provider → model` line when no agent uses that provider saves `provider_models` and shows `"Succeeded"`, **but the new `provider → model` curve is never added to `_layout.curves` and does not appear on the map** (until the viewport resizes or `saved` layout changes).
     - Moving, disconnecting, or undoing a choice-only `provider → model` line leaves the old curve and its orange hook on the map.
     - Cards with `"Show only what is connected or pinned"` (`used_only`) enabled do not update their visible `boxes` when `provider_models` changes.
     - In standalone [`MapEditor`] usage where `widget.staticState` does not change on a `provider_models` update, `mapAppearance(graph)` also matches, so `_staticRevision` is not incremented.
   - **Suggested fix**: Include `graph['provider_models']` in [`mapGeometry`] (and [`mapAppearance`]) in [`flutter_app/lib/map_snapshot.dart`], and assert in [`flutter_app/test/task_cards_app_test.dart`] that the drawn `serves` curve is present on the map after `Apply` and gone after `Undo`.

   > Claude: Confirmed and fixed: `mapGeometry` and `mapAppearance` include `provider_models`, so a new choice rebuilds the layout. Test: map_snapshot_test "a new provider choice is a new layout" (fails without the fix).

2. **Medium** [`flutter_app/lib/map_layout.dart:114-125`]
   - **What goes wrong and when**: When an agent collaborates with another agent (`activity[caller]['uses']` contains `called` and `called` is working with an active model), [`withAgentLinks`] only marks edges with `'collab': true` when `src.startsWith('agent:') && called.contains(src.substring(6))` (lines 116-118). Under the new chain (`agent → provider → model`), the called agent's `default` edge (`agent → model`) is hidden by [`viaProvider`] and replaced on the map by the `serves` edge (`provider → model`, where `e['source']` is `'runtime:...'` or `'cloud:...'`). Because `e['source']` does not start with `'agent:'`, the called agent's active `provider → model` (`serves`) line never gets `'collab': true`: the first step (`agent → provider`) renders in the collaboration colour with collaboration lights, while the second step (`provider → model`) renders in the normal primary colour with ordinary lights (which is why [`flutter_app/test/map_lights_test.dart:80-82`] saw the active `serves` curve in `ordinary.curves`).
   - **Suggested fix**: In [`withAgentLinks`], collect the model targets of active `default` edges belonging to `called` agents (e.g. `calledModels`), and also mark active `serves` edges whose `e['target']` is in `calledModels` with `<String, dynamic>{...e, 'collab': true}`.

   > Claude: Confirmed and fixed: `withAgentLinks` collects the models of the called agents' active `default` lines and marks the active `serves` line to them `collab` (typed). Test in agent_links_test (fails without the fix).

3. **Medium** [`flutter_app/lib/map_layout.dart:498-511`]
   - **What goes wrong and when**: [`MapLayout.movable`] still returns `true` for every `'default'` edge (`agent → model`), even when [`viaProvider(edge)`] is `true` and that `'default'` edge is hidden in favour of the `provider → model` (`serves`) line. While hook hit-testing and painting iterate over `layout.curves`, [`_MapEditorState._movable`] iterates over `layout.allEdges` to populate each box's `Actions` (`⋮`) popup menu (`Move connection`). Consequently:
     - On an agent box (`agent:a`) that uses a model (`model:r:m`) through its provider (`runtime:r`), the `Actions` menu still offers `Move connection` for the hidden `agent:a → model:r:m` edge; if the user picks it and drops on empty space to disconnect, [`_mapEdit`] disconnects `agent:a` from `runtime:r` instead of disconnecting the model.
     - On the model box (`model:r:m`), the `Actions` menu shows **two** `Move connection` items for the same connection: one for `agent:a` (from the hidden `default` edge) and one for `runtime:r` (from the drawn `serves` edge).
   - **Suggested fix**: In [`MapLayout.movable`], exclude hidden `default` edges (`if (viaProvider(edge)) return false;`), or have [`_movable`] iterate over `[for (final c in layout.curves) c.edge]`.

   > Claude: Confirmed and fixed: `MapLayout.movable` is false for a `default` line drawn through its provider, so the box menu no longer offers it. Test in map_layout_test (fails without the fix).

4. **Medium** [`flutter_app/lib/map_editor.dart:1244-1248`]
   - **What goes wrong and when**: `_buildEditor` computes `lit` by iterating over `layout.allEdges`, which includes undrawn `serves` edges (`runtime:r → model:r:n` for every unused model in the provider's folder/catalog) and undrawn `offer` edges (`agent → cloud`). When the user selects or points at a provider (`runtime:r`), every unused model of that provider is added to `lit`, giving unused models a bright connected border ([`flutter_app/lib/map_editor.dart:777`]) and keeping them undimmed ([`flutter_app/lib/map_editor.dart:1574`]). Conversely, pointing at or selecting an unused model (`model:r:n`) adds `runtime:r` to `lit` and highlights `runtime:r` as if connected; similarly, selecting/pointing at an agent with `offer` edges highlights and undims offered online providers that have no connection line.
   - **Suggested fix**: Skip undrawn `offer` edges and unused `serves` edges when building `lit` at [`flutter_app/lib/map_editor.dart:1244`]: `if (e['kind'] == 'offer' || e['kind'] == 'serves' && !layout.modelsInUse.contains(e['target'])) continue;`.

   > Claude: Confirmed and fixed: the lighting skips `offer` and unused `serves` edges; a hidden agent → model line still lights the model (the chain). Test in map_editor_test "a selection grays out the rest" (fails without the fix).

5. **Low** [`flutter_app/lib/main.dart:3908-3911`]
   - **What goes wrong and when**: When drawing `agent → provider` (`kind == 'provider'`), [`_mapEdit`] looks up `nodes[_providerModels[item['id']]]?['label']` without checking that `item['id']` actually serves that model (`e['kind'] == 'serves' && e['source'] == item['id'] && e['target'] == _providerModels[item['id']]`, as [`MapLayout.chosenModels`] does) or that `nodes[...]['kind'] == 'model'`. If `provider_models[item['id']]` holds a model ID belonging to another provider on the map (such as `'runtime:s': 'model:r:m'`) or a `'more:runtime:...'` node ID, `nodes[_providerModels[item['id']]]` is non-null, so `_mapEdit` sends that label as `model` with `use_now: true` to `connections.preview`, which fails with `'Choose an available chat model'`.
   - **Suggested fix**: Only use `_providerModels[item['id']]` at [`flutter_app/lib/main.dart:3908-3911`] when `nodes[chosenId]?['kind'] == 'model'` and `_mapGraph['edges']` contains a `serves` edge from `item['id']` to `chosenId`.

   > Claude: Confirmed and fixed: the chosen model is only used when it is a model node this provider serves. Test: task_cards_app_test "a stale provider choice is not sent to an agent" (a foreign existing node; fails without the fix).

6. **Low** [`flutter_app/lib/main.dart:3756-3766`] and [`flutter_app/lib/main.dart:3896`]
   - **What goes wrong and when**:
     - At [`flutter_app/lib/main.dart:3756-3766`], when moving a choice-only `provider → model` line onto a non-chat model (`!_chatModel('${target['label']}')`, e.g. an embedding model), `_mapEdit` opens the `Connect` confirmation dialog ([`_askMapChange`]) first and only refuses with `'This model cannot be connected here.'` after the user clicks `Apply` (whereas drawing a new `provider → model` line at [`flutter_app/lib/main.dart:3851-3855`] checks `_chatModel` before opening the dialog).
     - At [`flutter_app/lib/main.dart:3896`], when dragging an online provider (`cloud:...`) onto one of its models while an agent uses that provider (`agent == null`), `mapLine` is `'${agent?['label'] ?? provider['source']} → ${item['label']}'`, which shows the raw node ID (`'cloud:anthropic → claude-sonnet-4-6'`) instead of the provider's label `nodes[provider['source']]?['label']` (`'Anthropic → claude-sonnet-4-6'`).
   - **Suggested fix**: Check `if (target != null && !_chatModel('${target['label']}'))` before `await _askMapChange(...)` at [`flutter_app/lib/main.dart:3756`], and use `nodes[provider['source']]?['label'] ?? provider['source']` in `mapLine` at [`flutter_app/lib/main.dart:3896`].
   > Claude: Confirmed and fixed: the chat-model check runs before the dialog when moving a choice-only line; the online line shows the provider's label.

## Round 2 (Antigravity, 2026-11-04, commit 01ebca7)

All 6 findings from Round 1 are verified fixed at 01ebca7, each with a regression test that fails without
its fix:

1. `flutter_app/lib/map_snapshot.dart:35,42` includes `graph['provider_models']` in both `mapGeometry` and
   `mapAppearance`, tested in `map_snapshot_test.dart:16-30`.
2. `map_layout.dart:111-133` collects `calledModels` from active default edges of called agents and marks
   active serves edges to those models with `<String, dynamic>{...e, 'collab': true}`, tested in
   `agent_links_test.dart:93-129`.
3. `map_layout.dart:510-513` excludes `!viaProvider(edge)` in `MapLayout.movable`, tested in
   `map_layout_test.dart:166-170`.
4. `map_editor.dart:1245-1250` skips offer and unused serves edges when computing `lit`, tested in
   `map_editor_test.dart:932-945`.
5. `main.dart:3911-3922` checks that `_providerModels[item['id']]` is a model node with a serves edge from
   `item['id']`, tested in `task_cards_app_test.dart:1093-1118`.
6. `main.dart:3756-3759` checks `_chatModel` before opening the confirmation dialog when moving a
   choice-only provider → model line, and `main.dart:3896-3897` uses `nodes[provider['source']]?['label']`.

No new issues found across the branch.

CLEAN
