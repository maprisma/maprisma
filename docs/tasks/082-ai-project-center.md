# 082 AI Project Center and feature plugins

Author: Codex · Independent reviewers: Claude and Antigravity (pending)
Branch: `task/082-ai-project-center`

## Goal

Use Maprisma as an AI command center: save project goals, configure a cooperating
agent team, draft and review a plan, run it, pause and continue saved work. The
main map indicates active projects. Reports, Ask AI and AI Project Center have
separate feature ownership and a versioned process backend boundary.

Implementation details and boundaries are in
[AI Project Center](../plan-ai-project-center.md) and
[feature plugins](../plan-feature-plugins.md).

## Routes

Add `features.list`, `features.call`, `features.summary` and `features.shutdown`
to the protocol before the core/UI integration. Existing Reports and Ask AI routes
remain compatible. Generic calls identify a plugin, operation and argument map;
each feature validates its operations. Cross-process opaque handles return to
their owning feature for status, cancellation and checked apply operations.

## UI

AI Project Center opens from a project symbol on the main map. It contains saved
projects, brief/folder editing, team roles, plan editing/generation, explicit plan
review, execution output/events, pause and acknowledged continuation. Its header
indicator distinguishes active, pausing, review and attention states. Reports and
Ask AI retain their native presentations through feature contributions.

Translate new texts in all eight interface languages and add the project/plugin
workflow to all eight manual HTML sources. Native widgets remain compiled with
the host; compatible backend updates can replace an individual executable.

## Acceptance

- A saved project reopens with its brief, team, plan and progress. Removing its
  saved record never deletes the working directory.
- Stale revisions, duplicate launches and two active projects in the same folder
  are refused. Launch intent is durably stored before an agent starts.
- Changing the plan, goal, team, folder or effective profile invalidates execution
  approval. Reviewers use read-only launch profiles.
- Team assignments execute sequentially and pass a saved handoff. Native subagent
  presets and model overrides appear only where adapter capabilities declare them;
  native-session resume is not advertised.
- Pause waits for owned processes; continuation of uncertain work requires
  acknowledgement. Restarted active records become interrupted, without replay.
- Main-map counts come from project state; disconnected state is distinct from
  no active projects. The indicator has accessible text.
- Feature identity/API negotiation, frame bounds, signature/digest rejection,
  process loss, handle ownership and shutdown work. Development supports the
  embedded fallback; release verification covers real feature processes.
- Existing Reports/Ask AI behavior and their protocol clients stay compatible.

## Natural-language Project Setup extension

Add a Setup view that accepts a request such as “Use Claude with agy and Pi using
llama.cpp and choose a suitable model for this project.” A selected helper proposes
the team from installed profiles, actual agent/runtime bindings and available
models, with a task-specific rationale and visible effective permissions. The
user reviews and explicitly applies the proposal; applying changes the project
configuration without launching work or approving its execution plan.

Planning and Execution have separate selectors in Setup and Team. Their agents,
roles, models and runtime bindings can differ. Proposals target `plan` or `run`
without replacing the other configuration. Optional `plan_team` falls back to the
execution team for existing projects; plan approval covers both effective teams.

Local runtimes must already be running and connected on the main map. Launch
settings remain project-scoped. Pi is read/search only, with no shell/edit tools
because its managed profile lacks an OS sandbox. Validate missing/stale facts,
capability enforcement, proposal review, no global mutation and apply-without-launch
in the changed components before the final complete checks. Also verify independent
phase configurations, legacy fallback and approval invalidation for either phase.
Keep the new view and guidance translated in all eight interface/manual languages.
The extension is implemented and its focused core/native checks pass. The final
complete-suite results and remaining baseline/environment limits are recorded in
the review linked below. Separate planning/execution teams and prompt drafts,
reviewed proposals, runtime bindings and interruption safeguards are covered.

## Validation order and review

Uwe explicitly requested affected tests during development and the whole suites at
the end of this task. AGENTS.md now records that order, replacing the earlier pre-push-only full-suite
rule. Inspect `tools/test-changed --list`, run related checks while
editing, then run the complete Flutter/core, Python reference and typecheck suites
at final integration. Report any environmental failures with the actual command.

The initial extracted core feature modules and native descriptor registry analyze
without findings; the existing Smart Card tests passed 55 checks. Final integrated
results belong in the task review once the implementation is complete. Attempts
to involve Claude and Antigravity were made, but Claude could not resolve its API
endpoint and Antigravity could not open its required local socket. Their review is
pending; these attempts are not CLEAN rounds. Nothing is pushed or released by
this task.

Final validation and outstanding host checks: [task 082 review](../reviews/082-ai-project-center.md).
