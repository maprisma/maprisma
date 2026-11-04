# Ask AI parity and calm map guidance

## Goal

Maprisma gives a new user a clear picture of their AI setup and helps them make changes safely. A colored line represents a real connection or live activity. Red means a confirmed problem that the user can act on. Ask AI can perform every edit available by drawing on the map, through the same preview and apply routes, and can also help with downloads, diagnosis and local LLM performance.

## Current state (2026-11-04)

- The map can connect an agent to a provider, MCP server, skill folder or model; move or disconnect a line; switch a model; repair a failed line; and forget an unused MCP server. The UI uses `flutter_app/lib/main.dart` and the core's `map_edits.dart` routes.
- Ask AI searches and downloads models and MCP servers, connects and disconnects MCP servers, disconnects local models, moves or removes models, and handles selected agent and provider actions (`smart_card.dart`, `core.dart`). Its model and MCP searches use real results and checked candidates.
- Ask AI now proposes manual map edits through the same checked preview routes. The MCP column also connects an existing skill folder by its short id. Sign-in and sign-out are available through the agent's existing action review.
- The Performance page shows hardware stack, video memory, model context and measurements, and offers checked AI suggestions whose setting and context changes go through preview and Apply. Ask AI now opens that page for performance requests.
- The current Flutter subagent tree symbol and live list exist. The old app's separate subagent map has not been ported.

## Behavior

1. Show ordinary availability and healthy setup as neutral information. Show red only for a confirmed actionable error; a warning or uncertain observation stays neutral and explains what was observed. Never imply that an idle or unselected model is broken.
2. Give Ask AI the same checked action catalog as the map. Each candidate names the affected agent and item, uses the existing preview route, and needs Apply before a write. Keep one Undo for a configuration change when the route supports it. Ask AI and manual editing must obey the same action rules.
3. For ambiguous requests, ask one plain question. For unsupported edits, explain the limit and lead to the manual control. Never claim that a proposed action succeeded until the worker reports success and the refreshed map reflects it.
4. Keep model and MCP discovery grounded in search results and checked download/install plans. Explain size, format, disk and memory fit in familiar words before Apply. Expose precise technical details on request.
5. For performance help, gather the actual GPU, VRAM, available backends, running build, model size, context, measured speed and observed errors. Explain which evidence supports a suggestion. Offer supported actions such as context tuning or model choice through existing preview routes. Treat Vulkan and ROCm as alternatives only when this machine and the installed build support them; do not promise a speedup without a measurement.

## Delivery order

1. Finish map semantics and visual status: hide availability lines, keep distinct collaboration paths, and reserve red for confirmed errors.
2. Keep Ask AI candidates for manual map actions on the existing preview routes. Review protocol notes and implementation under `AGENTS.md`.
3. Continue refining guided repair and performance advice using Health, tuning and measurement facts. Test no-op and refusal paths as carefully as successful apply paths.
4. Update the manual and all seven translation files for each new user-facing action.

## Acceptance

- Every map draw action has an equivalent Ask AI request that reaches the same preview and apply behavior, including refusal, result and Undo.
- An idle available model has no connection line or alarm mark. A warning is never colored as a confirmed error.
- Download advice includes checked compatibility and does not begin a download without Apply.
- A performance suggestion states the measured or detected facts behind it and offers only actions this build can perform.
