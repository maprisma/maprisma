# 103 Schedule hardening: what AI Agents Map 2.1.0–2.1.4 fixed

> **Status 2026-11-23: ready for review (Antigravity round 2).** Round 1 (ea9807e0) found 8 points (2 High,
> 4 Medium, 2 Low), all confirmed and fixed in fb524392 (core) and 2e4415dd (gui), each with a test that fails
> on ea9807e0; record in `docs/reviews/103-schedule-hardening.md`. Earlier: the WIP was reviewed against
> `main` (0297b5f2, Maprisma 2.1.3), every finding below confirmed; the core suite's machine-dependent
> failures (usage_refresh ×10, map_chain R3 #10, dictation readiness, agent_detect OpenClaw/Hermes,
> smart_card local group, activity_stdio history CLI) also fail on main. Not merged, no release.

Author: Claude · Reviewer: Antigravity · Branch: task/103-schedule-hardening

Uwe (2026-11-23): check whether Maprisma 2.1.3 has the bugs found and fixed in its sister project, the
Omarchy plugin AI Agents Map (2.1.0–2.1.4: `harnesses.py`, `schedule_units.py`, `schedule_handover.py`,
`project_schedule.py`), and fix those it has.

## Goal
Task 101's schedules keep their bookkeeping straight when systemd or the file system fails: no timer
keeps running with its files gone, no occurrence is lost or half read, no folder is read whole into
memory, and nothing fails silently; the user is told and Maprisma tries again.

## Findings (per class)
- **Agent add-ons without `[project]`** (AI Agents Map 2.1.0): not in Maprisma. `addons.withNewerFacts`
  takes the built-in adapter's `[project]` table when the add-on has none (since task 082); the signed
  add-ons in `maprisma-addons` carry the same tables as `adapters/`. A test now keeps it so.
- **A request visible before it is complete:** not in Maprisma (temporary name, fsync, rename). Fixed
  around it: a draft that failed is removed; drafts a dead trigger left (older than 10 min) are cleaned;
  a request that cannot be written at all is told (notification, exit 1) instead of only logged.
- **A failed `disable --now` ignored:** in Maprisma (`SystemdUserScheduler.remove`). Fixed: the files
  stay and the removal throws with systemd's reason; a failed delete or `daemon-reload` throws too. A
  rewrite systemd refuses puts the previous files back (the store keeps the old schedule).
- **A failed status query counted as "stopped":** Maprisma queries no `is-active`; its analogue,
  an unreadable unit folder counted as "no timers" (`installed()`), is fixed: it throws.
- **Listing caps / whole folders in memory:** no cap hid anything, but both the unit folder and the
  spool were read whole (`listSync`). Both are now streamed; the spool keeps at most 64 requests per
  look (handled ones are gone at the next, directories never count).
- **Cleanup that reports success with a timer left:** Maprisma has no `clear` command; its paths
  (Off, delete, an ended schedule, reconciliation) swallowed every failure. Now each records event
  `schedule_timer_failed` with the reason on the project (once per reason) and sends a desktop
  notification (once per process); the next reconciliation or the timer's own next trigger tries again.
- **Hand-over:** a claimed request was deleted before it was handled, so an owner closing in between
  lost the occurrence. It is now removed only once handled; one the closing owner could not handle stays
  claimed (`.taken`) for the next owner (the slot check keeps it from running twice). A run that throws
  is told.

- **After review round 1:** removals run inside the schedule chain (awaited), so a following
  set_schedule waits and the headless owner stays until they end; an ended schedule is recorded once; an
  unreadable unit folder is an error in `remove()`/`install()` too (Dart's `typeSync` said "not found");
  a timer started next to a left-over service is stopped before its files go; every timer reason is one
  line of at most 200 characters without control characters; broken spool entries count as work; a timer
  report is an optional store write (a full store never stops running work); a look stops claiming once
  the store is released; a run dropped for a storage fault is told.

## Routes
`ai_project_center` `set_schedule` note (routes.json): event `schedule_timer_failed`, no silent timer
failures. No shape change.

## UI
`_eventText`: `schedule_timer_failed` in the user's language with systemd's reason. Six new texts (core
notifications and the event) in all 8 languages. Manual (8 languages), "Running a project on a schedule":
a sentence on timers systemd refuses.

## Acceptance
- `agent_detect_test.dart`: an agent add-on signed before `[project]` keeps the app's project profile.
- `project_schedule_test.dart` (each fails on 2.1.3): a failed `disable --now` keeps the files and
  throws; a refused rewrite restores the previous timer; an unreadable unit folder throws, a large one is
  read whole; a timer that cannot be removed is recorded and told once; reconciliation tells what it
  could not do; a claimed request a closing owner could not handle stays for the next; the spool is read
  whole and drafts go; a request that cannot be written is told.
- `project_event_translation_test.dart`: the new event in the user's language.
