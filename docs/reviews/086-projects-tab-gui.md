# Review: 086 Projects tab, part 2 (tabs and navigation)

Reviewers: Codex and Antigravity (read-only), rounds until both say CLEAN. Artifacts:
`.flutter-previews/task-086-checks/`.

## Deviations from the plan
- The board does not exist yet (step 2): "Clicking Projects while a project is open returns to the
  board" and "Esc: project → board" wait for it; Esc on the Projects tab leaves a text field, then
  closes or hides the window as on the map.
- The narrow header (< 760 px) moves Reports, Help, Settings and Refresh into "More"; Legend, the
  problems mark, Undo and Ask AI stay.
- Saving `main_tab` uses `settings.update`, which grows the discovery generation (085): one
  rebuild of the Project Center's display cache per tab choice.
- The translated manuals lag behind the English one (the Project Center chapter is not translated
  yet, `translations.py check`); this task changes the English manual only.

## Checks
- `flutter analyze lib` clean; widget tests; app tests `test/main_tabs_app_test.dart`.

## Round 1 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r1.txt`, `agy-review-r1.txt`. Widget tests before the fixes: 509 pass.

- **R1-1 (Codex): a save while leaving did not lock the page**; edits typed meanwhile were
  overwritten. *Fix:* the save inside the departure sets `busy` (fields and actions off); a second
  question cannot open (`_leaving`). Test with a delayed save.
- **R1-2 (both): Help's Agents, agent details and the guide's group pages stayed hidden behind
  Projects**, and Esc then acted on them. *Fix:* the Projects page shows only with the map's own
  state untouched (`_showMap`, no group focus); a page over Projects that leads to the map's own
  content switches the main tab to the AI Map (`_followMapDestination`, scanning the map if the
  start deferred it). A terminal no longer hides the page (focus and polling only). Test: Help ›
  Agents from Projects, Esc back to the map (fails without the redirect).
- **R1-3 (both): Ask AI and problems switched the tab before Reports agreed to close**, losing the
  return point on Cancel. *Fix:* `_toMapFirst` checks the open project and Reports first, then
  changes the tab. Test: Reports over Projects, Ask AI opens its card on the map.
