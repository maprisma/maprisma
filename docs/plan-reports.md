# Reports page

Task [075](tasks/075-reports.md). Builds on task 074
([plan](plan-agent-activity.md)): the activity log, `activitylog.report`,
the history CLI/MCP server and the three log settings already exist.
Review: [round 1](reviews/075-reports.md), all findings accepted below.

## Decisions (Uwe, 2026-11-19)

- A header symbol opens a Reports page with the log, AI topic reports and a
  library of saved reports.
- Saved reports are kept until the user deletes them. No retention setting.
- The log keeps one week by default (`ai_activity_log_days` default 7, was
  2). Range stays 1–365. A value the user stored stays.
- The log settings are also shown on the Reports page.
- Codex builds it, Antigravity reviews (plan first, then the branch).

## Existing code

- `ai_activity_log.dart`: writing, sanitizing, pruning and `report()`.
  `report()` filters neither project nor source and goes through
  `_activityReportWithTopics()` in `core.dart`, which may start the local
  LLM per page. The generator therefore gets its own bounded, filterable
  read method on `AiActivityLog` that does not use the topic helper.
- `activity_log_dialog.dart` has no refresh timer. Move its body into a
  widget the Log tab reuses. `settings_view.dart` opens it with
  `showDialog`; replace this with an `onOpenReports` callback.
- Settings default: change `settings_schema.py` (the source), run
  `tools/core-assets.py` to regenerate `core_assets.g.dart` (the Dart
  defaults), and change both `?? 2` fallbacks in `settings_view.dart`.
  Update `ai_activity_log_test.dart` (pruning assumed 2 days) and add a
  test that a stored 2 stays. Translation keys stay `Keep log for (days)`;
  new keys go in `translations/*.json` plus `tools/flutter-assets.py`.
- `sqlite_numbers.dart` opens `libsqlite3.so.0` read-only on a memory
  image. The library gets its own writable binding (see Library). No new
  pub package; no bundled `.so`; `tools/check-bundle.py` stays green.
- Helpers: Maprisma's own `smartHelpers()` / `localHelpers()` in
  `core.dart` and `local_helper.dart`, and the `smart_helper` setting (not
  `helpers.json`, which is exported for the other apps). Online helpers run
  through `smartAgent` / `guardBackground` with the adapter's `[rewrite]`
  form (no tools, prompt on stdin). Reports checks that the rewrite argv
  explicitly disables tools. A read-only sandbox alone still permits file
  reads, so helpers with that form are unavailable for reports. Local
  helpers run through `adviseArgv`
  against configured loopback runtimes, with no online fallback. **Never**
  `taskArgv`: it starts an interactive session with tools.
- Jobs: start like `map.smart_ask` (kind `read`, result `{task}`, polled
  through `tasks.status`, stopped through `tasks.cancel`). The finished
  draft is held in core memory behind `draft_id`, filled in the
  `tasks.startPrivate` finalize callback (like `SmartProposals` /
  `HelpPreviews`). Drafts expire with the session, and only the newest 8
  are kept.
- Request frames are capped at 64 KiB (`protocol.dart` `maxRequest`), so
  no route takes a draft. The worker reads the log itself from the
  validated filters; its stdin carries only parameters.
- `action_rules_test.dart` requires every change route in `actionChecks`
  or `rulesExempt`. All `reports.*` change routes go into `rulesExempt`.
- Ask AI rules: `/mnt/Data/Projects/maprisma-settings/docs/ask-ai-rules.md`.

## Generator

1. `reports.generate` validates its parameters and the helper (must come
   from `reports.helpers`) and checks the online gate, then starts the job.
   Pre-job refusals throw `ServiceError` with a code (`no_helper`,
   `online_blocked`, `no_entries`, `log_off`).
2. The worker reads up to 2,000 entries (filtered by range, project and
   source) through the new log method, capped at 200 KiB of prompt. When
   capped, `capped: true` and `total_entries` go into the draft and the
   prompt says so.
3. The prompt holds only sanitized entries with compact ids `1..N`: agent
   or runtime, model, project label, heuristic topic, start/end/duration,
   counts of files and helper tools, tokens. It contains no file paths
   beyond the project label, no file contents and no raw tool arguments.
   The focus line is user text, at most 500 characters with control
   characters stripped, and is wrapped in explicit "untrusted data"
   markers.
4. The online gate is checked again right before the helper runs (rules
   may have changed during preparation).
