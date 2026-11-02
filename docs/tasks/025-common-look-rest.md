# 025 One look, the rest: Ask AI, terminal, welcome, state colours

Author: Claude · Reviewer: Antigravity · Branch: task/025-common-look-rest, on task/024-dictation

Uwe, 2026-11-02: steps 4 and 5 of task 023 (docs/tasks/023-common-look.md), the parts that 023 left open. The same parts as 023: `AppSpace`, `WindowHeader`, `WindowFooter`, and the rules found in 023's review.

## Done
1. **Ask AI window** (`map_smart_card.dart`):
   - The window uses `WindowHeader`. Its title is "Ask AI · column". Its actions are the helper choice (at most 300 px wide) and the rules button. Back (`smart-back`) leaves the window, as Collapse did. Below 640 px the actions go under the title.
   - The footer is `WindowFooter`. There is no Close in the footer, because Back in the header leaves the window.
   - The old "← Back" (back to the question) is now "Ask again" (`smart-ask-again`). In the MCP form it is "Cancel", so the window never has two Backs.
   - The status page has an Ask button (`smart-status-ask`). It replaces the click on the title, which is now plain text.
   - The body has 16 px padding. The proposal boxes follow the corners setting and use `AppSpace`.
2. **Terminal window** (`agent_terminal.dart`): `WindowHeader` shows the command as title and the folder as the line under it. Stop/Close and the error symbol are its actions. Back (`terminal-back`) is at the right, as in every window. The padding is `AppSpace`.
3. **Welcome view and terminal tabs** (`map_welcome.dart`, `terminal_tabs.dart`): gaps and padding use `AppSpace`.
4. **State colours** (`app_look.dart` `StatusColors`): one green (`ok`) and one yellow (`warn`, amber 700) everywhere. This covers map lights, the Ask AI status icon (which was amber 800), health, runtime details, the agent list, usage, the welcome steps and terminal tabs. Red stays the theme's `error`.

## Left open, for Uwe to decide
- **16 Material dialogs** (`showDialog`), for example subagents, traffic, the MCP tools inspector, adding a custom MCP server, and runtime host/port. They already follow the corners setting through `DialogThemeData`. Moving them into `OverlayWindow` + `TaskHost` would be a task of its own.
- **Hard-coded font sizes** (11/12) in Ask AI and on the map's cards. Moving them to the theme's text styles changes nothing visible at today's sizes.
