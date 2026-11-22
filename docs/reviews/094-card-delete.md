# Review: 094 Delete a project from its card

Reviewers: Codex and Antigravity (read-only), rounds until both say CLEAN. Artifacts:
`.flutter-previews/task-094-checks/`.

## Checks
- `flutter analyze lib` clean; new `test/project_card_delete_test.dart` (8; the footer test fails
  without the return to the board); board, issue-link, link, Phases, translation and main-tab tests
  (109). Manual tests pass.

## Round 1 → fixes
- The card's question holds the page busy (as the footer's does), so F1, Ctrl+2, Ctrl+, and the
  window's close wait; a second click while it is open does nothing. Shell test (fails without it).
- Footer delete never saves first (an unsavable draft can still be deleted; Cancel keeps the draft
  unsaved); the deleted project leaves the list at once; back on the board after the read, with
  the keyboard on the first card the board shows (or New project), once the page is no longer busy.
- The card's actions sit in an Expanded row, the trash symbol after it (no Spacer squeezing them).
- While the board cannot be read the trash symbol stays, off.
- `_keepError` is a counter: one quick action's read no longer clears another's reason.
- Setup drafts of a deleted project are dropped.
- Tests (14): planning/reviewing off, focus after a footer delete (first card / New project),
  unsaved draft never saved, unavailable board; 127 affected tests pass.

## Round 2 → fixes
agy CLEAN. Codex: a read of the project still on its way when the footer delete succeeds could fail
afterwards and show "The project could not be found." on the board. A successful delete now marks
pending reads as outdated (`_selection++`). Regression test holds the read back until after the
delete (fails without the fix); 15 delete tests pass.

## Round 3 → fixes
Codex CLEAN. agy: a message from an older read (a failed `get` or board `list` while the delete
question is open, or a `list` failing after the delete while the page's own read waits) stayed on
the board after a successful delete. A successful delete now clears the page's message (unless a
board quick action keeps its reason), and the return to the board clears it again when the read
after the delete succeeded. Two tests (question open + failing `get` / failing `list`) fail only
when both clears are removed (each clear alone covers them); 17 delete tests pass, analyze clean.

## Round 4 → fixes
agy CLEAN. Codex: another card's failed Pause (its read of the board still on its way while the
delete question is open) lost its reason: the delete's read waited behind Pause's, Pause's counter
was back at 0, and the return to the board cleared the message. Failed quick actions are now
counted (`_quickFailures`); a footer delete clears the message only when no quick action failed
since it began. Regression test holds Pause's read back (fails without the fix); delete + board
tests pass, analyze clean.

## Round 5 → fixes
Codex and agy (same finding): the counter alone could keep a stale read error (Pause's own read of
the open project or the board failing) and lose the card's reason. Quick actions now also store
their reason (`_quickReason`); after a footer delete the message is cleared when no quick action
failed since it began, and otherwise set back to the latest quick-action reason (a failed read
after the delete still shows). Regression test: Pause fails, its read fails before the delete is
confirmed (fails without the restore); delete + board tests pass, analyze clean.
