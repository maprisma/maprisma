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
- **Result** `{project, message {id, at, mode, text, state, run_id}, continued, reason}`.
  `continued` is true when `now` started the new session; `reason` is null or the error code that
  kept a `now` message from continuing (`project_still_pausing`, `project_not_paused`,
  `project_plan_not_approved`, `project_folder_busy`, `project_capacity`,
  `project_center_closed`, ...). The project is then as the pause left it (paused, or pausing
  while a stop is unconfirmed) and the message stays queued.
- **Stored** per project: `messages` [{`id`, `at`, `mode`, `text`, `state` `queued`|`delivered`,
  `run_id`, `delivered_at`?, `delivered_to`? {`phase` planning|execution, `position`, `agent`,
  `role`}}], the last 20 (the oldest delivered ones make room; waiting ones are never dropped).
  Project views (`get`, every mutation) add `messages_queued`; board cards (`list`) carry
  `messages_queued` for a badge. A store from before this task has no `messages` (views show `[]`).
- **Delivery**: waiting messages go, oldest first, into the prompt of the next assignment
  dispatched by any launch (`plan`, `run`, `continue`; not team setup), as a "Messages from the
  user" section after the handoff. They count as delivered only once that assignment's process
  started; a launch refused or withdrawn before keeps them queued. On delivery each message is
  appended to the handoff ("User message (time), given to role (agent): text"), so later
  assignments and a continuation see it once, as history, not as a new message. A run that ends
  with messages still waiting keeps them for the next launch (carry-over, Uwe 2026-11-22): a
  message queued during planning can so reach execution; the user drops one that no longer fits.
- **Drop**: `message_drop {id, message_id}` removes a message that still waits, in any status
  (also after its run ended, so a carried-over message can be removed). Refused:
  `project_message_unknown`, `project_message_delivered`, `project_message_invalid`,
  `project_unknown`, `project_store_full` (only this request, as for `message`). Result
  `{project}`, event `message_dropped`.
- **Prompt size**: all four declared project profiles (claude, codex, agy, pi) pass the prompt as
  one argv word, which Linux limits to MAX_ARG_STRLEN (128 KiB). Bounds: title 200 B, goal
  16 KiB, member instructions 4000 B, plan 48 KiB, handoff 16 KiB (its newest part), waiting
  messages 16 KiB, plus about 1.5 KiB of fixed text: at most about 100 KiB (the largest case in
  the tests is 99,411 bytes). There was no guard before; a prompt over 120 KiB is now refused
  before any launch (`project_prompt_too_large`, the project fails, waiting messages stay
  queued). Profiles with `stdin: true` are not limited.
- **Events**: `message` (sent), `message_delivered` (given to an assignment), `message_waiting`
  (a `now` message could not continue, or messages are left when the run ended).

## Send now, step by step
1. Validate (including `acknowledge_interrupted: true`) and store the message (`queued`, event `message`). If this write fails nothing else
   happens.
2. The existing pause path with the message's `run_id`: dispatch stops, status `pausing`, owned
   processes are stopped and confirmed; the attempt ends `paused` with its handoff. An
   unconfirmed stop answers `reason: project_still_pausing` (Retry pause stays available).
3. If the project is `paused` and the controller is not shutting down, the existing `continue`
   path with the current revision and the user's acknowledgement; the prompt keeps the usual
   instruction to inspect actual files and not repeat uncertain side effects.
4. The continued run's first assignment (the interrupted one) receives the handoff plus the
   message, which is then delivered. Any failure in 2 or 3 leaves the message queued and records
   `message_waiting`; a later Continue delivers it.

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
largest prompt below 128 KiB.
`feature_plugins_test.dart`: `messages` capability and the route through the real worker.
`tests/test_protocol.py`. Codex and agy CLEAN.
