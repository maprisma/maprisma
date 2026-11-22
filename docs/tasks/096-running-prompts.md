# 096 Messages to a running project: Send and Send now

Author: Claude · Reviewer: Codex and Antigravity · Branch: task/096-running-prompts

Uwe (2026-11-22): "user must be able for additional prompts, like we are working now". Chosen: a
message box on the running project with **Send** and **Send now**; a live interactive terminal
chat was not chosen. This task is the core and the contract; the GUI follows in a later step.

## Goal
While a project's agents work, the user can add instructions. **Send** waits for the next
assignment while the current agent keeps working; **Send now** stops the agent at work and
continues at once in a new session with the saved handoff plus the message. No message is lost.

## Contract (backend capability `messages`)
The backend lists `messages` among its `@hello` capabilities (`summary2`, `board`, `messages`);
the GUI shows the message box only when it is there. New Project Center operation through
`features.call` (allowed in `feature_routes.dart`):

`message {id, run_id, text, mode?, acknowledge_interrupted?}`, mode `queue` (default) or `now`.
`now` requires `acknowledge_interrupted: true`, the same confirmation Continue asks for ("Continue
from saved handoff?"); `queue` refuses that field as unknown.

- **Allowed** while the run with that `run_id` is active in planning or execution: status
  `planning`, `running` or `reviewing`; `queue` also while `pausing` (it waits for the
  continuation). Planning is included on purpose: steering the lead's plan or a planning
  reviewer is the same need as during execution, and Continue already works for planning.
- **Refused** (checked in this order): `project_message_invalid` (unknown field, also
  `acknowledge_interrupted` with `queue`; mode; not a string; NUL), `project_message_empty` (blank), `project_message_too_long` (over 4096 UTF-8
  bytes), `project_unknown`, `project_not_running` (no active attempt: draft, ready, paused,
  interrupted, failed, completed, awaiting review; and team setup, whose helper only drafts a
  proposal), `project_changed` (`run_id` missing or of another run, so a message never reaches a
  run the user did not see), `project_still_pausing` (`now` while pausing),
  `project_review_changes_first` (`now` without `acknowledge_interrupted: true`, as Continue),
  `project_messages_full` (8 waiting, or the waiting texts together over 16 KiB UTF-8), `project_store_full` (only this message is refused; running
  work goes on and no store fault is set), a store fault as for every other change.
- **Result** `{project, message, continued, reason}`. `message` is the stored entry as it is
  now (null when it was dropped meanwhile). `continued` is true once the new session's first
  agent started; `reason` is null or the code that kept a `now` message from continuing:
  `project_still_pausing` (stop unconfirmed, still pausing), `project_changed` (a competing
  Pause, Continue, run, save, review, setup or delete arrived meanwhile, or the run changed: that
  request decides), `project_message_unknown` (dropped meanwhile), `project_message_delivered`
  (a Continue delivered it meanwhile), `project_not_paused`, `project_center_closed`, a launch
  refusal (`project_plan_not_approved`, `project_folder_busy`, `project_capacity`, ...), or a
  failure before the new session's agent started (`project_agent_unavailable`,
  `project_prompt_too_large`, ...; the project returns to `paused` with `needs_reconciliation`
  and event `continue_failed` instead of `failed`). The message stays queued in all of them; no
  `message_waiting` is written when it was dropped or delivered. A project deleted meanwhile
  answers `project_unknown`.
- **Stored** per project: `messages` [{`id`, `at`, `mode`, `text`, `state` `queued`|`delivered`,
  `run_id`, `delivered_at`?, `delivered_to`? {`phase` planning|execution, `position`, `agent`,
  `role`}}], the last 20 (the oldest delivered ones make room; waiting ones are never dropped).
  Project views (`get`, every mutation) add `messages_queued`; board cards (`list`) carry
  `messages_queued` for a badge. A store from before this task has no `messages` (views show `[]`).
- **Delivery**: waiting messages go, oldest first, into the prompt of the next assignment
  dispatched by any launch (`plan`, `run`, `continue`; not team setup), as a "Messages from the
  user" section after the handoff. They count as delivered only once the supervisor reports that
  the agent's own process started (`{"started": true}` after its spawn succeeded; a failed spawn,
  a withdrawn launch or a lost supervisor answers false); a launch refused, withdrawn or failing
  to spawn keeps them queued. While an agent with them in its prompt is starting they cannot be
  dropped (`project_message_pending`). On delivery each message is
  appended to the handoff ("User message (time), given to role (agent): text"), so later
  assignments and a continuation see it once, as history, not as a new message. A run that ends
  with messages still waiting keeps them for the next launch (carry-over, Uwe 2026-11-22): a
  message queued during planning can so reach execution; the user drops one that no longer fits.
