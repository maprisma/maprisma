# 004 Smart card

Core: Claude · GUI: Antigravity · each reviews the other · Branch: task/004-smart-card

GUI design: Antigravity's proposal (`docs/proposals/004-smart-card-gui.md`), with the changes below. Where they
differ, this file wins.

## Goal
A collapsed card at the top of all four columns (MCP servers and skills, Agents, Providers, Models). The user types
one request; a guarded agent proposes, the core checks, the user decides through the existing reviews.

## Changes to the proposal
1. **All four columns** (Uwe), as proposed: `column` is mcp · agents · providers · models.
2. **Group cards stay in their column** (Uwe), as proposed: free positions (`saved['cards']`) and Move
   left/right/up/down go; a card is dragged by its header within its column (`card_order`), with the drop line;
   the menu keeps Earlier card and Later card, which are also the keyboard way. An old saved `cards` value is
   ignored. The manual says "put it anywhere" (`docs/manual/manual.html`, the map chapter): change it in 8 languages.
3. **The GUI never calls a route taken from a proposal.** No `preview.route` / `preview.params` and no
   `connect_after[].route` in the result: the GUI would have to use `call(method, params)`, and `providers.run` is no
   preview, it starts the download at once. Instead the core keeps the checked proposal and the GUI names a candidate:
   - `map.smart_review {proposal, candidate}`: the same plan or preview the matching review widget shows.
   - `map.smart_run {proposal, candidate}`: after the user's OK, starts it (`{task}`).
   - `map.smart_connect {proposal, candidate, agent}`: the connection plan for step 4, then `connections.apply`.
4. **Helpers from their own route:** `map.smart_helpers` (read), not in `map.snapshot`, which is polled.
5. **No `out_of_tokens` state.** Nothing in the core can tell it from another failure yet: it is state 11 (error),
   and `"Ask {0} instead"` and `"{0} has reached its usage or token limit."` go. Eleven states remain.
6. **Who may answer:** the rule in `docs/plan-smart-helpers.md`, no list of agents. In this task: Claude Code, Codex
   and Pi (Pi also as the confirmed local helper); others follow without a change to the GUI.

7. **Tokens are always the user's decision** (Uwe): the card shows who answers and what it costs; only the click on
   Ask sends. No retry, no background request. See `docs/plan-smart-helpers.md`.

## Routes (`routes.json`, written by Claude first; the GUI builds against them)
`map.smart_helpers`, `map.smart_ask` (`column`: mcp · agents · providers · models, `command`, `request`, `answer?`; result
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

## Plan for Antigravity (GUI)
Work in `/mnt/Data/Projects/maprisma-agy` on branch `task/004-gui`, made from `task/004-smart-card`. Never edit
`packages/`, `routes.json`, `tools/` or the Python reference: what the core lacks goes to Claude as a note in the task.

**Part A: the map (no new route, start now).** One commit each, suites green:
1. `gui: group cards stay in their column`: remove free positions and the four Move items; vertical drag by the
   header within the column; the 2 px drop line; Earlier card / Later card stay. Old `cards` ignored. Widget tests,
   including that a card cannot leave its column.
2. `gui: a fixed slot for the smart card`: the 38 px slot under each column's summary card, shown only when helpers
   exist (a plain flag for now), and `MapSmartCard` collapsed and open as an overlay. Test: opening it changes no node
   position and not the transform; only one card open at a time; it stays inside the Omarchy popup size.
3. `gui: the manual on moving cards`: the map chapter in 8 languages (`docs/manual/translations.py`), no PDFs yet.

Stop there and ask for review of part A.

**Part B: the steps (after Claude's `protocol:` and `core:` commits are on `task/004-smart-card`).** Merge them into
`task/004-gui` first, then:
4. `gui: ask, working, clarify, redirect`: states 1 to 6 with `CoreClient` and a fake transport.
5. `gui: proposal, review, run, connect`: states 7 to 11, reusing the existing review widgets; `map.smart_review`,
   `map.smart_run`, `map.smart_connect`.
6. `gui: smart card texts`: all new texts in 8 languages (append to `translations/*.json`), keyboard and a11y tests
   in light and dark.
7. `gui: the manual on the smart card`: a section in 8 languages. PDFs are built by Claude at the end.

Then ask for review of part B. The app is never started on Uwe's desktop to test; widget tests only.
