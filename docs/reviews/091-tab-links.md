# Review: 091 Links between the tabs (Show on map, Used in N projects)

Reviewers: Codex and Antigravity (read-only), rounds until both say CLEAN. Artifacts:
`.flutter-previews/task-091-checks/`.

## Deviations from the plan
- Step 5 is split: the issue links (reason, target, fixable) need a contract change and follow as
  task 092.
- The agent chip lives with the Projects page (like its filter): leaving Projects for the AI Map
  takes it away; × or All clear it on the board.
- Show on map is on the Team graph's member boxes (the project page), not on the board cards.
- A filter or the chip that leaves no project says "No projects here." in both views (before, an
  empty filter showed an empty grid).

## Checks
- `flutter analyze lib` clean; new `test/map_links_test.dart` (6) and `test/project_links_test.dart`
  (9), one shell test in `test/main_tabs_app_test.dart` (guard, mark, nothing saved, mark goes,
  Used in → chip, chip gone after the AI Map); affected map, board, phases, page and translation
  tests (204 in all). Reveal test fails without the pan (mutation checked). Only affected tests per
  round; `tools/test-changed` once before the commit.

## Round 1 → fixes
- Reveal after the fit: the pending reveal is taken at the end of a settled `_fit` (scale,
  viewport and clamping done), like the smart-card pan; tests reveal a middle box on a newly shown
  map at 480 and 1000 px (they fail with the old post-frame timing).
- Leaving the AI Map for Projects (tab, Used in) forgets a pending reveal, the mark and its timer;
  the map gets `reveal` only while the AI Map is the tab; one map read in `_showOnMap` (the deferred
  scan or a refresh); the timer is cancelled before a new one.
- A new project saved on the way back is the card to return to (`_openedId ?? _project.id`), so the
  chip goes if it would hide it (test).
- Semantics: the Used-in badge's InkWell keeps tap/focus (label inside, number excluded); Show on
  map is one merged node with the button's tap/focus (tests check isButton, isFocusable, tap).
- Badge and menu entry only for agent boxes (non-empty command); the static cache also refreshes
  when onUsedIn appears or goes.
- Manual (8 languages): × removes the chip and keeps the filter; All shows every project again.
- New tests: hidden layer → not on the map, empty key no badge, shell test for an agent not on the
  map (snackbar, no mark). 211 affected tests pass.

## Round 2 → fixes
agy CLEAN. Codex: with a map read before, the reveal ran before `_showOnMap`'s refresh, so an
agent added meanwhile was reported missing. Now the mark is set at once, but a map read before gets
`reveal` only after its refresh finished (and only while the AI Map is still the tab and this Show
on map is still wanted, `_revealWanted`); a map not read yet reveals when its first scan builds it.
Regression test in the real window (fixture flag `agent_later`, map read held back): no "not on the
map", then the agent revealed and marked; it fails with the immediate reveal.

## Round 3 → fixes
Codex CLEAN. agy: after the refresh the late reveal was set whenever the AI Map was the tab, also
when the map itself had been left meanwhile (an agent's Details, a group page, providers) or the
refresh failed; the mark then stayed. Now it is set only onto the map still on screen
(`_mapOnScreen`, no group page, browser, providers or connections, refresh not failed); otherwise
the reveal and the mark are forgotten. New test: Details opened during the held map read, back on
the map nothing waits (fails without the gate). The round-2 test now also waits out the mark's timer
(proves the late reveal ran).

## Round 4 → fixes
agy CLEAN. Codex: on a map not read yet, Show on map returned before the cleanup, so a failed
first scan left the reveal and the mark for a later read. Now both cases take one path: an awaited
`_refresh(refreshMap: true)` (the first scan for a map not read yet), then the same guard (reveal
only onto the map on screen and freshly read, else forget). New test: started on Projects, the
first map read fails, F5 reads it later: no pan, no mark (fails with the old early return).

## Round 5
Codex CLEAN, agy CLEAN.
