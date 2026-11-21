# Review: 088 Projects board, part 2 (the board, GUI)

Reviewers: Codex and Antigravity (read-only), rounds until both say CLEAN. Artifacts:
`.flutter-previews/task-088-checks/`.

## Deviations from the plan
- The Phases view (step 4), the project page's large rail and Team graph (step 3) and the tab
  links (step 5) are later steps.
- The card shows the execution team (the planning team before a plan exists); the planning team
  of a running plan is shown when its assignment is active.
- The "needs an update" note for an older backend is one line above today's page.
- The first-agent guide link of the empty board waits for step 5 (links between the tabs).

## Checks
- `flutter analyze lib` clean; `test/project_board_test.dart` (10), `test/main_tabs_app_test.dart`
  (board cases), the page, setup and translation tests.

## Round 1 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r1.txt`, `agy-review-r1.txt`.

- **R1-1 (both): a failed Open still opened a project page.** *Fix:* `_choose` reports success;
  the page opens only after the project was read. Test (a deleted project stays on the board).
- **R1-2 (both): team setup had no Pause and no helper node.** *Fix:* Pause while the setup runs
  (not while old processes stop); the helper is the first node, marked working. Test.
- **R1-3 (both): the way back to the board bypassed the departure guards** (closing, another
  departure, a step, focus). *Fix:* Esc, the breadcrumb and the Projects tab go through the
  shell's `_backToBoard` (not while closing or occupied, "Wait for the current step" during a
  step, the keyboard given back when it does not happen, the tab saved only on success); not
  under a terminal. Test: Esc while the close waits for its summary keeps the project (fails
  without).
- **R1-4 (both): the store fault was dropped.** *Fix:* the list's summary error is a banner above
  the board. Test.
- **R1-5 (both): no loading or unavailable state; `_error` never cleared.** *Fix:* a spinner
  until the first answer; unreachable shows "Project status unavailable" with Retry and no
  counts (never the old page, never zero), retried about every 15 s; a successful read clears
  the board's message. Test.
- **R1-6 (both): narrow header and card overflowed with long translations.** *Fix:* on the board's
  project page status and "Unsaved changes" sit in the breadcrumb row and shorten; the tab
  selector is compact; card actions shorten; narrow "New project" is a symbol; the card and node
  sizes follow the text size; widths come from the available space, not the window. Test with
  doubled texts at 480 × 360 and 1.5× text, edited.
- **R1-7 (both): focus return failed for scrolled cards.** *Fix:* the board stays mounted (hidden)
  while a project is open, keeping its position and the card. Test: the last of 64 cards.
- **R1-8 (Codex): a refresh moved a focused card.** *Fix:* while a card has the keyboard the
  order is held (new cards at the end); the grid keeps elements by id. Test.
- **R1-9 (both): a project kept behind the board kept the poll at 2 s.** *Fix:* only the open
  project counts as active. Test: back from a running project, completed: no read for 14 s, then
  one (ticks instead of the clock, testable).
- **R1-10 (both): the last event was untranslated and without time.** *Fix:* the page's event
  translation and the time (today) or date. Test.
- **R1-11 (both): a marked member lost its model line; issues invisible; role untranslated.**
  *Fix:* the model or "Agent default" stays, the state is the ring, a symbol and the read-out
  label; a member problem has a mark; roles translated; positions checked. Tests.
- **R1-12 (agy): the narrow footer preferred Approve over Save after an edit.** *Fix:* edited:
  Save first. Also: the old page's list keeps room in a small window; `refresh` after a pause
  only while mounted; Review plan opens the Plan tab (test), no details read on the board (test).

## Round 2 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r2.txt`, `agy-review-r2.txt`.

- **R2-1 (both): a warning on the narrow project page left the body no height.** *Fix:* the
  "still stopping" warning and errors scroll with the body; the footer stays. Test: app bar,
  warning, doubled texts, 1.5× text, an edit, at 480 × 360 (no overflow, the More menu there).
- **R2-2 (both): a card that moved while its project was open lost the keyboard on return.**
  *Fix:* the board holds its order while a project is open (the card stays where it was left).
  Test: card 63 becomes the most urgent while open (fails without).