- **Drop**: `message_drop {id, message_id}` removes a message that still waits, in any status
  (also after its run ended, so a carried-over message can be removed). Refused:
  `project_message_unknown`, `project_message_delivered`, `project_message_pending` (in the
  prompt of an agent that is starting; it is delivered there), `project_message_invalid`,
  `project_unknown`, `project_store_full` (only this request, as for `message`). Result
  `{project}`, event `message_dropped`.
- **Prompt size**: all four declared project profiles (claude, codex, agy, pi) pass the prompt as
  one argv word, which Linux limits to MAX_ARG_STRLEN (128 KiB). Bounds: title 200 B, goal
  16 KiB, member instructions 4000 B, plan 48 KiB, handoff 16 KiB (its newest part), waiting
  messages 16 KiB, plus about 1.5 KiB of fixed text: at most about 101 KiB (the largest case in
  the tests, all bounds at once on the measured assignment, is 103,411 bytes). There was no guard before; a prompt over 120 KiB is now refused
  before any launch (`project_prompt_too_large`, the project fails, waiting messages stay
  queued). Profiles with `stdin: true` are not limited.
- **Events**: `message` (sent), `message_delivered` (given to an assignment), `message_dropped`,
  `message_waiting` (a `now` message could not continue, or messages are left when the run
  ended; written only when it fits the store), `continue_failed` (Send now's session failed
  before its agent started).
- **Store check on load**: unique ids, a `run_id` on every message, at most 8 waiting with at
  most 16 KiB of text, `delivered_at`/`delivered_to` exactly on delivered ones (`delivered_to`
  with phase, position 0–7, agent and role), no unknown fields; else `project_store_corrupt`.

## Send now, step by step
1. Validate (including `acknowledge_interrupted: true`) and store the message (`queued`, event `message`). If this write fails nothing else
   happens.
2. The existing pause path with the message's `run_id`: dispatch stops, status `pausing`, owned
   processes are stopped and confirmed; the attempt ends `paused` with its handoff. An
   unconfirmed stop answers `reason: project_still_pausing` (Retry pause stays available).
3. Then, only if the project still exists (else `project_unknown`), the message is still queued,
   no other lifecycle request for the project came meanwhile (a per-project counter grown by
   pause, plan, run, continue, save, review, setup, setup_apply and delete), the run is still the
   message's, the project is `paused` and the controller is not shutting down: the existing
   `continue` path with the current revision and the user's acknowledgement; the prompt keeps the
   usual instruction to inspect actual files and not repeat uncertain side effects.
4. Send now waits until the new session's first agent started (or failed before). The
   interrupted assignment receives the handoff plus the message, which is then delivered. Any
   failure in 2 to 4 leaves the message queued and records `message_waiting`; a later Continue
   delivers it.

## UI (later GUI step, not in this task)
On a running project (page and card when `messages` is offered): a multi-line message box with
**Send** (tooltip: the next agent gets it; the current one keeps working) and **Send now**
(tooltip: stops the agent at work and continues at once with your message), which first asks the
same "Continue from saved handoff?" question as Continue. Off when the project is not running or the box is empty; Send now
also off while pausing. Waiting messages listed with their time and state, delivered ones with
the agent they went to; a waiting one has a remove symbol (`message_drop`), also after the run
ended; a card badge from `messages_queued`. A refusal or a `reason` keeps its
text on the page. Texts in 8 languages; a manual paragraph in the Running section.

## Protocol
No new route; `routes.json`'s `features.call` note names the operation, its errors and fields.
Protocol version stays 2 (additive).

## Acceptance
`ai_project_center_test.dart`, group "messages to a running project (task 096)": queue while
running (current agent untouched, card count, next assignment's prompt contains it exactly once,
`delivered_to`, handoff, later assignment sees it only in the handoff); refusals (not running,
ended, another or no run_id, empty, too long, invalid mode/field, unknown project, queue full);
team setup refused; while pausing queue accepted and now refused; Send now pauses then continues
with handoff and message, event order; Send now whose continuation fails keeps it queued and the
project paused, delivered after the fix; a launch that never started keeps it queued; restart
keeps queued and delivered state; planning delivery; an oversize store refuses only the message;
Send now without the acknowledgement refused and `queue` with it refused; drop a waiting message,
drop of a delivered or unknown one refused, drop after the run ended; the 16 KiB total; the
largest prompt below 128 KiB. Round 1: a spawn failing in the real supervisor keeps it queued;
drop refused while its agent starts; a Pause during Send now wins; a drop during Send now leaves
no false note; Send now whose session fails before start returns to paused; Send now with an
unconfirmed stop; the 20-message eviction; `project_prompt_too_large` and the stdin exemption;
malformed stored messages refused. `project_supervisor_test.dart`: `started` true only after the
spawn. A deletion between the stop and Send now's resumption cannot be interleaved from a test
(no event-loop turn between them); its guards are by inspection.
`feature_plugins_test.dart`: `messages` capability, `message` and `message_drop` through the real
worker.
`tests/test_protocol.py`. Codex and agy CLEAN.

