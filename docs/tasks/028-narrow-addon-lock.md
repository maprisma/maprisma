# 028 Lock only the add-on of a running agent

Author: Claude · Reviewer: Antigravity · Branch: task/028-narrow-addon-lock

## Goal
Part B of task 027, option (c), Uwe's choice (2026-11-03). While an agent runs in one of Maprisma's
terminals, everything about add-ons works except switching off, updating or removing **that agent's own
add-on**. Switching any add-on on, and every change to other add-ons (local LLMs, online providers, other
agents), is always allowed. Asking Ask AI for help no longer blocks the add-on change it suggests.

## What a running terminal depends on (checked 2026-11-03)
- `sessions.start` (`agent_start.dart:78-140`) reads the agent's adapter once: the program and its `start`
  arguments. After that `PtySession` keeps only the process, the PTY, `command` and the folder.
- `sessions.read/write/resize/stop` never use the adapters (`AgentStart.session`); the rule check on Stop
  matches the command text only (`action_rules.dart`); `observe`/`forget` touch only the first-agent test.
- The Dart core takes add-ons as data only (`AddonRegistry.dataOnlyRefusal`): no file of an add-on folder
  is executed, so removing or updating one cannot take away a file a running agent uses.
- Switching a provider add-on on or off reloads the catalog and saves `addons_enabled`; no agent config is
  written.
- The only visible effect of switching off a running agent's add-on: its card leaves the map and its tab
  shows the command instead of the name. That is why its own add-on stays locked.
- Correction to task 027: the lock is not GUI only. The core refuses every add-on change while any session
  runs: `addonRoute` (`core.dart:283`) and `guardAddonChanges()` (`core.dart:3458`, used by `setup.apply`,
  `addons.file_preview/file_install`, `addons.install`, `addons.remove_*`); Python reference
  `flutter_backend.py:444` and `guard_addon_changes` (`:696`).

## The rule
An add-on is **locked** when its `kind` is `agent` and its `provides` contains the `command` of a running
session (`provides` of an agent add-on is its command: `agent-claude` → `claude`). A locked add-on cannot be
switched off, updated (catalog or file install of the same id) or removed. Everything else is allowed.
"An installation is already running" stays as it is.

## Routes
No new or changed route, params or result shape. The refusal text of the core stays
"Finish running agents before changing add-ons" and now comes only for a locked add-on:
- `addons.set_enabled`: only with `enabled: false` for a locked id.
- `setup.apply`: only when the selection switches a locked add-on off.
- `addons.install`: only when the catalog record's id is a locked add-on (an update); a new add-on installs.
- `addons.file_install`: only when the file's add-on id is locked. `addons.file_preview` is not refused:
  it names the add-on, so the app can say which agent holds it.
- `addons.remove_preview` / `addons.remove_apply`: only for a locked id. `addons.remove_undo` (puts an
  add-on back) is always allowed.
Dart core and Python reference both; `tools/diff-core.py` stays equal.

## UI
- `flutter_app/lib/main.dart`: `_agentsRunning` gives way to `_lockedAddons` (add-on id → names of its
  running agents, from `_terminals` and `_addons`' `provides`). The guards in `_toggleAddon` (only when
  switching off), `_removeAddon`, `_installAddon` (only for an installed id), `_installAddonFile` (after
  the preview, by its id), `_finishSetup` (only when the selection switches a locked one off) and
  `_updateAllAddons` (locked add-ons are left out; when only locked ones are left, the message) use it.
  The Undo snack bar has no lock check of its own; the core decides.
- `flutter_app/lib/map_addons_focus.dart`: `running` / `runningAgents` give way to the locked map. The
  banner shows only while an add-on on this page is locked; "Switch off", "Update", "Remove", the details
  sheet buttons and an unticked welcome checkbox are disabled with the reason only for locked add-ons.
  "Switch on", "Get add-on" and "Install from file…" are no longer disabled by running agents.
- Texts (all 8 languages, appended): "{0} is running in a terminal. Its add-on can be switched off,
  updated or removed when it has finished." and "{0} are running in terminals. Their add-ons can be
  switched off, updated or removed when they have finished." The two texts of task 027 and "Finish
  running agents before changing add-ons." go when no code uses them any more (also from `KEYS` in
  `tools/flutter-assets.py`).
- Manual: the sentence from task 027 in all languages becomes "While an agent runs in one of Maprisma's
  terminals (Ask AI included), its own add-on cannot be switched off, updated or removed; the page says
  which agent and can show its terminal."

## Acceptance
- With a `claude` terminal running: `agent-claude` cannot be switched off, updated or removed (GUI shows
  the reason; the core refuses), while `agent-pi`, `llm-ollama` and `providers-online` can be switched on
  and off, and a new add-on can be installed.
- When the terminal ends, `agent-claude` unlocks without a restart (task 027 behaviour kept).
- Core tests (Dart and Python) for each route above: locked id refused, other id and switching on
  allowed. GUI tests: `map_groups_test.dart` (banner only with a locked add-on on the page, reason only
  on its controls, Switch on enabled) and `task_cards_app_test.dart` (switching another add-on works
  while an agent runs; switching off the running agent's add-on shows the snack bar and sends no
  `addons.set_enabled`).
- `tools/test-changed --base main` passes.
