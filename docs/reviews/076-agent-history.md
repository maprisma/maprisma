## Round 1 (Antigravity, 2026-11-19, plan draft)

1. **High** `docs/tasks/076-agent-history.md:27, 48-66, 75-84` vs `packages/maprisma_core/lib/src/ai_activity_log.dart:141-149, 173-226, 255-289` & `core.dart:5318-5384` — Existing `AiActivityLog` row normalization, live rewrites, and local-topic enrichment silently destroy imported history entries, free-text topics, and `superseded_by` markers.
   - **What goes wrong and when:**
     - `AiActivityLog._rows()` (`ai_activity_log.dart:197-221`) unconditionally overwrites `'id'` with `'$kind:$source:${started.microsecondsSinceEpoch}'` (`:199`), coerces `'topic'` to `{'editing', 'testing'}.contains(row['topic']) ? row['topic'] : null` (`:204-206`), and drops all unknown fields (`origin`, `session`, `superseded_by`).
     - Because live `observe()` rewrites today's day file through `_rows(previous)` (`ai_activity_log.dart:141-149`), the very next live span completing on the same day **erases every imported history `id`, `topic`, `origin`, `session`, and every live `superseded_by`** in that file, breaking re-import idempotence and totals.
     - `AiActivityLog.report()` (`:255-289`) counts every row returned by `_rows()` into totals and `entries` without checking `superseded_by`. The plan also does not state whether superseded live entries are omitted from `activitylog.report`'s `entries` (and from task 075's `reports.generate` bounded log reader) or returned with `superseded_by`.
     - `_activityReportWithTopics()` (`core.dart:5318-5384`) sends `row['topic']` as `'heuristic'` to the local LLM and overwrites `row['topic']` with `'editing'`/`'testing'`, clobbering imported request topics and feeding raw topic text into the classifier.
     - `ai_activity_log.dart:148-149` skips `atomicWrite` silently if `body.length > _maxFile` (2 MiB); a large history import for one day would drop the entire day's write with no `partial` status or `skipped` count.
   - **Fix:** Extend the v1 row schema and `_rows()` to preserve validated `id` (accepting both live ids and `history:<source>:<session>:<start>`), `origin` (`"live"` default for legacy rows, or `"history"`), sanitized nullable `session`, nullable `superseded_by`, and sanitized free-text `topic` (up to 120 runes). Filter `superseded_by != null` out of totals, `entries`, and task 075's bounded generator read (so neither the Log tab nor AI topic reports double-count or show duplicates). Skip rows that already have a non-heuristic topic in `_activityReportWithTopics()`. Enforce the 2 MiB per-day file cap per entry during merge: keep existing records, append new history entries while `<= 2 MiB`, count overflow entries in `skipped`, and mark the source `partial`.

2. **High** `docs/tasks/076-agent-history.md:37-74, 131` vs `claude_sessions.dart`, `jsonl_session_activity.dart`, `trajectory_activity.dart`, `session_readers.dart`, `sqlite_numbers.dart`, `posix_ffi.dart:494-508`, `adapters/*.toml` — Existing readers cannot supply multi-span history, topics, verified edits, bounded `> 64 MiB` tails, or `corrupt`/`unavailable` status, and `ClaudeSessions` writes outside `ai-log/`.
   - **What goes wrong and when:**
     - **`claude_sessions.dart` (`claude-files`):** Only parses `"assistant"` and `"cost-state"` lines (`:213, 220-235`); it never reads `"user"` requests, tool calls, or edits, merges all turns into one `NumericSession` (no 30-min idle span split), ignores the day window (reads up to `maxBytes = 2 GiB`, `:19`), and **writes `cacheDir/claude-sessions.json` (`:441`, `session_readers.dart:672`)**, directly violating Acceptance (`076-agent-history.md:131`: "no writes outside `ai-log/`").
     - **`jsonl_session_activity.dart` (`codex-jsonl`, also used for `claude-files`/`pi-files` via `live_session_activity.dart:159`):** Clears `answers`, `tools`, `calls`, `patches`, and `edits` on every `user` message (`:113-119`), so it returns only the **last single turn**, never full-session spans. It does not extract `cwd`, `model`, or token usage, and for non-rollout files (`claude-files`/`pi-files`) it never extracts verified `edited_files` (`:124-130`).
     - **`trajectory_activity.dart` (`trajectory-sqlite`, `adapters/agy.toml:23-24`):** Queries only the last turn (`WHERE idx >= (SELECT COALESCE(MAX(idx), 0) FROM steps WHERE step_type = 14) ... LIMIT 64`, `:13-21`), returns `at: null` for every item (`:36, 39, 48, 54`), and extracts **no timestamps, no `cwd`, no `model`, and no tokens**. As written, it cannot produce span start/end, duration, 30-min idle splits, or live-overlap dedup.
     - **`session_readers.dart` & `posix_ffi.dart` bounds:** `SessionReaders.matching()` (`session_readers.dart:175-183`) hardcodes a 30-day cutoff instead of the requested `days` (up to 365); `fileSessions()` (`:420`) calls `files.bytes(..., limit: 64 MiB)` which returns `null` on files `> 64 MiB` (`posix_ffi.dart:530`); and `posix_ffi.dart:494-508` (`readSuffix`, used by `portion: 'tail'`) **hard-caps `limit` at 8 MiB** (`limit > 8 * 1024 * 1024` throws), so passing a `64 MiB` tail limit silently returns `null`. Moreover, reading only the tail of a `> 64 MiB` Codex/Pi JSONL drops line 1 (`session_meta`/`session`) where `cwd` and `session_id` live, and Codex `info.total_token_usage` (`session_readers.dart:235`) is cumulative across the session (requiring per-span deltas rather than raw totals).
     - **`sqlite_numbers.dart:94, 290-294, 310-311`:** `DynamicLibrary.open('libsqlite3.so.0')` is unguarded (throws `ArgumentError` if absent), and `snapshot()`/`select()` collapse missing files, corrupt DB/WAL, foreign UID, `> 512 MiB`, and query timeouts into `null`/`[]`, making it impossible to separate `corrupt`, `unavailable`, and empty.
     - **Adapter selection (`adapters/*.toml`):** The plan mixes `[sessions].reader` (`claude-files`) with `[sessions].activity_reader` (`codex-jsonl`, `trajectory-sqlite`) and leaves unspecified how `[sessions]` adapters (`codex.toml` has both `reader = "codex-files"` and `activity_reader = "codex-jsonl"`; `dsh-files`, `gemini-files`, `goose-db`, `crush-db`, `openclaw-db`, `omp-db`, `hermes`/`opencode` `hook = true`, plus enabled add-on adapters reloaded via `_reloadAddons` in `plan_worker.dart:1595`) are classified as supported vs `unsupported` vs skipped when not installed.
   - **Fix:** Specify a dedicated history-extraction layer (reusing low-level utilities: `ScanFiles`, `Posix`, `SqliteNumbers.committedImage`, `epoch`, `projectFolder`, protobuf `_field`, and `patchHeader`) with an explicit `[sessions]` dispatch table (no writes to `claude-sessions.json` or any agent folder). For `> 64 MiB` JSONL files, read a small bounded head (e.g. 64 KiB) for session metadata (`cwd`/`session_id`) plus a bounded tail via `posix.readAt` (e.g. 8 MiB, dropping the first partial line and marking the source `partial`), and compute Codex token deltas per span from `total_token_usage`. Verify what timestamp/cwd columns exist in Antigravity's trajectory SQLite schema and specify the exact query (or document its exact fallback/partial behavior if timestamps/cwd are absent). Add a guarded `libsqlite3.so.0` loader and typed read result (`ok | missing | corrupt | unavailable`) to `SqliteNumbers`. Define which adapters are scanned (all enabled adapters with `[sessions]`, reloading add-ons via `_reloadAddons(settingsPath)`, and whether uninstalled agents with no history directory are omitted or `unavailable`).

