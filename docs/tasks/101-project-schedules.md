# 101 Project schedules with recurrence

Author: Claude · Reviewer: Antigravity · Branch: task/101-project-schedules

Uwe (2026-11-23): "Projects need a scheduling feature with a recurrence option, for example: check
my emails every day at 5 o'clock." A project can run its approved plan by itself: every day at a
time, on chosen weekdays, once a week, every few hours or once a month, until a date or for ever;
also while Maprisma is closed.

## Goal
The user gives an approved project a schedule; at each planned time the project's approved plan
runs with its team exactly as a click on Run would, also with the app closed. When it cannot run
(the approval no longer fits, it waits for a review), it does not run, says why on the project and
in a desktop notification.

## Routes
No new route; `features.call`'s note in `routes.json` describes the new AI Project Center
operation (host allow-list in `feature_routes.dart`). Protocol version stays 2. The backend lists
the capability `schedule` in `@hello`; the GUI offers the schedule only when it is there.

- `set_schedule {id, schedule}`: `schedule` is an object or `null` (off); answer `{project}`.
  A setting like `set_importance`: no revision check; revision, `updated_at`, events and the
  approval stay; allowed while the project works.
  - `repeat`: `daily`, `weekdays`, `weekly`, `hours` or `monthly`.
  - `time`: `HH:MM`, local 24-hour clock (for `hours` the first run of each day).
  - `days`: ISO weekdays 1 (Monday) to 7: `weekdays` one or more, `weekly` exactly one.
  - `every`: 1, 2, 3, 4, 6, 8 or 12 hours (`hours` only; divisors of 24, so the runs are the same
    every day).
  - `day`: 1 to 31 (`monthly` only; a month without that day runs on its last day).
  - `until`: optional `YYYY-MM-DD` or null: the last local day with a run.
  - Refused: `project_schedule_invalid` (another field, a field of another repeat, a missing or
    invalid value, an `until` before today), `project_unknown`, `project_schedule_unavailable`
    (no timer can be kept: no systemd user manager or no program to start, the timer could not be
    written or enabled, or a unit file of that name Maprisma did not write is in the way; nothing
    changes), and like every write after a storage fault.
- Every project view and board card: `schedule` (the object or null) and `next_run` (ISO 8601 UTC of
  the next planned run, null without a schedule or after its end).
- Events: `schedule_started`, `schedule_skipped` (with the reason), `schedule_ended`.

## Design: how a timer starts a run

