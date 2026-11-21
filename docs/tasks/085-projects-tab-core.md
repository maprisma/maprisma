# 085 Projects tab, part 1: core contract

Author: Claude · Reviewer: Codex and Antigravity · Branch: task/085-projects-tab-core

Step 1 of `docs/plan-main-layout.md` (CLEAN after 11 review rounds), core part. The GUI part
(tabs, navigation, guards) follows as task 086 on top of it. Uwe's defaults (2026-11-21, "go on"
with the proposals): tabs **Projects** and **AI Map**, start on the last used tab, Reports stays a
header symbol, Phases view later.

## Goal
The core gives the GUI everything the Projects tab's header needs: one stage/activity/bucket
function for projects, the summary counts built from it, per-feature API ranges and capabilities,
a discovery generation with an explicit refresh, and the `main_tab` setting.

## Routes
- `features.summary`: adds `needs_you`, `ready`, `drafts`, `finished`, `total`, `error` (string
  or absent), `by_agent` ({agent command: projects}), `api` and `capabilities` (null on the
  no-project fast path). `running` (planning, active setup, running, reviewing; not stopping),
  `pausing` (stopping: `pausing` or `processes_stopping`), `waiting` (awaiting_review) keep their
  meaning, `attention` too (interrupted and failed plus one for a store fault); the new
  `attention_projects` counts interrupted and failed projects only (the Attention bucket; the
  store fault is in `error`). No incompatible change, so the protocol stays 2 (the plan's bump is
  not needed this way).
- `features.list`: per feature the supported API range, and the negotiated API and capabilities
  once a backend runs (null before).
- `features.call`: optional fourth key `refresh` (bool): the host grows its discovery generation
  and forwards the call without it.
- `settings.update` / `app.snapshot`: `main_tab` (`projects` | `map` | null).

## Core
- `features/project_stage.dart`: a pure function from a project record and its derived facts
  (approval valid, processes stopping) to stage, activity, second line and bucket (machine codes),
  exactly as the plan's table; Approved · blocked waits for step 2 (launch issues).
- `summary()` built from it, plus `by_agent`; approval validity from a display snapshot cached by
  the discovery generation (rebuilt when it grows, after 60 s, and on refresh); launches keep
  taking a fresh snapshot.
- Feature host: API ranges per feature (AI Project Center 1–2, Reports and Ask AI 1); `@hello` may
  list capabilities (absent means none; else a list of non-empty strings); a signed update's
  `@hello` API must equal its manifest's; embedded mode uses the host's own values. The AI Project
  Center backend answers API 2 with the capability `summary2`.
- The discovery generation travels with every Project Center request; the host grows it on map
  refresh, add-on, settings and connection changes and on `refresh`.

## UI
None in this task (086).

## Acceptance
Tests: the stage function over every status × phase × stopping × reconciliation × approval case of
the plan; summary counts and buckets (each project once; store fault only in `error`; no-project
fast path fields); API-1 backend through the real manifest/stdio path (old summary read the old
way, no capabilities); a signed update whose `@hello` API differs from its manifest is refused;
the generation grows on `refresh` and the worker rebuilds its snapshot; `main_tab` round trip.
Protocol test, translations untouched. Codex and agy review CLEAN.
