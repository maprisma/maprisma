# 089 Project page: large stage rail and Team graph

Author: Claude · Reviewer: Codex and Antigravity · Branch: task/089-project-page

Step 3 of `docs/plan-main-layout.md` ("A project"), on top of 088 (the board).

## UI
- **Large stage rail** under the breadcrumb on the project page: the six stops (Goal, Plan,
  Approval as a gate, Ready, Run, Agents finished) with their names, the current one lit, the
  activity label and the second line beside it; compact (only the current stage's name) in a
  narrow window. From the board projection of the open project (stage, activity, second), so it
  matches its card.
- **Team graph** in the Team tab, next to the form (below it when narrow): two rows, Planning and
  Execution, in launch order (the effective assignments of the projection: identity, role, name);
  each member a box with initials, name and role, a line to its provider/runtime box when one is
  chosen explicitly, else an "Agent default" box (never a guessed provider); the active, stopping,
  stopped or next member marked as on the card; member issues marked; read only. Text equivalent
  for screen readers (one line per member: phase, role, name, configuration, state, problem).
- Reuses the board's painters and node look (project_board.dart) where possible.

## Not in this step
Phases view (step 4), links to the map (step 5), finishing steps (own plan).

## Acceptance
Widget tests: rail stops and current stage for each stage, compact form; graph rows and order,
explicit provider/runtime vs Agent default, marked member, issue mark, semantics text, narrow
layout (below the form) at 480 × 360 with large text; texts in 8 languages; manual. Codex and agy
review CLEAN. Only the affected tests per round; tools/test-changed once before the commit.
