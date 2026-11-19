# 076 Agent history import and reports help

Author: Codex · Reviewer: Antigravity · Branch: task/076-agent-history
(started from `task/075-reports` once 075 is finished). Plan review: rounds 1–3
(CLEAN) in [reviews/076-agent-history.md](../reviews/076-agent-history.md), all
findings taken in below.

## Goal

The log also covers work that agents did while Maprisma was closed or before
the log was switched on: Maprisma collects it from the agents' own history
files. A help symbol on the Reports page explains how the reporting works.

## Decisions (Uwe, 2026-11-19)

- Collecting agent history is an **option, default on**. Most PCs have one
  user, so the request text the agent stored is not treated as foreign data.
- The Log tab gets a button **"Collect history"**, with the tooltip "Collect
  activity from outside Maprisma".
- The Reports page header gets a help symbol that opens a "How reporting
  works" dialog.

## Routes

| Route | Kind | Params | Result |
| --- | --- | --- | --- |
| `settings.get`, `settings.update` | read/change | unchanged | new keys `ai_activity_import` (bool, default true), `ai_activity_import_topics` (bool, default true) |
| `activitylog.import` | change | `days?: int` (1..retention, default retention), `auto?: bool` (default false) | `{task}` or `{skipped: "throttled"}`; `tasks.status` ends with `result {sources: [{source, name, sessions, added, updated, skipped, status}], added, updated, skipped}` or `{error, code}` |
| `activitylog.report` | read | unchanged | entries gain `origin: "live" \| "history"`, `session: string?`; superseded rows are left out. New top-level `import_sources: [{source, name, supported}]` from the loaded adapters and enabled add-ons with `[sessions]`, returned even with the log off or no entries (the help dialog lists them) |

- `source` is `agent:<command>`, as in the live log. `name` is the
  adapter's display name.
- Per-source `status`: `ok`, `partial`, `unsupported`, `unavailable`,
  `corrupt`. Agents that are not installed and have no history folder are
  left out.
- Pre-job refusals are `ServiceError`s: `log_off`, `import_off` (switch off;
  the button then offers to switch it on), `import_running`,
  and `invalid_request` for a bad `days`. Refusals during the job (log
  switched off meanwhile, lock taken by another process) are emitted as a
  `type: 'result'` payload `{error, code}`, never as an exception.
- Registration: `import` goes into `CHANGE` in `tools/protocol.py`,
  `activitylog.import` into `rulesExempt` and `portedRoutes`.
- Settings: `settings_schema.py`, then `tools/core-assets.py` to regenerate
  `core_assets.g.dart`, and both keys in `uiSettings` in `settings.dart`.
  Settings › Maprisma shows the two switches too, in step with the Log tab.

## Core

### Log row schema (extends `ai_activity_log.dart`, still version 1)

`_rows()` currently rewrites the id, forces the topic to `editing` or
`testing` and drops unknown fields. A live write would then destroy history
rows. Change it to keep these fields, validated:

- `id`: the live form, or `history:<source>:<session>:<span start µs>`.
- `origin`: `live` by default for old rows, or `history`.
- `session`: `^[A-Za-z0-9._-]{1,64}$`; otherwise the SHA-256 hex of it.
- `superseded_by`: a history id, or null.
- `topic`: `editing`, `testing`, or a free text topic of up to 120 runes,
  re-sanitized on read.

`report()`, the Log tab and 075's generator reader skip rows with
`superseded_by`. `_activityReportWithTopics()` (`core.dart`) leaves rows
alone that already have a free-text topic.

Live spans are filed by their local **start** day from now on, the same as
history. Rows that are already stored stay where they are.

### History extraction layer (new, `history_import.dart`)

A dedicated layer with its own explicit dispatch over the adapters'
`[sessions]` forms. It does **not** call `ClaudeSessions` (which writes
`claude-sessions.json` into the cache) or the last-turn readers. It reuses
only low-level parts: `ScanFiles`, `Posix`, `SqliteNumbers.committedImage`,
the epoch, project-folder and protobuf helpers. All adapters with a
`[sessions]` table are scanned, enabled add-ons included (reloaded like
`_reloadAddons`).

| Form | Reads | Span data |
| --- | --- | --- |
| `claude-files` | `~/.claude/projects/*/*.jsonl`, top level only (no `subagents/`, no `agent-*.jsonl`) | timestamps of user/assistant lines, `cwd`, model, usage per assistant line, `Edit`/`Write` tool targets, first user text per span |
| `codex-jsonl` | `~/.codex/sessions/**/rollout-*.jsonl`, skipping files whose `session_meta.source` is a map (subagents) | `session_meta` cwd and id, turn timestamps, `total_token_usage` as **deltas** per span, `apply_patch` targets, first user text |
| `trajectory-sqlite` | Antigravity conversations | step 0: Codex checks the schema of one real database read-only for timestamp and cwd columns and writes the result into the plan. Without timestamps, one span per conversation uses the file's birth and modification times and is marked `partial` |
| `pi-files` | pi's session files | as for codex-jsonl, as far as the format gives it |
| anything else | — | `unsupported` |

