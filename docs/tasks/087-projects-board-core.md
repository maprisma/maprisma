# 087 Projects board, part 1: the board projection (core)

Author: Claude · Reviewer: Codex and Antigravity · Branch: task/087-projects-board

Step 2 of `docs/plan-main-layout.md`, core part, on top of Maprisma 2.0.0 (tasks 085 and 086). The
GUI board (summary row, filters, cards, breadcrumb, small windows) follows as task 088.

## Goal
The AI Project Center's `list` answer carries everything a board card needs, from the same cached
display snapshot as `features.summary` and `get` (task 085), plus the "Approved · blocked" state
the plan left for this step.

## Contract (backend capability `board`)
The backend lists `board` among its `@hello` capabilities (`summary2`, `board`); the GUI draws the
board only when it is there. `list` keeps its old keys (`id`, `title`, `path`, `status`,
`revision`, `updated_at`) and adds per project, as stable machine codes:

- `phase`, `run_id`, `stage`, `activity`, `second`, `bucket` (the stage function of 085),
  `approval_valid`, `needs_reconciliation`, `processes_stopping`;
- `issues`: project-level `{code}`: `folder_missing`, `folder_changed`, `no_lead`, `empty_goal`;
- `planning` and `execution`: the **effective** assignments in launch order, tolerant (a draft
  with an incomplete team or a gone agent still lists): `{phase, position, agent, name, role,
  model?, provider?, runtime?, issues}`; planning without its own team is the lead and the
  reviewers; in a planning team of its own an implementer reads `contributor`; `name` is the
  agent's display name (its id when the agent is gone); member issues `agent_unavailable`,
  `runtime_stopped`, `model_unavailable`;
- `active`: `{phase, position, state}` with state `active`, `stopping`, `stopped` or `next`, or
  null (no assignment of the current phase; during team setup the helper shows instead);
- `setup_agent`: `{agent, name}` or null, `setup_error`;
- `last_event`: `{at, type, text}` or null.

The list comes most urgent first (bucket order Running, Attention, Needs you, Ready, Drafts,
Finished; then the latest change first). Limit: 64 projects (already enforced by save).

## Approved · blocked
A `ready` project whose approval is valid but whose launch would fail now gets the activity
`approved_blocked` and the bucket Needs you. "Would fail" is decided by the launch's own checks
(`_members`, `_memberOptions`) against the display snapshot: a stopped runtime, a model it no longer
serves, a local provider that now needs its runtime, a missing or changed folder. (A gone agent or
a removed runtime changes the approval itself: Approve again.) Its launch issues, each code once,
are in its `issues`, and each member's in its own. Fixing them needs no new approval: once they are
gone it is Ready again. The summary counts it the same way.

## Cost
Names, member issues and readiness come from the display snapshot (rebuilt per discovery
generation, after 60 s, on refresh) and are memoized by project revision and snapshot version, so
the summary's 2-second poll reads memory only; a folder is looked at again with the next
snapshot. A `list` derives each project once, and its summary comes from the same facts. No scan
per project.

## Protocol
No new route; `routes.json`'s `features.call` note names the projection. Protocol version stays 2.

## Acceptance
Tests: projection fields for every status; effective ordering (planning fallback, contributor,
gone agent, incomplete draft); active assignment states (active, stopping after a restart,
stopped, next); Approved · blocked with a stopped runtime, a missing model and a missing folder,
Ready again after the fix without a new approval, counted in the summary; sorting; `board`
capability through the real worker; no profile scan per project. Codex and agy review CLEAN.
