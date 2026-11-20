# 079 Compact Settings

Independent reviewer: Codex. Reviewed the working tree based on `2dd54ff`,
read-only until writing this review record. No tests or suites were run by
the reviewer.

The requested external reviews could not run: Claude returned API/DNS
`EAI_AGAIN`; Antigravity (`agy`) could not start its local socket server
(`EPERM`, operation not permitted). Neither external agent supplied a review
verdict. The CLEAN verdict below belongs to Codex only.

## Round 1 (Codex, 2026-11-20, working tree based on 2dd54ff)

1. **Medium** `flutter_app/lib/settings_view.dart`, sidebar focus visibility.
   Scrolling only on focus changes leaves Recent changes focused below the
   viewport when a wide window shrinks from 1400 × 900 to 1400 × 400.
   > Author: Track layout geometry and re-show the focused navigation item
   > after layout. Added a tall-to-short wide-window regression.
2. **Low** `flutter_app/test/settings_layout_test.dart`, locale/size/scale matrix.
   Checking only layout exceptions after a tap can pass without opening the
   requested section when the tap misses a popup item.
   > Author: Assert the actual dropdown value or selected sidebar tile after
   > each choice. Locate popup options within their scrollable, scroll them
   > into view, and assert that they are hit-testable before tapping.

## Round 2 (Codex, 2026-11-20, working tree)

The round-1 fixes address the reported cases.

1. **Medium** `flutter_app/lib/settings_view.dart`, open compact selector.
   Popup-route focus makes the selector and sidebar focus checks false.
   Resizing compact to wide while its menu is open removes the popup without
   restoring keyboard focus to the selected sidebar item.
   > Author: Track the open selector and transfer navigation focus after the
   > layout changes. Added an open-menu keyboard-resize regression.
2. **Medium** `flutter_app/lib/settings_view.dart`, activity-log retention.
   Converting the controlled retention dropdown to a form field leaves an
   optimistic internal selection visible when saving fails and the persisted
   value remains unchanged.
   > Author: Keep a controlled `DropdownButton` inside `InputDecorator`.
   > Added a regression verifying that an unsaved choice leaves the persisted
   > retention value displayed.

The review also identified a visual verification requirement for long selected
form-field labels: `itemHeight: null` alone does not remove the default dense
button's single-line height. The author uses `isDense: false` for long-value
Settings fields and the dictation-engine selector. The compact navigation
button deliberately uses a single-line selected label with a tooltip; its
popup choices wrap in full. The dictation badge's `Flexible` placements are
valid within their parent rows, and its test controls use `OverflowBar`.

## Round 3 (Codex, 2026-11-20, working tree)

1. **Medium** `flutter_app/lib/settings_view.dart`, pointer-open focus tracking.
   Opening the selector by pointer while search has focus can deliver the
   selector's initial focus notification before popup autofocus. Clearing the
   open flag on any focused notification loses the state needed for a later
   wide resize. The initial keyboard regression starts with the selector
   focused and does not exercise this sequence.
   > Author: Reproduced the pointer sequence, then track whether focus has
   > actually left the selector for the popup. Only returning focus clears the
   > open flag. Regressions now cover pointer and keyboard opening, wide resize,
   > and cancelling a later menu followed by a search-focused resize to check
   > that stale state does not steal focus.

## Round 4 (Codex, 2026-11-20, working tree)

**CLEAN — Codex source review.** The prior findings are addressed. The final
popup tracking distinguishes initial pointer focus from focus returning after
dismissal. Retention remains controlled; geometry changes preserve visible
navigation focus; matrix assertions verify actual section selection. No
additional actionable defects were identified in the reviewed changes.

This is a source-review verdict, independent of the author's runtime checks.
Claude and Antigravity remain unavailable and are not credited with CLEAN.

## Author verification reported separately

The author reports the following related checks; the reviewer did not execute
them:

- 19 layout tests pass: `/tmp/maprisma-079-final-layout.log`.
- 13 related appearance, local-LLM and map tests pass:
  `/tmp/maprisma-079-related.log`.
- Six fixture captures were produced for visual inspection.
- Two existing dictation integration tests fail identically with unchanged
  `2dd54ff` source: `/tmp/maprisma-079-dictation-baseline.log`. Their path-safety
  checks encounter sandbox ancestors owned by `nobody`. The Dart core is
  unchanged and its safety checks were not bypassed.

Only related checks were run, following Uwe's 2026-11-20 instruction. No full
suites were run; full suites are reserved for before a push. No push is part
of this task.
