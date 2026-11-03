# 026 Centralize Ask AI in the header bar

Author: Antigravity · Reviewer: Claude · Branch: task/026-centralize-ask-ai (on main)

## Goal
Replace the four per-column Ask AI bars on the map canvas with a single `✦` Ask AI button in the app header bar (`ask-ai-open`), matching Maprisma Launcher's centralized Ask AI header entry. Inside the Ask AI overlay window, category chips let the user switch between the four map categories (`MCP servers and skills`, `Agents`, `Providers`, `Models`) and run the same category-based Ask AI actions and status checks without a separate smart page.

## Routes
None (`tools/routes.json` unchanged).

## UI
- `flutter_app/lib/main.dart`:
  - The app header bar shows an `IconButton` with `Icons.auto_awesome` (`key: ValueKey('ask-ai-open')`, tooltip `tr('Ask AI…')`, disabled while `_keysBlocked || _busy`) next to the health status button (`health-open`).
  - `MapEditor` on the main map is rendered with `smartCards: false`; a single app-level `MapSmartCard` (`key: ValueKey('ask-ai-card')`, `showBar: false`) hosts the overlay window.
  - `_openAskAi([String? column])` opens the centralized Ask AI window on the requested (or active) category in prompt mode (`_askPromptSeq++`), ensuring the category's map layers are enabled.
  - `_openProblems([String? column])` opens the centralized Ask AI window in status mode (`_smartStatusSeq++`) on the requested (or first concerned) category.
- `flutter_app/lib/map_smart_card.dart`:
  - `MapSmartCard` gains `showBar` (default `true` for standalone `MapEditor` use/tests, `false` when hosted centrally from the header bar), `onColumnChanged`, and `promptTrigger`.
  - When `showBar` is `false`:
    - No per-column bar is rendered on the canvas.
    - The overlay window is wrapped in `KeyedSubtree(key: ValueKey('smart-card-$_column'))` so category-scoped selectors continue to find the active category's window.
    - The idle prompt view shows a row of category `ChoiceChip`s (`key: ValueKey('smart-category-$col')`) for `mapSmartColumns` below the prompt field (or below the no-helper hint when no helper is configured).
    - The status view shows a row of category `ChoiceChip`s (`key: ValueKey('smart-status-$col')`) with each category's `SmartStatusIcon` so the user can inspect findings, add-on hints, and updates across categories.
    - Redirecting a question to another category (`Move to …`) switches `_column` in place when `onMoveToColumn` is not provided.

## Acceptance
- No per-column `Ask AI…` bars appear on the main app's map canvas; the header bar has `ask-ai-open` (`Icons.auto_awesome`).
- Clicking `ask-ai-open` opens the Ask AI overlay window on the current category in prompt mode; clicking a category `ChoiceChip` (`smart-category-<col>`) switches the active category, updates the header title (`Ask AI · <Category>`) and prompt hint, and enables the category's map layers.
- Clicking `health-open` (or a welcome/health entry) opens the window in status mode on the concerned category; clicking `smart-status-<col>` switches categories in the status view.
- Redirecting a question to another category switches the active category and preserves the prompt text.
- `tools/test-changed --base main` and `MAPRISMA_PUB_OFFLINE=1 tools/flutter-dev check` pass.
