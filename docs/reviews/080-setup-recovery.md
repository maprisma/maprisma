# 080 Setup recovery states

Independent reviewer: Codex. Source review of the working tree on
`task/080-setup-recovery`, based on `2eb027d`. Task 079 is independent and is
not part of this task's base or review. The reviewer ran no tests or suites
and made no source changes.

External reviews remain unavailable: Claude's CLI reported API/DNS
`EAI_AGAIN`, and Antigravity (`agy`) could not start its local socket server
(`EPERM`, operation not permitted). Neither external agent supplied a review
verdict. The CLEAN verdict below belongs to Codex only.

## Contract inventory (Codex, 2026-11-20)

The existing asynchronous `guide.snapshot` and persisted `guide.choose`
operations support this GUI-only recovery work. Loading and retry state can
remain in the frontend; route rows already provide checklist details and
named actions. No protocol or Dart core changes are required.

The review identified limits retained in the implementation and task document:
catalog routes have a bundled fallback, so a failed read does not establish
an offline catalog; verification is historical and cannot establish current
readiness when prerequisites are incomplete; test output remains in the
existing terminal. The contract does not supply persisted inline answers,
selected-model identity or authentication-validity facts.

## Round 1 (Codex, 2026-11-20, working tree based on 2eb027d)

1. **Medium** `flutter_app/lib/main.dart:3918`, choice retry.
   The initial direct call to the controller's retry method could replay a
   failed save without the global mutation busy guard, permitting navigation
   while the choice was being saved. The author had also identified this
   concern before review.
   > Author: Route retries through `_retryGuide`. A failed-choice retry sets
   > global busy state and restores it in `finally`; read-only retry retains
   > local loading behavior.
2. **Medium** `flutter_app/lib/main.dart:3953`, missing provider add-on recovery.
   Every guide Add-ons action initially opened category 1 (Agents), including
   the core's action for a missing local-provider add-on. The offered page
   could not expose the provider needing activation.
   > Author: Offer translated Agents/Providers destinations through the
   > existing `TaskReview`, then open the chosen category with guide-return
   > provenance. Added a real-app fixture for provider recovery and return.
3. **Low** `flutter_app/lib/first_agent_view.dart:140`, malformed saved choice.
   The new missing-choice explanation cast `selected` to `String?`. The core
   passes through the saved route value and validates its enclosing setting
   only as a map. A numeric saved route previously showed the choices, but
   the new cast would throw.
   > Author: Remove the unsafe cast and keep available routes visible. Added
   > a widget fixture with saved selection `42`.

The controller's revision guards correctly discard superseded read results,
including completion after leaving or disposal. Read failure preserves the
last checklist; confirmed choice followed by read failure retains the new
selection without repeating the save. Readiness requires both recorded
verification and a complete, nonempty checklist.

## Round 2 (Codex, 2026-11-20, working tree)

The round-1 findings are addressed.

1. **Medium** `flutter_app/lib/main.dart:4027`, nested add-on handoff.
   Guide → Add-ons → Providers → Providers and models invoked `_guideAction`
   while the guide itself was hidden. Unconditionally deriving return state
   from `_showGuide` cleared the guided provenance. Returning from the nested
   page and closing the add-on page no longer returned to the refreshed guide.
   > Author: Preserve return provenance while a guided add-on page is active,
   > using `_showGuide || _guideReturn && _focusCategory != null`. Extend the
   > provider recovery fixture through the nested Providers and models handoff
   > and verify the selected route and additional guide refresh on return.

## Round 3 (Codex, 2026-11-20, working tree)

**CLEAN — Codex source review.** All reported findings are addressed. The
final nested-handoff condition retains provenance for guided add-on pages
while preserving the ordinary page behavior. Existing reviewed installation,
sign-in, connection and explicit test actions remain the action paths.
No additional actionable defects were identified in the reviewed changes.

This is a source-review verdict; it does not claim that external CLI reviews
or the author's runtime checks were performed by this reviewer.

## Author verification reported separately

The author reports these completed related checks; the reviewer did not run
them:

- **33 related Flutter tests pass** before the final nested-handoff amendment,
  covering controller, recovery widgets, existing first-agent and hosted views,
  and selected app handoffs. The controller and recovery groups contain 9 and
  12 tests respectively. Output: `/tmp/maprisma-080-related.log`.
- **Three affected app cases pass** after the nested-handoff change. Output:
  `/tmp/maprisma-080-final.log`.
- **Four strengthened German/Polish layout cases pass**, scrolling the actual
  actions into view at compact sizes and large text. Output:
  `/tmp/maprisma-080-layout-final.log`.
- **Eight light/dark fixture renders were produced and inspected.** Six are
  recorded in the final-check output. Two blocked-state captures passed in
  the layout-final rerun after fixing a capture-only offscreen finder by
  scrolling; no app-source change was needed for that correction.
- **Two translation checks pass**: `/tmp/maprisma-080-i18n.log`.
- Targeted analysis reports no issues.

The focused reruns overlap the earlier tests; these counts are not a count of
distinct test cases. App source is unchanged from the final CLEAN source
review; the subsequent matrix strengthening changes test coverage only.

