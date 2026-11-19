# Reports page

Task [075](tasks/075-reports.md). Builds on task 074
([plan](plan-agent-activity.md)): the activity log, `activitylog.report`,
the history CLI/MCP server and the three log settings already exist.

## Decisions (Uwe, 2026-11-19)

- A header symbol opens a Reports page with the log, AI topic reports and a
  library of saved reports.
- Saved reports are kept until the user deletes them. No retention setting.
- The log keeps one week by default (`ai_activity_log_days` default 7, was
  2). Range stays 1–365. A value the user stored stays.
- The log settings are also shown on the Reports page.
- Codex builds it, Antigravity reviews (plan first, then the branch).

## Existing code

- `ai_activity_log.dart`: writing, sanitizing, pruning and the report
  aggregation. Reuse its sanitizer and `report()` for the generator input.
- `activity_log_dialog.dart`: date range, entries, copy and export. Move
  the body into a widget the Log tab reuses; keep the dialog entry points
  opening the page on the Log tab.
- `settings.dart`, `settings_schema.py`, `settings_view.dart` (the
  `ai_activity_log*` keys): change the default in all three.
- `sqlite_numbers.dart` opens `libsqlite3.so.0` through FFI read-only on a
  memory image. The library needs a real writable connection: add a small
  FFI binding in a new file (open_v2 with READWRITE|CREATE, prepare,
  bind, step, column, finalize, close, busy_timeout). No new pub package.
  `tools/check-bundle.py` must stay green.
- AI helper: the shared choice in `~/.config/maprisma-ai/settings.json`
  (`helper`), helpers catalog `helpers.json`, and the task prompt helpers
  in `system_help.dart` (`task_prompt_path`, `write_task_prompt`,
  `task_argv`). Run the helper as a worker job like the map analysis
  (`analyzeMap`): cancellable with SIGTERM, progress on the handle.
- Ask AI rules: `/mnt/Data/Projects/maprisma-settings/docs/ask-ai-rules.md`.

## Generator

1. Read `activitylog.report` for the range and filters, all pages, capped
   (e.g. 2,000 entries and 200 KiB of prompt). When capped, say so in the
   draft and in the prompt.
2. Build a prompt from sanitized entries only: agent/runtime, model,
   project label, topic heuristic, start/end/duration, counts of files and
   helper tools, tokens. No file paths beyond the project label, no file
   contents, no raw tool arguments. The optional focus line is plain user
   text, bounded to 500 characters.
3. Ask the helper for JSON: `{title, topics:[{name, summary, entry_ids[]}],
   text}`. The core validates it, recomputes `spans`, `elapsed_ms`, tokens,
   `sources` and `projects` per topic from the referenced entries (never
   trusts the AI's numbers), drops unknown ids, bounds lengths, strips
   control characters. Invalid JSON → one retry with the error, then
   `{error}`.
4. Without a helper, without log entries in range, or with the log off and
   no files: a clear error, no job.

## Privacy and Ask AI rules

- A report is an **answer** of Ask AI, not an action. It runs in both
  levels (`review`, `answers`).
- New data id `maprisma.activity_log_online` (**default off**, in the
  "off unless switched on" list): with an online helper the log is sent
  only when it is on; otherwise only local helpers (pi loopback models,
  local runtimes) are offered and the dropdown says why. The log promise
  "never uploaded" stays true unless the user switches this on. The
  Maprisma Settings › AI table needs the id and its text (small follow-up
  in the maprisma-settings repo, listed as an open point, not in this
  branch).
- Read the rules file exactly as the contract says (missing = defaults,
  broken = restrictive). Never write it.

## Library

- `${XDG_DATA_HOME:-~/.local/share}/maprisma/reports/reports.db`, folder
  0700, file 0600, WAL mode, `busy_timeout`, `user_version` = 1.
- Table `reports(id INTEGER PRIMARY KEY, title, note, saved_at, from_day,
  through_day, filters_json, helper, generated_at, entry_count,
  topics_json, text)`. Search with LIKE on title, note, text and topic
  names (FTS5 only if available, with LIKE fallback).
- Never pruned with the log, never touched by log settings.
- A corrupt database: list/get return an error with a "Move aside and
  start new" action (renames to `reports.db.broken-<time>`), never a
  silent rebuild. A newer `user_version`: read-only with a notice.
- Bounds: title 200, note 2,000, text 200 KiB, 64 topics.

## UI notes

- Follow the maprisma-layout and maprisma-app skills: theme colours,
  corners, Esc, remembered tab, eight languages.
- The page refreshes the Log tab while open (same interval as the history
  dialog). Generation keeps running when switching tabs; leaving the page
  asks whether to cancel it.
- Export file names: `maprisma-report-<from>-<through>.<ext>`.

## Delivery

Commits `protocol:`, `core:`, `gui:` with `tools/test-changed` green, then
`tools/test-changed --base main` and the full suites from AGENTS.md. New
routes are Dart only, like 074 (Python reference only for the settings
default).