3. **High** `docs/tasks/076-agent-history.md:81-84` vs `ai_activity_log.dart:57-60, 117-155`, `read_service.dart:117-166`, `posix_ffi.dart:856-861` — Concurrency race with live `observe()` silently drops completed live spans.
   - **What goes wrong and when:**
     - `AiActivityLog.observe()` removes finished spans from `_active` (`ai_activity_log.dart:59`) **before** acquiring `ai-log/.lock` with **non-blocking** `_flock(lock, 6)` (`LOCK_EX | LOCK_NB`, `:124`). Whenever `observe()` hits lock contention, it returns immediately and **permanently discards those live spans**.
     - If the import worker holds `ai-log/.lock` across scanning (up to 60 s per source) or even briefly during day-file merges, concurrent `map.snapshot` ticks (`read_service.dart:136, 151, 157`) silently lose live activity. Conversely, if the importer also uses non-blocking `flock(6)`, a concurrent `observe()` causes the importer to drop its writes.
     - `observe()` re-checks `ai_activity_log` inside the lock (`:138`) before writing; the plan does not require the importer worker to re-check `ai_activity_log` (and `ai_activity_import` for auto-imports) inside the lock after scanning, so turning the log off mid-import can still write stale entries.
   - **Fix:** Split locking into two files inside `ai-log/`: (1) `ai-log/.import.lock` held with `Posix.tryLockExclusive` for the whole import worker lifetime to prevent concurrent imports across processes (returning `import_running` when contended) without ever blocking `observe()`; (2) `ai-log/.lock` held **only during the short read-merge-write commit phase** (never while scanning agent files), acquired by the importer with blocking `Posix.lockExclusive` (or bounded retry). In `observe()`, either buffer failed-to-lock `completed` spans to flush on the next tick or retry briefly so lock contention never drops a live span. Inside `ai-log/.lock`, re-read `settings.json` to verify `ai_activity_log == true` before writing, and re-read each target day file before merging/superseding.

4. **High** `docs/tasks/076-agent-history.md:21-33, 95-97` vs `protocol/routes.json`, `tools/protocol.py:41-43, 218-219`, `action_rules.dart:385-411`, `settings_schema.py`, `settings.dart:10-53`, `core_tasks.dart:177-182`, `plan_worker.dart:1517-1519` — Protocol contract, worker error propagation, `kind`/rules registration, and settings wiring gaps.
   - **What goes wrong and when:**
     - **Route `kind` and `rulesExempt`:** `activitylog.import` writes `ai-log/*.jsonl` and updates `superseded_by` on existing live rows, which violates `tools/protocol.py:218-219` ("**read** changes nothing; **change** changes files or state"). If made `kind: "change"`, `tools/protocol.py:41-43` (`CHANGE`) must include `import` (so `tools/protocol.py update` does not revert it to `read`) and `action_rules.dart:385-411` (`rulesExempt`) must include `'activitylog.import'` (otherwise `action_rules_test.dart:233-245` fails).
     - **Untyped/lost worker errors:** `plan_worker.dart:1517-1519` converts any thrown worker exception into `{'type': 'error', 'code': 'operation_failed'}`, which `core_tasks.dart:177-182` turns into `state: 'failed'` with empty `result: {}`. The plan does not separate synchronous pre-job `ServiceError` refusals (`log_off`, `import_off`, `import_running`, `invalid_request` for out-of-range/non-int `days`) from worker-emitted `{'type': 'result', 'result': {'error': ..., 'code': ...}}` (needed if `ai_activity_log` is turned off mid-job or `.import.lock` is held by another process).
     - **Settings wiring incomplete:** Adding `ai_activity_import` and `ai_activity_import_topics` requires updating `settings_schema.py`, regenerating `packages/maprisma_core/lib/src/core_assets.g.dart` via `tools/core-assets.py` (checked by `tests/test_protocol.py:21-27`), and adding both keys to `uiSettings` in `packages/maprisma_core/lib/src/settings.dart:10-53` (otherwise `settings.get` omits them and `settings.update` throws `Unknown settings`). It is also unspecified whether `flutter_app/lib/settings_view.dart:962-997` mirrors these two switches to stay in step with Reports › Log tab (as 075 did for the existing log settings).
     - **Result & UI state ambiguities:** `sources[]` (`{source, sessions, added, skipped, status}`) does not specify whether `source` is `"claude"` or `"agent:claude"` and omits a display `name` (required for `"Claude Code: 14 sessions, 9 new"` at line 96, including add-on agents). `activitylog.report` needs explicit `routes.json` shapes (`"origin": "string"`, `"session": "string|null"`). And line 95-97 defines UI behavior for `log_off`, but not for `import_off` (when `ai_activity_log` is on and `ai_activity_import` is off) or `import_running` (e.g., if a startup import is already in flight when the user opens Reports).
   - **Fix:** Declare `activitylog.import` as `kind: "change"` (updating `CHANGE` in `tools/protocol.py`, `rulesExempt` in `action_rules.dart`, `portedRoutes` in `core.dart`, and `routes.json` with `optional: ["days"]`, `result: {"task": "string"}`, `source: "manual"`), or explicitly justify `read` if kept. Specify synchronous `ServiceError` for pre-job `log_off`/`import_off`/`import_running` and `FormatException` (`invalid_request`) for invalid `days` (`< 1` or `> ai_activity_log_days`), plus worker `type: "result"` `{error, code}` for mid-job refusals. Include `name: "string"` (and document `source` as `"agent:<command>"` or `<command>`) in `sources[]`. List `settings_schema.py`, `tools/core-assets.py` -> `core_assets.g.dart`, and `settings.dart` `uiSettings` explicitly, and specify manual-button handling when `ai_activity_import` is off (disable or offer to switch on) and when an import is already running (show running progress / disable button).

