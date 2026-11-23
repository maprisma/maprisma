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

## Review round 1 (Codex + agy) — fixed
- Stopping without an active assignment (`activity: stopping`, `processes_stopping`, a paused
  team setup) now shows "Stopping the agent" on the page and the card bar.
- Without the board card: team setup (`phase: setup`) and planning review (`status: reviewing`)
  are named right; setup reads `setup_output`; the event's role is translated.
- The start time comes from the current attempt: the backward scan stops at `started`,
  `continued`, `assignment_done`, `finished`, ... (before the next dispatch the attempt's start
  counts).
- Output carried over from the previous agent (kept by the core on purpose, e.g. as evidence of
  interrupted work) is not shown as the current agent's: the strip shows an output line only once
  the output changed after it first saw the current dispatch.
- The plan hint only while the lead drafts (`phase: planning`), not during team setup.
- Layout: headline, detail and output each on their own full-width line.
- `FLUTTER_TEST == 'true'`; OSC sequences ended by ST are stripped; tests for all of these,
  the moving/still bar, and a 320 px window at text scale 2.

## Folder dialog (Uwe 2026-11-23, before the push)
"the folder dialog must have mounted folder like Data and Ai in the sidebar". All four
"Choose folder" places use `chooseFolder` (lib/folder_picker.dart): the runner's GTK folder
dialog (`maprisma/window` method `chooseFolder`) with sidebar shortcuts for every mounted data disk
(`/mnt`, `/media`, `/run/media`, `/srv`; not another system's root such as an opened Omarchy disk)
and the folders pinned in COSMIC Files (favorites) and KDE Places; GTK bookmarks GTK shows itself.
file_selector's dialog remains the fallback.

## Review round 2 (Codex + agy) — fixed
- The project view (`get`, a change's answer) decides whether an agent works (status planning,
  running, reviewing, pausing, or `processes_stopping`), as the core derives it; the board card,
  which can be older, only says who and which step.
- Output: no line while no dispatch is known (an attempt just started or continued keeps the
  last attempt's output). At a new dispatch the output seen before it is the baseline, so the new
  agent's first lines show at the first poll; opened mid-run, the output found then.
- Stopping a team setup stays "setup": its output, helper name (also from the project's
  `setup_agent`), no role "Agent"; `setup_failed` and `continue_failed` end an attempt.
- Folder dialog: GTK's own folder dialog instead of GtkFileChooserNative (with a portal that
  dropped the shortcuts); it no longer blocks in a nested main loop: the call is answered when the
  dialog closes, a second call brings it to the front, closing the window closes it. Title from
  the app's translation, buttons in GTK's own. Mounts: network shares and ZFS count, mounts inside
  another system's root do not; empty XDG variables, `HOME` with a slash, hidden KDE places and
  XML entities are handled.