5. The helper answers with JSON `{title, topics:[{name, summary,
   ids[]}], text}`. The core validates it:
   - it maps the compact ids back to entries, drops unknown ids and counts
     duplicates once;
   - it recomputes `spans`, `elapsed_ms`, tokens, `usage_unknown`,
     `sources` and `projects` per topic, never trusting the AI's numbers;
   - it bounds lengths (title 200, 64 topics, text 200 KiB) and strips
     control characters.

   Invalid JSON gets one retry with the error. A second failure ends with
   `{error, code: bad_answer}`. A crashed or timed-out helper ends with
   `helper_failed`.

## Privacy and Ask AI rules

- A report is an **answer** of Ask AI, not an action. It runs in both
  levels (`review`, `answers`).
- New data id `maprisma.activity_log_online`, in the "off unless switched
  on" list: only an explicit `true` allows it. A missing file, missing key,
  non-object `data`, non-boolean value, an unreadable file or a file over
  64 KiB all deny, and a broken file also sets `rules_broken`. Without it
  only local helpers are offered, and `reports.helpers` says why. The log
  promise "never uploaded" stays true unless the user switches this on.
- Read the rules file read-only, exactly as the contract says. Never write
  it. The Maprisma Settings › AI table needs the id and its text: a
  follow-up in the maprisma-settings repo, not in this branch.

## Library

- Location `${XDG_DATA_HOME:-~/.local/share}/maprisma/reports/reports.db`.
  The folder is created through `Posix.privateDirectory` (0700, owner
  checked, no symlinks). `reports.db`, `-wal` and `-shm` must not be
  symlinks or foreign-owned. Pre-create only the main file as 0600.
  Tighten existing sidecars to 0600 after enabling WAL.
- FFI binding in a new file, with the library opened lazily and guarded (a
  missing `libsqlite3.so.0` becomes `reports_db_unavailable`). It binds: `open_v2`, `close_v2`, `busy_timeout`, `exec`,
  `prepare_v2`, `bind_text` / `bind_int64` / `bind_null`, `step`,
  `column_*`, `finalize`, `last_insert_rowid`, `changes`,
  `extended_errcode` and `errmsg`. Text is bound as UTF-8 with the byte
  length and `SQLITE_TRANSIENT`.
- Open order:
  1. `open_v2` (READWRITE|CREATE|NOFOLLOW)
  2. `busy_timeout` 5 s
  3. read `user_version`
  4. if it is above 1: `query_only=ON`, read only, `read_only: true`,
     never write
  5. otherwise `journal_mode=WAL`, `synchronous=NORMAL`, then create or
     migrate the schema inside `BEGIN IMMEDIATE`

  All writes use `BEGIN IMMEDIATE`.
- Table `reports(id INTEGER PRIMARY KEY, title, note, saved_at, from_day,
  through_day, filters_json, helper, generated_at, entry_count,
  total_entries, capped, topic_names, topics_json, text)`. Search uses
  LIKE on title, note, topic_names and text, with `%`, `_` and `\`
  escaped (`ESCAPE '\'`).
- Never pruned with the log, never touched by log settings.
- Errors: `SQLITE_CORRUPT` / `SQLITE_NOTADB` → `reports_db_corrupt`, BUSY
  after the timeout → `reports_db_locked`, newer schema on a write →
  `reports_db_read_only`, a missing id → `report_not_found`.
- `reports.move_aside` closes the handle, takes a lock in the folder and
  renames `reports.db` **and** its `-wal` / `-shm` to
  `*.broken-<UTC time>`. It never rebuilds silently.
- `reports.update` needs at least one of `title` / `note`, and an empty
  note clears it to null. Bounds: title 200, note 2,000.

## UI notes

- Follow the maprisma-layout and maprisma-app skills: theme colours,
  corners, Esc, remembered tab, eight languages.
- `_view = 'reports'` in `main.dart` with `WindowHeader`. It pauses
  `_refreshLive()` like the other pages and calls `_loadHelpers()` on open
  so "Topic summaries by local LLM" shows.
- The Log tab refreshes when it opens, after a settings change, with its
  Refresh button, and every 30 s while visible and focused, keeping cursor,
  scroll and selection.
- While generating, every way out (Esc, Backspace, Back, `_toggleSettings`,
  and the header's AI Map, Ask AI, Help and Settings buttons) goes through
  an async guard. It asks "Cancel the report?" and calls `tasks.cancel`.
  Switching tabs inside the page keeps the job running.
- Export file names: `maprisma-report-<from>-<through>.<ext>`.

## Delivery

Commit in the order `protocol:`, `core:`, `gui:`, each with
`tools/test-changed` green, then run `tools/test-changed --base main` and
the full suites from AGENTS.md. New routes are Dart only, like 074. The
Python reference changes only for the settings default.
