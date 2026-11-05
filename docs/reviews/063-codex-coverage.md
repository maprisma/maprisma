# Review — Codex coverage review (Ask AI ↔ menus, existing installs, agent → provider → model, batteries)

Prompt: four parts (Ask AI and menus, existing installation, agent → provider → model, batteries).
Fixed on branch `task/063-codex-review`.

## Round 1 (Codex, 2026-11-05, commit 08498581b1546fc35c305fc675eb015c837a13da)

1. **High** `flutter_app/lib/main.dart:4201` Dropping an agent onto any online provider invokes that agent’s login without checking the destination provider. For example, dragging Codex onto Google runs Codex login; the selected Google target is discarded. The user approves a connection to Google but signs into OpenAI instead.

2. **High** `packages/maprisma_core/lib/src/inventory.dart:239` MCP servers from different agents are merged solely by name. If Claude’s `filesystem` entry and Codex’s `filesystem` entry have different commands or URLs, `putIfAbsent` preserves the first target and adds both agents to it. The map shows both agents connected to one server, concealing their different configurations.

3. **Medium** `packages/maprisma_core/lib/src/agent_catalog.dart:278` An installed OpenClaw outside pacman is rejected because `package_only` returns before wrapper, mise and PATH detection. Hermes similarly excludes ordinary PATH and `~/.local/bin` installations through `own_install_counts = false` (`adapters/hermes.toml:10`). On a COSMIC installation using npm, pipx, another installer or a hand-made wrapper, these agents can be absent from setup detection and the map despite being usable.

4. **Medium** `packages/maprisma_core/lib/src/agent_details.dart:189` Local-provider identity is inferred from the endpoint’s port using provider facts, rather than matched against the detected runtimes’ actual addresses. A Pi configuration pointing to llama.cpp on port 9090 gets `local: true` but no runtime identity. Although `provider_scans.dart:318` detects that server’s actual port, the graph cannot join the configuration to it; the agent/provider line disappears or becomes a misleading dangling/cloud connection.

5. **Medium** `packages/maprisma_core/lib/src/map_graph.dart:368` An unqualified model causes the agent’s built-in online provider to be drawn even when its configured endpoint is local. For example, Claude with `ANTHROPIC_BASE_URL=http://localhost:8080` and `model=qwen` gets a local runtime connection, followed by Anthropic → qwen and a default line to that online model. The model is attributed to Anthropic rather than the configured local service.

6. **Medium** `packages/maprisma_core/lib/src/map_graph.dart:493` Local model nodes are truncated before default and running-model references are resolved. With eleven models and the agent using the eleventh, the usual ten-model map omits its node; `map_graph.dart:559` then deletes the default edge because its target does not exist. The agent’s actual model is hidden behind “more” without its connection. A removed local model loses its edge through the same deletion, without a missing-model card or repair indication.

7. **Medium** `packages/maprisma_core/lib/src/map_graph.dart:431` A running instance with an unqualified `--model` loses its configured local-provider context. The running-model branch uses the command-line provider, which is empty, and then falls back to `cloud`, rather than the agent’s selected local provider. A locally configured Pi running `--model qwen` therefore fails to mark its local model as running; with an online default it can instead create an online model attribution.

8. **Medium** `packages/maprisma_core/lib/src/provider_scans.dart:375` LM Studio’s address and server-state test are fixed to port 1234. Jan is likewise fixed to 6767 and is marked running only when its worker explicitly uses that port (`provider_scans.dart:470`). When either runs its server on another port, the map reports the wrong endpoint/server state, and connections use that incorrect endpoint.

9. **Medium** `packages/maprisma_core/lib/src/agent_details.dart:208` Installed Gemini, Grok, Muse and Crush have no details reader in their adapters. The switch has no fallback for their settings or sessions. Consequently Gemini/Grok/Muse stop at their built-in online-provider cards without their configured model; Crush has neither an inferred provider nor model, despite its session reader and provider configuration. `--model` can supply a temporary running model, but does not recover the persisted chain.

10. **Medium** `packages/maprisma_core/lib/src/agent_details.dart:454` Claude’s session fallback differs from the Python reference: it retains `claude-opus-5-5` instead of normalizing it to `opus`, and obtains candidates from a session search restricted to the last 30 days (`session_readers.dart:175`). With no explicit model, an older last session yields no model at all; a recent session can yield separate full-name and alias cards for the same model. The reference expectations are explicit in `tests/test_agent_details.py:187`.

11. **Medium** `packages/maprisma_core/lib/src/existing_ai.dart:723` “Reuse model folder” saves the discovered GGUF directory only to `model_folders`. `read_service.dart:247` exposes that directory on the Providers page, but `InventoryReader.collect` and `MapGraph.build` do not consume it. After applying the reuse preview, those models still do not appear on the AI map unless a runtime independently scans that directory.

12. **Medium** `flutter_app/lib/map_smart_card.dart:2661` After downloading a model, Ask AI builds its connection targets from its helper agents, excluding only `local-helper`. This offers Claude and Codex, whose adapters have no `[local_llm]`, while excluding connectable agents such as Pi unless they also qualify as helpers. Selecting an offered unsupported agent fails at the local-connection preview instead of producing a chain.

13. **Medium** `packages/maprisma_core/lib/src/core.dart:3422` Ask AI’s post-download connection explicitly sets `use_now: false`. Dragging an agent onto a runtime with a chosen model sets it to true (`flutter_app/lib/main.dart:4231`). Thus the same apparent “connect this model” operation through Ask AI can leave the agent on its previous model, producing an available provider line without the requested default-model chain.

14. **Medium** `packages/maprisma_core/lib/src/smart_card.dart:293` Ask AI’s direct connection proposal accepts a provider only when `runtime:<item>` exists. It cannot propose the online-card login operation offered by dragging onto `cloud`. For example, “connect Antigravity to Google” cannot use that same target and preview; it must be translated into the separate agent-login action. Task 061’s map path therefore has no equivalent direct Ask AI connection path.

15. **Medium** `packages/maprisma_core/lib/src/smart_card.dart:612` Ask AI’s executable agent actions stop at install, update, remove, login and logout. Verify, start, halt, API-key entry, configuration and security changes available through the GUI have no corresponding structured candidate. Likewise its provider prompt excludes uninstall (`smart_card.dart:721`) and has no import/load/unload action. These requests are described, redirected or delegated to a general agent task instead of receiving the manual operation’s checked preview.

16. **Medium** `packages/maprisma_core/lib/src/map_edits.dart:561` Ask AI’s model-disconnect action also unloads models when all selected users leave. The ordinary connection-disconnect path removes configuration without that additional operation. The preview explicitly says runtime load/unload is not undone (`map_edits.dart:577`), so Undo after this Ask AI action restores the configuration but leaves the previously loaded model unloaded. The two disconnect paths do not have equivalent effects or Undo.

17. **Medium** `flutter_app/lib/main.dart:4042` Disconnecting an agent’s online-provider line invokes logout, but graph construction draws that provider again from the adapter’s built-in provider facts without checking authentication (`map_graph.dart:368`). For example, disconnecting Codex → OpenAI signs Codex out but leaves the connection visible after refresh. There is no connection Undo restoring that sign-in.

18. **Medium** `packages/maprisma_core/lib/src/agent_details.dart:570` On a non-Omarchy desktop, usage records are ignored unless the corresponding Omarchy collector is discoverable. On the supplied COSMIC setup, where only Claude’s collector is linked, Codex receives no plan battery—even though the available Codex collector obtains limits through Codex’s own `account/rateLimits/read` RPC (`/mnt/Data/Projects/omarchy/bin/omarchy-agent-usage-codex:948`). The core has no native RPC or session-limit fallback. This does not require Maprisma to read Codex credentials.

19. **Medium** `packages/maprisma_core/lib/src/costs.dart:166` Session costs alone cannot enable a cost badge: `paysPerToken` requires a recognized environment variable, an explicit `per_token` access fact with credentials present, or a ready usage record. Hermes, Oh My Pi, OpenCode and OpenClaw have readable session-cost sources but lack those billing facts. With API billing configured internally and no collector, they never get a cost badge even when `UsageReaders.costs` can calculate spending.

