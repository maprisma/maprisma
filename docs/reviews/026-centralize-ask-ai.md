# Review 026: Centralize Ask AI in the header bar

## Round 1 (Claude, 2026-11-03, commit b7755ab)

Checked: `tools/test-changed --base main` (all passed) and `MAPRISMA_PUB_OFFLINE=1 tools/flutter-dev check`
(analyze clean, 170 + 255 tests passed) on the detached branch. No route changes. The loose changes that were
on main's working tree are all in the branch (one test line differs only in formatting); the stash
`stash@{0}` "task/026-centralize-ask-ai" in the main checkout still holds them.

No High or Medium finding.

1. **Low** `flutter_app/lib/map_smart_card.dart:2411` and `:2536` The window's keys now contain the active
   category (`smart-window-$_column`, `smart-card-$_column`). A click on a category chip (`_buildCategoryChips`,
   `:1504`; the status chips, `:1916`) therefore throws the whole `OverlayWindow` away and builds a new one:
   a window the user dragged larger snaps back to its default size (the size lives in `_OverlayWindowState`),
   and the question field is rebuilt under the cursor. On main every column had its own card, so the key
   only told four windows apart; now it is one window whose content changes. Keep one key for the central
   window (e.g. `smart-window` / `smart-card` while `!showBar`) and find the active category in tests by the
   selected chip or the title instead.
   > Author:

2. **Low** `flutter_app/lib/map_smart_card.dart:1490` The prompt view's category chips are wrapped in
   `ExcludeFocusTraversal`, so with the keyboard alone the category cannot be changed any more (on main each
   column's bar was reachable with Tab). The status view's chips (`:1898`) are not excluded. Let the prompt
   chips take part in Tab order too (they come after the field, so typing is not disturbed).
   > Author:

3. **Low** `flutter_app/lib/main.dart` (the `ask-ai-open` button) The button is enabled while `_busy`, but
   `_openAskAi` returns at once when `_busy` (`main.dart`, `_openAskAi`): a click then does nothing and says
   nothing. The task doc says it is disabled while `_keysBlocked || _busy`; the code disables it for
   `_keysBlocked || _snapshot == null`. Add `_busy` to the condition (or have the doc say what the code does).
   > Author:

4. **Low** `docs/tasks/026-centralize-ask-ai.md` The doc says the tooltip is `tr('Ask AI…')`; the code uses
   `tr('Ask AI')`. One of the two should change so they agree.
   > Author:

5. **Low** `flutter_app/test/task_cards_app_test.dart` The new test covers the header button, the four prompt
   chips (title and hint) and Esc. Three acceptance points of the task have no test: switching categories
   with the status chips (`smart-status-<col>`), a chip enabling that category's map layers
   (`_neededLayersForColumn` → `map_layers`), and "Move to …" switching the category in place while keeping
   the question (`map_smart_card.dart:2034-2046`).
   > Author:
