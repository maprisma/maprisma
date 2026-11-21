# Plan: main layout with the AI Project Center in the middle

Status: draft for Uwe's decision (2026-11-21), revised after review rounds 1–8 (Codex and agy,
`.flutter-previews/layout-plan/`). Nothing is built until Uwe approves.

## Why

Uwe (2026-11-21): the AI Project Center, with planning and executing, moves into the middle of
using Maprisma. The map becomes the helper that configures and monitors the AI setup on the PC.
The Project Center is prominent, its layout uses cards that show the project overview
graphically, like the map, and it has **no symbol**: it is a tab of its own, handled like the map.
Finishing steps such as updating a website are optional per project; **website is off by default**
(not everybody has one).

Today the map is the main window and the Project Center is a page behind a header symbol (with a
status badge): a list on the left and one project's tabs on the right (Goal, Plan, Team, Activity,
Setup). Esc leaves it for the map.

## What other tools do (web research, 2026-11-21)

- Agent dashboards colour each session by activity so the ones that need attention stand out,
  group sessions by project, and keep one live overview of sessions with their results
  ([Coral](https://cdknorow.github.io/coral/multi-agent-orchestration),
  [Agent of Empires](https://betterstack.com/community/guides/ai/agent-of-empires/),
  [marcnuri](https://blog.marcnuri.com/ai-coding-agent-dashboard)).
- Card dashboards: a summary row with aggregated status first, one card per item with a single
  status marker and a few key figures, stage columns as a second view, most important first when
  narrow, few distinct patterns
  ([PatternFly](https://patternfly.org/patterns/dashboard/design-guidelines),
  [Preline](https://preline.co/blocks/data-display/projects/),
  [NVIDIA Elements](https://nvidia.github.io/elements/docs/patterns/dashboard/),
  [Once UI](https://handbook.once-ui.com/common-patterns/roadmap-and-kanban)).
- Human approval is a visible gate; the reviewer sees the output, the actions and who/when; intent
  is captured before anything runs
  ([LangGraph notes](https://notes.kodekloud.com/docs/LangGraph/Human-in-the-Loop-HILT-Architectures/Designing-Human-Approval-Nodes/page),
  [Mastra](https://mastra.ai/blog/hitl-where-to-put-approval-in-agents-and-workflows)).

## Status, stages and filters (decided first)

The backend has 11 statuses and the phases `planning`, `running` and `setup`
(`features/ai_project_center.dart`). The core derives three separate things per project, in one
pure function used by the header, the board and the filters alike: the **stage** (where the
project is), the **activity label** (what happens now) and the **filter bucket**.

**Stage** (by status and phase):

1. `phase == setup`: the stage of `setup_return`; without one, Goal when there is no plan, else
   Approval (the core's own fallback).
2. `draft` → **Goal**.
3. `planning`, or `reviewing` / `pausing` / `paused` / `interrupted` / `failed` with
   `phase == planning` → **Plan**.
4. `awaiting_review` → **Approval** (the gate).
5. `ready` → **Ready** when the approval is valid, else **Approval**.
6. `running`, or `reviewing` / `pausing` / `paused` / `interrupted` / `failed` with
   `phase == running` → **Run** (a stopped run stays on Run even when it must be approved again).
7. `completed` → **Agents finished** (not "accepted": the user still checks the result).

**Activity label**, the first that applies: **Stopping** (`pausing`, or `processes_stopping`,
also after a restart that restored another status) · Setting up team (`phase == setup` **and**
`status == planning`; a stopped setup keeps Paused, Interrupted or Failed) · Planning ·
Reviewing plan / Reviewing · Running · Paused · Interrupted · Failed · Needs your review · Approve
again (approval invalid where a run or a continue needs it: ready, and stopped runs) · **Approved ·
blocked** (only for `status == ready`: a valid approval, but a launch issue: a stopped runtime, a missing selected model, a
missing or changed folder; the issues are listed, fixing them needs no new approval) · Approved,
ready to run · Draft · Agents finished. A **second line** adds what is required next without hiding
the state: "Check the changes first" (`needs_reconciliation`, on every stopped run and on a project
restored from one, also a draft edited from it) and "Approve again" under a stopped run. Status is
never shown by colour alone.

**Filter bucket** (mutually exclusive, the first that matches; each project counts once):
**Running** (stopping first: `pausing` or `processes_stopping`, whatever the status; then
planning, active setup (`phase == setup` with `status == planning`), running, reviewing) →
**Attention** (interrupted, failed, also of a stopped setup) → **Needs you** (awaiting_review;
paused, also a paused setup; `needs_reconciliation` on a ready or completed project; approval
invalid where a run needs it; **Approved · blocked**) → **Ready** (`status == ready`, approved and
no launch issue). Launch issues of stopped runs are extra information under their own label; a
completed project stays **Agents finished** even when its runtime stopped later.
→ **Drafts** (also a draft that keeps `needs_reconciliation`: its second line says "Check the
changes first", and the requirement stays before any run) → **Agents finished**; plus **All**. The
summary's counts use the same predicates. A draft
or a planning project without an approval yet does not "need you". Stage columns (Phases view)
only navigate; nothing changes a status by dragging.

A store fault is not a project: it is a banner above the board **and** an accessible warning mark
on the Projects tab (visible from the AI Map too), never added to a count. When the feature backend
is disconnected the counts show **status unavailable**, never zero.

## The layout

### Header: two tabs, no Project Center symbol

`[ Projects ]  [ AI Map ]` as equal tabs at the left of the header, the actions on the right as
today (Ask AI, Legend, Undo when available, the problems mark, Reports, Help, Settings, Refresh).
Legend and the map's Undo show only on the AI Map. Refresh and F5 refresh the **active** tab (on
Projects: the board or the open project, through its refresh owner, keeping unsaved edits) and grow
the discovery generation.
The Project Center symbol and its badge go away; the **Projects** tab carries the counts (running,
needs you, attention; "status unavailable" when disconnected). Narrow windows: the counts shrink to
one dot with a tooltip, the actions move into an overflow menu; the tabs never wrap.

Start tab: decided **once**, after the startup data loaded (a short loading state meanwhile, no map
flash), never switched later by an async count. Order: when `setup_needed`, the AI Map with its
welcome/setup screen as today; else the last used tab (a new UI setting `main_tab`, `null` until the
user picks a tab); with `main_tab` null, Projects when a project exists, else the AI Map. If the
project status cannot be read in time, the AI Map.

### Projects tab: the board

1. **Summary row** as above, also filters (again clears; All resets).
2. **Project cards** in a lazy grid (2–3 columns by width, one when narrow; most urgent first, but a
   focused or pressed card does not move while a refresh reorders). Each card, drawn with simple
   painted shapes (not the full map renderer):
   - title, working folder (shortened), one status marker with its text label (never colour alone);
   - the **stage rail** from the table, the approval stage drawn as a gate;
   - the **team**: the **effective** assignments (a pure, tolerant ordering helper in the core, not
     the launch validation: a draft with an incomplete team or a project whose folder or agent is
     gone still shows, with its issues), each with an identity (phase and position), in order:
     Planning (without its own team it is the lead and reviewers; implementers are skipped, and
     in a planning team of its own "implementer" reads Contributor) and Execution (lead →
     implementers → reviewer); absent roles omitted; at most 4 nodes and "+N" (3 when narrow); the active or stopping assignment is always among the
shown nodes, with its phase and role, and so is the next one (or the one that stopped); "+N"
stands for the others. The member whose
     assignment is active is lit, the next one marked; stopping and stopped are shown (the core
     sends the active assignment's identity and state; `next_member` alone does not mean a process
     runs). The setup helper shows in phase setup. Under each name only an explicit model, provider
     or runtime, else **Agent default**. Agent names as text with initials (no agent icons yet);
   - the last event (`{at, type, text}`) and its time;
   - quick actions that never skip a review: **Open**, **Review plan** (opens the review, never
     approves), **Pause** while an assignment is active (planning, setup, reviewing, running),
     **Retry pause** when stopping failed (`pausing`); none while processes are stopping after a
     restart ("Stopping"). Pause and Retry pause send `{id, run_id}` as shown on that card (a stale
     card cannot stop a newer run: `project_changed` refreshes it); a second click while one is on
     its way does nothing. Continue, Retry and Run only on the project page, where the changes,
     handoff and approval are shown.
3. **View switch**: Cards | Phases (stage columns, compact cards, navigation only).
4. **New project** as a button in the summary row; as a card only on the empty board.
5. **States**: loading, empty (with a link to the first-agent guide when no agent is set up),
   disconnected ("status unavailable", a retry) and store fault (banner) look different.

Cost: the board has one owner for its refresh (no overlapping requests): every two seconds while
an assignment is active or processes are stopping, otherwise every 15 seconds and on focus; full
details only for the open project. Approval validity and readiness come from **one cached profile
and runtime snapshot** in the worker, shared by `features.summary`, `list` and `get`; it is rebuilt
when the host's discovery generation grows (see Protocol), when it is older than 60 seconds (an
agent, runtime or model can change outside Maprisma while the map is paused), and when the window
regains focus; never per request and never per project. A fresh launch snapshot replaces it and
clears the derived approval and readiness of every project, not only the launched one.
`processes_stopping` is never cached: it is read live from the run locks on every request. While
the window is hidden or unfocused the board and project page stop polling and animating; the
shell's cheap summary poll and notifications go on. So the shell's two-second summary poll stays
an in-memory count. The shell compares summaries structurally (nested `by_agent` must not trigger
a rebuild every poll). While the Projects
tab is shown, the hidden map's live, usage and traffic polling pause (notifications stay), and a
start on Projects defers the first map scan. Limits: 64 projects, up to 8 members per team (16
across both teams) plus the setup helper; animations off with reduced motion and for cards out of
view. Acceptance includes a 64-project board.

Small windows (down to the remembered minimum 480 × 360, with large text and long translations):
one column; the filter strip scrolls; the rail shows only the current stage's label; the team shows
at most 3 nodes; Phases becomes a stacked list per stage. The project page stacks too: compact
rail, tabs as a selector, the Team graph below the form (not beside it); the footer keeps the one
primary action for the project's state visible and moves the others into an overflow menu, so the
body keeps a usable scroll height. Acceptance case at 480 × 360 with large text, a warning and the
unsaved-changes text shown. Painted rails and graphs carry text
equivalents for screen readers; every action is reachable by keyboard; the tab's count dot has an
accessible label. Built from the family parts (`WindowHeader`, `WindowFooter`, `SectionCard`, theme
colours and spacing, maprisma-layout rules).

### A project

Opening a card shows the project page in the Projects tab: breadcrumb `Projects › Website
relaunch`, the stage rail large, then the existing tabs (Goal, Plan, Team, Activity, Setup). The
Team tab gets a **graph view** next to the form: Planning and Execution rows as above, each member
with its explicitly chosen provider or local runtime, else an "Agent default" box (no guessed
provider), as map boxes and lines, read only.

**Finishing steps** after the agents finished (commit and merge, push, release, update a website)
are planned separately in `docs/plan-finishing-steps.md`. Fixed by Uwe: every step is optional per
project, and **the website step is off by default** (not everybody has a website).

### AI Map tab: setup and monitoring

The map stays as it is. Links between the tabs:

- **Show on map** from a team member: switches to the AI Map and reveals that agent's box
  (temporary focus and scroll; it does not change the saved pins). A removed or hidden agent says so.
- **Used in N projects** on an agent box: distinct projects naming the agent in their planning or
  execution assignments, from a `by_agent` map in `features.summary` (empty on the no-project fast
  path, so the map never starts the Project Center backend); opens Projects with a named **agent
  chip** ("Claude Code ×") that combines with the status filter (the board's counts show the
  combination; the header's counts stay global), is cleared by its × or by **All** (All clears
  both). Acceptance: a completed project whose runtime stopped stays Agents finished.
- A project that cannot start shows its **issues**, each with a reason code, the target (agent,
  runtime, model, folder, permission) and whether the map can fix it; only those get a fix link to
  the map card, the others link to the project's Team or Goal tab.

## Navigation and keys

- The selected main tab is separate from subordinate pages. Leaving Projects for Settings, Reports
  or Help keeps a **return point** (the open project, its editor tab, scroll and focus) and coming
  back restores it. Ask AI and the problems list work on the map; dismissing them stays on the AI
  Map.
- **Esc**: inside a text field it only leaves the field; then project → board; on the board or the
  map it closes or hides the window as today. Backspace keeps editing text.
- **Every** way out of an open project with unsaved changes asks Save / Discard / Cancel: breadcrumb,
  Esc, the AI Map tab, Ctrl+2, header actions (Settings, Reports, Help, Ask AI, problems), Show on
  map, fix links, window close. Cancel or a failed save keeps the project open and the destination
  untaken. Clicking Projects while a project is open returns to the board (with the same guard).
- **Ctrl+1 / Ctrl+2** live with the window's own shortcuts (not above the dialogs), only while no
  dialog or terminal owns the keys. Focus returns to the card that was opened.
- One departure at a time: a second Esc, Ctrl+2 or click while the save question is open does
  nothing; while the project is busy (saving, starting, pausing) leaving says "Wait for the current
  step" instead of failing silently. The destination is taken only after every check succeeded.
- Window close keeps the project page, its selection, focus **and unsaved draft** until the whole
  close sequence (save question, then "stop running agents?") succeeded: "Discard" only takes effect
  when the departure commits, so cancelling the second question leaves everything as it was
  (acceptance case: Discard, then cancel "stop running agents?").
- **Esc order**: an open menu, dialog or Ask AI card → an editable field → project → board or map
  (close or hide the window).
- **Ask AI** works on the map: from Projects it switches to the AI Map first, through the guard.

## Protocol first

Every contract change is written first (`routes.json`, `tools/protocol.py doc` and `client`), then
the core, then the GUI (AGENTS.md).

- `features.summary` (fields, all integers unless said): `running` (planning, setup, running,
  reviewing; **without** stopping, as today), `pausing` (stopping: `pausing` or
  `processes_stopping`; the close question keeps summing both, and the header's and the filter's
  Running count is `running + pausing`), `waiting` (kept: awaiting_review), `attention` (the
  Attention bucket: interrupted and failed, not stopping; the store fault no longer adds one), `needs_you`, `ready`, `drafts`, `finished`,
  `total`, `error` (string or absent), `connected` (bool), `by_agent` (`{agent command: number of
  distinct projects}`). The no-project fast path returns all of them (zeros, `{}`). The app protocol
  version is raised (attention changes meaning).
- **Feature API, per feature**: the host accepts an API range per feature instead of one global
  number: the AI Project Center 1–2, Reports and Ask AI 1 (their updates stay valid). `features.list`
  shows the **supported** range per feature (static, no process start) and a nullable
  `negotiated_api` once a backend is running. For a signed user update the `@hello` API must equal
  the API its verified manifest names. `@hello` also lists **capabilities** (names such as `board`; the
  finishing-steps plan adds `finishing` and `store2`); the host decides per capability, not by
  the API number alone. The list is optional (absent, as from today's API-1 backends, means none);
  if present it must be a list of non-empty strings, else the backend is incompatible. Embedded mode
  (no `@hello`) uses the host's own API number and capabilities. The GUI sees them too:
  `features.list` shows the negotiated `capabilities` next to `negotiated_api` (null before a
  start), the host adds the negotiated `api` and `capabilities` to `features.summary` (null on the
  no-project fast path), and the Project Center's `list` answer carries them. The board is drawn
  only when `board` is among them; otherwise the tab says the backend needs an update and shows
  today's page. The Project Center's `list` answer itself carries `api`
  (missing means 1), so the very first answer decides, before any card is drawn: with api 1 the tab
  says "the AI Project Center backend needs an update" and shows today's page, whose summary is read
  the old way (the store fault inside attention). `features.summary` also carries `api` (null on the
  no-project fast path). Acceptance case through the real manifest and stdio path with an api-1
  fixture, on an installation without projects.
- **Discovery generation**: the host keeps a number that grows whenever the map's data changes (a
  refresh, an add-on, a settings or connection change). `features.call` gets an optional fourth
  key `refresh: true` (documented in `routes.json`); the host consumes it, grows the generation and
  forwards the call without it. The Projects tab sends it with Refresh/F5 (board or open project)
  and with its first request after the window regained focus. The generation travels with every
  Project Center request on the private feature pipe (as Ask AI's host context does). The worker
  gives its snapshot a **version** that advances on every replacement (generation, 60-second age,
  focus refresh, a launch's fresh snapshot); approval and readiness for **display** are memoized by
  project revision and that version. Launches, continues and every assignment start still take a
  fresh snapshot (and replace the cache).
- Project Center `list`: a **board projection** per project: status, phase, stage, activity label
  and filter bucket, approval_valid, needs_reconciliation, processes_stopping, run_id, revision,
  updated_at, project-level `issues` (missing or changed folder, no lead, empty goal), the effective
  planning and execution assignments (identity, agent, role, explicit model/provider/runtime,
  issues), the active assignment's identity and state (active, next,
  stopping, stopped), setup_agent, setup_error, the last event; full plan, output and handoff stay
  in `get`. Stage, activity, second line and bucket travel as stable machine codes; the GUI
  translates them. Every assignment and the setup helper carry the agent's display name (from the
  same profiles read; the command id when the agent is gone).
- Settings: `main_tab` (`projects` | `map` | null) in `settings_schema.py`, `settings.dart`, the
  generated core assets and `routes.json`.

## Steps (each a task with Codex and agy review)

1. **Semantics, summary contract and navigation**: the stage/label/bucket function, the summary
   fields and the feature API (protocol first); the tabs with counts and the store-fault mark, the
   symbol removed, the start tab rule and `main_tab`, Esc/guards/Ctrl+1/2, the compact header, the
   hidden-map polling paused. Projects shows today's Project Center page meanwhile, **without its
   own Back button** (the tab replaces it). Tests: indicator replaced, departure cancelled or failed,
   keys under dialogs, stale approval, recovery while stopping, disconnected summary, api-1 backend.
2. **Board and project navigation**: the board projection (protocol first), summary row, filters,
   cards, lazy grid, the board ↔ project breadcrumb with focus return, small windows for the board
   **and** the project page (tab selector, one primary action with an overflow menu, usable body
   height; also on the api-1 fallback page), the 64-project check.
3. **Project page**: large rail and the Team graph.
4. **Phases view**.
5. **Links** between the tabs (reveal on map without changing pins, used in N projects, issue
   links).
6. Screenshots and a manual review.

Every step brings its texts in all 8 languages (appended to the translation files, order and
whitespace kept) and its manual changes with it and follows the maprisma-layout family rules.
During a step only the related checks run (`tools/test-changed`); the complete suites once at the
end of each step. Acceptance cases besides those above: a startup timeout falls back to the AI Map
and a late answer does not switch tabs; a valid approval with a stopped runtime, a missing selected
model and a missing folder (Approved · blocked, then Ready after the fix without a new approval);
a setup recovered as interrupted with and without `setup_return`, while its run lock is still held
and after it is released; the cache after an external runtime change, after the
60-second age and focus, and after another project's launch; a stale card's Pause against a newer
run. Card events reuse the Project Center's existing event translation. Project widgets and state stay in the Project Center modules; the
shell only gets navigation hooks. Finishing steps follow in their own plan.

## Questions for Uwe

1. Tab names: **Projects** and **AI Map**, or **AI Project Center** and **AI Map**?
2. Start tab: the last used tab (proposed), with Projects on a first start when projects exist?
3. Reports: stays a header symbol (proposed), or a third tab?
4. Phases view in the first version, or later?
5. Finishing steps: a separate plan next (proposed), with website off by default as decided?