20. **Medium** `packages/maprisma_core/lib/src/agent_details.dart:501` Limit ingestion ignores the collector’s freshness indicators and record age. `currentLimits` only checks a parseable future reset; a missing or malformed reset remains valid (`agent_badges.dart:14`). After refresh fails, an old record can therefore continue displaying a normal battery, including records whose collector explicitly marks limits stale. `updatedAt`, `limitsStale` and `limitsFetchedAt` do not qualify the badge.

21. **Low** `flutter_app/lib/main.dart:4411` Choosing a runtime’s model through the map writes `provider_models` directly through `settings.update`, bypassing the model connect/disconnect rule checks used by `models.attach_preview` and `models.switch_preview`. Under a deny rule, the user can still change this map choice; Ask AI has no equivalent provider-choice operation. Its Undo is a settings snapshot, rather than the connection backup.

22. **Low** `packages/maprisma_core/lib/src/agent_badges.dart:125` API spending produces `kind: cost`, containing a monetary label rather than remaining charge. `AgentBadge` renders this as text (`flutter_app/lib/map_groups.dart:397`). An API-paid agent therefore never receives the requested battery representing today’s remaining budget, even when its costs and daily limit are known.

23. **Low** `flutter_app/lib/map_legend.dart:94` The legend fixes yellow at a quarter remaining and red below a tenth, while actual agent and GPU badge colours use configurable Settings › Costs thresholds. After changing those thresholds, the legend contradicts the cards; even at defaults, exactly ten percent remaining is red in the implementation.

### 1. Manual actions and Ask AI

Paths below are relative to the repository. “Shared” means the checked core operation is shared; it does not imply identical presentation. UI navigation and layout controls are identified separately from changes to the AI setup.

| Action | Menu path (file:line) | Ask AI path (file:line) | Same route and preview? | Same rule check, review card, Undo? | Gap |
|---|---|---|---|---|---|
| Agent details | Map click/Open; `main.dart:3016`; `map_editor.dart:896` | Agent lookup/redirect; `smart_card.dart:612` | No structured details-opening candidate | Read-only; different presentation | Ask AI describes/redirects |
| Agent install/update/remove | Details; `agent_details_view.dart:96`; missing card `map_groups.dart:227` | `smart_card.dart:612`; `core.dart:3344` | Shared `agents.action_preview/apply` | Same operation checks; lifecycle review, no general rollback | Covered |
| Agent login/logout | Cloud drag; `main.dart:4201`, `main.dart:4042` | `smart_card.dart:622`; `core.dart:3344` | Shared agent-action route, but cloud destination discarded | Agent connect/disconnect checks; login is not connection Undo | F1, F14, F17 |
| Verify/test question | Details; `agent_details_view.dart:102`; guide `main.dart:3322` | Agent prompt `smart_card.dart:612` excludes verify | No | Manual start check and action review only | F15 |
| API-key entry | Details; `agent_details_view.dart:101` | No structured candidate; `smart_card.dart:612` | No | Manual `agents.key_preview/apply` only | F15 |
| Security changes | Details; `agent_details_view.dart:114` | No structured candidate | No | Manual `agents.security_preview`, agent-update rule, connection backup | F15 |
| Configure/start/halt | GUI action dispatcher; `main.dart:3311`; action rules `action_rules.dart:311` | Agent prompt explicitly excludes running/settings; `smart_card.dart:628` | No equivalent structured action | Manual routes/checks only | F15 |
| Agent ↔ local runtime | Drag/Connect; `main.dart:4205`; Connections `provider_connections.dart:26` | `smart_card.dart:290`; `core.dart:3410` | Shared `connections.preview`; post-download params differ | Shared connection checks/backup; Ask AI uses `ConnectionReview` | F12–F14 |
| Agent ↔ online provider | Drag/Connect; `main.dart:4201` | `smart_card.dart:293`; separate login candidate `smart_card.dart:622` | Direct proposal cannot target cloud | No common target validation | F1, F14 |
| Agent ↔ MCP | Map drag; `main.dart:4205`; checkbox `connections_view.dart:492` | `smart_card.dart:935`; `core.dart:3514` | Shared `connections.preview` | Same connect check and backup; compact map review versus full review | Covered; F2 affects identity |
| Agent ↔ skill folder | Map drag; `main.dart:4205`; Connections `connections_view.dart:492` | `smart_card.dart:965`; `core.dart:3525` | Shared `connections.preview` | Same check and backup; different review density | Covered |
| Move/disconnect a line | Map edge menu/drag; `map_editor.dart:909`; `main.dart:4109` | Map-edit whitelist `smart_card.dart:181` | Shared `connections.move_preview` | Same checks and backup; compact versus full review | General path preserved |
| Repair failed connection | Map failed-line card; `main.dart:3994` | `smart_card.dart:183`; `core.dart:3484` | Shared `connections.repair_preview` | Same checks and backup | Covered |
| Forget unused MCP | Map menu; `map_editor.dart:905` | `smart_card.dart:184` | Shared `connections.forget_preview` | Same remove check and backup | Covered |
| Attach/switch online or local model | Model drag; `main.dart:4046`, `main.dart:4187` | `smart_card.dart:196`; `core.dart:3484` | Shared attach/switch preview | Same rule calculation and backup; review presentation differs | General task-050 path preserved |
| Choose runtime model without agent | Provider → model drag; `main.dart:4145` | No corresponding settings-choice candidate | Manual `settings.update` only | No model-action rule; settings Undo | F21 |
| Disconnect several local models/users | Individual map lines; `main.dart:4109` | `smart_card.dart:1332`; `core.dart:3537` | Ask AI uses `modelsDisconnect` | Extra unload operation; incomplete runtime Undo | F16 |
| Runtime install/update/start/stop | Providers page `providers_view.dart:132`; runtime controls in `main.dart:2165` | `smart_card.dart:705`; GUI handoff `main.dart:2163` | Ask AI opens the manual operation | Same downstream operation checks/review | Covered |
| Runtime performance/context/GPU tuning | Providers `providers_view.dart:169` | `smart_card.dart:713`; `main.dart:2178` | Opens shared Performance page | Same downstream tuning preview/checks | Covered |
| Import/load/unload model | Providers `providers_view.dart:182`, `providers_view.dart:251` | Models prompt `smart_card.dart:493` has no such action | No structured equivalent | Manual provider-operation checks only | F15 |
| Download/find fitting model | Providers `providers_view.dart:207` | `smart_card.dart:493`, `smart_card.dart:1280` | Common provider operation after different selection/review | Install checks shared; Ask AI has fit/download review | Post-download F12/F13 |
| Remove model | Providers `providers_view.dart:290` | `smart_card.dart:1374`; `core.dart:3360` | Shared `models.remove_preview/apply` | Same remove checks and removal review | Covered |
| Move model folder | System/folder route; `core.dart:3378` | Example `map_smart_card.dart:193`; `smart_card.dart:1313` | Shared `system.move_preview/apply` | Same move check and move Undo | Covered statically |
| Author MCP/skill connection | Connections `connection_authoring.dart:96` | MCP search/connect; `smart_card.dart:935`, `smart_card.dart:998` | Search can reach option preview; no equivalent arbitrary authoring form | Different preparation, shared connection backup | Arbitrary manual authoring has no structured Ask AI equivalent; F15 |
| Find installed MCP/apps; look inside/unpack/update | Connections `connections_view.dart:121`, `connections_view.dart:139`, `connections_view.dart:170`, `connections_view.dart:191` | MCP prompt `smart_card.dart:552` | No explicit found-scan/unpack candidate | Manual discovery/update routes only | F15 |
| Find existing AI/reconnect/reuse folder | Providers `providers_view.dart:85`; Found `found_on_pc_view.dart:69`, `found_on_pc_view.dart:117` | No `existing.*` candidate in whitelist `smart_card.dart:181` | No | Manual existing preview and backup | F11, F15 |
| Add-ons: details/switch/install/update/remove | Node right-click `main.dart:1337`; sheet `main.dart:1349`; missing `map_groups.dart:227` | Agent/runtime lifecycle candidates concern programs, not add-on lifecycle | No add-on-management candidate | Different routes and rules | F15 |
| Dashed “Not installed” cards | Install, add-on details, switch off; `map_groups.dart:227`; dispatcher `main.dart:1214` | Install through agent/provider candidates | Install shared; details/off not shared | Shared program preview; add-on choices separate | F15 for add-on choices |
| Add cards | Connections/catalog/authoring; `map_editor.dart:1573`; `connections_view.dart:347` | MCP search/skill connect/model search | Partial | Depends on selected manual operation | Authoring/discovery gaps above |
| Box menu/right-click | Connect, up/down, Open, Actions, Move, Forget and edge operations; `map_editor.dart:799`, `map_editor.dart:864` | Map-edit whitelist covers connection changes | Setup changes partially shared | Layout changes have no setup-rule/Undo equivalent | Layout/navigation only; functional gaps above |
| Category/group controls | Collapse, used-only, move category; `map_editor.dart:1489`, `map_editor.dart:1509`, `map_editor.dart:1528` | No layout candidate | No | GUI layout settings | UI-only |
| Guide/welcome | Look, skip, agents; `map_welcome.dart:151`; guide `main.dart:3311` | Agent/provider/model tasks | Shares install/login/download operations; verify/tool setup not fully covered | Guide is navigation plus manual actions | F15 |
| Header/Help | AI map, move Undo, problems, Ask AI, legend, Help, Settings, Refresh; `main.dart:5155`; Help `main.dart:2702` | Lookup/redirect/general task `smart_card.dart:1470` | No equivalent navigation commands | Read-only navigation except selected follow-on actions | UI-only |

