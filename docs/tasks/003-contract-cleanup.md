# 003 Clean contract, COSMIC's terminal

Author: Claude · Reviewer: Antigravity · Branch: task/003-contract-cleanup

## Goal
The contract and the client hold only what the core accepts, and Maprisma finds COSMIC's terminal.

## Routes
No route changes behaviour. routes.json: parameters from refused test requests go (`x`, `extra`, `bogus`,
`flutter_map_layout` as a parameter), `remove` is `bool`, map-shaped parameters are `object`; optional parameters
move from `OPTIONAL` in tools/protocol.py to `"optional"` in routes.json; `sessions.start`, `system.help_preview`
and `system.fix_preview` get their parameters.

## UI
None. `cosmic-term` joins the known terminals (Dart core, Python reference). notes.md of tools/test-session.sh gets
COSMIC checks.

## Acceptance
- `tools/protocol.py update` learns only from requests that were answered.
- No client call takes a raw map where the route's fields are known.
- The generic desktop finds `cosmic-term` and starts `cosmic-term -- <program>`.
