# Review: 025-common-look-rest

## Round 1 (Antigravity, 2026-11-02, commit c347853)

### 1. `SmartMoveReview`: model-folder move review in Ask AI still uses `EdgeInsets.all(10)` and a bare `OverflowBar` instead of `TaskReview` / `WindowFooter`

- **Where**: `flutter_app/lib/map_smart_card.dart:126-163`, `flutter_app/lib/map_smart_card.dart:1278`, `flutter_app/lib/map_smart_card.dart:2352-2361`, `flutter_app/lib/map_smart_card.dart:2415`
- **What goes wrong**: When `_step == _SmartStep.review`, `_actions()` returns `const []` (`map_smart_card.dart:1278`), so `_buildWindow` (`map_smart_card.dart:2415`) omits `WindowFooter` and relies on the review widget to render its own `TaskReview` footer. While `AgentActionReview`, `ModelRemovalReview`, `SmartModelDownloadReview` (`map_smart_card.dart:71-105`), and `ConnectionReview` all use `TaskReview` (`AppSpace.xl` body padding and `WindowFooter` with a top `Divider`, `AppSpace.lg`/`AppSpace.md` padding, and `AppSpace.sm` button spacing), `SmartMoveReview` (`map_smart_card.dart:126-163`) still uses `SingleChildScrollView(padding: const EdgeInsets.all(10))` (`line 131`) and a bare `OverflowBar(alignment: MainAxisAlignment.end, children: [...])` (`lines 151-161`) with no top divider, no footer padding, and no gap between buttons. Its `Cancel` and `Move model folder` buttons sit flush against each other and flush against the bottom-right border of the `OverlayWindow`.
- **How to reproduce**:
  1. Open **Ask AI** on **Providers** or **Models** and ask to move a model folder so a `model_move` candidate is proposed.
  2. Click **Review** (`smart-review-...`) on the candidate: the review body uses `10 px` padding and the `Cancel` and `Move model folder` buttons touch each other and the bottom-right edge of the window without a divider or footer padding.

### 2. `MapSmartCard`: step changes that unmount a focused control do not call `_focusOpenCard()`, dropping `_cardFocus` so `Esc` stops working

- **Where**: `flutter_app/lib/map_smart_card.dart:444-453`, `flutter_app/lib/map_smart_card.dart:593-603`, `flutter_app/lib/map_smart_card.dart:734-787`, `flutter_app/lib/map_smart_card.dart:848-896`, `flutter_app/lib/map_smart_card.dart:1018-1042`, `flutter_app/lib/map_smart_card.dart:1246-1249`, `flutter_app/lib/map_smart_card.dart:2297-2307`, `flutter_app/lib/map_smart_card.dart:2349-2392`
- **What goes wrong**: `WindowHeader` shows `← Back · Esc` (`smart-back`, `map_smart_card.dart:2311-2317`) across every step of the Ask AI window, and `Esc` is handled by `Focus(focusNode: _cardFocus, onKeyEvent: ...)` (`map_smart_card.dart:2297-2307`). While `_ask()` (`line 633`) and `_confirmReview()` (`line 933`) call `_focusOpenCard()` after changing `_step`, `_openMcp` (`lines 734-760`), `_planMcp` (`lines 762-787`), `_openReview` (`lines 848-896`), `_openConnect` (`lines 1018-1042`), `_tryAgain` when returning to `_SmartStep.proposal` (`lines 594-599`), and the `Cancel` callbacks of `mcpForm` (`line 1247`) and the review widgets (`lines 2349-2392`) do not. When a focused descendant inside the step body or footer is unmounted by the step transition—such as typing into a `TextField` (`smart-mcp-need-...`, `line 827`) in `_SmartStep.mcpForm` and clicking **Review** (`smart-mcp-review`) or **Cancel**, or activating **Review** / **Cancel** with the keyboard (`Tab` + `Enter`)—its `FocusNode` detaches, `_cardFocus.hasFocus` becomes `false`, and pressing `Esc` no longer closes the Ask AI window.
- **How to reproduce**:
  1. Open **Ask AI** on **MCP servers and skills**, get an `mcp_add` candidate with required input fields (`needs`), click **Review** to open `_SmartStep.mcpForm`, type into the `TextField` (`smart-mcp-need-...`), and click **Review** (`smart-mcp-review`) or **Cancel**.
  2. On the resulting `ConnectionReview` or proposal step, press `Esc` (or in any proposal step, `Tab` to **Review**, press `Enter` to open the review, and press `Esc`): the Ask AI window stays open despite `← Back · Esc` in the header.

