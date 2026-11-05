# 063h MCP identity, saved servers and old tool answers

Author: Claude · Reviewer: Codex · Branch: task/063h-mcp (part of task/063-codex-review)

## Goal
Fix the MCP findings of the Codex coverage review (`docs/reviews/063-codex-coverage.md`, round 3): #1, #4
and #5. Two servers of one name that differ only in env or headers are two servers; a saved server keeps its
key; an old tool answer without a digest is never shown as another server's.

## Routes
- None changed. No new texts; the map looks as before.

## Core
- **Identity (#1):** `mcpIdentity` also takes the env and headers, as a salted digest
  (`_settingsDigest`: sha256 of `maprisma-mcp-settings\n` and the sorted name/value pairs). Their values are in
  no id, label, identity string, cache or result; the box keeps its short target. An entry without env or
  headers keeps the identity it had, so its digest and the tool answers kept with it still match. Saved list
  entries keep their env, so a saved server with env is found again as the same server.
- **Saved servers (#4):** `McpPlans.knownServers` gives a new first server of a name its name only when no
  saved server holds it, used or not; else the next free `name~N`. Only an update (`mcp_update`, which
  rewrites the agents' entries and the list's keys together) changes a saved server. A server whose definition
  changed in an agent is a new one: the old definition stays under its key until it is forgotten.
- **Old tool answers (#5):** `cachedTools(…, identity:)` takes an answer only when it carries that digest. One
  kept before digests (it holds nothing that tells its server) counts as none, so the tools are asked again;
  the file stays. Without a digest to compare (no definition known) it is shown as before.
- Python reference in step: `mcp_ctl` (`identity`, `_settings_digest`), `mcp_library.remember`,
  `mcp_tools.cached`.

## Acceptance
- `packages/maprisma_core/test/mcp_variants_test.dart`: another ROOT or workspace header is another server, the
  same env in another order is not, and no value reaches the ids, labels or identity; a saved server with env is
  still that server and an env-less digest is unchanged; a saved unused `filesystem` keeps its key when another
  `filesystem` comes (`filesystem~2`), and a changed one becomes `filesystem~3`; an answer without digest is
  none for a known server and stays on disk; the digests are the reference's.
- `tests/test_inventory_graph.py` `ReviewChainTest` and `tests/test_mcp_tools.py`: the same on the reference,
  with the same digests.
