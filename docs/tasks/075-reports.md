# 075 Reports page: activity log, AI topic reports, report library

Author: Codex · Reviewer: Antigravity · Branch: task/075-reports

## Goal

A header symbol opens a Reports page. It shows the local activity log and
its settings, lets an AI helper write topic reports from the log, and keeps
saved reports in a local library that outlives the log.

The log now keeps one week by default (was two days).

## Routes

Wire contract. See the [plan](../plan-reports.md) for nested fields, error
codes and edge cases. Review round 1 settled the shapes below.

| Route | Kind | Params | Result |
| --- | --- | --- | --- |
| `activitylog.report` | read | unchanged | unchanged (reused by the Log tab) |
| `settings.get`, `settings.update` | read/change | unchanged | `ai_activity_log_days` default 7 |
| `reports.helpers` | read | none | `{helpers: [{command, name, local}], chosen: string?, online_allowed: bool, rules_broken: bool}` |
| `reports.generate` | read | `helper: string, from_day?, through_day?, project?, source?, focus?: string` | `{task: string}`; `tasks.status` ends with `result {draft_id, draft}` or `{error, code}` |
| `reports.save` | change | `draft_id: string, title: string, note?: string` | `{report: Report}` |
| `reports.list` | read | `query?: string, cursor?: int` | `{reports: ReportRow[], next_cursor?, read_only: bool, schema_version: int}` |
| `reports.get` | read | `id: int` | `{report: Report}` |
| `reports.update` | change | `id: int, title?: string, note?: string` | `{report: Report}` |
| `reports.delete` | change | `id: int` | `{deleted: bool}` |
| `reports.move_aside` | change | none | `{moved_to: string}` |

A draft is `{title, from_day, through_day, filters {project?, source?,
focus?}, helper, generated_at, entry_count, total_entries, capped, topics[],
text}`. A topic is `{name, summary, sources[], projects[], spans,
elapsed_ms, tokens_in?, tokens_out?, usage_unknown}`. A stored report adds
`{id, saved_at, note?}`. Rows list `{id, title, saved_at, from_day,
through_day, topic_count}`, 50 per page.

Error codes: `no_helper`, `online_blocked`, `no_entries`, `log_off`,
`helper_failed`, `bad_answer`, `draft_unknown`, `reports_db_corrupt`,
`reports_db_locked`, `reports_db_read_only`, `report_not_found`.

All `reports.*` change routes go into `rulesExempt` (they change only the
user's own library, never on an AI proposal).

The CLI gains `maprisma-core reports list|show <id>|export <id>
--format text|markdown|json` (`CoreService(migrate: false)`). The MCP
history server gains read-only `reports_list(query?, cursor?)` and
`reports_get(id)` (errors as `isError: true`).

## UI

- Header symbol "Reports" (beside Ask AI) opens a first-class page
  (`_view = 'reports'`), not a dialog. Esc and ← Back return to the map.
- Three tabs: **Log**, **Topic reports**, **Library**.
- **Log:** the entries and totals of `activitylog.report` with the date
  filter, copy and TXT/JSON export (moved over from the history dialog).
  The log settings are on top: "AI activity log", "Keep log for (days)",
  "Topic summaries by local LLM". They are the same keys as in Settings, so
  both places stay in step. When the log is off, the page shows a hint and
  the switch instead of an empty list. Refresh on open, after a settings
  change and with a Refresh button. While the tab is visible it also
  refreshes every 30 s, keeping scroll and selection.
- **Topic reports:** date range, optional project and agent filter, an
  optional focus line ("what should the report look at?"), the helper
  dropdown from `reports.helpers` with the reason when online helpers are
  hidden, and Generate. The page shows progress, then the draft (topics as
  cards, then the text). Copy, export TXT/Markdown/JSON, and **Save to
  library** with an editable title.
- **Library:** search field, saved reports newest first; open, rename,
  note, copy, export, delete (with confirmation). A broken database shows
  the error and "Move aside and start new".
- Settings' "AI activity log" history button opens the Reports page on the
  Log tab (callback, no dialog).
- Leaving the page while a report is being generated asks whether to cancel
  it. This covers Esc, Back and the header buttons.
- All texts in the eight languages. Manual chapter "Reports" in all eight
  manuals, and the retention text says one week.

## Acceptance

- The default retention is 7 days: `settings_schema.py`, the regenerated
  `core_assets.g.dart`, both settings view fallbacks, all manuals and the
  tests. A stored 2 stays 2 (tested).
- The page settings and Settings › Maprisma change the same keys and show
  each other's change after reopening.
- Generation sends only sanitized log entries with compact ids (no paths
  beyond the project label, no file contents), bounded in size. It obeys
  the Ask AI rules, and the online gate is checked in the route and again in
  the worker before the helper runs. Online helpers use the no-tools
  background form and local helpers the loopback form, never `taskArgv`. It
  fails with a code without a helper or entries. A fake helper in tests
  returns fixed answers; a malformed answer gives `bad_answer`, never a
  half-saved report. Duplicate entry ids in a topic count once.
- The library is a private SQLite file that survives log pruning and is
  never pruned. Tests cover: save, list, search (including `%` and `_`),
  get, update, delete, a corrupt database plus move-aside with sidecars, a
  locked database, a newer schema being read-only, two writers at once,
  non-ASCII text, file modes, and refusing symlinks.
- The 64 KiB request limit holds: no route sends a draft back.
- CLI and MCP results and all export formats are verified.
- Branch checks, full suites and build as listed in AGENTS.md. Capture the
  three tabs in light and dark (outside the commits). Report commits, test
  counts and open questions.