**Timers.** One systemd **user** timer per scheduled project,
`~/.config/systemd/user/maprisma-project-<id>.timer` and `.service` (the id is the 32-hex project
id; no title or other user text reaches a unit file). Both start with the marker line
`# Managed by Maprisma: scheduled AI project`; a file of that name without the marker, or a link, is
never overwritten or removed (`project_schedule_unavailable`). The timer has `OnCalendar=` lines
(month ends: several lines, e.g. day 31 is `*-01,03,05,07,08,10,12-31` plus `*-02,04,06,09,11~01`),
`Persistent=true` (a missed run runs once after the next login), `AccuracySec=1s`. The service is
`Type=exec`, `KillMode=mixed`, `ExecStart=` the AI Project Center program with `schedule-run <id>`
as separate quoted words (no shell; `%`, `$`, `\` and `"` escaped, control characters refused) and
`Environment=` pins for `PATH`, the XDG folders and the bundle root, so the run finds the same agents
and the same store as the app. `systemctl --user` calls are bounded (60 s). The writer lives behind
the desktop adapter (`desktop_schedules.dart`, `Desktop.projectScheduler`; macOS later gets
launchd there). The owner reconciles at start: timers of scheduled projects are written when missing
or different, managed timers of deleted or unscheduled projects are removed; nothing else is touched.

**One owner, a hand-over spool.** The store's owner is whoever holds the exclusive lock on
`ai-project-center/` (kernel `flock`: released when its process dies, so no stale PID or socket can
be taken over). The timer starts `plugin schedule-run <id>`, which:

1. writes a request `{id, at}` into the private spool `ai-project-center/schedule/`
   (`<id>.<random>.request`, written to a temporary name and renamed, mode 0600, inside the 0700
   store folder, so another local user can neither write nor read it);
2. tries to take the store lock. **Taken** (Maprisma is closed): it is the owner, handles the spool
   (its own request too), waits until its runs have ended, shuts down like the app's backend and
   exits. A `SIGTERM` (logout, `systemctl stop`) pauses the runs within the bounded shutdown.
   **Held** (Maprisma runs): the running owner polls the spool every 2 seconds and claims each
   request by renaming it (`.taken`) before reading it, so one request is handled once; the CLI
   exits when its request is gone. When the owner ends meanwhile the CLI takes the lock and handles
   its request itself; after 60 s without an answer it withdraws its request (a failed unlink means
   it was claimed) and notifies the user.

A request carries no command: the owner checks a regular, own, small file and runs only the stored,
approved plan. The request's time maps to the latest planned run at or before it (the slot); a slot
not after the last handled one, or before the schedule was set, is dropped, so overlapping triggers
(a catch-up and the next run, a manual `systemctl start`, a request left by an owner that died)
never run twice. Requests left as `.taken` by a dead owner are handled again by the next owner; the
slot check makes that safe.

**The run.** The owner records the slot first, then: already running (or its processes still
stopping): `schedule_skipped`, no notification. Not ready (draft, awaiting review, paused,
interrupted, failed, changes to review) or approval not valid (plan, team, folder or profiles
changed), a rule refusing one of its agents (checked before the launch, so a refusal does not fail
the project) or a refused launch (`project_folder_busy`, `project_capacity`, ...):
`schedule_skipped` with the reason and a desktop notification. Otherwise the run operation itself
(`_launch('run')`, also from `completed` while the approval is valid), with its rules check at each
assignment and its supervisor; event `schedule_started`. After the `until` day: `schedule_ended`
and the timer is removed.

While a scheduled run works with Maprisma closed, the CLI owns the store: an app started meanwhile
shows that a scheduled project is running in the background until it has ended (the host retries
the backend).

## UI
- Goal tab, under Importance: **Schedule**: Off, Every day, On weekdays, Every week, Every few
  hours, Every month; a time button (time picker), weekday chips, the weekday, the hours, the day of
  the month, Ends: Never / On a date (date picker); a summary line (“Every day at 05:00 · next run
  Tue 05:00”); a note when the project would not run now (not approved). Each change is sent at
  once (`set_schedule`), like the importance mark.
- Board cards: a small clock with the next run (tooltip with the summary).
- Texts in all 8 languages; manual chapter “Schedules” in all 8 manuals.

## Acceptance
- `project_schedule_test.dart`: validation (fields per repeat, hostile values), the next run and the
  slot for every repeat, DST (a fake Central European zone: a 02:30 run on the spring day moves to
  03:30, on the autumn day runs once, daily runs stay at their wall-clock time), month ends (31 →
  30/28/29), `until`; `OnCalendar` lines; unit text and quoting (newlines, `;`, quotes, `%`, `$`
  never reach a unit file or argv), the managed-marker rule (no overwrite or removal of a foreign
  unit, no link followed), install/remove/reconcile with a fake `systemctl`.
- `ai_project_center_test.dart` group "schedules (task 101)": set/clear without revision change,
  timer written and removed (also on delete), refusals, skip when not approved / waiting for review
  (event and notification), skip when running (no notification), a scheduled run from ready and
  from completed through the real run path, a refused rule, a duplicate slot, until ended, the
  spool hand-over (claim once, hostile request files ignored), the headless owner path.
- `feature_plugins_test.dart`: capability `schedule`, `set_schedule` passes the host.
- Flutter: `project_schedule_test.dart` (the control, the summary, sending `set_schedule`) and the
  board clock.