The task-050 map-edit whitelist, route dispatch and rule rechecks remain present at `smart_card.dart:181`, `core.dart:3310` and `core.dart:3484`. Its previously closed provider-model parameter findings are not repeated here.

### 2. Existing installations

Detection references used below:

- **A:** `agent_catalog.dart:259` — own installer/version, own wrapper, mise and system PATH branches.
- **B:** `agent_catalog.dart:272` — package detection and package-only restriction.
- **E:** `first_agent.dart:464` — temporarily load available add-ons for detection; `core.dart:334` enables found add-ons.
- **D:** `core.dart:324`, `core.dart:2050` — `addons_off` preserves explicit switch-off and setup decline.
- **G:** `map_graph.dart:300` — installed agents; `map_graph.dart:471` MCP/skills; `map_graph.dart:490` installed local runtimes.
- Installation mechanisms not declared by an adapter can still be detected through host PATH/own-wrapper detection, except the restrictions identified below. A Flatpak-only installation with no host executable or recognized host data directory has no generic detection path.

| What can already be on a PC | How found (file:line) | Add-on switched on? | Map and lines | After decline stays off? | Gap |
|---|---|---|---|---|---|
| Antigravity: mise, own installer, npm/bun/system executable, own wrapper | A; `adapters/agy.toml:24` | E, if detected | Agent → Google; log-derived model | D: yes | No generic Flatpak probe |
| Bionic: own installer, system executable or wrapper | A; `adapters/bionic.toml:18` | E | Agent → LM Studio; no persisted model reader | D: yes | Model unknown |
| Claude: mise, npm/bun global, system/AUR executable, own installer/wrapper | A; `adapters/claude.toml:13` | E | Anthropic plus settings/session model | D: yes | F5, F10 |
| Codex: mise, npm/bun global, system/AUR executable, own wrapper | A; `adapters/codex.toml:19` | E | OpenAI plus setting/session/cache model | D: yes | Custom-provider F4 |
| Copilot: mise, npm/bun global, system executable, own wrapper | A; `adapters/copilot.toml:13` | E | GitHub Copilot plus configured model | D: yes | No session fallback |
| Crush: mise, npm/bun global, system executable, own wrapper | A; `adapters/crush.toml:12` | E | Agent, MCP/skills; no persisted provider/model chain | D: yes | F9 |
| Cursor: mise, own installer/system executable, own wrapper | A; `adapters/cursor-agent.toml:15` | E | Cursor plus configured model | D: yes | No session fallback |
| dsh: own installer, mise/system executable or wrapper | A; `adapters/dsh.toml:15` | E | Profile provider/model, MCP/skills | D: yes | F4/F6 |
| Gemini: mise, npm/bun global, system executable, own wrapper | A; `adapters/gemini.toml:13` | E | Agent → Google; no persisted model | D: yes | F9 |
| Goose: mise release, system/package executable, own wrapper | A; `adapters/goose.toml:15` | E | Configured provider/model and MCP/skills | D: yes | Native local config read, but no `[local_llm]` editor |
| Grok: mise/npm/bun global, system executable, own wrapper | A; `adapters/grok.toml:13` | E | Agent → xAI; no persisted model | D: yes | F9 |
| Hermes: pacman/AUR, mise/pipx; own installer or hand-made wrapper | B/A; `adapters/hermes.toml:8` | Only recognized forms | Agent/settings/local chain only after recognition | D: yes | Own/PATH forms excluded: F3 |
| Muse: mise launcher, system executable, own wrapper | A; `adapters/muse.toml:10` | E | Agent → Meta; no persisted model | D: yes | F9 |
| Oh My Pi: mise, npm/bun/system executable, own wrapper | A; `adapters/omp.toml:14` | E | Settings/YAML local chain | D: yes | F4/F6 |
| OpenClaw: pacman/AUR; npm/bun global, own installer or wrapper | B; `adapters/openclaw.toml:8` | Only pacman-recognized form | Settings chain only when recognized | D: yes | Other forms excluded: F3 |
| OpenCode: mise, npm/bun/system executable, own wrapper | A; `adapters/opencode.toml:15` | E | Config provider/model and MCP/skills | D: yes | F4/F6 |
| Pi: mise, npm/bun/system executable, own wrapper | A; `adapters/pi.toml:20` | E | Settings provider/model and MCP/skills | D: yes | F4/F6 |
| llama.cpp installed/running/stopped/user unit/custom port | `provider_scans.dart:288`; units `provider_scans.dart:144` | E when installed | Runtime and scanned models; configured agent lines | D: yes | Custom port detected by runtime but not joined reliably: F4 |
| Ollama installed/running/stopped/user unit/custom address | `provider_scans.dart:340` | E when binary/unit recognized | Runtime, manifest models, agent lines | D: yes | F4; unrecognized install outside PATH/unit not detected |
| LM Studio installed/running/stopped | `provider_scans.dart:372` | E from `.lmstudio` or PATH `lms` | Publisher/index models; runtime lines | D: yes | Existing data directory alone counts as installed |
| LM Studio user unit/non-default port | `provider_scans.dart:375` | Depends on ordinary detection | Address/server check remains 1234 | D: yes | F8 |
| vLLM installed/running/stopped/user unit/custom port | `provider_scans.dart:426` | E from PATH/unit/process | Runtime and process/unit model | D: yes | Custom endpoint join F4 |
| Jan installed/running/stopped/user unit/custom port | `provider_scans.dart:460` | E from PATH/data/unit/worker | Runtime, presets/models | D: yes | Custom-port running state F8 |
| KoboldCpp installed/running/stopped/user unit/custom port | `provider_scans.dart:502` | E from PATH/unit/process | Runtime and named presets | D: yes | Command-line port supported; endpoint join F4 |
| GGUF cache/configured runtime model directories | `provider_scans.dart:219`, `provider_scans.dart:331` | Runtime-dependent | Runtime → displayed model nodes | Runtime decline respected | Display cap/missing model F6 |
| Ollama manifests/blobs, including configured model directory | `provider_scans.dart:355` | Binary/unit recognition required | Manifest names → runtime models | D: yes | Blobs alone do not establish installed runtime |
| LM Studio publisher layout/index | `provider_scans.dart:389` | Directory counts as installation | Runtime → model identifiers | D: yes | Can retain installed appearance after program removal |
| Extra GGUF folders and mounted disks | `existing_ai.dart:331`; apply `existing_ai.dart:723` | Folder reuse does not enable a runtime | Providers-folder list; no AI-map models solely from reuse | No add-on change | F11 |
| Portable runtime on another mounted installation | `existing_ai.dart:214` | Explicit reconnect preview/apply | Reconnect writes new local unit/configuration | Explicit action required | Portable program discovery supports only Ollama and llama.cpp |
| Online sign-in or environment API-key presence | Access facts; `agent_details.dart:480`; graph `map_graph.dart:368` | Online bundle detection in `first_agent.dart:484` is unconditional for multi-provider add-on | Built-in/selected providers, not evidence of authentication | D: yes | F17; presence does not establish active chain |
| Each agent’s MCP config | `inventory.dart:49`, `inventory.dart:273` | Agent must be enabled and detected installed | Agent → MCP | Agent decline respected | Different same-name servers collapsed: F2 |
| Agent-owned/shared/listed skill directories | `inventory.dart:145`, `inventory.dart:278` | Agent must be enabled and detected installed | Agent → skill set | Agent decline respected | Inventory map includes sets reached from installed agents |
| Found standalone skill folders | `found_scan.dart:940` | Discovery alone does not attach them | Found/Connections workflow; no agent line until connected | Explicit connection required | Not equivalent to automatic map inclusion |
| Prior Asterism data | `legacy_move.dart:72` | Migrated settings govern enabled state | Normal detection after migration | Saved off-state governs | Migration execution not tested |

