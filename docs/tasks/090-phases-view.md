# 090 Phases view

Author: Claude · Reviewer: Codex and Antigravity · Branch: task/090-phases-view

Step 4 of `docs/plan-main-layout.md` ("Projects tab: the board", point 3, and "Small windows").

## UI
- **View switch** in the board's summary row: **Cards | Phases** (symbols only in a narrow window,
  names as tooltips and labels). Like the filter, the choice stays while the Projects page
  lives: across an open project and under Settings, Reports or Help; it is not a saved setting
  (no new settings key).
- **Phases**: the six stages as columns (Goal, Plan, Approval, Ready, Run, Agents finished), each
  with its name and count, and compact cards in the board's order (most urgent first): title,
  bucket symbol and activity label, the second line. **Navigation only**: a compact card opens its
  project (click, Enter, Space); no quick actions, no dragging, nothing changes a status.
- The filter chips apply to Phases too; counts in the columns follow the filter.
- **Small windows** (narrower than six readable columns): a stacked list per stage (stage header
  with count, its cards), empty stages left out; an empty result says so.
- Back from a project: the compact card is scrolled into view and focused (as on Cards).
- Semantics: each compact card reads "title, stage, activity, second line"; column headers read
  "stage, N projects".

## Not in this step
Links between the tabs (step 5), screenshots (step 6).

## Acceptance
Widget tests: switch (both ways, keyboard), columns and order, counts, filter, navigation only (no
Pause/Review in Phases), open by click and Enter, stacked list at 480 × 360 with large text,
reveal + focus back from a project, the choice kept across a project; texts in 8 languages; manual. Codex and agy review CLEAN. Only affected tests per round;
tools/test-changed once before the commit.