5. **High** `docs/tasks/076-agent-history.md:48-56, 75-84` vs `ai_activity_log.dart:88, 141` & `read_service.dart:124-133` — Dedup and `superseded_by` fail across midnight, on multi-burst live sessions, on still-active sessions, and on subagent transcripts.
   - **What goes wrong and when:**
     - **Midnight boundary mismatch:** Live `observe()` files spans by **local end day** (`ai_activity_log.dart:141`), while 076 files history spans by **local start day** (`:81-82`). A session running 23:45–00:15 stores its live row in `day+1.jsonl` and its history row in `day.jsonl`; per-day dedup misses the live row and double-counts it. (And if `day.jsonl` hits the 2 MiB cap and skips writing the history entry, a live entry on `day+1.jsonl` must not be marked `superseded_by` an unwritten id.)
     - **Ambiguous "more than half" denominator:** A 25-minute history span typically covers multiple short 2–4 minute working bursts recorded by live `observe()`. Comparing `overlap > 0.5 * history_duration` fails to supersede any of those live bursts, causing systematic double counting; zero-duration live spans also risk divide-by-zero.
     - **In-progress sessions frozen as partial forever:** If a startup import runs mid-span (e.g. 10:00–10:05), it writes `history:<source>:<session>:<10:00>` with partial duration, tokens, and files. Because line 76 says "Importing again adds nothing new", later imports never update that span once it finishes at 10:20.
     - **Tail-read id drift & subagent collisions:** When a session file grows past 64 MiB and switches to tail-only reading, the first visible span's `<span start>` shifts, generating a duplicate id. In addition, Claude Code's `subagents/agent-*.jsonl` files share the parent's `sessionId` (`claude_sessions.dart:455-469`), and Codex subagent rollouts carry `meta['source'] is Map` (`live_session_activity.dart:127`); scanning them as top-level sessions collides on ids or replaces the user's topic with a subagent prompt.
     - **`session` id hygiene:** Unsanitized `session` ids containing `:`, `/`, or whitespace can break the `history:<source>:<session>:<span start>` delimiter or leak path fragments (cf. `ai_activity_log_test.dart:73`).
   - **Fix:** Check both the span's local start day and end day (and `start_day + 1` when a span crosses midnight, or align `observe()` to file by local start day too) when marking `superseded_by`, and only write `superseded_by` for history entries that were actually committed within the 2 MiB cap. Define overlap explicitly against the **live** entry: `overlap_ms > live_duration_ms / 2` (or `live_duration_ms == 0` with `live_start` inside `[hist_start, hist_end]`), matching same `source` (and compatible `project` when both are non-null). For still-active sessions, either skip spans modified within a short grace window (e.g. 2 min) or allow monotonic in-place updates of an existing `history:...` row when `ended_at`, tokens, or verified files grow. Exclude subagent transcripts (`agent-*.jsonl` / `subagents/` and Codex `meta['source'] is Map`) from top-level span creation (optionally rolling up tokens if desired). Hash `session` with SHA-256 hex whenever it exceeds 64 chars **or** fails `^[A-Za-z0-9._-]{1,64}$`.

