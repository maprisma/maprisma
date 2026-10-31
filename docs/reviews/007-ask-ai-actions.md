# 007 Ask AI does the real work

## Round 1 (Antigravity, 2026-10-31, commit e191354 + working tree)

Checked and fine: trust boundary between agent, core and GUI (`SmartProposals.keep` strips `action` before returning candidates; `smartMcpOption` filters out non-runnable options and any option where a secret would land in `args`, and clears `secret` values in `needs`; `_moveFacts` exposes only neutral `f1`/`d1` IDs and basenames/mountpoints, never full model-folder paths; `smartFinish` filters web lookup sources to `https://` and wraps notes in `<notes>` data tags with `<` replaced by `‹`); review before every mutating action (`mcp.option_preview` / `connections.preview`, `models.remove_preview`, `system.move_preview`, `agents.action_preview`, `helpPreviews`); multi-item progression (`_nextOrClose`) for model folder moves and agent actions; `MapLegend` dialog, `SettingsView` map-lights dropdown, `MapLayout` width/gap expansion up to 560 px, manual updates and 8-language translations.

1. **High** `packages/maprisma_core/lib/src/smart_card.dart:438` (`smartMcp`), `flutter_app/lib/map_smart_card.dart:466` (`_openMcp`), `packages/maprisma_core/lib/src/core.dart:3138,3163` (`_smartPlan`) Connecting or disconnecting an existing MCP server in the MCP smart card always fails when clicking Review. In `smartMcp`, `mcp_connect` and `mcp_disconnect` candidates put `'agent': command` only inside `'action'` (which `SmartProposals.keep` strips at `smart_card.dart:1262`) and omit top-level `'agents': [command]` (unlike `mcp_add` at line 486 and the protocol note in `docs/protocol.md:191`). When the user clicks Review, `_openMcp` (`map_smart_card.dart:466-468`) reads `candidate['agents']` (`null`) and calls `map.smart_plan` with `agents: []`, which `_smartPlan` (`core.dart:3138,3163`) rejects with `FormatException('Invalid request')`. Fix: include `'agents': [command]` on `mcp_connect` and `mcp_disconnect` candidates in `smartMcp` and add a test covering `map.smart_plan` for `mcp_connect` / `mcp_disconnect`.

2. **High** `packages/maprisma_core/lib/src/core.dart:2898-2901` (`smartRoute` for `column == 'providers'`) The provider facts sent to `smartProviders` set `'install': !rt.installed`, `'start': rt.installed && !rt.running`, and `'stop': rt.installed && rt.running` without checking whether the app can actually install or control that runtime (compare `read_service.dart:225,231-233` and `provider_ops.dart:206-209,358`). When a runtime without a checksummed installer (`lmstudio` or `vllm`, where `engine['can_install'] != true` and `Installers` uses `RefusedInstaller` at `installers.dart:1476-1483`) is not installed, or when an installed runtime has no systemd user unit / `lms` binary (`!canControl(rt)`), `smartProviders` offers `install` / `start` / `stop` instead of redirecting or looking up on the web, and clicking Review then fails in `installers.preview` or `providers.run`. Fix: gate `'install'` on `!rt.installed && (engines[rt.key] as Map?)?['can_install'] == true` and `'start'` / `'stop'` on `can_control` (as in `reads.providersSnapshot()['local']`).

3. **Medium** `packages/maprisma_core/lib/src/smart_card.dart:427-453` (`smartMcp`) When `action` is `'connect'` or `'disconnect'` and every requested agent is already in that state (`using.contains(command) != remove` for all `command` in `first['agents']`), the filtered `candidates` list is empty, yet `smartMcp` returns `{'status': 'proposal', 'summary': '', 'candidates': []}`. `SmartProposals.keep` (`smart_card.dart:1243`) returns it without a `'proposal'` handle, and `MapSmartCard` enters `_SmartStep.proposal` showing an empty proposal card with no summary and no candidates. Fix: when no candidate remains after filtering against `using`, return a redirect with a hint (or refuse so the user gets a clear message) instead of an empty `proposal`.