`setup.later` only marks setup complete (`core.dart:1998`); it does not record the detected add-ons as declined. Explicit unticking through Apply records declines. I did not classify Skip/Later as an explicit per-add-on decline.

### 3. Agent → provider → model

Common graph rules: built-in cloud mapping at `map_graph.dart:368`; local configuration lines at `map_graph.dart:334`; choices at `map_graph.dart:138`; running instances at `map_graph.dart:431`. Local editors are the six adapter-driven transforms in `llm_plans.dart:486`. All adapters can receive a running-model observation from `--model`; `-m` requires the adapter flag (`activity_readers.dart:128`).

| Agent | Own online provider | Persisted model source | Map model choices | Local LLM and how | Chain drawn today | Gap / Python comparison |
|---|---|---|---|---|---|---|
| agy | Google | Newest selected-model log; `agent_details.dart:428` | Current model only | No `[local_llm]` | agy → Google → log model | New reader and empty-details add-on merge present; inspected normalization matches Python |
| bionic | None; fixed LM Studio | No persisted model; reader adds runtime, `agent_details.dart:426` | None | Fixed LM Studio; no editable connector | bionic → LM Studio; runtime inventory models | No default model association |
| claude | Anthropic | Setting, then session; `agent_details.dart:208`, `agent_details.dart:454` | fable/opus/sonnet plus current | No editor; custom local base URL is read | Anthropic/current models; local endpoint can also appear | F5/F10; Python alias/tail fallback differs |
| codex | OpenAI | Setting/provider; newest session; priority cache fallback, `agent_details.dart:218`, `agent_details.dart:473` | Listed cache slugs plus current | No `[local_llm]`; existing provider endpoints read | OpenAI or selected provider → model | Inspected setting/cache mapping matches reference; F4 for local endpoint |
| copilot | GitHub Copilot | `config.json` model; `agent_details.dart:316` | Current only | None | Copilot → GitHub Copilot → configured model | Inspected config mapping matches reference |
| crush | None | Nothing in details reader | None | No `[local_llm]` | Agent without persisted provider/model chain | F9; session-cost reader does not supply graph model |
| cursor-agent | Cursor | CLI config displayName/modelId; `agent_details.dart:318` | Current only | None | Cursor → configured model | Inspected config mapping matches reference |
| dsh | None | Profile defaults/providers; `agent_details.dart:351` | Profile models and own-install built-ins | Profile YAML transform | Selected cloud/local chain and offered cloud choices | F4/F6; field mapping inspected against reference |
| gemini | Google | Nothing in details; sessions exist separately | None | None | Gemini → Google | F9; absent reader also absent from reference adapter |
| goose | None | Active provider and its model/YAML legacy fields; `agent_details.dart:365` | Current only | Existing local settings read; no `[local_llm]` editor | Config-selected provider/model | Field mapping inspected; manual map connector cannot create the native local configuration |
| grok | xAI | Nothing in details | None | None | Grok → xAI | F9 |
| hermes | None | YAML selected provider/model; `agent_details.dart:324` | Configured provider models | YAML providers/model transform | Selected cloud/local chain | F3/F4/F6; mapping inspected against reference |
| muse | Meta | Nothing in details | None | None | Muse → Meta | F9 |
| omp | None | Settings/config.yml and models.yml via Pi reader; `agent_details.dart:265` | Current; graph’s generic hook handling is not an OMP YAML picker | models.yml/config.yml transform | Selected provider/model if detected and joined | F4/F6; YAML detail mapping inspected |
| openclaw | None | agents.defaults.model.primary and models.providers; `agent_details.dart:394` | Current only | openclaw.json transform | Configured provider/model | F3/F4/F6; inspected field mapping matches reference |
| opencode | None | JSON/JSONC model/providers; `agent_details.dart:241` | Configured provider models | opencode.json transform | Selected cloud/local chain and cloud offers | Reader accepts JSONC; editable local file is JSON |
| pi | None | settings.json and models.json; `agent_details.dart:265` | Configured provider models | models.json/settings.json transform | Selected cloud/local chain and cloud offers | F4/F6; inspected field mapping matches reference |

| Required case/path | Checked behavior | Result |
|---|---|---|
| Online only | Built-in provider or qualified model provider creates cloud and model nodes | Works when a reader supplies model; F9 otherwise |
| Local only | Local endpoint must resolve to a visible runtime name; model qualifier must match configured provider name | F4/F5/F6 |
| Both configured | Provider `active` selects `uses` versus `available`; qualified model determines default | Inactive local connections remain visible; custom/unqualified cases can misattribute model |
| Runtime stopped | Installed runtime still receives a stopped card and scanned models | Configuration line can remain visible |
| Runtime not installed | A known configured runtime can get a missing runtime node through the agent-provider loop | Models are generated only for installed runtimes; complete chain unavailable |
| Different port | Runtime scan can learn llama.cpp/Ollama/vLLM/KoboldCpp address | Detail-to-runtime join fails independently; LM Studio/Jan also F8 |
| Model removed from disk | Referenced model absent from node set | Edge silently removed: F6 |
| Provider’s chosen model | GUI overlays valid `provider_models`; `map_layout.dart:638` | Choice retained only while served node exists; manual setting path F21 |
| Two running instances, distinct qualified models | Running models accumulated separately; `map_graph.dart:431` | Separate model usage labels; unqualified local instances F7 |
| No details reader | No generic setting/session fallback | F9 |
| Signed add-on versus built-in | Empty newer facts, including `details`, filled from own adapter; `addons.dart:452`, `addons.dart:480` | Task-062 agy reader reaches an older add-on with no details table |
| Drag local connection | Shared preview; chosen provider model can set `use_now: true` | Normal configuration chain, subject to graph defects |
| Ask AI direct map edit | Whitelisted manual preview dispatched again with rules enforced; `core.dart:3484` | Task-050 shared route remains |
| Ask AI post-download connection | Helper-based agent list; `use_now: false` | F12/F13 |
| Providers/Connections | Explicit local model and use-now controls; `provider_connections.dart:47` | Same local planner when parameters match |
| Guide | Install/login/verify dispatch or opens Providers/Connections; `main.dart:3311` | No separate graph-building implementation |
| Disconnect/Undo | ConfigFiles backs up affected files and checks subsequent changes; `connect_apply.dart:9` | Runtime operations excluded from rollback: F16; online logout F17 |

