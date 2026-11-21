# Plan: finishing steps for AI Project Center projects (hand-over first)

Status: draft for Uwe's decision (2026-11-21), revised after review rounds 4–8 of the hand-over scope. Scope chosen by Uwe after three review rounds of a
fully automated design (Codex and agy, `.flutter-previews/layout-plan/*-finishing-r*.txt`):
**hand-over first**. Follows `docs/plan-main-layout.md`; nothing is built until Uwe approves.

## Why

After the agents of a project finished and the user checked the result, the work often ends with
the same steps: commit and merge, push, a release, and for some projects a website update. Uwe
(2026-11-21): these steps are **optional per project**, and the **website step is off by default**,
because not everybody has a website.

The reviews showed that running git, `gh` or a deploy command from the app opens many ways to run
or publish more than the user saw (repository-local git configuration that starts programs,
transports, races between preview and run, release flags, rule migration). The first version
therefore runs **nothing outward-facing**: Maprisma prepares the steps, the user runs them.

## What the user gets

Maprisma does **not run git or anything else** in the project folder for the finishing steps, and
reads nothing in it: no `git status`, no file list, no remote lookup (round 4 showed that even
reading a repository with git can start programs or read file contents). Everything the commands
contain comes from what the user entered on the project page.

On the project page, after **Agents finished**:

1. **Check the result**: the project's last events and the advice to run `git status` and
   `git diff` in a terminal; **Mark as checked** records the completed run and the time. A new run
   or a changed goal or folder clears it.
2. **Finishing checklist**: the steps the user switched on for this project, in order, each with
   the commands to paste into a terminal opened in the project folder, a **Copy** button per step,
   and a **Done** tick. Each step's commands are joined with `&&`, so a failing command stops the
   rest:
   - **Commit and merge** (off by default, like every step), in three parts the user does in order:
     (a) `git switch <source>`, then check in the terminal: `git status` and `git diff --staged`;
     the step says plainly that a commit takes **everything** staged, so unwanted staged files
     must be unstaged first; (b) the user stages the reviewed files themselves (shown as text,
     **not** part of any Copy), then **Copy** gives only `git commit -m <message>`; (c)
     `git switch <target> && git merge --ff-only refs/heads/<source>` (a full ref, so a tag of the
     same name is never used). Without a target branch, or when it equals the source, part (c) is
     left out.
   - **Push**: `git push --no-follow-tags --recurse-submodules=no -- <remote>
     refs/heads/<branch>:refs/heads/<branch>` (no extra tags or submodule commits travel; `--` so a
     remote can never be read as an option). `<branch>` is the step's own **push branch** setting
     (filled with the target branch, else the source branch, when the user switches the step on).
   - **Release**: `git tag <tag> refs/heads/<release branch>`, where the **release branch** is the
     step's own setting (filled like the push branch when the step is switched on, editable when
     only Release is on, checked like every branch; changing it clears the Release tick),
     `git push --no-follow-tags --recurse-submodules=no -- <remote> refs/tags/<tag>:refs/tags/<tag>`,
     `gh release create --repo=<host/owner/name> --verify-tag --title=<title> --notes=<notes>
     -- <tag>` (empty notes as `--notes=''`, so no editor opens) plus `--draft` while "Publish as
     draft" is on (it is on by default; the step shows "draft" or
     "public" in words). The repository is typed by the user and shown in full.
   - **Update the website** (**off by default**, offered only when the project has a website
     command): the user's own command, shown exactly as entered.
   The card's second line reads "Finishing (2 of 3 done)" and "Steps done" when at least one step
   is switched on and all switched-on steps are ticked (through the layout's shared projection;
   Stopping and the other activity labels keep precedence, and "Check the changes first" replaces
   the finishing line while `needs_reconciliation` is set). Ticking is the user's statement;
   Maprisma does not check anything. A tick belongs to the completed run and to the step's
   settings when it was ticked: a new run, a changed setting, switching a step on, removing the
   website command, and every change that takes the project out of `completed` clear the affected
   ticks (the last one clears all of them, like the result mark).
3. **Open a terminal here**: a new host route (behind the desktop adapter) that opens the user's
   terminal with their login shell in the project's canonical folder, with Maprisma's own
   variables removed from the environment (as for agent sessions). Maprisma does not type into it.
   This is a hand-over into the user's own environment: their shell's startup and prompt hooks
   (for example direnv, a git prompt) run there as they always do; that is the one exception to
   "nothing in the folder is run or read", and the button says "opens your terminal".

**Copy** is disabled while the step's settings have unsaved edits or a required field is empty or
invalid (the command must never be built from stale settings); unsaved finishing edits are part of
the project page's Save / Discard / Cancel guard.

## Rules

- Nothing outward-facing runs from Maprisma, and nothing in the project folder is run or read for
  the finishing steps.
- Steps are off until the user switches them on, per project; **the website step is off by
  default** and only offered when a website command is configured.
- The AI team setup helper, agents, Ask AI and generic saves cannot switch a step on or edit its
  settings; only the user's own edits on the project page can (dedicated user operations, strict
  field allowlists as today).