4. **Medium** `flutter_app/lib/map_smart_card.dart:807-809` (`_applyConnect`) When a `connect` or `disconnect` request in the MCP column names multiple agents (producing candidates `c1`, `c2`, …), confirming the `ConnectionReview` for the first candidate calls `_applyConnect()`, which unconditionally resets `_step = _SmartStep.idle` and closes the card (`_close()`) instead of advancing via `_nextOrClose(candidate)` as `_confirmReview()` does at lines 684 and 714. The remaining agent connection candidates in the proposal are discarded. Fix: when `_activeCandidate?['kind'] != null` (`mcp_connect` / `mcp_disconnect`, and `mcp_add` if multiple candidates exist), call `_nextOrClose(_activeCandidate!)` (or close on `mcp_add` when one server was chosen, while stepping through remaining `mcp_connect` / `mcp_disconnect` candidates).

5. **Medium** `packages/maprisma_core/lib/src/smart_card.dart:1118,1134,1153,1203` (`smartAsk`), `packages/maprisma_core/lib/src/core.dart:1623,2987-2995`, `flutter_app/lib/map_smart_card.dart:1048` (`_buildRedirect`) Three issues in the `Do it with {0}…` (`agent_task`) flow after a web look-up:
   - `smartAsk` passes `task: '${data['command']}'` into `smartFinish` without checking whether the adapter has a `[task]` command (`adapter.table('task')['argv']`). If an online helper has `[research]` but no `[task]`, `smartFinish` still offers the `agent_task` button and clicking it fails in `map.smart_review` (`core.dart:2994`: `Guarded helper unavailable`).
   - `_buildRedirect` (`map_smart_card.dart:1048`) fills `{0}` in `Do it with {0}…` from `_activeHelper?['name']` (the currently selected dropdown item) rather than the helper that produced the reply/candidate.
   - `helpRoute` (`core.dart:1623-1627`) maps `topic` in `system.help_apply` with `switch (topic) { 'fix' => 'smart-fix', 'mcp-update' => 'mcp-update', _ => 'setup-help' }`, so `'smart-card'` tasks from `core.dart:3002` are logged as `'setup-help'` instead of `'smart-card'`.

6. **Low** `packages/maprisma_core/lib/src/smart_card.dart:267,345` (`smartAgents`, `smartProviders`), `flutter_app/lib/main.dart:1786` (`_smartProvider`)
   - `smartAgents` and `smartProviders` set candidate `'subtitle': action` to the raw English action key (`'install'`, `'update'`, `'remove'`, `'start'`, `'stop'`), which `_buildProposal` (`map_smart_card.dart:1153`) renders untranslated on the card.
   - `_smartProvider` (`main.dart:1786`) passes `'label': key` (e.g. `'llamacpp'`, `'koboldcpp'`) instead of the provider's display name (`Ollama`, `llama.cpp`, `KoboldCpp`) to `_mapRuntimeControl`, so the confirmation card asks `Start llamacpp?` / `Stop koboldcpp?`.

## Answer to round 1 (Claude)

All six confirmed in the code and fixed, not yet committed.

1. `mcp_connect` and `mcp_disconnect` candidates carry `agents`; a core and a widget test cover it. `connections.preview` takes the server name as `item`, so the path holds.
2. Provider facts come from `providersSnapshot()`: `installable` and `can_control`.
3. Nothing left to change gives a redirect with its own text, not an empty proposal.
4. `_applyConnect` goes on with the remaining candidates.
5. The button needs an agent with a `[task]`; it names the helper of the reply; the run is logged as `smart-card`.
6. Step names are translated on the card; the review names the provider by its display name.

## Round 2 (Antigravity, 2026-10-31, commit e191354 + working tree)

Findings 1 to 6 of round 1 are fixed and covered by unit and widget tests.

CLEAN