Only related checks are in scope. No full suites were run by the reviewer;
Uwe's policy reserves full suites for before a push. No push, release, live
provider operation, protocol change or core change is part of this task.

## Round 4 (Claude, 2026-11-20, task branch at daf2b55 against 2eb027d)

Reviewed read-only first (implementation and tests before the earlier rounds); Uwe then asked the
same session to fix the findings, so the answers below are the author's in that session and the
fixes still need an independent round.

1. **Medium** `flutter_app/lib/first_agent_view.dart:227-233`. Every unfinished step without a
   button said "This step needs manual setup", but the core sends no action for steps that only
   wait for an earlier one (sign-in and the test question while the agent is not installed,
   `first_agent.dart:358`/`:446`; Node.js while mise is missing, `:336`). On a fresh online route
   the guide told the user to do by hand what it offers one step later.
   > Author: the hint is shown only for the next step (the first unfinished one). Test: "steps
   > waiting for an earlier step are not called manual setup".
2. **Low (concern)** `main.dart:3546`, `:3908`. A `guide.snapshot` or `guide.choose` that never
   answers kept the guide busy; after a choice `_busy` also blocked navigation and closing.
   > Author: `FirstAgentController.timeout` (90 s) ends a hung save or check as a failed one
   > with Retry; a late answer is ignored like any stale one. Test: "a hung check or save ends as
   > a failed one with Retry".
3. **Low** `main.dart:3039`, `:3078`. Esc/Backspace now leave an add-on group page for every
   caller; the menu's Agents item left `_focusCategory` set, so the first Esc on the agent list
   did nothing visible.
   > Author: the Agents item clears `_focusCategory`. The new keys match the manual's "go back
   > from a page". Test: "guide add-on recovery can open Agents and Esc returns to the guide".
4. **Low (concern)** `first_agent_controller.dart:43`. Only `routes` being a list of maps was
   checked; the view hard-casts title, access, detail, action, target, starter and command.
   > Author: `validGuideSnapshot` checks every field the view reads (with its type, and target /
   > starter / command where a button needs them); a malformed row is a failed check. Tests:
   > "rows the view could not show are a failed check", "a malformed row keeps the last snapshot
   > and says it could not be checked".
5. **Low** `first_agent_controller.dart`. Refresh after a failed save dropped the unsaved choice
   without a word.
   > Author: Refresh keeps it with its Retry and the save message; only a new open of the guide
   > (`replace`) starts over. Test: "refresh after a failed save keeps the unsaved choice and its
   > Retry".

