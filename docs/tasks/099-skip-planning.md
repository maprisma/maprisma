# 099 Skip planning

Author: Claude · Reviewer: Codex and Antigravity · Branch: task/098-working-indicator (with 098)

Uwe (2026-11-23): "make a possibility to omitt planing".

## Goal
A project can run without a planning phase: one action, one question, and the agents work
directly from the goal.

## Routes
None. The core already runs any approved plan, also one the user typed; the GUI chains the
existing `save` (plan = a fixed note), `review {approved: true}` and `run`.

## UI
- Footer action **Skip planning** (in a narrow window under More), enabled while the plan box is
  empty, the execution team has a member, nothing runs and the project is not paused,
  interrupted or failed.
- Question **Skip planning?** "The agents work directly from the goal, without a plan. This
  approves the team, working folder and permissions and starts the run." — **Skip planning and
  run** / Cancel. It is the approval: the same facts as Approve plan's question.
- The plan becomes, in the user's language: "No separate plan: work directly from the goal.
  Inspect the project first, keep the changes to what the goal asks, and report what you did and
  checked." A failed save restores the empty box; a failed approval or run leaves the saved (or
  approved) project with the reason, as the single actions would.
- Texts in 8 languages; manual paragraph in "Planning and running a project".

## Acceptance
- Widget tests: Cancel calls nothing; confirm calls save (with the note), review (approved), run
  in this order with each new revision; the action is disabled with a plan and while running.