### 4. Batteries, costs and limits

Common paths:

- **L:** usage record → `agent_details.dart:480`, limits at `agent_details.dart:501` → `core.dart:2708`.
- **C:** billing classification `costs.dart:156` → session costs `usage_readers.dart:45` → `core.dart:2729`.
- **GPU:** `model_guard.dart:114` → `core.dart:4602` → `_gpuBadges`, `main.dart:1929`.
- Collector lookup is `agent_details.dart:82`; Maprisma itself need not decode credentials to invoke an agent-owned API or read session statistics.
- An arbitrary valid collector can technically provide limits for any command. “No source confirmed” below means no agent-specific limit source was established in this offline review.

| Adapter / local LLM | Limits or costs; possible source | What Maprisma reads today (file:line) | Battery drawn and conditions | Possible without Maprisma reading credentials? | Gap |
|---|---|---|---|---|---|
| agy | Google-account limits, per supplied context; exact quota interface unconfirmed | L only; no sessions/replies reader | Only if discoverable collector supplies limits | Possible in principle through agent API/collector; concrete source unconfirmed | No agy collector/fallback established |
| bionic | Local inference; no online plan identified | LM Studio provider reader `agent_details.dart:426` | No agent plan/cost battery | Yes for runtime GPU | Runtime battery applies to LM Studio |
| claude | Plan limits through supplied collector; session API-value/cost data | L/C; sessions/replies adapter facts | Plan battery with valid limits; cost text when API billing recognized | Yes: collector handles authentication; session costs need none | F10/F20/F22 |
| codex | Plan limits through app-server RPC; native session tokens | L/C; sessions `session_readers.dart:229` | Plan battery only through discoverable collector record | **Yes**, agent-owned RPC; collector source confirms it | COSMIC F18; stale F20 |
| copilot | Account limits; no specific offline quota source confirmed | L; no sessions reader | Collector limits only | Unconfirmed for current quota source | No built-in quota acquisition |
| crush | Agent-reported session costs | C; `adapters/crush.toml:16`; `usage_readers.dart:45` | Cost text when billing presence recognized; no charge battery | Yes, session database and presence check | F22 |
| cursor-agent | Account limits; no specific offline quota source confirmed | L; no sessions reader | Collector limits only | Unconfirmed | No built-in quota acquisition |
| dsh | API-token costs from sessions | C; dsh-files reader | Cost text if billing presence recognized | Yes | F22 |
| gemini | Google account or API billing; session token source | L/C; `adapters/gemini.toml:17` | Environment-key API costs can show as text; plan needs collector | Yes for session cost; account-limit interface unconfirmed | No native plan acquisition; F22 |
| goose | Provider-dependent API costs; session database | C; `adapters/goose.toml:23` | Cost text with recognized environment billing or usage record | Yes | Internally configured billing without record is not enough; F19 mechanism |
| grok | Supplied Omarchy collector; API key billing | L; no native sessions reader | Plan/limit battery if collector provides it; native session cost unavailable | Collector can isolate credential handling | No portable native collector replacement |
| hermes | Session database tokens/API-value | C; `session_readers.dart:579` | No cost badge for internal API billing without usage record | Yes for session costs | F19 |
| muse | No local cost/quota reader established | L only | Collector limits only | Unconfirmed | No confirmed native source |
| omp | client_usage database tokens/cost calculation | C; `session_readers.dart:430` | No cost badge for internal API billing without usage record | Yes for session costs | F19 |
| openclaw | Session-reader API costs | C; `adapters/openclaw.toml:27` | No cost badge for internal API billing without usage record | Yes for session costs | F19 |
| opencode | Session database tokens/API costs | C; `session_readers.dart:579` | No cost badge for internal API billing without usage record | Yes for session costs | F19 |
| pi | Session tokens/API costs | C; `adapters/pi.toml:28` | Cost text with recognized environment key; provider-account limits not acquired | Yes for session costs | F22; account quota source unconfirmed |
| llama.cpp | Free/total GPU memory, process VRAM | GPU; process classification `model_guard.dart:186` | Runtime battery when process group exists and GPU total > 0 | Yes | Device-specific correctness not exercised |
| Ollama | Same GPU source | GPU; `model_guard.dart:187` | Same conditions | Yes | No confirmed missing-battery defect |
| LM Studio | Same GPU source; own model API | GPU; `model_guard.dart:188` | Same conditions, even though inventory running detection differs | Yes | Custom-port inventory F8; GPU badge itself process-based |
| vLLM | Same GPU source | GPU; `model_guard.dart:194` | Same conditions | Yes | Process variants not exercised |
| Jan | Same GPU source | GPU; `model_guard.dart:201` | Worker group and GPU total > 0 | Yes | Non-default-port map state F8 |
| KoboldCpp | Same GPU source | GPU; `model_guard.dart:206` | Process group and GPU total > 0 | Yes | No confirmed missing-battery defect |

The supplied Kimi and Fireworks collectors do not correspond to adapters in this tree. They are not automatically shared with an agent that happens to use those providers: usage lookup is keyed by the agent command.

Agent and GPU colour computation both use `warnLevels` and `charge`; I found no divergence between those computations and Settings › Costs. The confirmed colour discrepancy is the fixed legend wording.

### Not checked

- No files were changed. No network calls, collectors, agents, installers, refresh/apply operations or GUI were executed. Tests were not run because their execution and fixtures were not audited for the requested read-only/no-network constraints.
- Credential files and key/token files were not read. No conclusions depend on their contents.
- Actual installed-program variants, Flatpak application IDs, authentication state, mount permissions, GPU hardware and live provider responses were not exercised. Installation rows describe the checked detection branches, not successful installation tests.
- Antigravity, Copilot and Cursor quota interfaces and whether their current local files contain sufficient credential-free limit data remain **unconfirmed**. Antigravity’s plan limits are supplied context; a concrete acquisition implementation was not verified.
- Reader parity was inspected for the cited field mappings and Claude’s explicit reference tests; full differential parity, session/database schema variants, transactional Undo failures and concurrent running-instance behavior were not executed.
- Complete add-on archive contents/signatures, every Help destination, all authoring-form variants, migration outcomes and every systemd unit/drop-in syntax were not exhaustively verified.
- The named pre-existing failures were not investigated or reported.
## Author answers (Claude, 2026-11-05, branch task/063-codex-review)

Fixed in four parts, each with tests that fail before and pass after (task notes `docs/tasks/063a-graph.md`,
`063b-readers.md`, `063c-batteries.md`, `063d-ask-ai.md`):

