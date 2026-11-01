## Design discussion (Antigravity, 2026-11-01)

Draft reviewed: `/mnt/Data/Projects/maprisma-claude/docs/tasks/019-action-rules.md`

---

### 1. Combining logic: "most specific rule wins, on a tie allow wins"

#### Where I agree
 Claude correctly identifies "the trap": if `"allow all"` is written out as explicit default rules (`allow <action>, *, *, *`) and any `allow` globally overrides any `deny` (classic XACML `permit-overrides`), then **no `deny` rule can ever take effect** unless the user first deletes the default `allow` rule ([What is a XACML combining algorithm?](https://www.webfarmr.eu/tgif-xacml-whats-a-xacml-combining-algorithm/)).

Conversely, global `forbid-overrides-permit` as in [AWS Cedar](https://docs.cedarpolicy.com/auth/authorization.html) and `deny → ask → allow` evaluation in [Claude Code permissions](https://code.claude.com/docs/en/iam) ([How allow, ask and deny compose in Claude Code](https://dev.to/ottoflightrules/claude-code-permissions-how-allow-ask-and-deny-actually-compose-3kme)) treat `deny` as an absolute floor that no narrower `allow` can ever override (Cedar can only carve out exceptions inside the `forbid` policy itself via an `unless` clause; Claude Code cannot carve out a narrower `allow` over a broader `deny` at all). And top-to-bottom `first-applicable` ordering as in classic firewalls ([Abiquo classic firewall rules](https://abiquo.atlassian.net/wiki/spaces/ABI54/pages/310739306/GUI+Create+classic+firewall+rule)) breaks down as soon as rules are split into two separate **Allow** and **Deny** lists, where rule shadowing is a well-known user complaint ([Wilders Security firewall UI complaints](https://www.wilderssecurity.com/posts/1602589)).

Therefore, **order-independent specificity precedence with `allow` winning ties** is the right family of algorithm for Uwe's requirements.

#### Where I disagree: counting non-`*` fields (`0..4`) produces unexpected results
Counting how many of `(action, category, item, agent)` are not `*` treats all four fields as equal weight (`1` point each). Because the default rules already have `action != '*'` (`1` point), and because `item` (an instance) and `agent` are orthogonal, **unweighted field counting fails on real requests users will write**:

1. **Request 1 — A category or agent deny across "all actions" (`action: *`) loses to the default rules:**
   - Uwe's prompt says: *"Actions such as install, remove, update, connect, reconnect, for one or all categories. ... A scope picker: all, a category, an instance."*
   - Suppose a user adds a rule in the Deny list: `deny, action: *, category: skills, item: *, agent: *` (*"Deny all actions on skills"*) or `deny, action: *, category: *, item: *, agent: pi` (*"Deny all actions for Pi"*).
   - That `deny` rule has **1 field set** (`category = skills`, or `agent = pi`).
   - Every default rule (`allow, action: disconnect, category: *, item: *, agent: *`) **also has 1 field set** (`action = disconnect`).
   - When a request `(disconnect, skills, ~/.agents/skills, claude)` arrives, the default `allow` (`1` field) and the user's `deny` (`1` field) **tie at `1 == 1`**, and because **on a tie allow wins**, the default `allow` beats the user's `deny`! Any 1-field `deny` with `action: *` is **completely dead out of the box**.

2. **Request 2 — Protecting one specific skill folder (`item`) loses to a general agent exception (`agent`):**
   - Start with Uwe's example:
     - `deny, action: disconnect, category: skills, item: *, agent: *` (**2 fields**)
     - `allow, action: disconnect, category: skills, item: *, agent: pi` (**3 fields**: `action, category, agent` — Pi may disconnect skills).
   - Now the user wants to protect one specific shared skill folder (`~/.agents/skills`) so **no** agent—not even Pi—disconnects it:
     - `deny, action: disconnect, category: skills, item: ~/.agents/skills, agent: *` (**3 fields**: `action, category, item`).
   - Request: disconnect `~/.agents/skills` from `pi`.
   - Both the general Pi rule (`action + category + agent = 3`) and the specific instance rule (`action + category + item = 3`) have **3 fields set**. They tie (`3 == 3`), `allow` wins the tie, and **Pi disconnects the specifically protected `~/.agents/skills` folder**. Users universally expect a rule naming a specific **instance (`item`)** to be more specific than a rule naming only a **category + agent**.

3. **Request 3 — Deleting a default `allow` rule still allows the action ("No match is allow"):**
   - Line 21 of the draft says: *"No match (a user deleted the defaults) is allow, as Uwe's default says."*
   - If the UI shows `[Allow disconnect, all]` in the Allow list with a delete button (`×`), a user who clicks `×` to delete `[Allow disconnect, all]` does so because they want `disconnect` to **stop** being allowed. If "no match is allow", deleting `[Allow disconnect, all]` removes the row from the screen while **still allowing all disconnects**!

#### Comparison of alternatives

| Approach | How it resolves conflicts | Handles Uwe's Pi example? | Handles `action: *` deny & `item` vs `agent`? | Assessment |
|---|---|---|---|---|
| **A. Unweighted field count** *(Claude's draft)* | `score = count(f != '*')`; highest score wins; tie → `allow` | Yes (`3 > 2 > 1`) | **No** — `deny, *, skills` (`1`) ties with default `allow disconnect, *` (`1`) and loses; `item` (`3`) ties with `agent` (`3`) and loses to `allow` | Too coarse; causes silent dead rules and instance-vs-agent surprises. |
| **B. Subset / Dominance partial order** *([Ninghui Li et al., SACMAT '09](https://www.cs.purdue.edu/homes/ninghui/papers/pca_sacmat09.pdf))* | $R_1$ beats $R_2$ iff $R_1$'s match set $\subsetneq R_2$'s match set; incomparable rules fall back to tie-breaker (`allow`) | Yes (`{disconnect, skills, pi}` $\subsetneq$ `{disconnect, skills}`) | **No** — `deny, *, skills` and `allow, disconnect, *` are incomparable (neither is a subset of the other), so the tie-breaker lets the default `allow` win | Mathematically clean, but too many pairs are incomparable when defaults set `action` and denies set `category` or `item`. |
| **C. Hierarchical bit-weights (Lexicographic scope tiers)** *(Recommended)* | `score = (item != '*' ? 8 : 0) + (agent != '*' ? 4 : 0) + (category != '*' ? 2 : 0) + (action != '*' ? 1 : 0)` (with `item != '*'` requiring `category != '*'`); highest score wins; tie → `allow` | Yes: default `allow disconnect, *` = `1`; `deny disconnect, skills` = `3`; `allow disconnect, skills, pi` = `7` | **Yes**: `deny *, skills` = `2` > default `1`; instance `deny disconnect, skills, ~/.agents/skills` = `11` > category+agent `allow disconnect, skills, pi` = `7`; instance+agent `allow disconnect, skills, ~/.agents/skills, pi` = `15` > `11` | **Best fit.** Matches Uwe's scope hierarchy (*instance > agent > category > all*), is a 1-line integer score, and **never ties unless two rules specify the exact same fields**. |

**Recommendation for Question 1:**
1. Keep order-independent specificity with `allow` winning ties, but replace unweighted field counting (`0..4`) with **hierarchical bit-weights**:
   $$\text{specificity} = 8\cdot[\text{item} \neq \text{'*'}] + 4\cdot[\text{agent} \neq \text{'*'}] + 2\cdot[\text{category} \neq \text{'*'}] + 1\cdot[\text{action} \neq \text{'*'}]$$
   Because the weights are powers of two (`8, 4, 2, 1`), **two rules can only tie when they have the exact same set of non-`*` fields** (an obvious direct collision in the UI).
2. Fix the "deleted default" trap: either make **no match = `deny`** (since `"allow all"` is already materialized as explicit default rules, so a request only fails to match when the user deliberately deleted its default `allow` rule), or keep the default `allow` rules non-deletable (baseline rows) if no-match stays `allow`.

---

### 2. Fields (`action`, `category`, `item`, `agent`) and completeness of the action list

#### Are `action`, `category`, `item`, and `agent` the right fields?
Yes, with **two structural rules** that the draft must state explicitly:
1. **`item` requires `category != '*'`:** An `item` key such as `ollama` can exist in both `mcp` and `providers`. In both the UI and schema validation, `item` may only be non-`*` when `category` is non-`*` (or picking an instance in the UI automatically sets `category`).
2. **Avoid ambiguity between `item` and `agent` when `category == 'agents'`:**
   - For lifecycle actions (`install`, `update`, `remove`, `start`, `stop`), the target being acted on is `item` (e.g. `category: 'agents', item: 'pi'`), and there is no second `agent` endpoint—the `agent` picker should be hidden/disabled and set to `'*'` whenever `category == 'agents'` or `action` is not a connection action (`connect`, `disconnect`, `move`, `*`).
   - However, if a user writes a cross-category rule `{action: '*', category: '*', item: '*', agent: 'pi'}` (*"Allow/Deny everything for Pi"*), `actionAllowed` should treat `agent: 'pi'` as matching `item: 'pi'` when `category == 'agents'` so that a blanket rule for `pi` covers both Pi's connections and Pi's own lifecycle actions.

#### Is the action list complete? (`routes.json` audit)
The draft has:
- `action`: `install, update, remove, connect, disconnect, move` (`reconnect` is `connect`)
- `category`: `mcp, skills, agents, providers, models`

Checking `packages/maprisma_core/protocol/routes.json` and `smart_card.dart` shows several gaps and mismatches:

1. **`start` and `stop` are in Ask AI (`Providers` column) and on map boxes, but missing from `action`:**
   - In `smart_card.dart:294-305`, Ask AI in the `Providers` column has four actions: `install`, `update`, **`start`**, and **`stop`** (`providers.run` with `runtime.start` / `runtime.stop`).
   - On the map, agent boxes also have `Start` (`sessions.start`) and `Stop` (`agents.halt_preview` / `agents.halt_apply`), and runtime boxes have `Start` / `Stop`.
   - If `start` and `stop` are not in `action`, a user cannot stop Ask AI (or a child) from stopping a running local LLM server (`runtime.stop`) or halting a running agent (`agents.halt_apply`) or starting an agent terminal (`sessions.start`). Adding **`start`** and **`stop`** to `action` covers both Ask AI's `Providers` column and map start/stop controls cleanly.
2. **Where `reconnect` belongs:**
   - Uwe listed `reconnect`; the draft folds `reconnect` into `connect`.
   - In `routes.json`, "reconnect" is `connections.repair_preview` (repairing a failed connection line on the map) and `existing.preview` / `existing.apply` / `system.folder_preview` (reconnecting existing AI folders/models/programs on disk; `core.dart:1850` literally calls it `'Invalid reconnect preview'`).
   - **I agree with folding `reconnect` into `connect`**, because anyone who denies `connect` for an agent/server certainly does not want it bypassed via `Repair` or `Find existing AI`, and anyone who allows `connect` expects repairing/reconnecting to work. The UI label/tooltip for `Connect` should note that it includes reconnecting and repairing.
3. **The problem with `move` on map lines vs. `disconnect` + `connect`:**
   - Uwe did **not** ask for `move`; Claude added `move`.
   - In `routes.json`, `move` appears in two very different places:
     1. `system.move_preview` / `system.move_apply`: moving a model folder to another disk (`model_move` in Ask AI `Models` column).
     2. `connections.move_preview` and `models.switch_preview`: dragging a connection hook on the map from `old` to `new` — **or dragging it into empty space (`new == null`) to disconnect!**
   - **Critical trap:**
     - When `new == null` in `connections.move_preview` or `models.switch_preview`, the user is **disconnecting** `old`. That must check `action: 'disconnect'`, never `'move'`!
     - When `new != null` in `connections.move_preview` or `models.switch_preview`, moving a line from `old` to `new` disconnects `old` **and** connects `new`. If it only checked `action: 'move'`, then a user who set **`deny disconnect, skills`** or **`deny connect, providers, item: lmstudio`** would be bypassed whenever someone dragged a hook from one box to another instead of disconnecting first!
     - Therefore, moving a connection on the map (`new != null`) must check **`disconnect` on `old` AND `connect` on `new`** (and if `move` is kept as an action in the picker, `move` should either apply to `system.move_preview` model-folder moves or be checked *in addition* to `disconnect(old)` + `connect(new)`). Honestly, dropping `move` from the user-facing action picker—or keeping `move` only for model-folder disk moves while checking `disconnect(old)` + `connect(new)` on map line moves—is much less error-prone for users.
4. **Do these areas need rules?**
   - **Model downloads (`providers.run` with `models.download`, `models.pull`, `model.import`, `jobs.continue`, `map.smart_run`):** **Yes, essential.** Downloading a multi-gigabyte model is the #1 action of Ask AI in the `Models` column. It maps naturally to `action: 'install', category: 'models', item: <model/repo>`.
   - **Add-ons (`addons.install`, `addons.file_preview`, `addons.remove_preview`, `addons.set_enabled`, `setup.apply`):** Each add-on has `kind: 'agent'` or `kind: 'provider'`. Ask AI cannot change add-ons, so if rules were only for Ask AI they wouldn't matter; but since rules also protect the setup in the GUI (`action_rule_hints: off`), leaving `addons.remove_preview` and `addons.set_enabled` unchecked lets a child remove or disable an agent/provider adapter in two clicks. Map add-on install/enable to `install` and remove/disable to `remove` under `category: 'agents'` or `'providers'` (according to `addon.kind`).
   - **Starting an agent (`sessions.start`, `agents.action_preview` with `login`/`verify`, `system.help_apply`, `checks.mcp_task`):** **Yes, if `start` is in `action`.** In particular, `"Do it with …"` (`agent_task` from Ask AI web lookup -> `map.smart_review` -> `system.help_apply`, `checks.mcp_task`, `system.help_preview`, `system.fix_preview`) starts an interactive agent in a terminal with a prompt to modify the PC. Checking `actionAllowed('start', 'agents', command, command)` lets a user who wants a locked-down setup (`deny start, agents`) block terminal agent launches and `"Do it with …"`!
   - **Ask AI's web lookups (`lookup` in `smart_card.dart`, `checks.mcp_check`, `models.tuning_ask`):** The web lookup itself is a read-only query (`research` table) and does not change the setup, so it does not need an action rule—**provided** that:
     1. A web lookup is never triggered as a fallback when an action is refused by `action_rules` (see Section 5), and
     2. The `"Do it with …"` terminal task button offered after a lookup is gated by `actionAllowed('start', 'agents', command, command)`.
   - **Settings (`settings.update`):** Should **not** be a category in `action_rules` (otherwise `deny *, settings` would brick the rules editor itself, since `action_rules` is saved via `settings.update`). Protecting `settings.update` is the job of the PIN/lock (Section 6).

---

### 3. Enforcement in the core: is one function before the plan enough?

#### No — "one function before a plan is made" is not enough, for four reasons:
1. **Several routes change the setup directly without making a preview or plan handle:**
   - `providers.run` (`models.download`, `models.pull`, `model.import`, `model.load`, `model.unload`, `runtime.start`, `runtime.stop`)
   - `jobs.continue` (resumes a saved `models.download` or `models.pull` from `jobs.json` **without** calling `providers.run` — `core.dart:2319-2335`)
   - `updates.run` (launches `mise`/`npm`/`pipx`/`uv` in a terminal to update an agent or provider **without** a preview route — `core.dart:2729-2781`)
   - `sessions.start` (starts an agent in a terminal without a preview)
   - `addons.set_enabled` and `setup.apply` (enable/disable adapters directly)
   - `found.unpack` (unpacks an AppImage into `~/Applications/` without a preview — `core.dart:877-893`)
2. **Compound previews affect multiple `(category, item, agent)` tuples in a single call:**
   - `_disconnectAll(pairs)` in `core.dart:3226` builds a combined plan for multiple MCP servers **and** skill folders across multiple agents—and **calls `skills.plan` and `mcp.plan` directly without calling `connections.preview`**!
   - `connections.author_preview`, `mcp.option_preview`, `skills.web_preview`, `models.attach_preview`, and `models.switch_preview` all act on a **list of `agents`** (and `found.update_preview` acts on multiple MCP servers).
   - Therefore, a static table mapping `route -> (action, category)` is not sufficient on its own: each route handler (or a route-level extractor `requiredChecks(method, params) -> List<ActionCheck>`) must yield **every `(action, category, item, agent)` tuple** touched by that request and check `actionAllowed` on all of them.
3. **TOCTOU between `*_preview` / `map.smart_ask` and `*_apply` / `map.smart_run`:**
   - Preview handles live up to 5–10 minutes (`connections._plans`, `actions._previews`, `removalPreviews`, `movePreviews`, `installerPlans`, `helpPreviews`), and `smartProposals` live 30 minutes (`smartProposalMinutes = 30`).
   - If `actionAllowed` is only checked in `*_preview`, a pre-existing preview handle or proposal could be applied after rules were tightened—or in `map.smart_review` for a model download (`core.dart:3072-3079`), `map.smart_review` doesn't even call a preview route!
   - **Fix:** Check `actionAllowed` both at **preview/proposal time** and at **apply/run time** (by storing the `List<ActionCheck>` on the `Plan` / preview record and re-checking in `*_apply`).
4. **In `map.smart_ask`, waiting until `Review` wastes a second LLM call and network search:**
   - In `smartModels` and `smartMcp`, after the first LLM answer returns `{"action": "search", ...}`, the worker searches Hugging Face or the MCP registry and makes a **second LLM call** (`smartPicksPrompt` / `smartMcpPicksPrompt`).
   - If the user has `deny install, models` or `deny connect, mcp` and the first LLM step still returns `search` (because the helper's output is untrusted), checking `actionAllowed` immediately after step 1 in `smartAsk` aborts before the network search and second LLM call, saving tokens and immediately returning the refusal message instead of showing unusable `Review` cards.

#### Complete list of setup-changing routes in `routes.json` (and ways around the check)

| Route(s) | What it changes | Required `actionAllowed(action, category, item, agent)` check(s) | Way around the check if missed |
|---|---|---|---|
| `connections.preview` → `connections.apply` | Connects or disconnects an agent and an MCP server, skill folder, or local provider (+ optional model) | `action: remove ? 'disconnect' : 'connect'`, `category: kind` (`'provider'` → `'providers'`), `item: item`, `agent: command` (plus if `!remove && model != ''`, also `('connect', 'models', model, command)`) | In `flutter_backend.py:404` and `core.dart:3589`. |
| `connections.move_preview` → `connections.apply` | Disconnects `old` (`new == null`) or moves agent from provider `old` to `new` (`new != null`) | If `new == null`: `('disconnect', cat(old), item(old), agent)`. If `new != null`: **both** `('disconnect', 'providers', item(old), agent)` **and** `('connect', 'providers', item(new), agent)` | Calling `move_preview` with `new: null` is how the map disconnects a line! Mapping `move_preview` statically to `'move'` would let every drawn disconnect on the map bypass `deny disconnect`! |
| `connections.repair_preview` → `connections.apply` | Repairs/reconnects a failed edge | `('connect', cat(target), item(target), agent)` | In Dart (`map_edits.dart:578`) it calls `preview()`, **but in Python (`flutter_map_editor.py:repair_preview`)** check that it also goes through `connections.preview`. |
| `connections.author_preview` & `mcp.option_preview` → `connections.apply` | Defines a new MCP server or skill folder and connects it to `agents: [...]` | For each `a` in `agents`: `('connect', kind, item, a)` (and if server is new to `inventory.mcp`, `('install', 'mcp', name, '*')`) | Multi-agent list: must check **every** agent in `agents`, not just one. |
| `skills.web_preview` → `connections.apply` | Stages a skill from `skills.sh` into `folder` and connects `folder` to `agents: [...]` | `('install', 'skills', folder, '*')` plus for each `a` in `agents`: `('connect', 'skills', folder, a)` | Does **not** call `authorPreview` or `connections.preview`; builds `Plan` directly in `core.dart:2159-2186`! |
| `found.update_preview` → `connections.apply` | Updates found MCP servers across agents | For each chosen server `c`: `('update', 'mcp', c['name'], '*')` | Builds `Plan` directly via `McpUpdate.planAll` in `core.dart:992`! |
| `models.switch_preview` → `connections.apply` | Switches all agents using model `old` to model `new` (or disconnects `old` if `new == null`) | For each affected `agent` using `old`: `('disconnect', 'models', label(old), agent)` and if `new != null`, `('connect', 'models', label(new), agent)` | Affects all default users of `old` implicitly (`selected` in `map_edits.dart:405-409`); `params` does not pass `agents`! |
| `models.attach_preview` → `connections.apply` | Connects `model` (and its `provider`) to `agents: [...]` | For each `a` in `agents`: `('connect', 'models', label(model), a)` and `('connect', 'providers', key(provider), a)` | Multi-agent list; also connects the runtime in `llm.plan`. |
| `models.remove_preview` → `models.remove_apply` | Deletes a model from a local LLM | `('remove', 'models', model, '*')` | In both `core.dart:1213` and `flutter_backend.py:374`. |
| `models.tuning_preview` → `connections.apply` | Changes a local LLM's tuning or model context size | `('update', 'providers', key, '*')` (or `('update', 'models', section, '*')` when `section != '*'`) | Creates a `connections.keep(Plan(...))` directly in `core.dart:2294`. |
| `models.slots_preview` → `connections.apply`, `models.slots_reload` | Syncs loaded model slots after a connection/model change | **Exemption note:** Called automatically by `_syncSlots()` after a connection/model change (`main.dart:3498`). Should follow the triggering connection change rather than failing mid-workflow, or map to `('update', 'providers', rtKey, '*')`. | — |
| `providers.run` | Runs `models.download`, `models.pull`, `model.import`, `runtime.start`, `runtime.stop`, `model.load`, `model.unload` | `models.download` / `models.pull` / `model.import` → `('install', 'models', modelOrRepo, '*')`; `runtime.start` → `('start', 'providers', key, '*')`; `runtime.stop` → `('stop', 'providers', key, '*')`; `model.load`/`unload` → allowed if runtime/model use is allowed (`models.search` and `models.files` are read-only) | Called directly by `ProvidersView`, `ModelBrowser`, map runtime start/stop button, `_smartProvider` (`main.dart:1740`), and `map.smart_run` (`core.dart:3091`). Also in `flutter_backend.py:415`. |
| `jobs.continue` | Resumes an unfinished `models.download` or `models.pull` | Same as `providers.run` (`('install', 'models', modelOrRepo, '*')`) | `core.dart:2319-2335` calls `tasks.start(operation, inner)` directly **without** calling `providers.run`! |
| `installers.preview` → `installers.install` | Installs or updates a managed agent or local LLM runtime | Check whether `key` is already installed: `action = installed ? 'update' : 'install'`, `category = kind == 'runtime' ? 'providers' : 'agents'`, `item = key` | Used for **both** fresh installs and updates (`_runUpdate` at `main.dart:1763`); also in `flutter_backend.py:337-350`. |
| `updates.run` | Runs an agent or provider update in an external terminal | `('update', found['kind'] == 'agent' ? 'agents' : 'providers', key, '*')` | Runs directly in `core.dart:2729-2781` with **no preview route**! |
| `agents.action_preview` → `agents.action_apply` | Runs `install`, `update`, `uninstall`, `login`, `logout`, `verify` (or `kind: 'tool', command: 'node', action: 'install'`) | `install` → `('install', 'agents', command, '*')`; `update` → `('update', 'agents', command, '*')`; `uninstall` → `('remove', 'agents', command, '*')`; `login` → `('connect', 'providers', command, command)`; `logout` → `('disconnect', 'providers', command, command)`; `verify` → `('start', 'agents', command, '*')` | Note `'uninstall'` in route params vs `'remove'` in rules! Also in `flutter_backend.py:360-367`. |
| `agents.key_preview` → `agents.key_apply` | Sets an API key for an agent | `('connect', 'providers', command, command)` | Writes `.env` or runs key helper (`core.dart:1430`). |
| `agents.security_preview` → `connections.apply` | Changes an agent's security/permission setting | `('update', 'agents', command, '*')` | Creates a `connections.keep` plan directly (`core.dart:1419`). |
| `agents.halt_preview` → `agents.halt_apply` | Stops running agent processes | `('stop', 'agents', command, '*')` | In `core.dart:4096-4097` and `flutter_backend.py:390-396`. |
| `sessions.start` | Starts an interactive agent in a terminal | `('start', 'agents', command, '*')` | In `core.dart:3814` and `flutter_backend.py:645`. |
| `system.help_preview`, `system.fix_preview`, `checks.mcp_task`, `map.smart_review(agent_task)` → `system.help_apply` | Starts an agent in a terminal with a task prompt (`"Do it with …"`) | When `topic != 'check'` (`argv.isNotEmpty`): `('start', 'agents', command, '*')` | Spawns an interactive agent in a terminal (`core.dart:1622`, `flutter_backend.py:310`) that can edit any file! |
| `system.move_preview` → `system.move_apply` | Moves a model folder to another disk | `('move', 'models', label(source), '*')` | In `core.dart:1647` and `flutter_backend.py:250`. |
| `system.folder_preview` → `connections.apply` | Connects a discovered model folder/store on disk to a local LLM | `('connect', 'providers', runtime, '*')` | In `core.dart:1757` and `flutter_backend.py:233`. |
| `system.stack_preview` → `system.stack_apply` | Installs GPU stack packages (`rocm`, `cuda`, `vulkan`) | `('install', 'providers', part, '*')` | In `core.dart:1747` and `flutter_backend.py:272`. |
| `existing.preview` → `existing.apply` | Reconnects discovered existing AI folders/models/MCP/skills | Check `('connect', categoryOf(record), itemOf(record), '*')` | In `core.dart:1831` and `flutter_backend.py:324`. |
| `found.unpack` | Unpacks a discovered AppImage into `~/Applications/` | `('install', 'mcp', candidate['name'], '*')` | No preview route (`core.dart:877`). |
| `addons.install`, `addons.file_preview` → `addons.file_install`, `addons.remove_preview` → `addons.remove_apply`, `addons.set_enabled`, `setup.apply` | Installs, updates, removes, or enables/disables agent/provider add-ons | Map to `install` / `update` / `remove` on `category: item.kind == 'provider' ? 'providers' : 'agents'`, `item: item.id` | Both `core.dart` and `flutter_backend.py`. |
| `map.smart_plan` (`_disconnectAll`) | Disconnects $\ge 2$ `(server/skill, agent)` pairs in one plan | Loop over `pairs`: for each pair check `('disconnect', 'mcp' or 'skills', item, agent)` | When `pairs.length > 1`, `_smartPlan` calls `_disconnectAll(pairs)` (`core.dart:3206`), which **bypasses `connections.preview`**! |
| `changes.undo` (`Settings › Recent changes › Put back`) | Restores any historical config backup from `connection-backups/` | Either check the restored files' item/agent or gate `Recent changes › Put back` when rules/PIN restrict changes | `changes.undo` (`core.dart:3868`) can revert a disconnection days later without going through `connections.preview`. |

---

### 4. What the user sees: two lists, `+`, dead-rule hints, Restore defaults, and a live tester

1. **The two lists and pickers per row:**
   - Having an **Allow** list and a **Deny** list with `+` per list and `×` per row is clean and avoids order-dependence.
   - **Conditional pickers:** Do not show all 4 pickers blindly on every row:
     - When `category == '*'` ("All categories"), `item` must be locked to `'*'` ("All") or hidden, because an `item` belongs to a specific category.
     - When `category == 'agents'` or `action` is `install`, `update`, `remove`, `start`, or `stop`, hide/disable the 4th picker (`agent`) and set `agent = '*'`, because those actions act on the `item` itself, not on a `(item, agent)` connection pair.
     - Preserve unknown `item` values in the picker if an MCP server, skill folder, or model was later uninstalled, so opening the popup never crashes `DropdownButton` and the user can still see and delete the rule.
2. **Rules that can never decide ("shadowed / redundant" hint line under the row):**
   - With power-of-2 specificity weights (`item=8, agent=4, category=2, action=1`), a rule $R$ can never decide in three clear, enumerable cases that the UI can explain in one short line under $R$:
     1. **Duplicate row:** Another row in the same list has identical `(action, category, item, agent)`.
     2. **Exact tie in the Deny list:** An `Allow` row has the exact same `(action, category, item, agent)`. Show under the `Deny` row: *"Never applies: the matching Allow rule wins on a tie."*
     3. **Redundant Allow row:** An `Allow` row is broader-covered by another `Allow` row (e.g. the default `Allow disconnect, all`) and there is **no** matching `Deny` rule with specificity between them for it to override. Show a subtle note: *"Already covered by 'Allow disconnect, all' (no Deny rule blocks this)."*
     4. **Subsumed by a broader rule with all specific instances covered** (or if unweighted field counting were kept, a 1-field `Deny` with `action: *` beaten by the 1-field default `Allow` rules).
3. **Restore defaults:**
   - Must reset **both** lists to the factory state (the default `Allow` rules restored, all `Deny` rules and custom `Allow` exceptions removed)—not merely re-append missing default `Allow` rows while leaving `Deny` rules intact. If custom rules exist, confirm or offer a snackbar `Undo`.
4. **Is a live "what would happen" tester worth having?**
   - **Yes, definitely.** Users writing exceptions (especially parents/admins who are about to turn `action_rule_hints` **off**, after which the app will only say `"This is not allowed here."`) need a way to verify that their rules actually do what they think before closing the window.
   - Because `actionAllowed` is a pure synchronous function over the in-memory rule list, a single compact bar at the bottom of the popup:
     `Test: [Action ▾] [Category ▾] [Item ▾] [Agent ▾]  →  ✓ Allowed (by: Allow disconnect · skills · Pi)`
     takes ~40 lines of Flutter code, requires no backend call, and can highlight the winning row in the list above.

---

### 5. The refusal hint, its `off` setting, and what the helper should say

#### Does `action_rule_hints: off` leak anything else?
**Yes — there is a major leak in the draft as written!**
Look at lines 40 and 43 of the draft:
- Line 40: *"The helper also gets the rules as facts, so it can say what is refused instead of proposing it"*
- Line 43: *"With `action_rule_hints` on: the rule that decided, in words ('Disconnect, skills: not allowed by your rules'). Off: 'This is not allowed here.' with no rule named."*

**What goes wrong when `action_rule_hints` is `off`:**
1. **The AI helper itself leaks the rule and the allowed exceptions!**
   If `action_rule_hints` is `false` (off) and the core still passes `action_rules` in `facts` to the LLM in `map.smart_ask`, the LLM will answer with a `redirect` hint such as:
   > *"Disconnecting skills is denied by your rules, except for Pi — ask me to disconnect skills for Pi instead, or change Action Rules in Settings."*
   That completely defeats `action_rule_hints: off`: it tells the child/other user (a) that an Action Rule in Settings is blocking them, and (b) the exact loophole (`agent: Pi`) that *is* allowed!
   - **Fix:** When `action_rule_hints` is `false`, either do **not** include `action_rules` in the prompt text (let the core refuse or filter deterministically and return the fixed string `i18n.text('This is not allowed here.')`), or have the core overwrite any refusal/redirect reason with `i18n.text('This is not allowed here.')`.
2. **Cross-column privacy leak to cloud helpers:**
   `core.dart:3118` and `smart_card.dart:84, 161` carefully avoid sending local filesystem paths or unrelated column data to cloud helpers. If the raw `action_rules` list is sent to the helper in every column, a rule in `skills` (`item: "~/secret-client/skills"`) or `mcp` (`item: "internal-db"`) would be sent to the cloud helper when asking a question in the `Models` or `Agents` column.
   - **Fix:** Only pass rules that can match the current column (`category == '*' || category == column`), and better yet, **pre-apply the rules to the `facts` handed to the helper** (e.g., set `a['remove'] = false` in `facts['agents']` when `actionAllowed('remove', 'agents', a['command'], '*')` is false!).

#### What should a helper say when it gets the rules as facts?
1. **Never fall back to `lookup` ("find out on the web" + `"Do it with …"`) when an action is refused by `action_rules`!**
   Today in `smart_card.dart:61, 219, 305`, the prompts tell the helper: *choose `lookup` when this column cannot do it*. If `remove` is false for an agent (or forbidden by a rule), the helper will pick `{"action": "lookup", "question": "how to uninstall ..."}`, which runs a web search and offers a **`"Do it with Claude Code…"`** button to run the forbidden action in a terminal!
   - The prompt must explicitly state: *"Never choose `lookup` for an action forbidden by `rules`."*
2. **Prefer a deterministic `"action": "refused"` (or core-side check) over LLM-paraphrased rule explanations:**
   - For **partial restrictions** (e.g. user asks *"disconnect all skills"*, and `deny disconnect, skills` + `allow disconnect, skills, agent: pi` are set): the prompt should tell the helper: *"When the user asks for 'all' and `rules` allow only some agents or items, include only the allowed ones."* (And `smartMcp` / ` core.dart` should also filter `pairs` in a multi-item request to the allowed ones if at least one pair is allowed!).
   - When **everything requested is forbidden by `rules`**: the core itself knows the exact winning `deny` rule (`decideRule(action, category, item, agent)`) and should format the refusal message deterministically in the user's language (`"Disconnect, skills: not allowed by your rules"` when `action_rule_hints` is on, or `"This is not allowed here."` when off), rather than relying on the LLM to phrase it.

---

### 6. Is the "What it is not" section honest and complete?

It is honest that this is not an OS security boundary, **but it is incomplete** in ways that matter if Uwe or a user relies on it for children or shared desktops:

1. **Not just `"Do it with …"` — every terminal button in Maprisma (`▶ Start` on an agent box, `Console`, `Sign in`, `Test`, and `Update` in an external terminal) runs under the user's OS account:**
   The draft only mentions `"Do it with …"`. Any agent started via the `▶ Start` icon on its map box (`sessions.start`) opens a full agent session in a terminal tab where the user can ask the agent to edit `~/.config/maprisma/settings.json` or any agent config file.
2. **Other GUI backdoors if only the rules popup has a PIN:**
   Even if a PIN is added to the Action Rules popup later:
   - `Settings › Recent changes › Put back` (`changes.undo`) can restore old config states unless gated.
   - `Add-ons` (`addons.set_enabled`, `addons.remove_apply`) can disable or delete agent/provider support unless covered by rules.
   - The `action_rule_hints` toggle itself must live **inside** the Action Rules popup (not on the main Settings page), otherwise someone can turn hints back on without opening the popup.
3. **Background watcher (`providers_with_agents`):**
   When *"Start and stop local LLMs with their agents"* is enabled, the background `WatchService` starts and stops local LLM systemd services automatically; action rules only govern interactive actions in Maprisma and Ask AI.

---

### 7. What else is missing from the draft

1. **How refusal messages cross the protocol wire (`core.dart:4214`, `flutter_backend.py:827`, `routes.json`):**
   - Currently, `core.dart:4219-4233` and `flutter_backend.py:834-839` strip **all** exception messages and return only `{"id": id, "error": {"code": "invalid_request"}}` (or `"operation_failed"`), and the Flutter GUI catches any `BackendException` and shows the generic `"The action could not be completed."` (`map_smart_card.dart:662, 750, 859`, `main.dart`).
   - If `actionAllowed` simply throws `FormatException('Disconnect, skills: not allowed by your rules')`, **the user will never see that message**—they will only see `"The action could not be completed."`!
   - **Fix:** Add `RuleRefusedError(String message)` in both cores, serialized in `handle()` / `serve()` as `{"id": id, "error": {"code": "action_refused", "message": e.message}}` (safe because `e.message` is produced only by the core's rule formatter, never from raw OS/file exceptions), and surface `error['message']` in Flutter's `BackendException` when `code == 'action_refused'`.
2. **`action_rule_hints` is missing from the "Storage" section and `routes.json`:**
   - The draft mentions `action_rule_hints` under "Refused", but "Storage" only mentions `action_rules`. Both `action_rules` (list, max 200) and `action_rule_hints` (`bool`, default `true`) must be added to `settings_schema.py`, `settings.dart`, `core_assets.g.dart`, `UI_SETTINGS` in `flutter_backend.py`, and the `settings.get` / `settings.update` shapes in `routes.json`.
3. **Canonical normalization of `item` IDs:**
   - Skill folders appear as `~/...` in `inventory.skillSets` and `/home/...` in `skills.plan`. The core must normalize `item` for `category == 'skills'` with `config.tilde(skills.expand(path))` both when saving/matching rules and inside `actionAllowed`, so `~/.agents/skills` and `/home/uwe/.agents/skills` always match.
4. **8 languages and user manual:**
   - Per `AGENTS.md`, all new UI strings and refusal templates need translations in `translations/*.json` (8 languages) and documentation in `docs/manual/manual*.html` (8 languages).

---

### Sources
- [How Cedar authorization works](https://docs.cedarpolicy.com/auth/authorization.html) — order-independent evaluation, `forbid-overrides-permit`, and why exceptions in a `forbid-overrides` system require explicit `unless` clauses rather than separate `permit` rules.
- [Claude Code permissions (official)](https://code.claude.com/docs/en/iam) — `deny → ask → allow` precedence and `Tool(specifier)` syntax.
- [How allow, ask and deny compose in Claude Code](https://dev.to/ottoflightrules/claude-code-permissions-how-allow-ask-and-deny-actually-compose-3kme) — why flat `deny-overrides` prevents a narrower `allow` from overriding a broader `deny` across scopes.
- [What is a XACML combining algorithm?](https://www.webfarmr.eu/tgif-xacml-whats-a-xacml-combining-algorithm/) — comparison of `deny-overrides`, `permit-overrides`, `first-applicable`, and `only-one-applicable`.
- [Access Control Policy Combining: Theory Meets Practice (Ninghui Li et al., ACM SACMAT 2009)](https://www.cs.purdue.edu/homes/ninghui/papers/pca_sacmat09.pdf) — formal analysis of policy combining algorithms, specificity/dominance partial orders, and conflict resolution when rules have overlapping scopes.
- [Firewall rule order and default rule (Abiquo documentation)](https://abiquo.atlassian.net/wiki/spaces/ABI54/pages/310739306/GUI+Create+classic+firewall+rule) — classic ordered firewall evaluation and default fallback behavior.
- [Firewall UI complaints about conflicting rules (Wilders Security)](https://www.wilderssecurity.com/posts/1602589) — user confusion when separate allow/block lists interact with hidden precedence or unintuitive default rules.

---

### Short list of changes I would make to the draft

1. **Use hierarchical bit-weights (`item = 8, agent = 4, category = 2, action = 1`) instead of unweighted field counts (`0..4`):** Ensures `item` (instance) beats `agent`, `category` (`2`) beats a 1-field default `allow <action>, *` (`1`) even when `action` is `*`, and two rules never tie unless they set the exact same fields.
2. **Fix "no match" when a default `allow` is deleted:** Either make "no match" return `deny` (so deleting a default `allow <action>, *` row actually stops allowing that action), or make the default `allow` rows non-deletable baseline rows.
3. **Add `start` and `stop` to `action`, and map `move_preview` / `switch_preview` properly:**
   - Add `start` and `stop` to `action` (needed for Ask AI's `Providers` column `start`/`stop` and map agent/provider start/stop, including `"Do it with …"` terminal tasks).
   - In `connections.move_preview` and `models.switch_preview`, check `disconnect` when `new == null`, and check **both** `disconnect(old)` and `connect(new)` when `new != null` so dragging a line to another box cannot bypass `connect` or `disconnect` rules.
4. **Enforce `actionAllowed` on all setup-changing routes (including direct routes and multi-item loops) and at both preview/proposal and apply/run time:** Cover `providers.run`, `jobs.continue`, `updates.run`, `skills.web_preview`, `found.update_preview`, `found.unpack`, `_disconnectAll`, `system.help_apply`, and `addons.*`, plus check after step 1 in `map.smart_ask` before running a second LLM call.
5. **Define the wire error for refusals (`code: "action_refused"` with `message`):** `core.dart` and `flutter_backend.py` currently strip all exception messages; add `RuleRefusedError` so the GUI receives and displays `"Disconnect, skills: not allowed by your rules"` or `"This is not allowed here."`.
6. **Prevent helper leaks when `action_rule_hints` is `off`:** Add `action_rule_hints` (`bool`, default `true`) to Storage/settings schema, place its toggle inside the Action Rules popup, do not let the LLM explain which rule or exception applies when `action_rule_hints` is `off`, and forbid the helper from choosing `lookup` when an action is denied by rules.
7. **Add a 1-line live "Test a request" bar at the bottom of the popup** and hide the `agent` picker on rows whose `action` or `category` does not connect to an agent.