- **Quoting for the user's shell**: the commands are written for the user's login shell (bash, zsh
  or fish, from `$SHELL`; another shell gets bash syntax with a note). **Every** value put into a
  command (branches and the refs and refspecs made from them, tag, remote, `--repo=`, `--title=`,
  `--notes=`, the message) goes through one quoting function per shell, with tests (apostrophes,
  backslashes, newlines, `$`, backticks, `;`, `&`, `|`, `<>`, `()`, `#`, `!`, Unicode). Only the
  website command is shown as the user entered it.
- **Input rules** (checked in Maprisma, no git call):
  - branch and tag: bare names (a leading `refs/` is refused), checked as `refs/heads/<name>` /
    `refs/tags/<name>` by every refname rule: no `..`, `@{`, `\`, `~^:?*[`, spaces or control
    characters, no `//`, no leading `/` or `-`, no trailing `/` or `.`, no segment that starts with
    `.` or ends with `.lock`; not `HEAD` or `@`; at most 100 characters;
  - remote: one name of letters, digits, `.`, `_`, `-`; not starting with `-`; not `.` or `..`; no
    `/`, `:`, `@`; at most 100 characters;
  - repository: `host/owner/name`: a DNS host name (letters, digits, `-`, `.`; no scheme, port,
    user or leading `-`) and two segments of `[A-Za-z0-9._-]` (not `.` or `..`); at most 200
    characters;
  - line breaks (LF only; CRLF is turned into LF; a lone CR and U+0085, U+2028, U+2029 are refused)
    only in the commit message and the release notes; every other control character,
    ANSI escape and Unicode direction override is refused in every field, also in the website
    command (a pasted command must not run on its own);
  - bounds: message 2 000, title 200, notes 8 000, website command 1 000 characters.
- No credentials: a remote or repository typed with user names or tokens is refused when saved; a
  website command containing something token-like (`token=`, `Bearer`, `ghp_`, `github_pat_`, a
  URL with user:password) is refused when saved.

## Data

Per project (store version 2, migrated): the switched-on steps, the step settings (source, target,
push and release branch, commit message, remote name, release tag, repository, title, notes, draft
on/off, website command), every field bounded as above, the result mark (completed run, time) and
the Done ticks (step, run, settings revision, time). Migrated projects get every step off, empty
settings, "Publish as draft" on, no result mark and no ticks. Clearing the website command switches
the website step off and clears its tick in the same write; the section and the board count the
same effective set of steps. Deleting the project deletes them. The project's status
does not change; the board's stage stays **Agents finished**. The result mark is cleared by a new
run and by any change that takes the project out of `completed` (goal, folder, plan or team edits,
an applied team setup).

Dedicated user operations through `features.call` (added to its operation allowlist):
`finishing_get {id}` (a read, also allowed during a store fault), and the writes `finishing_save`
(settings and switches), `finishing_mark` and `finishing_tick`, each with the project revision,
only while the project is idle (no assignment, no stopping processes), blocked during a store
fault, written atomically like every project write, never changing the plan's approval or the
status. Mark and tick need `status == completed`, no `needs_reconciliation` and the completed run;
a tick needs its step switched on and complete. These operations need a Project Center backend
that names the capabilities **`finishing`** and **`store2`** in its `@hello` answer (a list of
capability names next to the API number; the API number alone does not say it, since a backend
with only the layout changes is also API 2). The host forwards the finishing operations only to
such a backend. With a backend without `store2` (any API) the host first reads the version of
`projects.json` (Maprisma's own file, through the store's safe reader): when it is 2, the host
forwards **no** Project Center operation to that backend (`@summary`, `list`, `profiles`, `get`, writes) and the tab says the
backend needs an update instead of showing today's page, so a version-2 store is never shown as
damaged. Downgrading the whole app below the version that brings store version 2 is not supported:
the older app fails closed with its existing "project store damaged or unavailable" message and
does not write the store.

## UI and board

The Finishing section in the project page (step order, switches, commands, Copy, Done), the card's
activity label as above, all texts in 8 languages, the manual chapter with a screenshot. No new
counts in the summary (nothing runs), so the close guard is unchanged.

## Later: automation

Running steps from the app can follow in a later plan. It must answer every point the review rounds
1–4 raised (automated design 1–3, git reads 4), among them: configuration isolation for every git
call and its children, includes refused before their targets are opened, no lazy fetching, bounded
repository discovery, credential exclusions before any content-comparing git read; and also: trusted git configuration only (also `core.gitProxy`,
`protocol.*.allow`, remote helpers, signing keys, includes before opening them), a single resolved
push destination with an independent fast-forward check and immutable commit ids (a lease alone
permits non-fast-forward pushes), protected attachment copies, host-qualified `gh` calls with bound
draft/prerelease flags and tag identity, action-rule defaults that never override a user's deny
(score-1 default, one-time migration marker, the 200-rule limit), supervised asynchronous attempts
with durable states, and the folder claim shared with agent runs.

## Steps (each a task with Codex and agy review)

1. Store version 2, result mark, ticks, step settings with their validation, the four operations,
   the per-shell command builder with its tests, the terminal route (protocol first).
2. The Finishing section and the card label; manual (8 languages) and screenshot.

## Questions for Uwe

1. Every step off by default (proposed; Maprisma no longer looks whether the folder is a git
   repository), and the release as a draft by default (proposed)?
2. Merge: fast-forward only (proposed)?
