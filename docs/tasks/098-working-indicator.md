# 098 Show that the AI is working

Author: Claude · Reviewer: Codex and Antigravity · Branch: task/098-working-indicator

Uwe (2026-11-23, screenshot of an empty Plan tab while the lead drafted the plan): "i need an
indication that ai is working, in planning and executing". The page only showed a progress
bar while the GUI waited for its own request; once an agent ran, it looked idle.

## Goal
While a project's agent works (plan, execution, review, team setup) or stops, the project page
and its board card show it: a moving bar, what is happening, who does it, for how long, and the
agent's latest output line. The planning lead's answer becomes the plan without notes about
missing tools.

## Routes
None. The GUI uses what the board card (`list`) and the project view (`get`) already carry:
`status`, `active {phase, position, state}`, `activity` (`setting_up_team`), `planning` /
`execution` assignments, `events` (the last `assignment` / `setup_started` event's `at` and
text "Agent: role"), and the live `output` (saved every 500 ms while an agent runs).

Core change (prompt only): the planning prompt tells the agent to answer with the plan itself
as plain text, write no files and not mention its tools or plan mode, since that answer is
saved as the plan.

## UI
- **Project page:** a "working" strip under the tabs, visible on every tab, while the card's
  `active.state` is `active` or `stopping`, or the team setup runs:
  - moving bar (still when the platform asks for no animations);
  - headline: "AI is drafting the plan" (planning lead), "AI is checking the plan" (planning
    reviewer), "AI is working on the project" (execution), "AI is reviewing the changes"
    (execution reviewer), "AI is setting up the team", "Stopping the agent";
  - detail: "<Agent> · <role> · step N of M · for 3 min";
  - the latest non-empty output line, one line, ellipsised.
- **Plan tab:** while the plan is being drafted and still empty, the box's hint reads "The AI
  is drafting the plan. It appears here when the agent is done."
- **Board card:** a thin moving bar at the card's bottom while an agent works there.
- Texts in all 8 languages; manual chapter on the project page mentions the strip.

## Acceptance
- Widget tests: strip with headline/detail/output line for planning lead, execution and
  stopping; no strip for draft/paused/completed; card bar only while active; plan hint.
- Core test: the planning prompt carries the "answer with the plan" instruction; execution
  prompts do not.
- Screenshot of the planning state (F12 style) checked by eye.
