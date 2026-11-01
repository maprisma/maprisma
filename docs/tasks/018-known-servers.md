# 018 Known servers stay, skills in Ask AI, lines that are not ours

Author: Claude · Reviewer: Antigravity · Branch: task/018-known-servers

Uwe, 2026-11-01, screenshot notes after disconnecting all servers: where is the card to reconnect them; why can skills not be disconnected, at least a better answer; why is there a line that cannot be disconnected.

## Known servers
`mcp_library.py` promises a server stays after its last agent, and the inventory lists it, but the map drew only servers with agents. This reverses the older rule "no MCP server no agent uses" in `tests/test_inventory_graph.py`. Both graphs now add a faded box for a known server without agents; drawing a line sets it up from the library. Ask AI's facts list these servers too, so it can connect them.

## Skills in Ask AI
`disconnect` takes `skills` beside `servers`, in the one candidate with one preview and Undo. Facts name the agents that can leave each folder.

## Lines that are not ours
An edge has `fixed`: why an agent keeps a skill folder Maprisma cannot take away, such as links in a folder it shares with other agents. Such a line gets no hook and no Disconnect in the box menu; a click shows the reason as a message, not a tooltip, because lines have no hover. Agents in `fixed` are left out of Ask AI's folders.

## Manual
smart-card and flutter-map-editor, 8 languages.
