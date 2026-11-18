# Agent activity and local activity log

Task [074](tasks/074-agent-activity.md) delivers a live report for every known
agent and an optional local history for agents and runtimes.

## Existing code and constraints

- `session_readers.dart` dispatches numeric session reads by the adapter's
  `[sessions]` form. Pi and Claude have file forms, Codex and Gemini have other
  file forms, several adapters use database forms or hooks, and Antigravity
  has no session declaration. Keep text reads on demand. The numeric paths in
  `claude_sessions.dart`, `usage_readers.dart` and `usage_rpc.dart` serve usage
  displays and limits, with different scopes and accounting semantics.
- `activity_readers.dart` and the reference `agent_activity.py` give activity
  signals such as turn markers, recent writes and CPU deltas. Reuse those
  signals, retaining per-process identity for this report. The matching and
  rendering in `session_follow.py` provide reference cases for Pi and Claude.
- `sqlite_numbers.dart` and the reference `readonly_sqlite.py` take bounded
  read-only snapshots of the database and committed WAL and query a private
  in-memory image. Reuse that mechanism with purpose-specific bounded reads.
  `agent_status.py` documents session and runtime usage attribution.
- `agent_actions.dart` and the reference `flutter_agent_actions.py` resolve
  lifecycle commands through preview and apply. Add the activity menu item
  alongside those actions and open a read route directly. Read process
  identities through the existing Linux process helpers used by
  `process_group.dart`. Keep OS queries behind the desktop boundary.
- `mcp_tools.dart` is an MCP client for tool discovery. The feedback tool
  needs a local stdio server entry point in Dart. `settings.dart` owns defaults
  and validation. Follow the existing Flutter overlay and theme patterns in
  the app until the named design references can be located.

## A. Session details

Add `[sessions]` to `adapters/agy.toml` with a reader form and a declared
conversation root and filename pattern. Keep SQLite schema and wire decoding
in the reader for that format, with adapter identities and paths in TOML. Dispatch by form with optional text
support per adapter. Match an instance by an open database or a verified
session ID. For file forms, reuse conservative cwd, start-time and sibling
checks from the reference. Ambiguous matches yield unavailable details.

Schema-only inspection of one installed conversation database using
`sqlite3 -readonly` with `immutable=1` found `trajectory_meta` and `steps`.
The latter has primary key `idx`, integer `step_type`, `status`, and
`step_format`, plus BLOBs including `step_payload`, `metadata`,
`task_details`, and `render_info`. Three controlled conversations confirmed protobuf wire payloads in
format 0 for types 14 (request), 15 (answer), and 132 (tool execution). The
tool fixture included a harmless terminal invocation and a separate file
creation. Treat other tool and edit forms as unknown until verified. Implement only verified types and encodings. Verify columns,
bound row and blob sizes and decoding work, and return unavailable for
unknown or corrupt schemas. Use a generated fixture with synthetic request,
answers, tools and edited filenames, plus tests for schema drift and WAL.
Never snapshot files outside the adapter's recognized session locations.

Wire details as
`{status, session_id?, request?, answers[], tool_calls[], edited_files[]}`.
Status is `available`, `partial`, or `unavailable`. Requests and answers use
`{at?, text}`. Tools use `{at?, name, status?}`. Edited files use
`{at?, path}`. Bound display text and strip control characters. Omit raw
tool arguments, outputs and file contents. Connect Pi and Claude first
through their declared forms and add supported adapters as formats are
verified. All remaining adapters still receive the process and file evidence.

## B. Self-reported progress

Expose MCP `report_progress(step, done, total, note?)` through a local stdio
entry point that resolves its owning instance from verified process ancestry
or an instance credential issued by Maprisma when launching it. Bind reports
to boot identity, PID and process start ticks. Never accept a target PID from
MCP arguments. Validate bounded strings and integers with
`0 <= done <= total` and `total > 0`. Acknowledge valid calls with
`{accepted: true}`. Reject missing or expired instance bindings. The latest
report per live instance is `{step, done, total, note?, at}`. Clear stale
reports after exit. Use private atomic files under the runtime directory
for the handoff, including when the desktop is closed. On reads and writes,
recheck boot and process identity and prune stale reports. Register the
local stdio command through the existing MCP connection flow on user
request. Walk ownership-checked parent identities through wrapper shells.
Ship the server as a mode of the existing compiled Dart core and exercise
it in the bundle gate. Test simultaneous instances, PID reuse, limits
and disabled or expired bindings. Show the latest update in map and follow.

## C. Live activity report

Use a read route taking a known adapter command and an optional verified
instance ID. The agent menu lists live instances when several are running.
The instance menu opens that exact report. A stopped agent gets an explicit
empty state. The report has current work and progress from A and B along
with the following evidence.

