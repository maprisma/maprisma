# 074 Agent activity and local activity log

Author: Codex · Reviewer: Antigravity · Branch: task/074-agent-activity

## Goal

Show what each running agent is doing and what started it. Let users opt
into local history for agent and model activity and review or export it.

## Routes

Wire contract. See the [plan](../plan-agent-activity.md) for nested
fields and applicability.

| Part | Route | Kind | Params | Result |
| --- | --- | --- | --- | --- |
| A | `agents.session_activity` | read | `command: string, instance: string` | Bounded session detail with status, latest request, answers, tool calls and edited files |
| B | `agents.progress` | read | `command: string, instance: string` | `{progress: Progress?}` |
| B | `map.snapshot` | read | Existing params | `nodes[].activity_instances[]` contains `{id, pid, progress?}`. `nodes[].activity_progress` is the most recent report and carries its instance ID |
| B | `sessions.read` | handle | Existing terminal session handle | Adds `activity_instance?` for the agent in that terminal |
| C | `agents.activity_report` | read | `command: string, instance?: string` | `{status, observed_at, instances[], report?}` |
| D | `settings.get`, `settings.update` | read/change | Existing update envelope with the three log settings | Extend settings response with validated defaults and stored values |
| D | `activitylog.report` | read | `from_day?: string, through_day?: string, cursor?: int` (inclusive ISO dates) | `{from_day, through_day, entries[], next_cursor?, by_source[], by_project[], by_day[], by_week[]}` |

Instances use `{id, pid, label}`. An activity report contains
`{instance, details, progress, timeline[], helpers[], origin, phase, stuck}`.
Timeline groups use `{from, to, kind, files[]}`. A file observation is
`{path, at, attribution}` with attribution `verified` or `observed`. Helpers use
`{pid, label, elapsed_ms}`, and origin uses
`{ancestors[], terminal_title?, close_risk}`. Phase is `planning`,
`editing`, `testing`, `finished` or `unknown`. Stuck is nullable evidence
with elapsed idle time. History aggregation rows contain group key, span
count, elapsed total, token subtotals with unknown counts and an unavailable-usage count. Entry costs are unknown with the
current observation sources. Wire times are UTC ISO 8601, except local
calendar keys. Missing, exited and ambiguous instances have explicit
statuses.

MCP tools are `report_progress(step, done, total, note?)` (B) and
`activity_log_report(from_day?, through_day?, cursor?)` (D). Both use local stdio.
The report delegates to `activitylog.report`. The progress tool writes only
for the owning live instance.

## Local commands

The installed core executable is `lib/maprisma-core` in the app bundle.
Run `maprisma-core activity-log --format json` for machine-readable history
or use `--format text` for a plain-text page. Both accept
`--from-day YYYY-MM-DD`, `--through-day YYYY-MM-DD` and `--cursor N`.
Configure `activity-mcp` and `activity-log-mcp` as separate stdio servers.
The history CLI, the history MCP server, and the Flutter history dialog
use the same report and fall back to its heuristic topics when the selected
local helper cannot classify them.

## UI

Add “What is it doing?” to agent and instance menus. The live overlay shows
request, answers, tools, progress, changed-file timeline, helpers, origin,
phase and possible stuck state. It refreshes while open, copies the whole
report and closes with Esc. Show reported progress on map and follow.

Add “AI activity log”, “Keep log for”, and “Topic summaries by local LLM”
to Settings. The log and local summaries default off and retention defaults
to two days. History opens in the themed report overlay with copy, date
filter and export to text and JSON. Append UI keys in all eight languages
and add a manual chapter covering evidence, settings and exports.

## Acceptance

- Antigravity fixture database returns current work and edited files.
  Missing, incompatible and corrupt databases fall back without writes.
  Adapter metadata selects the reader form.
- Progress validates arguments, isolates concurrent instances and rejects
  PID reuse. Map and follow show the latest report.
- All known adapters can open the live overlay. Tests cover timeline
  grouping, excluded directories, phase and stuck evidence, ancestry and
  process-tree text, and multiple or exited instances. Live copy includes
  every section, refresh preserves scroll, and Esc stops refreshing.
- History is opt-in and works for supported agent and runtime observations.
  Tests cover sanitization, private JSONL writing, day-file pruning, usage
  accounting, local-summary fallback and day/week aggregation. Verify local
  CLI and MCP results and both export formats.
- Run branch checks, full suites and build as listed in the plan. Capture
  both dialogs in light and dark. Report commits, test counts, schema
  assumptions and unresolved questions.

External runtime coverage uses existing observations and displays unknown
values when attribution is unavailable.