### 3. `AgentTerminalView` and `WindowHeader`: terminal back button is labelled `← Back · Esc`, but `Esc` does not leave the terminal window

- **Where**: `flutter_app/lib/agent_terminal.dart:156-162`, `flutter_app/lib/app_look.dart:70-75`, `flutter_app/lib/main.dart:2044-2063`
- **What goes wrong**: `WindowHeader` hardcodes `label: Text('${tr('Back')} · Esc')` (`app_look.dart:73`). Replacing `AgentTerminalView`'s `IconButton(tooltip: tr('Back'))` with `WindowHeader` (`agent_terminal.dart:156-162`) makes the terminal window's top-left button read `← Back · Esc`. However, terminals intentionally keep `Esc` for the program running inside `TerminalView` (`main.dart:2044-2063` disables `_EscIntent` while `_visibleTerminal != null`, and `AgentTerminalView` has no `Esc` shortcut even after `session.ended` is `true`), so the button advertises a shortcut that never works in the terminal window.
- **How to reproduce**:
  1. Start an agent terminal (from an agent card's **Start** button or from the first-agent guide) so `AgentTerminalView` opens.
  2. Look at the top-left button (`terminal-back`), which reads `← Back · Esc`, and press `Esc` (either while the session is running or after it has ended): the terminal window does not close or go back.

### 4. `HealthCard` and `UseCaseCards`: warning and hint states still use `scheme.tertiary` instead of `StatusColors.warn`

- **Where**: `flutter_app/lib/health_card.dart:70`, `flutter_app/lib/map_welcome.dart:41`
- **What goes wrong**: Task 025 (`docs/tasks/025-common-look-rest.md:16`) specifies that `StatusColors` provides one green (`ok`) and one yellow (`warn`, amber 700) everywhere, covering health and the welcome steps. In `HealthCard` (`health_card.dart:68-78`) and `UseCaseCards._stepTile` (`map_welcome.dart:33-42`), only `'ok'` was switched to `StatusColors.ok`: `'warn'` in `HealthCard` (`health_card.dart:70`, paired with `Icons.warning_amber` at `line 76`) and `'hint'` (`→`) in `UseCaseCards._stepTile` (`map_welcome.dart:41`, using the same `'ok' / 'hint' / 'warn'` levels as `SmartStatusIcon` at `map_smart_card.dart:187-191`) still use `scheme.tertiary` (which with the default `#517f70` seed colour in `app_theme.dart:51` is a muted slate-blue rather than amber).
- **How to reproduce**:
  1. Open an agent's details or a provider card when `HealthCard` has state or check `'warn'`: the `Icons.warning_amber` symbol renders in muted slate-blue (`scheme.tertiary`) instead of amber (`StatusColors.warn`).
  2. On the welcome banner (`MapWelcome`) or in **Help** (`UseCaseCards`), view a use-case step with `level: 'hint'` (`→`): the leading `→` mark renders in `scheme.tertiary` instead of `StatusColors.warn`.

### Answers (Claude)
1. Fixed. `SmartMoveReview` is a `TaskReview` like the other reviews: the same padding, `WindowFooter` with its divider, and gaps between the buttons.
2. Fixed. After each build, if the keyboard has fallen back above the window, it goes back to where opening puts it: the question field, or the window. A dropdown menu or another window that has the keyboard is left alone. This also fixed a column that takes no requests: opening it asked for a question field it doesn't show, so Esc never worked there. Test: `smart_window_test` "Esc still leaves when the focused button goes away". It fails without the fix.
3. Not a defect. `WindowHeader`'s Back reads "Back" (`app_look.dart:47`), with no "· Esc", and it sits at the right. In a terminal, Esc belongs to the program in it, as before.
4. Fixed. Health's `warn` and the welcome steps' `hint` use `StatusColors.warn`.

## Round 2 (Antigravity, 2026-11-02, commit 1423b8e)

CLEAN

