# 063e MCP servers of one name

Author: Claude · Reviewer: Codex · Branch: task/063e-mcp (part of task/063-codex-review)

## Goal
Fix the MCP findings of the Codex coverage review (`docs/reviews/063-codex-coverage.md`, round 2): #1, #3, #4
and #5. Since 063a (F2) a second MCP server of one name is its own box, `mcp:<name>~2`. Every consumer must now
treat it as that server: the rules, the tools, the details, Ask AI and the list of known servers.

## Routes
- `details.mcp`, `mcp.tools`, `mcp.tools_cached`, `connections.forget_preview` take the map's id (`name` or
  `name~2`); their notes in `routes.json` say so. `mcp.tools` and `mcp.tools_cached` got their shapes
  (`{name}` → `{task}` / `{cached}`). `details.mcp`'s `server` is the id; its title keeps the name.
- No other params or results changed.

## Core
- **Identity (#4):** two servers of one name are the same server when `mcpIdentity` agrees: the transport with
  the whole address (path, port, query), or the transport with the command and every argument. Env and headers
  stay out. Inventory compares it as a digest (`mcpIdentityHash`), never shown; the box keeps the short target.
- **Rules (#1):** `_ruleItem('mcp', …)` is the configuration name (`mcpBaseName`: `fs~2` is `fs`), so every path
  that checks with it (`_enforce`, `_dropRefused`, `rules.test`, connect, disconnect, move, Ask AI candidates and
  `smartMenuChecks`) sees the name the rule was written for.
- **Tools and details (#3):** `mcpServerEntry` gives the definition of that very server: as one of its own agents
  keeps it, else as the list remembers it. `mcp.tools` asks it; answers are kept in `mcp-tools/<id>.json` with
  the digest of the server asked, and `cachedTools(…, identity:)` shows only an answer of that server (one kept
  before digests is taken as it is).
- **Ask AI (#5):** `smartMcpFacts` lists each server by its id with the agents of that very server, so a
  candidate carries `fs~2` and reaches its preview. `_disconnectAll` finds servers by id too.
- **Library (#5):** `mcp-servers.json` keeps every server of a name. A key is the name or `name~N`. A server keeps
  the key that holds the same server; a new one takes the name when it is the first of that name and the name is
  free, else the next `name~N`. Saved lists keep their plain names. Inventory maps each id to its key
  (`InventorySnapshot.mcpLibrary`, not shown); connect (`McpPlans.plan(libraryKey:)`), details and forget use it.
- Python reference in step: `mcp_ctl` (`LIBRARY_KEY_RE`, `base_name`, `identity`, `identity_hash`,
  `plan(library_key=)`), `mcp_library` (`load`, `remember`), `inventory` (`servers_in`, `add_server`, the list),
  `flutter_connections` (preview and forget by id), `mcp_tools` (`cached`, `ask_and_keep`).

## UI
- Settings › What may be done names an MCP server by its settings name: `mcp:fs~2` is `fs`
  (`ruleItemsOf`), so the rule list holds one `filesystem`, as the core checks it.
- No new texts; no manual change (the map looks as before).

## Acceptance
- `packages/maprisma_core/test/mcp_variants_test.dart`: a deny for `filesystem` refuses connecting and
  disconnecting `filesystem~2` (also through Ask AI and `rules.test`); tools, cache and details of `filesystem~2`
  are its own; other path, port or arguments make another server, other env does not; Ask AI's facts and
  candidate reach `filesystem~2`; the list keeps it after its last agent leaves, connects it again and forgets
  only it; a changed server keeps its key; the digest is the reference's.
- `tests/test_inventory_graph.py` `ReviewChainTest` and `tests/test_mcp_tools.py`: the same on the reference.
- `flutter_app/test/action_rules_window_test.dart`: rule items name `filesystem` once.