6. **High** `docs/tasks/076-agent-history.md:57-66` vs `ai_activity_log.dart:158-168`, `activity_readers.dart:14-25`, `trajectory_activity.dart:87`, `docs/plan-reports.md:67-73` — Topic secret stripping cites an incompatible sanitizer, truncates in the wrong order, and misses common secret shapes and downstream prompt-injection boundaries.
   - **What goes wrong and when:**
     - **"`The existing sanitizer applies`" breaks all natural-language topics:** `AiActivityLog._label()` (`ai_activity_log.dart:158-168`) requires `^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$` and returns `null` for any string with spaces, punctuation, non-ASCII characters (DE/FR/ES/PL/PT), or length > 64. Meanwhile `metaText()` (`activity_readers.dart:14-25`) does not strip Unicode bidi overrides (`\u202a-\u202e\u2066-\u2069`, handled in `trajectory_activity.dart:87`).
     - **Truncating before redacting leaks secret prefixes:** Cutting to 120 characters first splits tokens/JWTs/emails/credential-URLs crossing character 120 so regexes no longer match, leaking the secret's prefix into the log. Using Dart `.substring(0, 120)` also splits UTF-16 surrogate pairs.
     - **Incomplete secret patterns:** Listing only `sk-`, generic words, emails, and URLs with credentials misses common developer-prompt secrets: `gh[pousr]_`, `github_pat_`, `glpat-`, `AIza`, `AKIA`/`ASIA`, `xox[baprs]-`, `hf_`, `npm_`, `pypi-`, `Bearer <token>`, `Basic <b64>`, JWTs (`eyJ...`), PEM headers (`-----BEGIN ... PRIVATE KEY-----`), URL query secrets (`?token=`/`?key=`/`?sig=`), `KEY=value`/`password: ...` assignments, and long high-entropy hex/base64 blobs (`>= 32` chars).
     - **Downstream exposure in task 075:** `docs/plan-reports.md:67-73` assumes log entries carry only heuristic topics (`editing`/`testing`). With 076, 120-char user prompts enter `ai-log/*.jsonl` and will be passed to AI helpers in `reports.generate` (including online helpers when `maprisma.activity_log_online` is on) and to `activity-log-mcp` (`bin/maprisma-core.dart:87-90`).
   - **Fix:** Specify a dedicated `sanitizeTopic(String raw)` pipeline in strict order: (1) strip C0/C1 control chars and bidi overrides (`\u202a-\u202e\u2066-\u2069`) and collapse whitespace; (2) redact credentialed URLs and sensitive URL query params (`token`, `key`, `secret`, `auth`, `sig`, `password`); (3) redact PEM blocks, JWTs, `Bearer`/`Basic` credentials, known provider token prefixes (`sk-`, `gh[pousr]_`, `github_pat_`, `glpat-`, `AIza`, `AKIA`/`ASIA`, `xox[baprs]-`, `hf_`, `npm_`, `pypi-`), `key`/`token`/`secret`/`password` assignments, long hex/base64 blobs (`>= 32` chars), and email addresses with `…`; (4) shorten absolute paths (`/...`, `~/...`) to basenames without mangling already-processed URLs; (5) cut to 120 runes (`String.fromCharCodes(text.runes.take(120))`). Re-enforce control/length bounds in `_rows()` on read, and note in 075's report prompt (and section 3 of the help dialog) that imported topics are untrusted user-request text when `ai_activity_import_topics` is enabled.

7. **Medium** `docs/tasks/076-agent-history.md:29-30, 85-87, 131-132` vs `bin/maprisma-core.dart:42, 69` & `core_tasks.dart:85-86` — Start-up import trigger ownership, cross-restart throttling, and `CoreTasks` slot contention are underspecified.
   - **What goes wrong and when:**
     - **Trigger ownership:** If `CoreService` schedules the start-up import in its constructor, short-lived CLI/MCP processes (`bin/maprisma-core.dart:42, 69`), `tools/protocol.py` (`route_probe.dart`), and tests will spawn background workers or write to `ai-log/`.
     - **Throttle vs manual runs & restarts:** `activitylog.import` has no `auto?: bool` parameter, so the core cannot distinguish a 1-hour-throttled start-up run from an explicit user click on "Collect activity from outside Maprisma". Keeping the 1-hour timestamp only in memory breaks throttling across restarts (common in Omarchy popup mode), while storing it outside `ai-log/` violates Acceptance (`:131`, "no writes outside `ai-log/`").
     - **`CoreTasks` 4-task limit (`core_tasks.dart:85-86`):** Startup already launches background jobs (`setup.detect`, `updates.check`, `found.scan`, `costs.rate`). Unchecked `tasks.start` fails with `Too many active operations`, and a multi-source import (60 s budget *per source*) can hold 1 of the 4 global slots for several minutes.
     - **Internal contradiction:** Line 29-30 says "It is started on purpose, not on a timer", while line 85-87 schedules an automatic delayed run after startup.
   - **Fix:** Trigger the delayed start-up import from the Flutter GUI once after initial `app.snapshot` (never in `CoreService` construction), silently ignoring busy-slot / already-running / throttled outcomes. Add `auto?: bool` (default `false`) to `activitylog.import`: when `auto: true`, check a private 0600 timestamp file **inside `ai-log/`** (e.g. `ai-log/.import-state.json`, ignored by pruning and `report()`) and skip without starting a worker if `< 1 h` has elapsed; manual calls (`auto: false`) bypass the throttle. Add an overall wall-clock cap (e.g. 120–180 s in addition to 60 s per source) and align line 29-30 to say "not on a recurring timer; one throttled run after start plus manual runs".

