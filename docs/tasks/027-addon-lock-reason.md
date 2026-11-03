# 027 Say why add-ons are locked while agents run

Author: Claude · Reviewer: Antigravity · Branch: task/027-addon-lock-reason

## Goal
While an agent runs in one of Maprisma's terminals, add-ons cannot be switched on or off. The user should
see that at once, learn which agents hold the lock, and be able to jump to them. Today the switch is only
greyed out, and a click on a menu item that is still reachable does nothing.

## What happened (Uwe's PC, 2026-11-03)
Uwe switched on agent-pi, llm-llamacpp and llm-ollama under Add-ons. Nothing was saved
(`~/.config/maprisma/settings.json` stayed unchanged since 2026-10-31), and no message appeared. At that
time a Claude session that Maprisma's Ask AI had started was running in one of the app's terminals
(since 20:58), so `_agentsRunning` was true.

- `flutter_app/lib/main.dart:1024`: `_agentsRunning` is `_terminals.any((t) => !t.ended)`: any running
  agent terminal, Ask AI's own included.
- `main.dart:1295` `_toggleAddon` returns at once while `_busy || _agentsRunning`: no request, no message.
  `_removeAddon` (`main.dart:1261`), add-on updates (`main.dart:1705`) and the Undo snack bar
  (`main.dart:1080`, which at least shows `_actionFailed`) are guarded the same way.
- `flutter_app/lib/map_addons_focus.dart:150`: the menu item "Switch on/off" is disabled with no reason
  given. The only hint is one plain line among the page's other texts (`map_addons_focus.dart:272`,
  "Finish running agents before changing add-ons."). The details sheet (`main.dart:1181`) shows the same
  line above its disabled button.
- The core has no such guard: `addons.set_enabled` works while agents run. The lock is GUI only.
  Commit `ddae426` (2026-10-28) introduced it; no plan or review gives the reason.
- The trap: asking Ask AI for help opens an agent terminal, and that terminal blocks the add-on change
  the agent is likely to suggest.

## Scope
**Part A (this task): make the lock visible and explain it.**
1. While agents run, the add-ons page (`MapAddonsFocus`) shows a banner at the top instead of the plain line.
   The banner names the running agents ("Claude Code is running in a terminal. Add-ons can be changed when
   it has finished.", plural form for several) and has a button to show that terminal (`_visibleTerminal`;
   with several agents, the first one).
2. Each disabled "Switch on/off" menu item, the welcome checkboxes (`map_addons_focus.dart:122`) and the
   details sheet button get the same reason as a tooltip or subtitle, not just a greyed state.
3. `_toggleAddon`, `_removeAddon` and the update path never return silently. If they are reached while
   agents run (a race between a click and a terminal starting), they show the banner text as a snack bar.
4. The lock lifts by itself when the last terminal ends: the page rebuilds without a restart. This should
   already happen through `_refresh`; the task adds a test for it.

**Part B (decision for Uwe, not done here): how narrow should the lock be?**
The reason for the lock is not written down. Plausible reasons: an agent add-on switched off while its
agent runs takes the agent off the map under its own terminal; and an add-on change makes the map rebuild
while a terminal reads the agent's session files. Options:
- (a) Keep the lock for every add-on (only Part A).
- (b) Lock only the add-ons of agents that are running (and the provider add-ons they use); switching
  *on* anything else is always allowed.
- (c) Never lock switching *on*; lock only switching off, removing and updating an add-on that a running
  agent uses.
Part B gets its own task once Uwe has chosen, with a check of what a running terminal really depends on.

## Routes
None. The GUI already knows its terminals (`_terminals`, `AgentTerminal.command`); the agent's display name
comes from the snapshot's agents.

## UI
- `flutter_app/lib/map_addons_focus.dart`: new parameter for the running agents (names plus a callback to
  show the terminal) in place of `bool running`, or next to it. Banner (`key: ValueKey('addons-locked')`)
  with the button `ValueKey('addons-locked-show')`. Reason on disabled menu items and checkboxes.
- `flutter_app/lib/main.dart`: pass the running agents and the show-terminal callback; snack bar on a blocked
  `_toggleAddon` / `_removeAddon` / update; details sheet text uses the same wording.
- New texts in all 8 languages (`translations/*.json`, appended, source order kept):
  "{0} is running in a terminal. Add-ons can be changed when it has finished.",
  "{0} are running in terminals. Add-ons can be changed when they have finished.", "Show terminal".
  The old line "Finish running agents before changing add-ons." stays as long as another view uses it.
- Manual: the add-ons part of the Map chapter (`docs/manual/`, all languages) gets one sentence: "While an
  agent runs in one of Maprisma's terminals (Ask AI included), add-ons cannot be changed; the page says
  which agent and can show its terminal."

## Acceptance
- With an agent terminal running: the add-ons page shows `addons-locked` with the agent's name, and
  `addons-locked-show` brings that terminal to the front. The disabled "Switch on/off" item, the welcome
  checkbox and the details sheet button each give the reason.
- A blocked `_toggleAddon` call shows a snack bar and sends no `addons.set_enabled`.
- When the terminal ends, the banner goes and the switches work without a restart.
- Without running agents nothing changes (existing `map_groups_test.dart` "Switch off" path still green).
- Tests: extend `flutter_app/test/map_groups_test.dart` (the `running: true` case at line 244: banner,
  agent name, reason on the item) and add an app-level test in `task_cards_app_test.dart` or
  `hosted_views_test.dart` for the snack bar and for the lock lifting.
- `tools/test-changed --base main` and `MAPRISMA_PUB_OFFLINE=1 tools/flutter-dev check` pass.
