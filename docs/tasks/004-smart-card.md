# 004 Smart card

Core: Claude · GUI: Antigravity · each reviews the other · Branch: task/004-smart-card

GUI design: Antigravity's proposal (`docs/proposals/004-smart-card-gui.md`), with the changes below. Where they
differ, this file wins.

## Goal
A collapsed card at the top of the Models, Providers and Agents columns. The user types one request; a guarded agent
proposes, the core checks, the user decides through the existing reviews.

## Changes to the proposal
1. **Three columns only:** Models, Providers, Agents. No card and no `mcp` column value for MCP servers and skills
   in this task.
2. **Keep free card dragging.** `saved['cards']`, dragging anywhere and Move left/right/up/down stay (the manual
   documents them). No drop separator, no change to `card_order`. The smart card's slot is fixed; a card the user
   placed there may lie under an open smart card, which is drawn above it.
3. **The GUI never calls a route taken from a proposal.** No `preview.route` / `preview.params` and no
   `connect_after[].route` in the result: the GUI would have to use `call(method, params)`, and `providers.run` is no
   preview, it starts the download at once. Instead the core keeps the checked proposal and the GUI names a candidate:
   - `map.smart_review {proposal, candidate}`: the same plan or preview the matching review widget shows.
   - `map.smart_run {proposal, candidate}`: after the user's OK, starts it (`{task}`).
   - `map.smart_connect {proposal, candidate, agent}`: the connection plan for step 4, then `connections.apply`.
4. **Helpers from their own route:** `map.smart_helpers` (read), not in `map.snapshot`, which is polled.
5. **No `out_of_tokens` state.** Nothing in the core can tell it from another failure yet: it is state 11 (error),
   and `"Ask {0} instead"` and `"{0} has reached its usage or token limit."` go. Eleven states remain.
6. **Who may answer:** only an agent that is installed, signed in and has a guarded start (today Claude Code, Codex,
   Pi; Pi also as the confirmed local helper). Others are not listed, Antigravity and Gemini included.
7. `"Move to {0}"` only offers these three columns.

## Routes (`routes.json`, written by Claude first; the GUI builds against them)
`map.smart_helpers`, `map.smart_ask` (`column`: models · providers · agents, `command`, `request`, `answer?`; result
`{task}`, then in `tasks.status`: status proposal · clarify · redirect · error, as in the proposal's section 6 without
`preview` and `connect_after`, plus `proposal` (a handle) and per candidate `connectable: [{command, name}]`),
`map.smart_review`, `map.smart_run`, `map.smart_connect`.

## Core (Claude)
Allowed actions per column as a fixed list; the agent's answer is data checked against it, candidates must come from
real search results, PC limits and fit are computed by the core, the proposal handle expires. Dart only (AGENTS.md).

## GUI (Antigravity)
`map_smart_card.dart`, the map's fixed slot, the steps and states, the 8 languages, keyboard and a11y, widget tests
with a fake transport. Uses `CoreClient` only. Manual chapter in all 8 languages at the end.

## Acceptance
- Nothing changes without a review and the user's OK; a request outside the column gets a helpful answer.
- A proposal naming something not in the search results, or an action off the list, never reaches the GUI (core test).
- Opening the card does not move the map; collapsed by default; hidden with no helper.
- The three suites from AGENTS.md green; review by the other agent until CLEAN on each part.