- **063a, map chain:** F1 (only the agent's own online provider signs in; other drops refused with a reason),
  F2 (same-named MCP servers with another target stay separate, `name~2`), F4 (a local endpoint matched by the
  runtime's real port), F5, F6 (used and missing models always drawn; missing ones marked), F7, F8 (LM Studio and
  Jan ports), F11 (reused model folders on the map), F17 (online line `available` when signed out; disconnecting
  a provider the agent sets itself no longer signs it out).
- **063b, readers:** F3 (`install_marks`: OpenClaw and Hermes outside their packages count when proven; Omarchy
  stubs still do not), F9 (Gemini CLI, Grok, Crush), F10 (Claude's session alias, newest file whatever its age).
  Open: Muse (where it keeps its model is not known); Gemini's and Crush's settings keys follow their published
  formats, unconfirmed on a real install.
- **063c, batteries:** F18 (`[plan_limits]`: Codex's limits from its own app-server when no collector exists),
  F20 (stale limits faded with a note, old ones without a reset expire), F19 (sessions that report money count
  as per token: Hermes, OpenCode, Crush), F22 (a cost's battery), F23 (the legend at Settings › Costs' levels).
  Open: Oh My Pi and OpenClaw costs (their sessions cannot tell a plan from API billing).
- **063d, Ask AI:** F12, F13, F14 (sign-in to the agent's own provider only), F15 (`menu_action` candidates that
  open the manual menus with their own previews; the list is in the task note), F16 (model disconnect equals the
  manual one, no unload), F21 (`models.choose_*` with rule checks and Undo). Open: no uninstall of a local LLM
  program, because the app has no manual one.

Also fixed: two fixed-table tests that tasks 061/062 left behind (`test_providers`, `test_agent_facts`).
Suites on the merged branch: core all but `dictation_test` "Omarchy readiness…"; app 318 pass; typecheck clean;
Python 1342, the 9 failures all fail on main too.

## Round 2 (Codex, 2026-11-05, commit 5a68683)

Review complete. No files changed and no network used.

1. **High** `packages/maprisma_core/lib/src/action_rules.dart:241` Suffixed MCP IDs bypass rules written against the server’s configuration name. With a deny rule for connecting MCP `filesystem`, connecting `filesystem~2` is checked against that different string; `_ruleItem` leaves it unchanged (`core.dart:4399`). The operation then writes an entry named `filesystem` (`core.dart:4201`). A connection forbidden under its actual name is therefore allowed through its new map alias.

2. **High** `packages/maprisma_core/lib/src/usage_rpc.dart:23` Native usage refresh executes the first `codex` on PATH without excluding Omarchy lazy launchers or mise shims. On a PC with a retained Codex sign-in file, a recognized mise installation and a lazy launcher first on PATH, opening Maprisma can execute that launcher automatically, potentially invoking installation/update work during a limits check. The Omarchy collector explicitly skips lazy launchers and resolves installed binaries offline; this new client omits that protection.

3. **High** `packages/maprisma_core/lib/src/core.dart:2152` Tool queries still accept only unsuffixed MCP names and choose the first agent containing that name. Although `details.mcp` resolves `filesystem~2`, its response exposes the raw `filesystem` name (`core.dart:799`), and cached tools are also keyed by that name. Inspecting/testing the second server can consequently show the first server’s tools or start the first server’s command. Passing the suffixed ID directly instead is rejected by the name regex.

4. **Medium** `packages/maprisma_core/lib/src/inventory.dart:258` MCP separation compares redacted display targets, not server identity. `serverTarget` reduces URLs to their hostname and commands to a basename or short launcher/package label. Thus `https://example.test/a` and `https://example.test/b`, different ports on the same host, or the same executable with different arguments still merge under one card. F2 remains reproducible for distinct configurations whose display labels coincide.

5. **Medium** `packages/maprisma_core/lib/src/core.dart:3299` Ask AI still groups MCP candidates by raw name and unions agents by that name. With `filesystem` and `filesystem~2`, it cannot choose the second server: a connect candidate reaches `connections.preview` with the unsuffixed ID and selects the first variant. In addition, inventory deliberately excludes suffixed variants from the remembered MCP library (`inventory.dart:333`), so disconnecting the last user of the second variant loses its definition instead of retaining a reusable unused server.

6. **Medium** `packages/maprisma_core/lib/src/map_edits.dart:458` A newly retained missing-model card cannot be replaced through the provider’s model hook. For example, an agent defaults to deleted model `gone`, and the user moves its provider/model line to available model `qwen`. The switch rejects the operation because the *old* model is absent from `rt.models`. The map now preserves the broken chain, but its normal replacement action cannot repair it.

7. **Medium** `packages/maprisma_core/lib/src/core.dart:4497` `models.choose_preview` accepts a model marked `missing`: it checks its node kind and `serves` edge, both deliberately created for missing models, but not its status or current runtime inventory. Ask AI’s choice validator has the same omission (`smart_card.dart:662`). It can therefore offer and save a provider’s choice of a deleted model that the map refuses as a drop target. Apply also checks only whether the saved choice changed, so deletion between Preview and Apply is not detected.

8. **Medium** `flutter_app/lib/main.dart:4187` Switching a provider’s chosen model when it has agent users still updates `provider_models` through `settings.update`, outside the connection backup. After switching X → Y and pressing the connection’s Undo, the agents return to X while the provider remains set to Y. Ask AI’s shared `models.switch_preview` path does not perform this GUI settings update either. F21 fixes the choice without users, but leaves this second choice-changing path inconsistent.

9. **Medium** `packages/maprisma_core/lib/src/provider_scans.dart:72` Endpoint matching falls back to the usual-port runtime even when that runtime’s detected address contradicts the configuration. With llama.cpp detected on 9090 and an agent still configured for 8080, the first match fails and the fallback nevertheless returns llama.cpp. Both the graph and `rt.agents` show a valid connection to the moved server instead of exposing the stale endpoint.

10. **Medium** `packages/maprisma_core/lib/src/agent_catalog.dart:257` Installation marks expand `~/` to an absolute path before searching wrapper text, but do not recognize shell home references. A valid wrapper such as `exec "$HOME/.openclaw/bin/openclaw" "$@"` contains neither the expanded absolute marker nor `/node_modules/openclaw/`, so the installed agent remains undetected. The tests cover absolute-path wrappers, not this ordinary hand-made wrapper form.

11. **Medium** `packages/maprisma_core/lib/src/inventory.dart:397` Reused-folder models are suppressed by normalized model name across all installed runtimes, without checking file identity or directory. If a runtime lists `qwen-Q4_K_M` and a different reused folder contains `qwen-Q8_0.gguf`, both normalize to `qwen`; the reused file disappears from the map. Applying “Reuse model folder” still fails to reflect distinct files in this neighbouring F11 case.

12. **Medium** `packages/maprisma_core/lib/src/usage_readers.dart:101` A positive session cost is now treated as evidence of API billing, but Hermes’s reader obtains that value from `COALESCE(actual_cost_usd, estimated_cost_usd)` (`session_readers.dart:585`). A session containing only an estimated API value can therefore classify Hermes as paid per token and produce a daily-budget battery without evidence of an actual charge. The reason given for withholding OMP/OpenClaw billing inference also applies to this estimated-cost fallback.

13. **Medium** `packages/maprisma_core/lib/src/agent_details.dart:847` Native Codex limits require a file under the fixed home-relative `access.files` path. A signed-in Codex using its supported keyring store, or a relocated `CODEX_HOME` without `~/.codex/auth.json`, is never queried and still receives no battery. The supplied Omarchy collector recognizes non-file stores before asking Codex. The app can do the same using non-secret configuration and Codex’s RPC, without decoding credentials.

14. **Medium** `packages/maprisma_core/lib/src/agent_details.dart:819` Native usage records remain readable after sign-out, while `planLimitsRpc` becomes unavailable once the sign-in file disappears. Consequently logout can change the map line to `available` while the badge and details continue showing the previous account’s plan and limits as current. Removing the sign-in file does not invalidate or stale the cached record immediately.

15. **Medium** `flutter_app/lib/main.dart:5097` The minute timer reloads badges but never refreshes their native usage source. Native Codex limits are requested at startup and when details refresh, so leaving the map open without opening an agent’s details never renews them. The battery eventually fades or disappears at its reset despite a working app-server being available.

16. **Medium** `packages/maprisma_core/lib/src/map_graph.dart:113` An adapter with no sign-in files is unconditionally considered signed in, even when it declares environment credentials that are absent. Grok without `XAI_API_KEY` therefore gets a `uses` line while readiness checks report missing access. The map also accepts its own-provider drop through `MapLayout.ownProvider`, although Grok has no registered login action; Ask AI correctly refuses that action. The provider identity agrees, but action availability and sign-in state do not.

17. **Medium** `packages/maprisma_core/lib/src/agent_badges.dart:24` Limits with no usable measurement timestamp never become old: `_tooOld` returns false when `measured_at` is null. A legacy record with no `updatedAt`/`limitsFetchedAt`, no reset and no explicit stale flag therefore keeps a normal battery indefinitely. The F20 fix handles dated old records, but not records whose age is unknown.

### F1–F23 verdicts

“Fixed” below refers to the original case, with neighbouring limitations identified explicitly.

| Finding | Verdict | Code check and remaining scope |
|---|---|---|
| F1 — wrong online-provider login | **Partly fixed** | `own_provider` now guards layout, refusal messages and `_mapEdit`. Foreign-provider login is blocked. Own-provider action availability still differs from Ask AI: #16. |
| F2 — same-name MCP collapse | **Partly fixed** | Different display targets receive suffixes and graph edges follow them. Full identity, rules, Ask AI, tools and library preservation remain inconsistent: #1, #3–#5. |
| F3 — non-package installations | **Partly fixed** | `install_marks` allows recognized upstream/npm/pipx paths, while retaining package restrictions. Ordinary `$HOME` wrappers remain missed: #10. |
| F4 — custom-port identity | **Partly fixed** | Detected ports now feed both graph and inventory matching. Contradictory-address fallback remains: #9. |
| F5 — local endpoint attributed online | **Fixed** | One active local provider supplies the qualifier for an otherwise unqualified configured model (`map_graph.dart:361`). |
| F6 — capped/missing models | **Partly fixed** | Default, running and provider-chosen inventory models are retained beyond the cap; missing configured models retain nodes and lines. Replacement/choice validation remains inconsistent: #6–#7. |
| F7 — unqualified running model | **Fixed** | Running instances inherit the configured provider before local/cloud resolution (`map_graph.dart:455`). |
| F8 — LM Studio/Jan ports | **Fixed for implemented formats** | LM Studio’s server configuration and Jan’s service/router port now drive addresses. Actual installation formats remain unconfirmed offline. |
| F9 — absent readers | **Partly fixed** | Gemini, Grok and Crush readers exist in Dart and Python. Muse remains open; live Gemini/Crush format compatibility is unconfirmed. |
| F10 — Claude session fallback | **Fixed** | Dedicated newest-file search, age-independent tail read, aliases and cache now match the inspected reference behavior. |
| F11 — reused model folders | **Partly fixed** | Settings reach inventory and folder model cards. Name-based suppression can hide distinct files: #11. |
| F12 — wrong post-download agents | **Fixed** | Download candidates carry installed local-connector agents; GUI uses that list and core validates it (`core.dart:3498`). |
| F13 — connection not activated | **Fixed** | Post-download connect now uses `use_now: true` (`core.dart:3504`), matching the equivalent manual connection. |
| F14 — Ask AI online connection | **Fixed for supported logins** | `smartCloudSignIn` validates `own_clouds` and produces the existing login/logout action preview. Availability mismatch on the map remains #16. |
| F15 — menu coverage | **Fixed for the documented handoffs** | Verify uses the agent preview; new menu candidates reach manual handlers. Navigation candidates open the appropriate selection workflow rather than applying an unspecified item. Local-program uninstall is absent on both sides. |
| F16 — disconnect unload/Undo | **Fixed** | `modelsDisconnect` now changes configuration only; the extra unload actions were removed. |
| F17 — online disconnect semantics | **Partly fixed** | Signed-out own-provider lines become `available`; foreign-provider disconnect no longer signs out the agent. Sign-in and cached-account state remain inconsistent: #14, #16. |
| F18 — Codex without collector | **Partly fixed** | Native app-server client and cache work for the file-store gate. Launcher safety, other stores and ongoing refresh remain: #2, #13, #15. |
| F19 — session-based billing | **Partly fixed, with a regression** | Money-bearing sessions can enable a badge; token-only OMP/OpenClaw remain intentionally undecided. Estimated Hermes costs are now incorrectly accepted as billing evidence: #12. |
| F20 — stale limits | **Partly fixed** | Dated stale limits fade, reset limits expire and dated reset-less limits age out. Unknown-age records and sign-out invalidation remain: #14, #17. |
| F21 — provider model rules/Undo | **Partly fixed** | New choose routes check rules and implement entry-specific Undo. Missing/stale models and the agent-user switch path remain: #7–#8. |
| F22 — cost battery | **Fixed** | Cost badges carry remaining charge; `AgentBadge` draws battery plus monetary label. |
| F23 — legend thresholds | **Fixed** | Legend receives Settings › Costs thresholds and uses inclusive remaining-percentage wording. |

The deliberately open cases:

- **Muse:** the reason holds. No persisted model source was established in the reviewed material. Existing command-line observation remains usable when the agent exposes `--model`. A reliable persisted-model fix needs evidence of a non-secret setting, session field or agent-owned interface; guessing a file/key would invent a fact.
- **OMP/OpenClaw billing:** the reason holds. Tokens establish API value, not whether an account was charged. A sound credential-free solution is an explicit user billing classification or trustworthy provider/agent billing metadata. It should not infer payment merely from a priced model.
- **Local LLM program uninstall:** the reason holds. There is no manual uninstall operation to mirror. Add-on removal is correctly distinguished from uninstalling the program.
- **Gemini/Crush settings formats:** the implementations and Python counterparts agree on the stated keys. Their agreement does not independently verify the published formats. With network and live-install checks excluded, that compatibility remains **unconfirmed**, rather than a confirmed defect.

### 1. Ask AI and menus — changed rows

Core paths below are under `packages/maprisma_core/lib/src/`; GUI paths are under `flutter_app/lib/`.

| Action | Menu path | Ask AI path | Same route and preview? | Rules, review, Undo | Remaining gap |
|---|---|---|---|---|---|
| Online-provider login/logout | `main.dart:4140`, `main.dart:4293` | `smart_card.dart:385` | Same `agents.action_preview/apply` for supported own-provider actions | Shared agent-action checks/review; authentication has no connection Undo | #14, #16 |
| MCP connect/disconnect/details/tools | `main.dart:4293`; core `core.dart:4194` | Core `core.dart:3299`, `smart_card.dart:1312` | Shared connection preview, but identities differ between consumers | Alias versus raw-name checks differ | #1, #3–#5 |
| Verify | `main.dart:3647` | `smart_card.dart:919`; core `core.dart:3344` | Shared agent preview/apply | Shared start rule and action review | Original gap closed |
| API key/security/start/halt | `main.dart:2194` manual handoffs | `smart_card.dart:424` menu candidates | Opens existing manual handlers | Downstream manual routes enforce rules; keys stay outside helper input | Covered statically |
| Agent details/configure | `main.dart:2228` | `smart_card.dart:424` | Details/Connections navigation | Selected follow-on changes use manual previews | Covered as navigation |
| Add-on details/on/off/install/update/remove | `main.dart:2232` | `smart_card.dart:529`; core `core.dart:3518` | Existing add-on handlers/catalog operations | Candidate checks plus downstream manual checks | Covered for currently advertised facts |
| Model load/unload/import | `main.dart:2242` | `smart_card.dart:620` | Existing provider operation; load/unload receive a review question | Provider-operation checks rerun | Covered statically |
| Provider’s own model | `main.dart:4515` | `smart_card.dart:650` | New shared `models.choose_*` | Model connect/disconnect checks; entry-specific Undo | #7–#8 |
| Post-download connect | `map_smart_card.dart:2661`; core `core.dart:3498` | Candidate `connect` list; `smart_card.dart:1807` | Shared connection preview, now activated | Same planner and connection backup | Original F12/F13 closed |
| Find/reconnect/reuse existing AI | `main.dart:2280` | `smart_card.dart:1093` | Opens existing discovery workflow | Item selected there receives manual preview | Folder identity issue #11 |
| Found MCP/unpack/update | `main.dart:2282` | `smart_card.dart:1221` | Opens Found on this PC | Follow-on item operations retain manual checks | MCP identity issues above |
| Multi-model disconnect | Core `map_edits.dart:529` | Core `core.dart:3661` | Configuration-only plan | No additional unload; configuration Undo | Original F16 closed |
| Local LLM program uninstall | No manual operation | Explicitly excluded by `smart_card.dart:1057` | Neither side offers it | Add-on removal remains separate | Accepted scope correction |

All advertised `menu_action` area/step combinations have handlers in `_smartMenu`. I found no direct `menu_action` core apply path: GUI handoffs reach existing operations, and unsupported core action kinds are refused. Candidate filtering uses `smartMenuChecks`; downstream operations recheck their actual parameters.

### 2. Existing installations — changed rows

| Existing state | How found | Add-on switched on? | Map and lines now | Decline preserved? | Remaining gap |
|---|---|---|---|---|---|
| Hermes outside pacman | `agent_catalog.dart:295`; `adapters/hermes.toml:11` markers | Through existing setup/enable-found path when proven | Normal agent/settings chain | Yes; decline handling unchanged | `$HOME` wrappers #10 |
| OpenClaw outside pacman | `agent_catalog.dart:295`; `adapters/openclaw.toml:11` markers | Same | Normal agent/settings chain | Yes | `$HOME` wrappers #10 |
| Older signed Hermes/OpenClaw add-on | `addons.dart:470`; Python `harnesses.NEWER_FACTS` | New markers inherited when absent | Same as built-in facts | Yes | Marker limitations remain |
| Local LLM on detected custom port | `provider_scans.dart:64`; inventory `inventory.dart:282` | Existing detection path | Graph and runtime agent lists use common matcher | Yes | Contradictory fallback #9 |
| LM Studio custom port | `provider_scans.dart:398` | Existing directory/PATH detection | Configured address and listener check | Yes | Live format compatibility unconfirmed |
| Jan custom service/router port | `provider_scans.dart:487` | Existing unit/data/process detection | Detected port and running state | Yes | Unit/router variants not exercised |
| Selected/running model beyond cap | `map_graph.dart:537` | No add-on change | Retained model node; adjusted “more” count | Unchanged | Missing-model operations #6–#7 |
| Deleted configured local model | `map_graph.dart:630` | No add-on change | Missing model plus provider/default lines | Unchanged | Replacement rejected: #6 |
| Reused GGUF folder | `read_service.dart:339`; `inventory.dart:392` | Folder reuse does not enable a program | Folder model cards now drawn | Unchanged | Distinct quantizations suppressed: #11 |
| Same-name MCP variants | `inventory.dart:252` | Agent detection unchanged | Separate cards when display targets differ | Unchanged | #1, #3–#5 |
| Signed-out own online provider | `map_graph.dart:111`, `map_graph.dart:403` | Existing add-on state | Available rather than uses line | Yes | #14, #16 |

### 3. Agent → provider → model — changed rows

| Agent/case | Own online provider | Model source and choices | Local connection | Current chain | Gap / reference check |
|---|---|---|---|---|---|
| Claude | Anthropic | Settings, then cached newest-session tail and alias; `agent_details.dart:269` | Existing endpoint read | Single active local endpoint now owns unqualified model; CLI model inherits provider | Original F5/F7/F10 closed; matcher #9 |
| Gemini | Google | `model.name`/legacy model, then newest session; `agent_details.dart:574` | No new connector | Google → discovered model | Dart/Python implementations agree; live settings format unconfirmed |
| Grok | xAI | Newest usage file’s last model-usage turn; `agent_details.dart:613` | None added | xAI → discovered model | Reader agrees with inspected Python counterpart; access mismatch #16 |
| Crush | Configured provider | `models.large` and configured providers; `agent_details.dart:645` | Existing local endpoint can be read; no new editor | Configured provider → model | Dart/Python agree; live settings format unconfirmed |
| Muse | Meta | No new persisted reader | None added | Meta without persisted model | Intentionally open; no reliable source established |
| Hermes | Configured provider | Existing YAML reader | Recognized non-package installs now participate | Cloud/local chain after detection | Marker #10; billing #12 |
| OpenClaw | Configured provider | Existing defaults/provider reader | Recognized non-package installs now participate | Cloud/local chain after detection | Marker #10 |
| All adapters: own provider | `own_provider` and `own_clouds` derive from visible provider facts | Login availability additionally represented in Ask AI facts | Foreign cloud login blocked | Pair identity agrees | Availability/sign-in mismatch #16 |
| Two running local instances | Configured provider inherited for unqualified command-line models | Distinct models in runtime inventory retained beyond cap | Same matcher | Separate running-model usage labels | Original F7 closed for inspected case |
| Missing configured model | Existing runtime | Synthetic missing node | Existing provider connection retained | Provider → missing model plus default line | Cannot switch away through model hook: #6 |
| Provider’s chosen model | `provider_models` now reaches core graph | Retained beyond cap while runtime lists it | Future connections use choice | Choice routes added | Missing/stale acceptance and Undo: #7–#8 |
| Older signed adapters | Built-in newer facts fill absent fields | Includes `details`, `install_marks`, `plan_limits` | Existing connectors unchanged | New readers/native limits reach old add-ons | Python newer-fact list and inspected snapshots include both new facts |

The touched Python graph, inventory, installation and reader implementations generally mirror the Dart changes—including several remaining behaviors identified above. Agreement with the reference therefore does not establish correctness for those cases.

### 4. Batteries — changed rows

| Agent/case | Available limits/cost source | Reads now | Battery conditions | Credential-free at app level? | Remaining gap |
|---|---|---|---|---|---|
| Codex, no collector, file-store sign-in | Own app-server limits | `usage_rpc.dart:17`; native cache `agent_details.dart:123` | File-existence gate, successful RPC, current limits | Yes | Launcher #2; refresh #15 |
| Codex keyring/relocated home | Same agent-owned RPC | Gate still checks fixed home-relative access files | Often never queried | Yes; non-secret configuration plus RPC suffices | #13 |
| Codex after logout | Cached native record | `agent_details.dart:819` | Old future-reset limits remain eligible | Yes | Cache not invalidated: #14 |
| Hermes | Actual **or estimated** session cost | `session_readers.dart:585`; `usage_readers.dart:101` | Positive cost can classify API billing | Yes | Estimate mistaken for billing: #12 |
| OpenCode | Session-reported cost | `usage_readers.dart:101`; `core.dart:2738` | Positive billed amount with no plan/limits can enable badge | Yes | Actual billing interpretation not independently verified |
| Crush | Session-reported cost | Same cost aggregation | Cost battery when billing recognized | Yes | Live store semantics not exercised |
| OMP | Token-based API value | Existing sessions reader | No new billing inference | Yes for estimates | Intentionally open: billing mode unknown |
| OpenClaw | Token-based API value | Existing sessions reader | No new billing inference | Yes for estimates | Intentionally open: billing mode unknown |
| Every API-cost badge | Daily cost versus configured budget | `agent_badges.dart:159` | Battery plus monetary label when budget > 0 | Yes | F22 closed |
| Every plan-limit badge | Measurement/reset/stale metadata | `agent_badges.dart:22` | Old dated limits fade; passed resets expire | Yes through records/agent APIs | Unknown-age records #17 |
| All six local LLM GPU badges | Existing GPU/process source | Existing GPU path | Same runtime/GPU conditions as before | Yes | No new GPU acquisition change |
| Legend | Settings › Costs thresholds | `main.dart:5364`; `map_legend.dart:8` | Configured inclusive thresholds and stale illustration | Yes | F23 closed |

The native RPC sends initialization and account-limit/account-read requests, not a model prompt. Its stdout has a 1 MiB bound, answer/overall deadlines are present, and normal/error/timeout paths enter process cleanup. Actual descendant-process termination was not executed.

### Not checked

- No GUI, agents, collectors, installers or provider APIs were executed. No credential/key/token files were read.
- Behavioral suites were not run; conclusions are code-checked rather than runtime reproductions. The listed known failures were not reported.
- `python3 -B tools/protocol.py check` passed, including generated protocol documentation/client consistency.
- All eight generated translation files contain all 860 keys declared by `tools/flutter-assets.py`.
- `python3 -B docs/manual/translations.py check` fails for `map` in all seven translated manuals. The starting commit already had stale `map` stamps, so this is recorded as an outstanding validation issue, not a new regression.
- The inspected adapter snapshots include the new installation marks, Codex plan-limit facts and new reader flags. Full generated-asset and differential parity suites were not executed.
- Live Gemini/Crush/LM Studio settings compatibility, Muse’s persisted model source, account billing semantics, every Jan unit variant, and real process-group cleanup remain **unconfirmed**.