- **R1-4 (agy): departures could stack under the close questions** (Ctrl+, / F1 / F5 while "stop
  running agents?" was open; the page read before the summary's await). *Fix:* `_leaveProjects`,
  `_selectTab` and `_retry` do nothing while closing or departing; the page is read after the
  await. Test: Ctrl+, and F1 under the close question ask nothing; Cancel keeps the draft.
- **R1-5 (Codex): F5 or the focus during a running read was dropped.** *Fix:* one more read
  follows it. Test (fails without it).
- **R1-6 (both): the tab buttons lost their tap action for assistive technology.** *Fix:* the
  button keeps its own semantics; label and selected state merge into it. Test through the
  semantics tree, including a semantic tap.
- **R1-7 (Codex): choosing the tab already shown was not remembered.** *Fix:* every explicit
  choice is saved (once per change of the saved value). Test (fails without it).
- **R1-8 (agy): switching to the map after a start on Projects showed the agent list** until the
  first scan. *Fix:* a loading state while the map's graph is missing.
- **R1-9 (agy): live polls could run before the start tab was decided.** *Fix:* they wait for it.
- **R1-10 (agy): F5 read the summary before the refreshed list.** *Fix:* the summary follows.
- **R1-11 (both): tests.** Added: startup summary not in time (AI Map, no late switch), Esc on
  Projects (the field, then close: this found that the focus left the window's key handler after
  leaving a field, fixed by returning the focus to the window page's own node), focus regained
  sends `refresh`, narrow header (More, no Legend, tabs kept), and those above.

## Round 2 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r2.txt`, `agy-review-r2.txt`. Widget tests after round 1: 529 pass.

- **R2-1 (agy): the app had no translations for the new texts**, and none for most of the AI
  Project Center page since its first task: the app reads only the keys listed in
  `tools/flutter-assets.py`. *Fix:* every text of the Projects tab and the Project Center page
  added (all already translated in `translations/`); test
  `project_texts_translated_test.dart`: every `tr('…')` of both files in all seven languages
  (fails with the old assets). Other pages' gaps (Provider settings and a few more) are not part
  of this task.
- **R2-2 (Codex): Help guarded before its lookup**: edits made meanwhile were not asked about.
  *Fix:* the guard runs right before Help shows; one opening at a time. Test with a delayed lookup
  (fails without).
- **R2-3 (both): after Help › Agents from a start on Projects, the map could stay loading**
  (scans manual). *Fix:* the deferred first scan is marked and runs as soon as the map is on
  screen, also for Ask AI and problems. Test with manual scans (fails without).
- **R2-4 (both): a refresh queued behind a running read returned at once**, so the counts were read
  before the refreshed list. *Fix:* its future ends after the queued read. Test.
- **R2-5 (agy): leaving while the departure's save ran said nothing.** *Fix:* "Wait for the current
  step". Test with a held save.
- Test backend: `slow_<method>` holds one answer until `release_<method>` exists.

## Round 3 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r3.txt`, `agy-review-r3.txt`. Widget tests after round 2: 533 pass.

- **R3-1 (Codex): back from Settings the keyboard was not in the project's field any more.** *Fix:*
  the page has its own focus scope; the node that had the keyboard when a page covered it gets it
  back when the page shows again. Test (fails without). Writing it found an older bug: a click
  or a cursor move in a field marked the project changed (the controllers report those too), so
  leaving asked "Save project changes?" without any edit. *Fix:* only a text that differs from
  the adopted project counts. Test. (The full widget run then showed that the role instructions
  and two more edits outside the four fields used the same hook: they now mark the change
  directly, `_changed()`; `ai_project_setup_test.dart` passes again.) (Ctrl+, does not reach the app from inside any text field:
  Flutter's text field takes it; not new, not changed here.)
- **R3-2 (agy): a Help lookup could open Help over a task, Ask AI or a terminal started
  meanwhile.** *Fix:* Help opens only when nothing else owns the window, checked before and after
  the lookup and the guard.
- **R3-3 (both): closing during a departure's save said nothing.** *Fix:* "Wait for the current
  step", also for a second close. Test.
- **R3-4 (agy): a waited-for refresh never ended when the page went away mid-read.** *Fix:* it
  ends with the page.

## Round 4 (Codex and agy, 2026-11-21): NOT CLEAN

Reports: `codex-review-r4.txt`, `agy-review-r4.txt`.

- **R4-1 (both): the round-3 change lost edits outside the four fields** (role instructions,
  optional model, AI setup request). Already found by the full widget run and fixed before the
  reports came (`_changed()`, see Round 3). Tests: each of the three on a saved project enables
  Save (all three fail with the round-3 state).
- **R4-2 (both): the keyboard did not come back after Help (a card over the page) or after a
  save on the way out.** *Fix:* the focus returns when the page can take the keyboard again (no
  card, no terminal); the field is remembered before the save question. Test: Help then Esc, and
  a saved edit on the way to Settings then Esc (fails without).

## Round 5 (Codex and agy, 2026-11-21): agy CLEAN, Codex NOT CLEAN

Reports: `codex-review-r5.txt`, `agy-review-r5.txt`. Widget tests on the round-4 state: 537 pass.

- **R5-1 (Codex): a departure that did not happen lost the field's keyboard** (a save that failed
  after the fields were locked; closing with Save, then Cancel at "stop running agents?"). *Fix:*
  the field is read before every departure and gets the keyboard back when the departure ends
  without leaving. Test for both cases (fails without).

## Round 6 (Codex and agy, 2026-11-21): Codex CLEAN, agy NOT CLEAN

Reports: `codex-review-r6.txt`, `agy-review-r6.txt`.

- **R6-1 (agy): F1 under the save question started Help's lookup**, and after Cancel the question
  came a second time (or Help opened over the destination). *Fix:* Help waits for a departure
  under way ("Wait for the current step" while its save runs). Test with a slow lookup (fails
  without).
- **R6-2 (agy): the failed-save focus test failed before the fields were locked.** *Fix:* the test
  now holds a save the service refuses (fields locked meanwhile, F1 says to wait), then checks
  the keyboard. Test backend: `error_<method>` makes a held answer an error.

## Round 7 (Codex and agy, 2026-11-21): agy CLEAN, Codex NOT CLEAN

Reports: `codex-review-r7.txt`, `agy-review-r7.txt`. Widget tests on the round-6 state: 539 pass.

- **R7-1 (Codex): closing took a "Discard" before the agents' shutdown was confirmed**; when the
  service refused (a project still pausing), the window stayed without the draft. *Fix:* the
  discard takes effect only right before the window goes; a refused shutdown keeps the draft and
  gives the keyboard back. Test with a refused shutdown (fails without).
- **R7-2 (Codex): Help did not wait for the page's own save question** (choosing another project or
  New project). *Fix:* Help also waits while the page asks or saves (`leaving`). Test through New
  project with a slow lookup (fails without).

## Round 8 (Codex and agy, 2026-11-21): Codex CLEAN, agy NOT CLEAN

Reports: `codex-review-r8.txt`, `agy-review-r8.txt`.

- **R8-1 (agy): F1 (it works above dialogs) started Help while the page ran a step or showed one
  of its own questions** (delete, approve, continue); Help then opened afterwards. *Fix:* Help
  waits while the Projects page is busy; under the page's own question nothing shows, during a
  step "Wait for the current step". Leaving under such a question stays silent too. Test: F1
  under "Delete saved project?" with a slow lookup, Cancel: no Help (fails without).

## Round 9 (Codex and agy, 2026-11-21): agy CLEAN, Codex NOT CLEAN

Reports: `codex-review-r9.txt`, `agy-review-r9.txt`.

- **R9-1 (Codex): closing the window waited behind the page's own question or step** (the summary
  is read first); after Cancel at "Delete saved project?" the window closed anyway. *Fix:* before
  the summary's wait and after it, a departure, a step or a page question under way stops the
  close (a note to wait during a step, nothing under a question). Test with a held summary
  (fails without).

## Round 10 (Codex and agy, 2026-11-21): agy CLEAN, Codex NOT CLEAN

Reports: `codex-review-r10.txt`, `agy-review-r10.txt`.

- **R10-1 (Codex): Ctrl+, under the page's own save question gave the keyboard back to the page**
  underneath (Esc then missed the question). *Fix:* leaving does nothing while the page asks or
  saves, before any focus is read or restored. Test: the keyboard stays in the question and Esc
  cancels it (fails without).

## Round 11 (Codex and agy, 2026-11-21): CLEAN

Reports: `codex-review-r11.txt`, `agy-review-r11.txt`. Both CLEAN: rounds 1–10 verified against
the code and the tests, no new finding.

**Task 086 review: CLEAN.**
