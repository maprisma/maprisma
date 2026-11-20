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

## Round 5 (Claude, 2026-11-20, task branch at 44820c4 against 2eb027d)

Reviewed read-only first (implementation and tests before the earlier rounds); Uwe then asked the
same session to fix the findings, so the answers below are the author's in that session and the
fixes still need an independent round.

1. **Medium** `flutter_app/lib/settings_view.dart` (all changed `DropdownButtonFormField`s) and
   `flutter_app/lib/dictation_card.dart:162`. `isDense: false` everywhere made every drop-down
   80 px tall at normal text in the wide layout (56 px before, as tall as the text fields next
   to them; measured), and the Map card's compact dictation controls lost their compact height.
   > Author: `SettingsView.denseFields` keeps drop-downs dense in the wide layout at normal text
   > (the base look) and lets them wrap only in the compact layout (narrower than 840 px times
   > the text scale, the rule `_SettingsPages` uses) or with larger text. `DictationControls`
   > uses `isDense: compact`. Test: "drop-downs stay dense in the wide layout at normal text".
2. **Low** `settings_view.dart:1581`. During a search the compact selector still showed the last
   section, while the wide list marks none.
   > Author: the selector's value is null while a search runs (its hint shows). Test: "a search
   > marks no section in the compact selector".
3. **Low** `settings_view.dart:1500`. With `section: 'all'` there is no section focus node, so
   going from compact to wide with the selector focused lost the focus.
   > Author: falls back to the first section's node.
4. **Low** `settings_view.dart:991`. The retention field's `InputDecorator` showed neither
   keyboard focus nor the busy state.
   > Author: `_DecoratedField` follows its drop-down's focus and greys out while busy; it still
   > shows the saved value after a failed update. Test: "the retention field shows focus and its
   > busy state".
5. **Low (concern)** `settings_view.dart:1573`. The selector's semantics label equals the window
   title.
   > Author: kept; the drop-down reports the chosen section as its value after the label. Not
   > verified with a semantics test.
6. **Low** `docs/manual/manual.html:908` (all 8 manuals). The compact paragraph came before the
   one introducing the sections.
   > Author: swapped in all 8 manuals; `translations.py stamp <lang> settings-list` for the 7
   > translations.

Coverage still open: choosing a section by keyboard (arrows, Enter, Tab into it), reaching the
end of long sections, search in de/pl at 150/200 %, resizing with a content drop-down open, the
Map card's dictation controls (only the `compact` flag is set; no widget test), and the two
blocked Dictation integration tests.