8. **Medium** `docs/tasks/076-agent-history.md:100-118, 133-134` vs `flutter_app/lib/main.dart:5585-5616`, `flutter_app/lib/help_view.dart:4-7, 182-194`, `docs/manual/` — `F1` collides with the global Help shortcut, and the static PDF manual cannot link to an in-app Flutter dialog.
   - **What goes wrong and when:**
     - **Global `F1` shortcut collision (`main.dart:5585-5616`):** `MaterialApp.shortcuts` binds `LogicalKeyboardKey.f1` to `_HelpIntent`, which calls `_openHelp()` and navigates away to the global Help page (also colliding with task 075's page-exit cancel guard while a report is generating). Without intercepting `_HelpIntent` when `_view == 'reports'` (and guarding against double-opening when the dialog is already shown), `F1` on Reports opens the wrong view.
     - **Impossible manual hyperlink (`076-agent-history.md:116-117`):** Maprisma's user manual (`docs/manual/manual*.html`) is built into a static PDF opened in an external viewer (`xdg-open` via `help.open_manual`, `help_view.dart:4-7, 182-194`); it cannot hyperlink to an in-app Flutter dialog.
     - **Dialog layout & copy:** The 5-section dialog needs a `SingleChildScrollView` and the app's configured `corners` radius (for Omarchy popup window sizes), a tooltip distinguishing the page `?` (`"How reporting works (F1)"`) from the top bar's `"Help (F1)"`, and accurate section 1/2/3 text (matching the actual supported `[sessions]` adapters and noting sanitized request topics when `ai_activity_import_topics` is on).
   - **Fix:** Override `_HelpIntent` while `_view == 'reports'` so `F1` opens (and does not duplicate) the "How reporting works" dialog without triggering task 075's leave-page cancel prompt. Reword line 116-117 so the "Reports" manual chapter in all 8 `docs/manual/manual*.html` files *describes* the `?` / `F1` dialog, and optionally give the dialog an "Open user manual" button calling `help.open_manual`. Make the dialog scrollable, themed with the app's `corners` setting, and aligned with the actual supported adapters and topic privacy behavior.

### Answers (Claude, 2026-11-19)

I checked findings 1, 3 and 5 in the code: `_rows()` rewrites id and topic, `observe()` uses `flock(6)` and files rows by end day. All 8 findings are **accepted** and taken into the task text:

1. Row schema extended (id, origin, session, superseded_by, free-text topic). Superseded rows are left out of the report and the generator. Topics from the history are kept. The 2 MiB cap is checked per entry.
2. New history layer with its own dispatch. No ClaudeSessions or last-turn readers. Head plus tail for big files, Codex token deltas, a step-0 check of the agy schema, a typed SQLite result.
3. Two locks (import lock and a short commit lock). observe() keeps spans when the lock is taken. The log setting is read again inside the lock.
4. The route is kind change and registered. Error codes are split into pre-job and in-job. `name` is in sources. Settings wiring and the mirror in Settings.
5. Superseding is measured against the live duration and checks both days. Live rows are filed by start day. Still-running spans are skipped. Re-import updates grown spans. Subagents are excluded. Session ids are hashed.
6. sanitizeTopic with a fixed order and the full pattern list; it cuts by rune. Imported topics count as untrusted in 075.
7. The GUI triggers the start-up run with `auto`, throttled through `.import-state.json`, 180 s overall.
8. F1 is taken over on Reports. The manual describes the dialog instead of linking to it. Scrollable, corners, Open-manual button.

## Round 2 (Antigravity, 2026-11-19, plan draft)

All 8 Round 1 findings are addressed in the revised plan; 6 new/remaining gaps need fixing before implementation:

1. **Medium** `docs/tasks/076-agent-history.md:82, 88-104` vs `packages/maprisma_core/lib/src/ai_activity_log.dart:125-136, 280` — Missing span-level `days`/retention cutoff, Codex tail-read token baseline, and day-file chronological sorting.
   - **What goes wrong and when:**
     - **Out-of-window spans re-added and pruned forever:** Line 88 filters only *file mtimes* against `days`, not the individual spans inside those files. When a user resumes a multi-week Claude/Codex/Pi session today, its mtime is within `days`, so the importer extracts old spans from outside `days` / `ai_activity_log_days`, writes `YYYY-MM-DD.jsonl` files older than retention, and counts them in `added`. On the next map tick, `AiActivityLog.observe()` (`ai_activity_log.dart:129-135`) immediately deletes every day file `< cutoff`, causing every subsequent import to re-add and re-delete the same old spans indefinitely.
     - **Codex cumulative token over-counting on `> 64 MiB` tail reads:** Line 82 computes Codex tokens as deltas of cumulative `total_token_usage`, while lines 91–93 skip the middle of `> 64 MiB` files and read only an 8 MiB tail. Diffing the first tail span's `total_token_usage` against `0` attributes the entire session's lifetime tokens to that one span; even when updating an existing row in place (`:103-104`), the inflated total passes the "more tokens" growth check and overwrites the true span delta.
     - **Scrambled Log tab order:** `AiActivityLog.report()` (`ai_activity_log.dart:280`) reads `_rows(text).toList().reversed`, assuming rows inside each day file are sorted chronologically. Appending older history rows to a day file that already holds later live rows puts older spans above newer ones.
   - **Fix:** Drop any extracted span whose local start day is older than the requested `days` window (clamped to `ai_activity_log_days`), and sort merged day-file rows by `started_at` before `atomicWrite`. On Codex tail reads, seed the running `total_token_usage` baseline from the first observed `token_count` event in the tail (leaving the truncated leading span's tokens `null`/unchanged rather than diffing from `0`, or summing `last_token_usage` deltas), and compute `total_token_usage` deltas only for complete spans starting after a 30-min gap inside the tail.

2. **Medium** `docs/tasks/076-agent-history.md:25-35, 184-186` vs `settings_schema.py:155` & `AGENTS.md` — Help dialog Section 2 has no source list before an import completes.
   - **What goes wrong and when:** Section 2 of the Help dialog (`:185-186`) shows *"which agents are supported (from the import's source list)"*, while `AGENTS.md` forbids hardcoding agent names outside `adapters/`. However, `activitylog.import` is the only route returning `sources`, and it does **not** return `sources` when `ai_activity_log` is off (the default in `settings_schema.py:155`), when `ai_activity_import` is off, when the start-up import returns `{skipped: "throttled"}`, or while an import is still running. Opening `?` / `F1` on Reports in any of those normal states has no supported-agent list to display.
   - **Fix:** Expose a lightweight adapter list (e.g. `import_sources: [{source, name, supported}]` computed from loaded adapters and enabled add-ons with `[sessions]`) on a read route already called on Reports open (such as `activitylog.report`, returned even when no entries exist, or `reports.helpers`), document it in `routes.json`, and have Help dialog Section 2 read from it.

3. **Medium** `docs/tasks/076-agent-history.md:106, 123-125, 187-188` vs `docs/plan-reports.md:67-73` — Turning off `ai_activity_import_topics` does not stop previously imported request topics from being sent to AI helpers in topic reports.
   - **What goes wrong and when:** Because `ai_activity_import` and `ai_activity_import_topics` both default to `true`, the first import writes sanitized user-request topics into `ai-log/*.jsonl`. Section 3 of the Help dialog (`:187-188`) promises: *"The AI only gets log entries, request topics included when that switch is on."* Because the plan only checks `ai_activity_import_topics` at import time, disabling the switch before generating a report (especially with an online helper) still sends previously stored free-text topics from `ai-log/*.jsonl` to the AI helper.
   - **Fix:** Have task 075's generator log reader check `ai_activity_import_topics`; when `false`, omit non-heuristic topics (any value other than `'editing'` / `'testing'`, sending `null` instead) so switching it off immediately blocks request text from being sent to AI helpers.

4. **Medium** `docs/tasks/076-agent-history.md:158-174` vs `flutter_app/lib/activity_log_dialog.dart:55-56` & `docs/plan-reports.md:25-26` — Log tab rendering and TXT export silently drop imported free-text topics.
   - **What goes wrong and when:** Task 075 reuses `ActivityLogDialog`'s body (`activity_log_dialog.dart:49-80`) for the Reports page Log tab (`plan-reports.md:25-26`). Lines `55-56` only emit `row['topic']` when it equals `'testing'` or `'editing'`. The 076 UI section adds the history icon (`:173-174`) but omits updating the Log tab row display and TXT export for free-text topics, leaving imported request topics invisible in the UI despite `ai_activity_import_topics` defaulting to `true`.
   - **Fix:** Specify in the UI section (and Acceptance) that the Log tab and its TXT export display any non-empty free-text `row['topic']` alongside the translated `'editing'` / `'testing'` labels (matching `formatActivityLog` in `ai_activity_log.dart:326`).

5. **Low** `docs/tasks/076-agent-history.md:109-110` — Literal Unicode bidi override control characters embedded verbatim in the plan Markdown.
   - **What goes wrong and when:** Line 110 contains raw unescaped `\u202a`, `\u202e`, `\u2066`, and `\u2069` characters inside backticks. Committing those bytes into `docs/tasks/076-agent-history.md` scrambles display in editors/diffs and triggers Trojan Source (CVE-2021-42574) warnings.
   - **Fix:** Replace the literal control characters with ASCII code-point notation (`U+202A–U+202E, U+2066–U+2069`).

6. **Low** `docs/tasks/076-agent-history.md:66-67, 136-137, 149-156, 171-172` vs `packages/maprisma_core/lib/src/ai_activity_log.dart:54, 141` — Start-up auto-run refusal handling and `observe()` multi-day flush edge cases left implicit.
   - **What goes wrong and when:**
     - `ai_activity_log` defaults to `false` (`settings_schema.py:155`). Line 153–154 says busy slots and `import_running` are silently ignored on start-up, but does not exclude `log_off` and `import_off` from the manual button's "offer to switch it on first" prompt (`:171-172`), nor state when `.import-state.json` is written (only on completed runs vs refused ones, and whether manual runs update it).
     - Filing live spans by local **start** day (`:66`) plus buffering spans on lock contention (`:136-137`) means `observe()` can flush spans belonging to different local start days (whereas `ai_activity_log.dart:141` currently writes all `completed` rows into one file for `now`), and turning `ai_activity_log` off (`ai_activity_log.dart:54`) must also clear the pending retry buffer.
   - **Fix:** Clarify that start-up `auto: true` skips (or silently ignores `log_off` / `import_off`) without prompting, that `.import-state.json` is updated on completed imports (both manual and auto, never on refusals), and that `observe()` groups `completed` + buffered spans by each span's local start day (dropping spans `< cutoff` and clearing the buffer when `ai_activity_log` is off).

### Answers (Claude, 2026-11-19)

All 6 **accepted** and taken into the task text:

1. Spans before the window are dropped. Codex tail baseline from the first token_count. Day files sorted by started_at.
2. `import_sources` in `activitylog.report` (also with the log off). The help dialog reads it.
3. The generator checks `ai_activity_import_topics` at run time and sends free-text topics as null when it is off.
4. The Log tab and the TXT export show free-text topics.
5. Bidi characters written as U+ code points.
6. Start-up ignores log_off/import_off without a prompt. .import-state.json is written only after completed runs. observe() groups by start day and clears the buffer.

## Round 3 (Antigravity, 2026-11-19, plan draft)

**CLEAN**

All 6 round-2 findings are resolved in [076-agent-history.md](file:///tmp/claude-1000/-home-uwe/2e56a6b9-b08b-49d5-a964-5c4dcc4ae952/scratchpad/076/docs/tasks/076-agent-history.md) (span-level `days`/retention cutoff, Codex tail-read token baseline, chronological day-file sorting, `import_sources` on `activitylog.report`, runtime `ai_activity_import_topics` filtering in the generator, free-text topics in the Log tab and TXT export, ASCII `U+` bidi notation verified free of control bytes, start-up refusal/state-file rules, and multi-day `observe()` buffer flush/clear), and nothing new blocks implementation.

Optional notes for implementation:
1. **Stale phrasing in the task doc:** Lines 4–5 still mention "round 1", and line 204 says "(from the import's source list below)" instead of `activitylog.report`'s `import_sources` above.
2. **Log-off fetch path for the Help dialog:** If task 075's Log tab skips calling `activitylog.report` while `ai_activity_log` is off, ensure the Reports page or Help dialog still loads `import_sources` from `activitylog.report` when the log is off so Section 2 is populated immediately.

### Answers (Claude, 2026-11-19)

Note 1 fixed (header and wording). Note 2 taken in: the Reports page loads `import_sources` when it opens, also with the log off.

## Code review round 1 — Antigravity

Reviewed read-only with `agy --mode plan --sandbox`. Findings below were
checked against the working tree; no agent history was modified.

1. **HIGH — Unbounded history SQLite reads** (`history_import.dart:55`,
   `reports_sqlite.dart:71`). The guarded image loader did not activate the
   configured progress handler and limits.
   **Answer:** activate `restrictReads(budget)` before returning the database,
   and close the connection if setup fails. A recursive-query regression
   verifies that a five-millisecond budget interrupts excessive work.
2. **HIGH — Topic sanitizer leaks and damaged paths** (`history_topic.dart:16`).
   Prefixed environment assignments and padded base64 escaped redaction;
   ordinary URLs, relative paths and case-sensitive provider prefixes were
   mishandled.
   **Answer:** cover prefixed assignments and padded token boundaries,
   sanitize URL components separately, preserve relative paths, and match
   provider prefixes case-sensitively. Added regressions for these examples.
3. **HIGH — Noncanonical metadata breaks re-import** (`history_import.dart:223`,
   `ai_activity_log.dart:395`). Rejected labels were written and subsequently
   removed on read, causing endless updates.
   **Answer:** use the activity log's canonical label validator before
   storage and normalize each incoming row before comparison. A regression
   checks the raw stored data and an unchanged second import.
4. **HIGH — Tail fragments shrink stored totals and replace metadata**
   (`history_import.dart:494`, `ai_activity_log.dart:395`).
   **Answer:** leading fragments have unknown tokens for every JSONL form;
   merges preserve their original metadata and totals, take the larger
   totals for complete spans, and detect growth in the union of file names.
   Tests cover a real sparse tail fixture and metadata/file-union merges.
5. **MEDIUM — Undecodable trajectory steps and invalid birth timestamps**
   (`history_import.dart:604`, `posix_ffi.dart:148`).
   **Answer:** ignore undecodable individual step text while retaining the
   partial timing span; reject invalid or out-of-range birth timestamps so
   modification time is used. Added a malformed-step fixture regression.
6. **MEDIUM — Modal F1 and unmounted collection dialogs** (`main.dart:5676`,
   `reports_page.dart:131`).
   **Answer:** Reports F1 respects `_keysBlocked`; manual collection checks
   `mounted` before each dialog and after both asynchronous operations.
7. **LOW — Codex context assigned to the previous span**
   (`history_import.dart:430`).
   **Answer:** retain the pending context model and apply it on actual span
   activity. Removed the unreachable duplicate branch; a two-span fixture
   verifies that each model belongs to the correct span.

### Baseline exception

Uwe approved ordered commits with the seven existing Python parity failures
recorded in the 075 review, provided focused checks pass and every additional
failure is investigated. The protocol and initial core/branch checks each ran
1,441 Python tests with exactly four failures and three errors, in
`test_same_add_ons`, `test_same_setup_and_guide`, `test_same_actions`,
`test_same_moves`, `test_same_previews_and_installs`,
`test_same_imports_and_pulls`, and `test_same_removals`.

### Real import and screenshots

A fresh seven-day import of the final code read the actual adapters and
histories, using the normal home only as a read source. Its settings and
output were redirected into `/tmp/maprisma-history-real-UVTEPB/maprisma/ai-log/`.

| Source | Sessions | Added spans | Updated | Skipped | Status |
| --- | ---: | ---: | ---: | ---: | --- |
| Claude Code | 32 | 38 | 0 | 1 | ok |
| Codex | 18 | 17 | 0 | 5 | ok |
| Gemini CLI | 0 | 0 | 0 | 0 | unsupported |
| Pi | 0 | 0 | 0 | 0 | ok (supported, no sessions) |
| Antigravity CLI | 61 | 60 | 0 | 1 | partial |
| Total | 111 | 115 | 0 | 7 | |

Antigravity's inspected schema supplies no verified timestamp or cwd column;
its spans use the documented birth/mtime fallback, with unknown cwd and
usage. These are approximations, not measured active durations. Other loaded
history formats remain explicitly unsupported. The existing
`maprisma.activity_log_online` Maprisma Settings follow-up from 075 remains
outside this task.

Screenshots use synthetic history rows and app themes, without personal
request text. Files stay outside the commits in
`.flutter-previews/task-076-history/`: `log-light.png`, `log-dark.png`,
`help-light.png`, and `help-dark.png`.

## Code review round 2 — Antigravity

1. **HIGH — Further sanitizer URL and assignment edge cases**
   (`history_topic.dart:19`). Fragments, non-HTTP credential URLs, camelCase
   assignments and long tokens following `=` could escape redaction; long
   multi-segment URL paths could be mistaken for a single token.
   **Answer:** sanitize fragments, decoded path segments and query values;
   cover URI schemes generally and reject credentialed URLs; cover prefixed
   camelCase names and hyphenated query names; allow `=` before a token.
   Regressions cover each reported example and preserve ordinary URL paths.
2. **MEDIUM — Partial-span matching and fixtures use different clocks**
   (`ai_activity_log.dart:332`, `history_import.dart:250`, tests).
   **Answer:** pass the import clock into partial-span matching; inject it
   into the generator fixture, and make the actual-worker fixture relative
   to its real execution time. Fixed-date fixture behavior no longer depends
   on the date on which the tests run.
3. **MEDIUM — Full day files repeatedly rewrite and requeue overflow**
   (`ai_activity_log.dart:190`).
   **Answer:** write only when a row was appended. The existing 2 MiB daily
   storage limit remains terminal for overflow entries, distinct from lock
   contention, which still buffers finished spans. A full day no longer
   builds an impossible-to-flush queue or gets rewritten on every tick.
   A regression checks that the file's modification time remains unchanged.
4. **MEDIUM — Reports F1 can stack over Reports' own modal dialogs**
   (`reports_page.dart:120`).
   **Answer:** check that the containing route is current both before and
   after asynchronous source loading. A widget regression invokes help while
   the switch-on dialog is open and verifies that no help dialog is stacked.
5. **LOW — Oversized first JSONL line discards readable tail spans**
   (`history_import.dart:558`).
   **Answer:** an incomplete head on a large file is partial, not corrupt;
   readable resumed Claude/Pi spans are retained. A Codex file whose bounded
   head cannot establish session metadata is conservatively left partial
   without importing it, because its subagent status is unknown. A sparse
   fixture verifies both behaviors.

Additional boundedness check: a 50,000-character hyphenated request exposed
quadratic regex retries (over eight seconds). Token boundaries now prevent
restarting inside the same identifier, and unfinished PEM blocks are removed
in one match. The same fixture takes about 16 ms locally; a 500,000-character
regression covers ordinary identifiers and an unfinished PEM block.

## Code review round 3 — Antigravity

The reviewer confirmed all round-2 fixes, including the sanitizer's bounded
regex behavior, injected clocks, daily-cap handling, modal F1 guards and
oversized-header handling. One finding remained:

1. **HIGH — Query names and nested credentialed URLs bypass redaction**
   (`history_topic.dart:49`). A valueless query such as `?sk-…`, a long token,
   JWT or email used as a query name, or a credentialed URL inside a decoded
   query value or fragment could survive URL protection and reach the log.
   **Answer:** reject the outer URL when a query name changes under the shared
   secret redactor. The redactor also consumes whole nested URI tokens and
   removes credential markers, including percent-encoded `@`, before other
   secret patterns run. This avoids another repeated-scan regex. Extended
   fixtures verify all six concrete examples from the review; all 28 history
   import tests pass, including the long-input performance regression.

Review file/line references identify the snapshot reviewed in each round;
core filenames are under `packages/maprisma_core/lib/src/`, GUI filenames
under `flutter_app/lib/`.

## Code review round 4 — Antigravity

**CLEAN** — no concrete remaining findings. Reviewed read-only on the final
implementation, in order `fa43875` protocol, `d6436e1` core and `87f4633` GUI.
The reviewer confirmed that query names and nested credentialed URLs now go
through the shared redactor, all six round-3 cases have regressions, and the
prior rounds' SQLite, locking, merge, clock, bounds and modal-dialog fixes
remain intact.

The final GUI commit also records this result and the completed verification
counts; its final documentation amendment does not change the reviewed code.

## Final validation

All suites and captures ran headlessly with `DISPLAY` unset. The final
`tools/test-changed --base main` run includes the complete Flutter and Python
suites. Offline package/typecheck flags were set.

- Core: **413 tests passed**, analyzer and formatting clean.
- Flutter: **368 tests passed**, analyzer and formatting clean.
- Differential: **69 cases passed**; AOT release transport passed and refuses
  unported routes without a Python fallback.
- Python: **1,441 tests**, exactly the approved **four failures and three
  errors** listed in the baseline exception above. Compared the failing test
  names with the isolated baseline gate: identical, with no additional
  failures. The full selector stops here, so the typecheck ran separately.
- `UV_OFFLINE=1 tools/typecheck.sh`: **0 errors, 0 warnings, 0 informations**.
- Final development build and `tools/check-bundle.py`: passed, no Python in
  the bundle or app sources.
- Core's final changed-code gate: **413 core + 96 Flutter + 8 Python tests**,
  all passed. Earlier core checks also passed the 21 selected Python checks.
- GUI's changed-code gate: **116 Flutter + 14 Python tests**, all passed.
- Selected Python checks use `PYTHONPATH` pointing to this repository so the
  reference modules can be imported when the launcher runs from `tests/`.
- Screenshot fixture: **1 test passed**, producing all four light/dark
  screenshots outside the commits; all four were inspected visually.

The unrelated `docs/plan-maprisma-experience.md` remains untracked and was not
changed or included. No push, publication, signing or agent-folder writes
were performed by the importer; the real import's output is isolated as
recorded above.

## Code round 1 — Antigravity, verified by Claude

No blockers or majors. The reviewer reported green full suites (413 core,
368 Flutter, 1,441 Python tests and typecheck 0) and the following six items.
File/line references identify the snapshot supplied with this review.

1. **Minor — DST previous-day lookup** (`ai_activity_log.dart:170`).
   Subtracting 24 hours after a 23-hour DST day could skip the previous
   calendar day's history file.
   **Fix:** use `_date(localStart, -1)`. A subprocess regression explicitly
   sets `TZ=Europe/Berlin`, verifies that 29 March 2026 has 23 hours, and
   checks a 30 March 00:15 live span against the preceding day's history.
2. **Minor — Source error status can be downgraded** (`history_import.dart:193`).
   An older partial or unavailable file could mask an earlier corrupt file.
   **Fix:** one helper raises status monotonically through
   `ok < partial < unavailable < corrupt`; unsupported sources stay separate.
   Ordered database fixtures verify corrupt→unavailable→partial and
   unavailable→partial without losing the more severe result.
3. **Minor — Invalid timestamps discard whole sessions** (`history_import.dart:442`).
   Finite but mis-scaled or garbage numeric timestamps could overflow the
   DateTime conversion and discard valid records in the same file.
   **Fix:** bound epochs to nonnegative seconds within the four-digit ISO
   year range before conversion. Skip invalid records and mark the file
   partial; retain neighboring valid records. Regression covers nanoseconds,
   `1e30`, negative values and malformed text.
4. **Minor — Missing history-row widget coverage** (`reports_page_test.dart`).
   **Fix:** mount ActivityLogPane with live editing/testing rows and a history
   row carrying a free-text request topic. Verify all rows, the history icon
   and its tooltip, and copied text containing the topic and translated
   heuristic labels. Copy and TXT continue to share `_text(report)`.
5. **Nit — Unchanged end-day file rewritten** (`ai_activity_log.dart:464`).
   **Fix:** `supersede()` returns whether a marker actually changed. Write
   the end-day file only in that case. Re-import tests preserve its bytes and
   modification time both for a different source and for an already marked
   overlapping live row when the historical span grows.
6. **Nit — Collection confirmation translates twice** (`reports_page.dart:141`).
   **Fix:** pass source keys to `_confirm(title, 'Switch on')`. A widget
   regression uses a non-idempotent translator and verifies the dialog text
   and action label are translated exactly once.

### Code round 1 verification

Antigravity's read-only follow-up on `454187f` (core) and `a1d8815` (GUI)
returned **CLEAN** across all six fixes. No routes, protocol files or UI
strings changed. The final documentation amendment records this result
without changing the reviewed implementation.

- Core changed-code gate: **419 core tests, 96 Flutter tests, 19 Python
  checks**, all passed; formatting and analyzers clean.
- GUI changed-code gate: **89 Flutter tests and 8 Python checks**, all passed.
- Focused regressions: **34 history-import tests and 9 Reports widget tests**,
  all passed.
- Typecheck: **0 errors, 0 warnings, 0 informations**.
- The documented `python3 -m unittest discover -s tests -q` command in the
  default shell: **1,441 tests, OK (52 skipped)**. Native Dart is absent from
  that shell's PATH, so the native-Dart parity cases are skipped.
- With `/mnt/Data/flutter/bin` on PATH, those parity cases run. Before these
  fixes, that run still reproduced the **same seven historical failures**
  listed above (four failures, three errors). The SDK-enabled branch gate
  exercises those cases too; its final result is recorded below. A green
  SDK-free Python run should not be confused with native-Dart parity passing.

Final `tools/test-changed --base main` result (SDK enabled, headless):
**419 core + 370 Flutter tests and 69 differential cases passed**, as did
formatting, analyzers and AOT release transport. Python ran **1,441 tests**
with the same **four failures and three errors** as the pre-fix SDK-enabled
run; compared all seven failing names, with no additions or changes. These
remain covered by the earlier approved baseline exception. The selector
stops before typecheck on that failure, so typecheck was run separately and
passed with zero errors, warnings or informations. The documented SDK-free
Python command independently passed with its **52 explicit skips**, as
noted above.