- **Bounds:**
  - only files modified inside the window (`days`), not the readers' fixed
    30 days;
  - at most 2,000 sessions per source;
  - files of 64 MiB or less are read whole. Bigger files get a 64 KiB head
    (metadata) and an 8 MiB tail through `readAt`, with the first partial
    line dropped, and are marked `partial`;
  - SQLite goes through a guarded loader (a missing `libsqlite3.so.0` gives
    `unavailable`) and a typed result (`ok`, `missing`, `corrupt`,
    `unavailable`);
  - 60 s per source and 180 s overall;
  - never write anywhere except `ai-log/`.
- **Spans:** a new span starts after 30 min without a turn. A span whose
  last turn is under 2 min old is still running and is skipped this time.
  A span whose local start day lies before the window (`days`, clamped to
  `ai_activity_log_days`) is dropped. This keeps old spans of a resumed
  session from being written, pruned and written again on every import.
- **Codex tokens on a tail read:** the baseline is the first `token_count`
  in the tail. The cut-off leading span keeps tokens `null` (or its stored
  value) and is never diffed from 0. Only spans that start after a 30-min
  gap inside the tail get deltas.
- **Re-import:** the same id updates an existing history row in place, and
  only when the row grows: a later end, more tokens or more files. A
  tail-read file never adds a row for a span whose start lies before the
  tail; it only updates rows it can match by session and overlap.

### Topic sanitizer (`sanitizeTopic`, only with `ai_activity_import_topics`)

The steps run in this order:
1. Strip C0/C1 control characters and bidi overrides
   (U+202A–U+202E, U+2066–U+2069), and collapse whitespace.
2. Redact URLs with credentials, and query values named `token`, `key`,
   `secret`, `auth`, `sig` or `password`.
3. Redact these and replace them with `…`:
   - PEM blocks, JWTs, `Bearer` and `Basic` credentials;
   - the prefixes `sk-`, `gh[pousr]_`, `github_pat_`, `glpat-`, `AIza`,
     `AKIA`, `ASIA`, `xox[baprs]-`, `hf_`, `npm_`, `pypi-`;
   - `key`, `token`, `secret` and `password` assignments;
   - hex or base64 strings of 32 or more characters;
   - e-mail addresses.
4. Shorten absolute and `~/` paths to their basename.
5. Cut to 120 runes, never splitting a character.

With the option off, the topic stays heuristic. In 075's generator prompt,
imported topics count as untrusted user text inside the "untrusted data"
markers. The generator's log reader checks `ai_activity_import_topics` when
it runs. When it is off, every topic other than `editing` / `testing` is
sent as null, so switching it off stops request text from being sent at
once, including topics imported earlier.

### Writing and locking

- `ai-log/.import.lock`, taken with `tryLockExclusive` for the whole import.
  When it is taken, the result is `import_running`. It never blocks
  `observe()`.
- `ai-log/.lock` is held only for the short read-merge-write of each day
  file, never while agent files are scanned. The importer waits for it with
  a bounded retry. Inside the lock it reads `ai_activity_log` again, and
  reads the day file fresh.
- `observe()`: when its non-blocking lock fails, the finished spans are
  kept in memory and written on the next tick, never dropped.
- Merged day files are sorted by `started_at` before writing (the report
  reads each file in reverse order).
- `observe()` groups its finished spans and any buffered spans by each
  span's local start day. It drops spans before the cutoff, and clears the
  buffer when the log is switched off.
- The 2 MiB cap per day file is checked per entry. New rows that don't fit
  are counted in `skipped` and the source becomes `partial`.
- **Superseding:** a live row of the same source (and the same project when
  both have one) is superseded when its overlap with a committed history
  span is more than half of the **live** row's duration. A zero-length live
  row is superseded when its start lies inside the span. The importer checks
  the start day and the end day of each span, and marks only rows whose
  history entry was actually written.

### Start-up import

The **GUI** triggers it once after the first `app.snapshot`, never the core
constructor, so CLI, MCP, the protocol probe and tests never import. It
sends `auto: true`, and the core checks `ai-log/.import-state.json` (0600,
ignored by pruning and the report). With less than 1 h since the last run,
the result is `{skipped: "throttled"}` and no worker starts. Busy task slots,
an import already running, `log_off` and `import_off` are ignored without a
message or prompt. `.import-state.json` is updated after every completed
import (automatic or manual), never after a refusal. Manual
clicks (`auto: false`) ignore the throttle. Besides this one start-up run
there is no repeating timer.

