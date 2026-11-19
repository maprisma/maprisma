# One question across the AI map

## Round 1 (Antigravity, 2026-11-19, working tree based on bef1307)

1. **High** `map_smart_card.dart:822`. Returning to the editor or starting from a finding could send the previous exchange with an unrelated request.
   > Author — Cleared conversation context on Back, Edit, close, initial prompts, example selection and health handoff. Tested a new question after a follow-up and both choices when switching helpers.
2. **High** `core.dart:4629`. Refusing the optional terminal task also discarded a sourced answer.
   > Author — Retained the answer and links while removing denied candidates. Tested through the job result finalizer.
3. **High** `smart_card.dart:2248`. An add-on operation without an area was rejected.
   > Author — Routed add-on decisions directly to the existing add-on validator. Tested a decision without an area.
4. **High** `map_smart_card.dart:1101`. Automatic mode removed an explicitly typed category prefix before sending.
   > Author — Preserved the full request, including a translated prefix, and kept explicit-column calls compatible. Tested sending an MCP-prefixed question through auto.
5. **Medium** `map_smart_card.dart:1330`. MCP form controllers retained secrets after leaving the form or applying.
   > Author — Dispose of the controllers when abandoning the form, closing, applying or starting a new question. Returning from a preview to the active form preserves the user's entries.
6. **Medium** `core.dart:3413`. Expired update findings appeared current. The sign-in answer omitted agents with observable credentials and no interactive login.
   > Author — Use the update cache's check time, expire evidence after six hours and invalidate it after changes. Include agents with observable sign-in facts. Tested two installed agents with different observed states.
7. **Medium** `map_smart_card.dart:1025`. New question could race with a pending preview.
   > Author — Disable New question while previewing, guard the handler, and invalidate previous request tokens when starting again.
8. **Medium** `map_smart_card.dart:2563`. Follow-up accepted empty input and retry appeared available without a helper.
   > Author — Disable invalid submissions, preserve drafts, attach dictation feedback to the response field and offer helper setup on failure.
9. **Low** `docs/manual/manual.de.html:3` and six other languages. Updated sections retained old translation stamps.
   > Author — Stamped the four translated sections in all seven manuals.
10. **Low** `ask_ai_menus_test.dart:92`, `smart_card_test.dart:985`, `smart_window_test.dart:185`. The review identified missing regression cases across the worker, follow-up and preview UI.
    > Author — Added fixtures for automatic model search, checked map edits and add-ons, a sourced lookup with its optional action denied, two sign-in states, and fresh and stale agent/MCP caches. Widget tests cover unavailable helpers, consent and expiry of the previous exchange, a delayed job ID after Esc and a second submission, reviewing filled forms, double Apply, and the online dictation notice before recording. The release evaluation of live helper quality and first-time users remains open.

## Round 2 (Antigravity, 2026-11-19, working tree)

1. **Medium** `map_smart_card.dart`, MCP form teardown. Closing with a form in the Back stack abandoned its controllers but could reopen the form, and controllers were disposed before their fields detached.
   > Author — Closing a form or its preview resets the destination to the proposal. Required fields must exist and be populated. Detached controllers are erased and disposed after the frame. A widget test closes and reopens a preview, verifies the secret field starts blank, then checks that Back preserves values within the active form and Apply runs once.
2. **Low** `core.dart`, refused proposals. Filtering every candidate removed the helper identity, causing a follow-up to ask for consent to send to the same helper.
   > Author — Preserved helper identity and locality in the refusal and added a result-finalization test.

## Round 3 (Antigravity, 2026-11-19, working tree)

Both Round 2 defects were verified as resolved. The contextual map menu had two findings.

1. **Medium** `map_smart_card.dart`, initial question handling. A map item could replace a running confirmed operation or a retained MCP form.
   > Author — Item handoff respects active work and pending previews and releases abandoned MCP form state before prefilling. The apply test changes the item while a confirmed request is outstanding and checks that the job still delivers its result.
2. **Low** `main.dart`, map item prompt. The previous Polish wording specifically described a program and read incorrectly for a model.
   > Author — Added dedicated wording for “Tell me about {0}” in all eight app languages.

## Round 4 (Antigravity, 2026-11-19, working tree)

**CLEAN.** Verified that the item handoff preserves a pending confirmed Apply, the completion callback fires once, abandoned form fields are released, and all eight Flutter bundles contain the item-neutral prompt.
