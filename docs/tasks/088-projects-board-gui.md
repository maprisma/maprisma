# 088 Projects board, part 2: the board (GUI)

Author: Claude · Reviewer: Codex and Antigravity · Branch: task/088-projects-board-gui

Step 2 of `docs/plan-main-layout.md`, GUI part, on top of task 087 (the board projection). The
project page's large rail and Team graph are step 3; the Phases view is step 4; links between the
tabs are step 5.

## When
The board is drawn when the Project Center backend lists the capability `board` (its `list`
answer carries `capabilities`). Without it (an api-1 or older backend) the tab keeps today's page
and says "The AI Project Center backend needs an update".

## Board (project_board.dart)
- **Summary row**: filter chips with counts, each with its own symbol (never colour alone):
  Running (running + stopping), Attention, Needs you, Ready, Drafts, Agents finished, All; a chip
  chosen again clears the filter. **New project** as a button in the row; as a card only on the
  empty board.
- **Cards** in a lazy grid: 3 columns from 1100 px, 2 from 700 px, else 1; the list's order (most
  urgent first). Each card: title, working folder (shortened), the activity label and, when set,
  the second line; a painted **stage rail** (Goal, Plan, Approval as a gate, Ready, Run, Agents
  finished) with a text equivalent; the **team** (execution, else planning): up to 4 nodes (3
  when narrow) with initials, name and an explicit model or "Agent default", the active one lit,
  the next one marked, stopping and stopped shown, "+N" for the rest, the active or next one
  always among the shown; issues (folder, lead, goal, launch) as one line; the last event and its
  time; quick actions **Open**, **Review plan** (needs review: opens the Plan tab, never
  approves), **Pause** (an assignment active), **Retry pause** (status pausing), with `{id,
  run_id}` as shown; one click at a time.
- **States**: loading, empty (New project card), disconnected (status unavailable, Retry), store
  fault (banner) look different.
- **Refresh**: one owner, no overlapping requests: every 2 s while an assignment is active or
  processes stop, otherwise every 15 s, and on focus; full details only for the open project.

## Project page
Opening a card shows the project page with a breadcrumb `Projects › <title>`; the breadcrumb, Esc
and the Projects tab go back to the board (unsaved changes ask first), with the keyboard on the
card that was opened. New project opens an empty project page the same way.

## Small windows
Down to 480 × 360 with large text: one column, the filter row scrolls sideways, the team shows 3
nodes, the rail shows only the current stage's label; the project page's footer keeps the primary
action for the project's state and moves the others into a "More" menu.

## Texts
All new texts in 8 languages (activity labels, stages, filters, issues, actions, states).

## Acceptance
Widget tests: filters and counts, card contents for each activity, rail and team nodes (+N,
active always shown), quick actions with run_id, a stale card's Pause refused with
project_changed refreshes, board ↔ project with the breadcrumb, Esc and the tab (focus back on the
card), unsaved changes ask, api-1 fallback notice, states, 64 projects scroll, 480 × 360 with large
text without overflow. Codex and agy review CLEAN.
