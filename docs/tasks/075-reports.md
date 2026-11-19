# 075 Reports page: activity log, AI topic reports, report library

Author: Codex · Reviewer: Antigravity · Branch: task/075-reports

## Goal

A header symbol opens a Reports page. It shows the local activity log and
its settings, lets an AI helper write topic reports from the log, and keeps
saved reports in a local library that outlives the log.

The log now keeps one week by default (was two days).

## Routes

Wire contract. See the [plan](../plan-reports.md) for nested fields and
edge cases.

| Route | Kind | Params | Result |
| --- | --- | --- | --- |
| `activitylog.report` | read | unchanged | unchanged (reused by the Log tab) |
| `settings.get`, `settings.update` | read/change | unchanged | `ai_activity_log_days` default 7 |
| `reports.generate` | handle | `from_day?, through_day?, project?, source?, focus?: string` | job handle. Final result `{draft: Draft}` or `{error}` |
| `reports.save` | change | `draft: Draft, title: string` | `{report: Report}` |
| `reports.list` | read | `query?: string, cursor?: int` | `{reports: ReportRow[], next_cursor?}` |
| `reports.get` | read | `id: int` | `{report: Report}` |
| `reports.update` | change | `id: int, title?: string, note?: string` | `{report: Report}` |
| `reports.delete` | change | `id: int` | `{deleted: bool}` |

A draft is `{title, from_day, through_day, filters, helper, generated_at,
entry_count, topics[], text}`. A topic is `{name, summary, sources[],
projects[], spans, elapsed_ms, tokens_in?, tokens_out?}`. A stored report
adds `{id, saved_at, note?}`. Rows list `{id, title, saved_at, from_day,
through_day, topic_count}`.

The CLI gains `maprisma-core reports list|show <id>|export <id>
--format text|json`. The MCP history server gains a read-only
`reports_list(query?)` and `reports_get(id)`.

## UI

- Header symbol "Reports" (beside Ask AI). Opens a full page, not a dialog.
  Esc and ← Back return to the map.
- Three tabs: **Log**, **Topic reports**, **Library**.
- **Log:** the entries and totals of `activitylog.report` with the date
  filter, copy and TXT/JSON export (move them over from the history
  dialog). On top, the log settings: "AI activity log", "Keep log for",
  "Topic summaries by local LLM", the same keys as in Settings, both places
  stay in step. When the log is off, a hint and the switch instead of an
  empty list.
- **Topic reports:** date range, optional project and agent filter, an
  optional focus line ("what should the report look at?"), the AI helper
  dropdown (shared choice), Generate. Shows progress, then the draft
  (topics as cards, then the text). Copy, export TXT/Markdown/JSON,
  **Save to library** with an editable title.
- **Library:** search field, list of saved reports newest first, open,
  rename, note, copy, export, delete (with confirmation).
- The old "AI activity log" history dialog opens the Log tab instead.
- All texts in the eight languages. Manual chapter "Reports" in all eight
  manuals, and the "Keep log for" text updated to one week.

## Acceptance

- Default retention is 7 days in Dart, the Python reference schema, the
  settings view fallback, the manual and tests. Stored values stay.
- The page settings and Settings › Maprisma change the same keys and show
  each other's change after reopening.
- Generation sends only sanitized log entries (no paths outside the
  project label, no file contents), bounded in size; it obeys the Ask AI
  rules and the online switch; it fails cleanly without a helper or log.
  A fake helper in tests returns a fixed answer; a malformed answer gives
  an error, never a half-saved report.
- The library is a private SQLite file, survives log pruning, and is never
  pruned. Tests cover save, list, search, get, update, delete, a corrupt
  or locked database, schema version, and concurrent writers.
- CLI and MCP results and all export formats verified.
- Branch checks, full suites and build as listed in AGENTS.md. Capture the
  three tabs in light and dark (outside the commits). Report commits, test
  counts and open questions.
