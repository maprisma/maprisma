# 007 Ask AI makes real changes

Author: Claude · Reviewer: Uwe in the running app (Antigravity paused, 2026-10-31) · Branch: task/007-ask-ai-actions

## Goal
Uwe, 2026-10-31: Ask AI is a key feature. In each column of the map the user asks, the helper proposes, the user sees
the normal preview and approves, the change happens on the PC and the map shows it.

The column stays the frame: its helper has a fixed list of actions and turns down anything else, naming the right
column. A more general helper can come later on a page of its own (System Map's AI buttons are the start).

## Rules
From task 004, unchanged: the agent has no tools and answers once with JSON; the core checks it and keeps the action;
the GUI names a candidate and never holds what runs; tokens only on the click on Ask; nothing changes without the review.

## Columns, one at a time
| Column | Actions | State |
|---|---|---|
| MCP servers and skills | add an MCP server from the registry, connect a server to an agent, disconnect it | this step |
| Models | search and download, remove, move a model folder to a disk | done |
| Agents | install, update, remove | done |
| Providers | install, update, start, stop | done; remove needs an uninstall first, none exists |

Not yet in the MCP column: skills, and updating or removing a server from the PC. The helper says so.

## Routes
`map.smart_ask` answers for `column: mcp`. New `map.smart_plan {proposal, candidate, agents, values}` (preview): the
plan for ConnectionReview, then `connections.apply`. An MCP candidate has `kind` (`mcp_add`, `mcp_connect`,
`mcp_disconnect`), `agents`, and `needs` (fields the user fills in; secrets never reach the agent).

## UI
The card's proposal step opens a form for `mcp_add` (agents to connect, needed fields), then the normal review. A
provider step opens the app's own page with its review.

## Acceptance
Unit tests: only a listed action passes, unknown servers and agents are refused, the pick comes from the real search,
a secret is never in a prompt. Widget test: proposal, form, review, applied. Real run on Uwe's PC with a real agent.