Coverage added: leaving while a choice is being saved ("leaving while a choice is being saved
ignores its late result"), Add-ons → Agents → back. Still open: Find existing AI → reopen the
guide → the saved choice is used.

## Round 5 (Codex, 2026-11-20, task branch at bdcddd1 against 2eb027d)

1. **Medium** `first_agent_controller.dart:51`. The round 4 timeout stopped waiting, but the
   `guide.snapshot` task kept polling and running; repeated Retry on a hung check could fill the
   core's four active-operation slots (`core_tasks.dart:88`), and leaving the guide left it too.
   > Author: confirmed. `FirstAgentController.abandonRead` stops the read that timed out, was
   > replaced or was left (`cancelPending`, `dispose`); the app cancels its core task
   > (`tasks.cancel`, which also ends the poll), and a task id that arrives after leaving is
   > cancelled at once. A stale read's late timeout stops nothing (found by the new test). Tests:
   > "a read that timed out, was replaced or was left is stopped", "leaving a running guide check
   > cancels its core task".
2. **Medium** `main.dart:3908`, `:6298`. The page's Refresh was wired to `_openGuide`, which
   replaces the state, so a failed choice and its Retry were still dropped; the round 4 test
   used the controller's plain `refresh()`.
   > Author: confirmed. The page's Refresh is `_refreshGuide` (plain `refresh()`); opening the
   > guide again still starts over. App test: "the guide Refresh keeps a failed choice and its
   > Retry saves it" (Retry saves `online` both times).
3. **Low** `task_cards_app_test.dart:2573`. The round 4 test never went through Help → Agents,
   where `_focusCategory` is cleared.
   > Author: confirmed. Test "Help → Agents from an add-on group page: the first Esc shows the
   > map".

## Round 6 (Codex and Antigravity, 2026-11-20, task branch at ab1a98f against 2eb027d)

Both reviewers found 1–3; Antigravity also found 4 and the local poll stop in 1.

1. **Medium** `main.dart:3566`. A failing `tasks.status` call ended the poll and dropped the task
   id in `finally`, so the core task kept its slot; and a poll whose cancel did not get through
   kept polling.
   > Author: confirmed. `_readGuide` cancels its task when the poll fails (unless it was
   > abandoned, and cancelled, already), and `_awaitTask(stopped:)` stops polling once the read
   > is left or replaced. The test fake now implements `tasks.cancel` (its task reports
   > `cancelled`). Tests: "a failing status poll cancels the guide check's task"; the leaving test
   > asserts one cancel and no further poll.
2. **Medium** `main.dart:3405` and every other menu path. Hiding the guide through the menu,
   AI Map, Settings, Reports, Open problems or Ask AI did not stop a running check.
   > Author: confirmed. `setState` stops the guide's running check whenever the guide goes from
   > shown to hidden, one place for every path. Test: "the menu hiding a running guide check stops
   > it too".
3. **Low** `main.dart:3079`. Esc on agent details opened from a group page cleared the hidden
   group focus without leaving the details.
   > Author: confirmed. The group branch of `_goBack` needs the group page on screen
   > (`_showMap`); details go back to the group page. Test: "Esc on agent details opened from a
   > group page returns to it".
4. **Medium** (Antigravity) `main.dart:6101`, `:6583`. After a guide step page left by AI Map,
   Open problems, Ask AI or "What you can do with it", `_guideReturn` stayed set, and closing a
   group page opened later from the map jumped into the guide.
   > Author: confirmed. These entry points and opening a group from the map clear
   > `_guideReturn` (a central clear would also fire inside `_closeGroupFocus`). Test: "a guide
   > step left by the AI Map button no longer returns to it".

Every new test was checked to fail without its fix.

## Round 7 (Codex and Antigravity, 2026-11-20, task branch at 73ad81c against 2eb027d)

1. **Medium** (Codex) `main.dart:3345`. Round 6 cleared `_guideReturn` as soon as "What you can
   do with it" opened; closing it without a choice left the guide's Providers page on screen
   without its return.
   > Author: confirmed. `_openUses` no longer clears it; Open problems and Ask AI clear it only in
   > the state change that leaves the page (not before a refused Reports leave or a busy return).
   > Test: "closing Help on a guide step keeps its return to the guide".
2. **Low** (Codex) The leaving test did not exercise the local poll stop (the fake's cancel always
   worked).
   > Author: confirmed. The fake can ignore `tasks.cancel`; test "a guide check whose cancel is
   > ignored stops polling anyway" fails without `_awaitTask(stopped:)`.
3. **Low** (Antigravity) `main.dart:5736`. `_finishSetup` from the guide's add-on page left
   `_guideReturn` set; agent details → Esc later jumped into the guide.
   > Author: confirmed. Instead of one more clear, one rule: a pending return lives only while a
   > page the guide opened is on screen. `setState` ends it when the plain map is still showing a
   > frame later (a page's Back passes the map on its way to the guide within the same call).
   > Test: "finishing setup from the guide's add-on page ends its return" (fails without the rule).
4. **Low** (Antigravity) The AI Map test passed without the AI Map clear (the group expand also
   cleared it).
   > Author: confirmed. The test now also opens agent details from the map and presses Esc, which
   > fails without the clear.

## Round 8 (Codex and Antigravity, 2026-11-20, task branch at 484a8da against 2eb027d)

1. **Medium** (both) `main.dart:3373`. On a guide step, Help → "What you can do with it" →
   a use case (Add skills) opened Connections, which inherited the return: its Back opened the
   guide.
   > Author: confirmed. The return now belongs to the screen the guide step opened
   > (`_guideFrom`, set by the first screen after the step; a new step or group page from the
   > guide starts it over). Any other screen still showing a frame later ends it; only agent
   > details opened from the guide's group page keep it. This replaces round 7's plain-map
   > rule and covers this path, the welcome banner's use cases and the earlier ones. Test: "a use
   > case chosen in Help on a guide step ends its return" (fails without the rule).
2. **Low** (Antigravity) `main.dart:3123`. Esc on agent details opened from the guide's Agents
   group page skipped that page and opened the guide.
   > Author: confirmed. `_goBack` from details over a group page goes back to the group page; the
   > next Esc returns to the guide. Test: "details from the guide's group page go back to it,
   > then to the guide" (fails without it).
3. **Low** (Codex) The round 7 claim that the AI Map test fails without the AI Map button's clear
   no longer held once the plain-map rule also cleared it.
   > Author: agreed; the record above was too narrow. The AI Map path is now covered by two
   > things, the button's own clear and the screen rule, and the test checks the behaviour (map →
   > details → Esc stays on the map), which fails only when both are removed.

## Round 9 (Codex and Antigravity, 2026-11-20, task branch at b25b89f against 2eb027d)

Both reviewers found the same two points.

1. **Medium/Low** `main.dart:3107`, `:3398`. A Help use case leading to the guide step's own
   screen (Connections → Add skills, Providers → Models, group page → details) kept the return.
   > Author: confirmed. Actions the user chooses from Help's use cases, the welcome banner and
   > Open problems go through `_chosenAction`, which ends the return first; the guide's own add-on
   > page keeps calling `_healthAction` directly. Test: "a use case opening the guide step's own
   > page ends its return" (fails without it).
2. **Low** `first_agent_controller.dart:73`. A failed Refresh after a failed save showed the
   check message while Try again would save the choice.
   > Author: confirmed. While a choice is unsaved its message stays. Test: "a failed refresh
   > after a failed save still says the choice is unsaved" (fails without it).

## Round 10 (Codex and Antigravity, 2026-11-20, task branch at 36edb45 against 2eb027d)

**CLEAN** (both). Both round 9 fixes are correct, and their tests fail without them. No new finding.
