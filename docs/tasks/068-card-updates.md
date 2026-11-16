# 068 Updates on the map's boxes

Author: Claude · Reviewer: Antigravity · Branch: task/068-card-updates

## Goal
A box on the map whose program has a newer version shows a yellow ↑ version badge, and its ⋮ menu has
**Update with AI…** (the Ask AI helper does the update as a reviewed task in a terminal tab, as MCP's
"Do it with …") and, where the app has its own way, **Update now** (as the hint's Update). Uwe, 2026-11-11:
all four kinds (agents, local LLMs, MCP servers, add-ons), AI first, the direct way kept.

## Routes
- New `updates.task {key}` (read, like `checks.mcp_task`): an update the last `updates.check` found (agent or
  runtime) as a task for the AI helper. The helper is Ask AI's (`smart_helper`) when it can take a task, else
  the one "Do it with …" uses; never the agent being updated while another can do it. Checked like a start of
  that helper (`start`, agents) and like an update of the item (`update`, its column). Result: the help
  preview (`preview`, `name`, `prompt`, `topic: "update"`), applied with `system.help_apply` as MCP's task.
- The prompt names the program, both versions and how it was installed (its update command when it has one,
  else Maprisma's installer: look up what changed and stop before installing, the Update page installs it,
  SHA-256 checked there), and asks before every step that changes something.

- Fix (Uwe, 2026-11-11): an agent's Update from its page or from Ask AI (`agents.action_preview` /
  `agents.action_apply`, `map.smart_run`) built its own `mise --yes upgrade` with mise's version service, which
  can lag behind a release: mise found nothing while the check had found Claude Code's new version (its
  channel, `claude update`). Now it runs what `updates.check` found (allowed commands only, mise with
  `MISE_USE_VERSIONS_HOST=0`), and the check asks again afterwards.

## UI
- `map_editor.dart`: the badge beside the battery (`UpdateBadge` in `map_groups.dart`, tooltip
  "Update available: {0}"), and in the box's ⋮ menu, first: **Update with AI…**, **Update now** (agents and
  local LLMs), **Use the new version…** (an MCP server whose newer version is already on this PC), **Update
  add-on to {0}** (add-on boxes; an add-on is signed, so no AI there).
- `main.dart`: one map node id → update (agents `agent:<key>`, local LLMs `runtime:<key>`, MCP servers
  `mcp:<name>`, add-ons: the boxes their `provides` names), given to the map as `update_badges`. Update now is
  `_runUpdate`; the AI review is the MCP task's dialog, shared.
- Texts in all 8 languages; manual: "Updating agents" says the map's boxes have the badge and both items.

## Acceptance
- A fake updates.check / mcp check / add-on catalog with one update of each kind: each box has the badge and
  its menu items; Update with AI… shows the prompt and starts `system.help_apply`; Update now calls
  `updates.run`. Core: `updates.task` refuses an unknown key, extra params, a helper the rules forbid, and
  never picks the agent being updated when another helper can take the task.
- Core: an agent's Update plan is the found command (`claude update`; mise with MISE_USE_VERSIONS_HOST=0), a
  command the check may not run is not taken over.
- `tools/test-changed --base main` green.
