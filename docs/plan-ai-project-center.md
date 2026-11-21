# AI Project Center

Status: task 082 implementation; final integration checks and independent review pending.
User decisions, 2026-11-20: Maprisma becomes an AI command center. Its project page
is named **AI Project Center**, opens from a project symbol, and has an indicator
on the main map while project work runs. Reports, Ask AI and AI Project Center
are separate [feature plugins](plan-feature-plugins.md).

## User workflow

1. Open AI Project Center from the main map and create a project with a title,
   goal/brief and existing project folder. Save it and reopen it from the list.
2. Describe the desired team in Setup and review the helper's proposal, or
   configure one lead, optional implementers and optional reviewers manually from
   installed agent profiles. Use the Planning/Execution selector in Setup and Team
   to choose different agents, models, runtime bindings and roles for each phase.
   Give each member role-specific instructions. Inspect the
   effective launch arguments and permissions supplied by its adapter. Choose
   read-only execution or permission to edit project files. Reviewers always use
   the read-only profile.
3. Write a plan or ask the lead to generate one. During planning, reviewers use
   the read-only planning profile and their results remain available as evidence.
4. Edit and review the plan. Explicitly approve its current version, team, folder
   and effective profiles. A relevant change invalidates that approval.
5. Execute the approved plan. See the current assignment, bounded output and
   saved handoff. Pause, inspect partial work, then continue later.
6. Review the final evidence and keep the project for further work, or delete its
   saved record while idle. Deleting a project record does not delete its folder.

The initial team runs sequentially: lead, implementers, reviewers. This supports
cooperation without concurrent writers racing in one directory. The same folder
cannot be used by two active managed projects. Native subagent presets are offered
only for capability-declared profiles; other agents show that capability as
unavailable. Parallel worktree scheduling and resuming an agent's own conversation
are not part of this release.

## State and ownership

`features/ai_project_center.dart` owns the durable project records under Maprisma's
data directory, in `ai-project-center/projects.json`. It uses a private directory,
an exclusive ownership lock, a versioned store and atomic writes. Intent is stored
before a process launches. A write failure blocks further mutations instead of
allowing work to run without saved state: the first failed write, including a
store that would exceed its size limit while work runs, stops every active attempt,
and Pause stays available. A full store accepts only deletions, and the fault
clears once a deletion was written. A stop that cannot be saved is still
shown in memory; a restart recovers from the last durable record. Project and output counts/sizes are
bounded; malformed state is reported rather than silently reset.