- Timeline: bounded mtime scan of the instance's cwd and normalized
  extra roots declared by the adapter (e.g. `--add-dir` in separate or equals
  form). Reject root and home as scan roots. Bound each scan to 4,000 visited
  entries, eight directory levels and a 250 ms elapsed budget, checked between
  filesystem calls. Run scans away from the Flutter UI. Skip hidden credential paths
  and the requested build/cache directories, never descend symlinks, inspect
  metadata only and deduplicate overlapping roots. Restrict observations to
  the identified turn or process lifetime. Group chronological observations
  by an initial five-minute gap and test/edit evidence. Label changed files
  as observed unless a verified session event attributes the edit.
- Helpers and origin: take a same-user process snapshot, verify ancestry
  with start ticks and list executable labels plus elapsed time. Use existing
  terminal/session metadata for titles where a match is verified. Render
  close-window consequences only for evidenced ownership and otherwise
  describe uncertainty. Handle reparenting and detached children.
- Phase: use a completion marker or observed exit for finished, then live
  test helpers or test-file evidence, then edits, then active planning with
  no files. Use unknown when evidence is insufficient. Show possible stuck
  only during work after an initial ten minutes with no new evidence and
  consistently low sampled CPU across the instance and helpers. Use a
  monotonic clock for elapsed thresholds and suppress the hint on a fresh
  sample or an observed running inference.

Show the report in the existing themed overlay style. Esc closes it and
stops refresh. Refresh without overlapping polls, with selection and scroll
preserved. Copy renders the entire current report as localized plain text.
Use the same presentation for 2D and 3D map actions.

## D. Local activity log and reports

Register settings with the existing defaults and validator.

| Key | Type and default | Behavior |
| --- | --- | --- |
| `ai_activity_log` | boolean, false | Enables collection of new observed work |
| `ai_activity_log_days` | integer, 2 | Count local calendar dates including today (proposed range 1–365) |
| `ai_activity_local_topics` | boolean, false | Offer only with a usable local inference endpoint and model |

Collect forward while the Maprisma core is running. Spans already active at
startup begin at first observation unless their original start is verified.
Persist only spans with an observed end. Write completed observed spans as private, versioned JSONL under
`~/.local/share/maprisma/ai-log/`, by local end date. Respect the log toggle
before sampling for history and before appending. Serialize appends and
pruning across writers and deduplicate by stable observed event identity
across retries. Prune only owned date-named log files on startup, day
rollover and retention change, including when logging is disabled. Keep
already retained entries available for review until pruning. Handle
truncated or invalid rows without dropping healthy rows.

An entry contains `{version, id, source_kind, source, model?, project?,
topic?, started_at, ended_at, duration_ms, files[], helpers[], tokens_in?,
tokens_out?, cost?, outcome}`. Source kind is `agent` or `runtime`. Cost
carries amount, currency and accounting kind. Outcome is `completed`,
`failed`, `interrupted` or `unknown` when supported by the observation.
Use project labels and file basenames, discard sensitive names and URLs,
and never persist raw transcripts, environment values, full paths, argument
vectors or arbitrary tool output. Generate topics from allowlisted task
categories and sanitized project/file signals, so literal task text is
discarded. Optional inference receives only this sanitized representation
through an existing local provider and falls back to the heuristic if
unavailable. Revalidate the result before recording it. Record only
attributable usage. Unknown quantities remain null. Keep estimated and
billed amounts distinct, separate currencies, and prevent agent and runtime
views of the same inference from inflating totals. Keep runtime counters
that may include agent traffic visible as separate, non-additive usage.
Include independent runtime usage in combined totals only when its source
proves it is distinct.

Aggregate by agent/runtime, project, day and ISO week, preserving known
subtotals and counts of unavailable values. Provide a review overlay with
date range, topic, source, elapsed time, outcome, totals, copy and explicit
user-selected plain-text or JSON export. CLI and local MCP read the same
sanitized aggregates. Bound detail pages with a cursor and return complete
aggregates for the requested retained range. Test permissions, sanitization, retention at day and
week boundaries, corruption, restart/retry, disabled collection, local
provider fallback, and aggregation with missing data or duplicate sources.

## External runtime coverage

Use existing provider and session observations with explicit unknown values.
An independent external request may be visible only as aggregate runtime
activity. The log scope does not include a client proxy or instrumentation.

## Delivery and verification

Land this plan first and request Antigravity's read-only review. Implement A through D in order. New routes are Dart-only. The existing
parity suite continues to compare shared behavior where a reference exists. For each part affecting the
wire contract, update the manual entries in `routes.json`, regenerate docs
and client, then commit protocol, core and GUI in that order. A protocol commit for a
new route may include the minimal Dart handler needed by the protocol gate. Preserve
compatibility with additive fields and fully type each touched route. Run
`tools/test-changed` before every commit and
`tools/test-changed --base main` before review. Save review rounds and
responses and iterate to CLEAN. All new UI text goes in eight translations
by appending keys, with a chapter in the localized manuals.

Run the protocol checks and applicable differential/parity tests.
Run `MAPRISMA_PUB_OFFLINE=1 tools/flutter-dev check`,
`python3 -m unittest discover -s tests -q`,
`UV_OFFLINE=1 tools/typecheck.sh` and `tools/flutter-dev build`.
Capture light and dark screenshots of both overlays in the preview output
or ignored shots directory. Keep screenshots out of the commits.