- **R2-3 (both): a pressed card could still move.** *Fix:* cards report pointer down and up; the
  order holds while one is pressed; the grid's elements are keyed by card. Test (fails without).
- **R2-4 (agy): a failed Pause's reason vanished with its own refresh; the button came back
  early.** *Fix:* the reason survives the read the pause asked for; Pause stays off until that
  read ended. Test: stale run (project_changed) refreshes, the reason shows, a second click while
  the first is on its way sends nothing (fails without).
- **R2-5 (agy): a failed read of the open project marked the board unavailable.** *Fix:* the
  details are read on their own; their failure is the project's message. Test.
- **R2-6 (agy): a stopped team setup left its helper unmarked; the marked member did not name its
  phase.** *Fix:* stopped setups mark the helper stopped; a marked member's phase (Planning or
  Execution) is in its tooltip and read-out. Test. The old page's title shortens.

## Round 3 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r3.txt`, `agy-review-r3.txt`.

- **R3-1 (Codex): profiles that could not be read made the board unavailable.** *Fix:* the list is
  read on its own; a profile failure is only a message (on the old page). Test.
- **R3-2 (both): a poll on its way erased a failed Pause's reason.** *Fix:* only the pause clears
  its keep flag, after its own read. Test with a held poll.
- **R3-3 (Codex): a card that left the filter lost the keyboard on return.** *Fix:* back on the
  board the filter is cleared when it would hide the opened card. Test.
- **R3-4 (both): the empty board overflowed at 480 × 360 with large text.** *Fix:* it scrolls.
  Test with the app bar and doubled texts; New project from it opens the project page.
- **R3-5 (agy): the project page's message stayed on the board; a late detail answer could show
  there.** *Fix:* leaving the project clears its message; a detail failure shows only while its
  project is open.
- **R3-6 (agy): tests.** The looked-up board texts (filters, stages, activities, issues, roles,
  states) are checked in all languages; a dead assertion removed.

## Round 4 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r4.txt`, `agy-review-r4.txt`.

- **R4-1 (both): after the filter was cleared the opened card could lie outside the built part of
  the grid**, so it did not get the keyboard; no fallback for a deleted card. *Fix:* the page owns
  the grid's scroll controller; back from a project the board scrolls the card into view (only
  when it is not visible already) and then gives it the keyboard; a deleted card's place goes to
  the first card (a node is used only while its card is still mounted). Tests: a draft behind 63
  running cards, filter Drafts, it starts running, back: visible and focused (fails without the
  scroll); a deleted project: the first card.

## Round 5 (Codex and agy, 2026-11-22): NOT CLEAN

Reports: `codex-review-r5.txt`, `agy-review-r5.txt`.

- **R5-1 (both): the fallback for a deleted card could be off screen or filtered out.** *Fix:*
  the fallback is chosen before the reveal, from what the filter shows (scrolled into view like
  any card); with no card left, New project gets the keyboard. Tests: the last of 64 deleted
  (the first card, in view); the only Drafts card deleted (New project).
- **R5-2 (agy): a card in the last row was not scrolled to** (its place was clamped before the
  visibility check), **and without a scroll the focus waited for an unrelated frame.** *Fix:* the
  check uses the card's real place, the scroll clamps; without a scroll the card is focused at
  once, after one the next frame is asked for. Test: 10 cards, the last-row card fully in view and
  focused (fails with the clamped check).

## Round 6 (Codex and agy, 2026-11-22): agy CLEAN, Codex NOT CLEAN

Reports: `codex-review-r6.txt`, `agy-review-r6.txt`.

- **R6-1 (Codex): a wide but low window left the compact layout** (640–800 × 360 with 1.5× text
  overflowed by 157 px). *Fix:* the project page is compact (tab selector, one action and More)
  when it is narrow or low for the text size (height below 460 × the text scale). Tests at 640,
  700 and 800 × 360 with 1.5× text, the app bar and doubled texts (fail without).

## Round 7 (Codex and agy, 2026-11-22): CLEAN

Reports: `codex-review-r7.txt`, `agy-review-r7.txt`. Both CLEAN: rounds 1–6 verified against the
code and the tests, no new finding.

**Task 088 review: CLEAN.**