Each project keeps a stable identifier, revision, title, brief, canonical folder,
planning/execution team assignments, plan and plan version, approval digest, phase/current assignment,
bounded output, handoff and recent events. Revision checks reject stale edits and
duplicate run requests. Approvals bind execution-relevant inputs and effective
agent profiles for both phases, so an adapter or permission change cannot silently reuse an old
approval. Approval is checked again before each assignment, against the same
profile and runtime snapshot that is then launched. The fingerprint contains the
launch-affecting facts (argv template, stdin, access modes, permission text,
model/provider/subagent options and chosen subagent definitions, the runtime
binding's provider), not refreshing model catalogs or a runtime's served models;
model availability is validated at each dispatch. Every project view reports a
derived `approval_valid`, so the page can offer renewed approval after an
out-of-band change or for a completed project.

The main states are draft, planning, awaiting review, ready, running, reviewing,
pausing, paused, interrupted, failed and completed. Completion means configured
agent processes ended successfully; it is not a claim that all acceptance checks
passed or that reviewer findings were automatically resolved. The user reviews
the actual result and verification evidence.

Usage statistics, project-folder history and the general task cache remain useful
resources but are not authoritative project execution state. Existing download
recovery is not reused as if it were an agent checkpoint implementation.

## Launch profiles and permissions

The feature domain names no particular CLI. Reviewed adapter facts provide its
planning/run argv templates, permission description and declared capabilities.
The launch uses an installed executable, canonical existing working directory
and explicit argv words. A prompt placeholder occupies an entire argument; it is
not interpolated into a shell command. Global agent settings are not rewritten.
Inherited agent-session markers and Maprisma's own process variables
(`MAPRISMA_FEATURE_*`, `MAPRISMA_CORE_WORKER`, page markers) are removed before
starting a managed assignment, so an agent working on a Maprisma checkout does not
reach the installed bundle or its workers. Model, provider and subagent options
follow the template words; a template containing `--` is refused. The four
declared CLIs (claude, codex, agy, pi) were checked to parse an option placed
after the prompt.

Planning and reviewer assignments use the profile's read-only command. Execution
uses the selected read-only or project-edit command, bound into approval. Host
action rules are checked again at each assignment start. Permission bypass is not
a default. A missing agent,
unsupported launch template, changed folder or unavailable permission profile
blocks the assignment. The first release enables only profiles whose behavior is
actually declared; CLI flag availability alone is not proof of safe lifecycle or
resume semantics.

The configured lead and teammates are independent CLI assignments. An agent's
native subagents are a different capability. The initial declared Claude profile
offers allowlisted read-only researcher/reviewer presets through its native agent
option, and a model override only where the adapter declares a model option.
Selection is explicit and is included in plan approval. Profiles without those
capabilities do not offer them; choosing teammates alone does not create native
subagents. A configured preset permits the coordinator to use that specialist,
and does not prove that the agent actually spawned one.

## Process ownership

Each assignment runs under its own supervisor: the AI Project Center executable in
`supervise` mode (in a source checkout the Dart entry point, in an embedded build
the bundle's plugin). The supervisor is a Linux child subreaper, so descendants
that change session or process group, or double-fork, re-parent to it rather than
leaving its tree. The tree counts as stopped only when the kernel reports that the
supervisor has no child left (`waitpid` ECHILD after the leader was reaped), not
because a `/proc` scan was empty. After the leader exits, the remaining tree is
stopped with SIGTERM, then SIGKILL (pidfd, start-time identity checked). Output
is complete when the supervisor reports the confirmed end.

Startup has no moment without an owner. The start frame names the controller (pid
and start time). The supervisor takes its run lock, checks that its parent is still
that controller, reports `locked` and waits. The controller sends `launch` only
while it still owns the project store and that attempt was not paused, halted or
shut down meanwhile. A retired controller (a disposed embedded core, a worker
between dispose and exit, a dead process) never authorizes, and the supervisor
then ends without launching; a launch withdrawn by a pause counts as a pause. A
controller without its store descriptor never writes the store either, so a
retired one cannot overwrite its replacement's records.

The supervisor holds a shared lock on `ai-project-center/runs/<id>.lock` while any
owned process may live, also after its controller disappeared: EOF on its control
pipe makes it stop its tree, and it keeps the lock until the tree is empty. A later
controller treats a held lock as a project whose processes are still stopping
(`processes_stopping`); that project and every overlapping folder stay busy.
A stop that cannot be confirmed fails and is asked again by each retry; nothing is
cached except a confirmed empty tree. Not owned are processes another service
starts on an agent's behalf (systemd-run, D-Bus activation, container daemons);
they are not descendants.

## Pause, continuation and closing

Pause stores the request, stops new dispatch and shows **Pausing** until owned
agent processes have stopped. A stopped assignment can have changed files without
finishing its last action. The saved handoff therefore does not certify an exact
execution checkpoint. Before continuing uncertain work the user must inspect
partial changes and acknowledge that reconciliation is needed.

Continue starts a new agent session with the saved brief, approved plan and handoff.
It does not silently substitute a new session while advertising native session
resume. The agent is instructed to inspect actual files and avoid repeating an
uncertain side effect. Completed assignments are kept; the unfinished assignment
is the next one considered. A changed approval or folder requires review again.

Team setup only drafts a proposal. It keeps the project's phase, status,
position and approval and returns to them when it ends; a failed, stopped or
interrupted setup records `setup_error` instead of changing the project. Applying a
proposal is the change; it is refused for a paused, interrupted or failed
execution checkpoint, like a new setup. A proposal is dropped when its context
changes, including a title-only edit.

Shutdown stops all attempts in parallel within one deadline of about ten seconds,
below the host's 30-second shutdown request limit. The host stops the AI Project
Center before the other features; a refused or late answer keeps every feature
usable and can be retried. An embedded core awaits the same cleanup before release
(`CoreService.close`, the isolate's acknowledged close, the core helper's EOF).

On restart, records left in active states become interrupted. They are not
automatically relaunched. Closing Maprisma shuts down its managed feature processes
and project assignments; background execution while the application is closed is
not part of this release. Failed persistence or unconfirmed child termination must
remain visible rather than be presented as a clean pause.

## Main map indicator

The AI Project Center entry remains visible in the main map header. Its summary
comes from the project feature and distinguishes running work, pausing, awaiting
review and interrupted/failed work. Count projects, not agent processes. Planning
and reviewer activity count as active project work. Clicking opens the center.
Provide a text tooltip and accessibility label; meaning cannot depend on color or
animation. A disconnected feature is shown as unavailable, not as zero activity.

## What existing tools teach us

Vibe Kanban separates reusable agent profiles, workspace sessions and review. Its
session documentation distinguishes running, idle and attention states and notes
that a new session does not inherit another's conversation. These inform the team
profiles, explicit state indicator and honest handoff behavior here.
[Profiles](https://www.vibekanban.com/docs/settings/agent-configurations),
[sessions](https://www.vibekanban.com/docs/workspaces/sessions),
[review](https://www.vibekanban.com/docs/reviewing-code).

LangGraph distinguishes persisted per-thread checkpoints from longer-lived stored
information. Its interrupt documentation requires a stable thread identity and
warns that code before an interrupt can execute again on continuation. Maprisma
adopts the requirement for durable state and explicit side-effect reconciliation,
without adding LangGraph or claiming native CLI checkpoint equivalence.
[Persistence](https://docs.langchain.com/oss/python/langgraph/persistence),
[interrupts](https://docs.langchain.com/oss/python/langgraph/interrupts).

Symphony's specification separates scheduling, isolated workspaces and observable
agent runs. Maprisma uses explicit ownership and bounded dispatch; parallel
worktrees and automatic retries need a later task because retrying uncertain
agent side effects requires stronger evidence than restarting a process.
[Symphony specification](https://github.com/openai/symphony/blob/main/SPEC.md).

## Extension: natural-language Project Setup

The Setup view accepts a team request such as “Use Claude with agy and Pi using
llama.cpp and choose a suitable model for this project.” A selected helper drafts
a configuration proposal using the project goal, installed managed profiles,
existing agent/runtime connections and available local model facts. It must not
invent an installed agent, binding, model or permission capability.

Setup and Team each offer separate Planning and Execution selections. Each phase
can use a different set of agents, roles, models and runtime bindings. A natural
setup proposal targets only its selected phase (`plan` or `run`), leaving the
other phase's configuration intact. Saved projects may provide an optional
`plan_team`; when it is absent, planning uses the execution team for compatibility
with existing projects. Approval binds both effective configurations.

The proposal presents the chosen roles, runtime/model bindings, effective access
and a rationale. A suitable model is a recommendation for the current goal and
available facts, not a claim to know the universally best model. Missing or stale
bindings require refresh/reconfiguration rather than a hidden substitution.
The user reviews the proposal and explicitly applies its team configuration.

Applying a setup proposal only updates the selected phase's saved team. It does not
launch an agent, start a runtime, download a model, change global agent settings
or approve the execution plan. The local runtime must already be running and the
agent connected to it on the main map. Model selection and launch flags are scoped
to this project. Changed team settings invalidate the previous plan approval;
the user still drafts/reviews the plan and separately starts execution.

Pi's initial managed profile is read/search only. It does not receive shell or
editing tools because the profile has no OS sandbox. It may contribute research
or review within that capability; a helper cannot promote it to an unrestricted
implementer by changing the proposal text.

This extension needs targeted tests for bounded helper proposals, absent/mismatched
agents and bindings, unavailable models, project-scoped settings, stale proposals,
read-only capability enforcement and apply-without-launch behavior, followed by
the final whole-suite checks. Earlier task checks do not validate this extension.

## Acceptance and follow-up

Verify persistence across reopen/restart, stale revision rejection, approved-plan
binding, missing profiles and folders, bounded output, failed saves, duplicate
launch prevention, sequential handoffs, pause during startup/output, interruption,
acknowledged continuation and the main-map counts. Test the feature through both
embedded development mode and its private process protocol. Keep all new native
texts translated and document the workflow in every manual language.

Future reviewed extensions include parallel isolated worktrees, more native subagent
profiles, proven native session resume, granular interactive permission prompts,
project templates, richer result artifacts and a background supervisor. The
language-neutral process boundary allows a Rust implementation if measured needs
justify it; a language rewrite is not required for the initial workflow.

During work run affected checks first; at final integration run all repository
suites once, following Uwe's task instruction. Record the tests actually run and
their limitations. Claude/Antigravity independent review remains pending: the
current environment prevented API DNS/local-socket access. No CLEAN result is
claimed for those attempts.

Final validation and outstanding host checks: [task 082 review](reviews/082-ai-project-center.md).

Continuation checks now exercise the native widgets with the socket-free runner. Pause retry and popup-safe folder selection are covered; see the [updated review](reviews/082-ai-project-center.md).