## UI

- **Reports page, Log tab, settings section** (mirrored in Settings ›
  Maprisma):
  - **"Collect activity from agent history"**, a switch, default on;
  - **"Use the agent's request as topic"**, a switch, default on, disabled
    when the first one is off.
- **Log tab button "Collect history"** (tooltip "Collect activity from
  outside Maprisma"):
  - While an import is running, the button is disabled and shows progress,
    including for a start-up run.
  - Afterwards it shows one line per agent, for example "Claude Code: 14
    sessions, 9 new, 2 updated", plus the not-supported agents.
  - When the log or "Collect activity from agent history" is off, it offers
    to switch it on first.
- The Log tab rows and the TXT export show a free-text topic as it is (like
  `formatActivityLog`), and `editing` / `testing` as translated labels.
- History rows get a small history symbol with the tooltip "From the agent's
  own history".
- **Help symbol (?)** in the Reports page header, tooltip "How reporting
  works (F1)". While `_view == 'reports'`, F1 is taken over and opens the
  same dialog: it doesn't open the global Help page, doesn't trigger 075's
  leave-page guard, and never opens the dialog twice.
- **The dialog:** themed, using the app's corner setting, scrollable, Esc
  closes it, with a copy button and an "Open user manual" button
  (`help.open_manual`). Five short sections:
  1. **The log:** what is recorded while Maprisma runs, and what never is
     (file contents, secrets); where it is stored; how long it is kept.
  2. **Outside Maprisma:** the agents' own history, the button, the two
     switches, and which agents are supported (`import_sources` from
     `activitylog.report`, loaded when the page opens, even with the log off). Request topics are shortened and secrets are removed.
  3. **Topic reports:** range, filters and focus, then Generate. The AI only
     gets log entries, request topics included when that switch is on.
     Local and online helpers, and the online switch in Maprisma Settings ›
     AI.
  4. **Library:** save, search, rename, export; kept until deleted.
  5. **Tips:** for example "Collect first, then generate", or "Use the focus
     line for one project or question".
- Texts in all eight languages. The "Reports" chapter in all eight manuals
  describes the dialog, the button and the switches.

## Acceptance

- **Fixtures:** synthetic sessions per supported form, with requests,
  tools, tokens, an edit, a subagent file, a secret-looking string and a
  session over midnight.
- **Import tests:**
  - spans with the 30-min split and the 2-min still-running skip;
  - Codex token deltas;
  - subagent files excluded;
  - the topic sanitizer, with every pattern above plus a secret that
    crosses character 120 and non-ASCII text;
  - topics off gives the heuristic only;
  - a re-import adds nothing and updates a grown span;
  - a live row survives a history write and the other way round;
  - superseding with short live bursts, zero-length rows and midnight;
  - the 2 MiB cap gives `partial`;
  - a big file is read head plus tail;
  - corrupt, missing and unsupported sources report their status;
  - nothing is written outside `ai-log/`, and no `claude-sessions.json`
    appears.
- **Concurrency tests:** observe and import running at the same time lose
  no live span; a second import gets `import_running`; switching the log off
  during an import writes nothing.
- **Start-up tests:** only the GUI triggers it, it is throttled across a
  restart, and a manual run bypasses the throttle.
- **Topic tests:** with the topics switch off, the generator sends no
  stored free-text topic. The Log tab and the TXT export show free-text
  topics.
- **Help dialog tests:** the source list shows with the log off, Esc closes it, copy includes every section, F1 on
  Reports opens it (only once), and it is shown in all eight languages.
- Branch checks, full suites and build as in AGENTS.md. Screenshots of the
  Log tab with history rows and of the help dialog, light and dark.

## Step 0 schema check (Codex, 2026-11-19)

Inspected one existing Antigravity CLI conversation database using
`sqlite3 -readonly 'file:…/conversations/ead64663-d6a3-47c5-aa00-146aab4cd680.db?immutable=1'`.
Only schema metadata and file metadata were queried.

Tables are trajectory_meta, steps, gen_metadata, executor_metadata,
parent_references, trajectory_metadata_blob and battle_mode_infos.
The steps columns are idx, step_type, status, has_subtrajectory, metadata,
error_details, permissions, task_details, render_info, step_payload and
step_format. No table exposes a timestamp or cwd column. The auxiliary
metadata and payloads are BLOBs whose timestamp/cwd encoding is unverified.
The inspected file has a filesystem birth time and modification time.

Implementation will use the reviewed fallback of one span per conversation,
filesystem birth/modification times, unknown cwd/tokens, and status partial.
Only verified format-0 request and edit protobuf fields will be decoded.
Missing or invalid birth metadata must be reported as partial, with mtime
as the conservative zero-duration fallback.
