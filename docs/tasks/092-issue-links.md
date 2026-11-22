# 092 Issue links: reason, target, where to fix

Author: Claude · Reviewer: Codex and Antigravity · Branch: task/092-issue-links

Step 5 of `docs/plan-main-layout.md`, second part ("A project that cannot start shows its issues,
each with a reason code, the target and whether the map can fix it; only those get a fix link to
the map card, the others link to the project's Team or Goal tab"). Protocol first.

## Contract (features.call list, board projection)
Every issue object, project-level (`issues`) and per assignment (`planning[].issues`,
`execution[].issues`), keeps `code` and adds:
- `target`: what it is about — `folder`, `goal`, `team`, `agent`, `runtime`, `provider`, `model`,
  `permission` or `profile`;
- `node` (optional): the AI Map box to go to — `runtime:<key>` of an **installed** runtime (the
  only boxes the map always shows for these issues and can act on: start it, its models, the
  agent's connection);
- `fix`: where it is fixed — `map` only with such a node, else `team` or `goal` (the project's tab).
Codes are unchanged. The card's launch issues are unique by code **and** box (two stopped runtimes
are two issues). Old GUIs ignore the new keys; a GUI meeting an issue without `fix` treats it as
`team` (no map link).

| code | target | node | fix |
| --- | --- | --- | --- |
| folder_missing, folder_changed | folder | — | goal |
| empty_goal | goal | — | goal |
| no_lead | team | — | team |
| agent_unavailable | agent | — | team (not installed or not for projects: the map has no box or no action) |
| profile_invalid | profile | — | team |
| runtime_stopped | runtime | runtime:<key> if installed | map if installed, else team |
| model_unavailable | model | runtime:<key> when a model is chosen | map (a model it does not serve has no box; its runtime's has the models); no model chosen: team |
| provider_unavailable | provider | runtime:<key> if the agent is not connected and has a provider option | map, else team (another provider than the connection names, or no provider option) |
| runtime_required | runtime | — | team |
| access_unsupported | permission | — | team |
| model_unsupported | model | — | team |
| subagents_unsupported | agent | — | team |
| launch_unavailable | agent | — | team |

## UI
- The card's and the project page's issue lines become links: a `map` issue says **Fix on map**
  and goes there like Show on map (guard, reveal and mark the box; not on the map says so); a
  `team` or `goal` issue opens that tab of the project (on the board: opens the project there).
- The Team graph's member problem line links the same way.

## Acceptance
Core tests for every code's target, node and fix, uniqueness by code and box, old keys unchanged;
protocol doc and generated client; GUI tests for the links (map, team, goal; from the card and the
project page), keyboard and screen readers; texts in 8 languages; manual. Codex and agy CLEAN.