## Core review round 2 corrections

Both review files were read in full and every finding was reproduced in the core;
none was skipped.

- **Send now recovery before execution:** the continuation receives its immutable
  `sendNow` flag at attempt creation, before `_execute` runs. Send now retains that
  attempt and awaits its own startup future even if synchronous checks already
  removed it from `_active`. Prompt-limit and dispatch-authorization refusals keep
  their original codes, queued messages and the paused / `continue_failed` checkpoint.
- **Failure completion after cleanup:** successful startup still answers immediately.
  A failed or withdrawn startup answers only after the final stop (bounded to six
  seconds) and removal or retention of the attempt. Unconfirmed cleanup returns
  `project_still_pausing` with status `pausing`. Delayed and refused cleanup, including
  concurrent shutdown, have regression coverage; immediate Continue works after a
  confirmed failed startup.
- **Optional end-of-run note:** save the essential checkpoint and finished event
  first, then attempt `message_waiting` with `optional: true`. A boundary test leaves
  space for the checkpoint but not the note, while another project keeps running;
  the messages remain durable and no store fault is latched.
- **Supervisor startup compatibility and deadline:** `locked` now advertises
  `start_ack: true`. A supervisor without that capability is refused before `launch`
  with the existing `project_agent_unavailable`; no delivery is guessed and a queued
  message remains available. `out`, `leader`, `stuck` and `exit` also prove successful
  spawn if the explicit `started` frame is omitted. The lock handshake is bounded
  to five seconds. Waiting for agent startup has a ten-second budget including the
  handshake; final cleanup is bounded to six seconds. With the existing pause path
  (at most about twelve seconds), Send now stays within about twenty-eight seconds,
  below the worker's 30-second shutdown and 45-second call deadlines.
- **Cancelled launch:** an agent that never started exits the assignment loop on
  cancellation. Its output and exit result are not consumed and no fictitious
  assignment result enters the handoff.
- **Lifecycle arbitration:** successful lifecycle mutations advance their counter
  after their guards and durable write; Pause advances after its active/run guards.
  Send now's own internal pause does not compete with itself. Rejected stale calls
  leave a waiting Send now alone. Shutdown and detach invalidate every active
  project's token before stopping work, including when shutdown later fails;
  deletion removes its counter entry.

GUI impact: no new public fields, codes or protocol version. Synchronous startup
refusals now report their actual code with the promised paused checkpoint; cleanup
failures report `project_still_pausing` / `pausing` before returning. Optional
`message_waiting` may be absent at the store boundary and follows `finished` when
present. Older supervisors fail cleanly before launch; stalled startup is bounded.

Validation (2026-11-22, round 2 fixes):

- All 26 added regression cases fail against the original `HEAD` core and pass
  with these fixes (the cleanup/startup deadline cases included).
- Requested `dart format lib test` and `dart analyze`: passed, no analyzer issues.
- Requested three-file Dart run (`ai_project_center_test.dart`,
  `feature_plugins_test.dart`, `project_supervisor_test.dart`): **211 passed,
  5 failed**. Every failure is in the unchanged feature-plugin suite and was
  reproduced with the original `HEAD` core: linked-data update size checking;
  signed API-1 update; signed API-2 update; manifest/@hello API mismatch (these
  four surface `feature_signature_invalid` in this sandbox); real-worker discovery
  generation (`invalid_request`). No project-center or supervisor test failed.
- `python3 -m unittest tests.test_protocol`: all 8 passed.
- `git diff --check`: passed. `tools/test-changed --list` inspected; validation
  narrowed to the user-requested core files and protocol test.
- The supplied headless environment was used. The Flutter `dart` wrapper tried
  writing its read-only SDK cache, so Dart commands used
  `/mnt/Data/flutter/bin/cache/dart-sdk/bin/dart` directly.

No routes.json or generated client changes were needed. Changes stay in the core
package and this task record; nothing was committed or pushed.
