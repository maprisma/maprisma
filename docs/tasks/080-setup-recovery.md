# 080 Setup recovery states

Author: Codex · Reviewer: independent agent · Branch: task/080-setup-recovery

## Goal

Show a useful first-agent guide while setup is being checked, when reading or
saving fails, when no choices exist, or when prerequisites need manual work.
Keep the last confirmed route and the existing reviewed setup actions.

Base: `2eb027d` (main `2dd54ff` plus the related-only testing policy). Task 079
remains separate on its own branch; this task does not depend on its layout.

## Routes and evidence

None changed. `guide.snapshot` is already an asynchronous read task and
`guide.choose` persists the route. Snapshot rows contain route/step labels,
done flags, allowed actions, starter details and historical verification.
Loading/errors belong to the GUI. Catalog choices use loaded add-ons with a
bundled fallback; a failed snapshot is not evidence of an internet failure.

The current contract does not report expired sign-ins, a selected model, or
a persisted test answer. Verification output stays in the existing terminal.
Current incomplete prerequisites must remain visible even for an agent with
historical verification.

## UI

- Open the guide immediately with local progress, then keep the last snapshot
  if refresh fails. Offer explicit retry for a failed read or failed choice.
- Show an empty-options explanation and Add-ons/Find existing AI actions.
- Identify a missing previous route and show the next incomplete step.
- Explain steps without an available action; retain their details and offer
  Add-ons/Refresh. Keep manual install, sign-in, connection and test reviews.
- Preserve selection across cancellation and guided page handoffs. Add-ons
  returns to the refreshed guide. Find existing AI retains its existing map
  journey; reopening the guide uses the persisted choice.
- Offer the map only when the current checklist is complete and verification
  is recorded. No test question is sent automatically.
- Translate new text in all eight languages and update the manuals.

## Acceptance and checks

Use related controller, first-agent widget, hosted-view and guide-handoff tests
only. Cover delayed success/failure, retry, failed route persistence, confirmed
choice followed by failed refresh, cancellation/late completion, empty choices,
missing prerequisites, historical verification and explicit test/map actions.
Check compact German/Polish and large text. Use private fixtures only.

Full suites are reserved for before a push. No push, release, live provider
operation or settings change is authorized by this task. External Claude/agy
reviews were unavailable in the preceding task; record the actual reviewer
and any remaining environment limits without claiming those reviews ran.

## Implementation and verification (2026-11-20)

Implemented entirely in Flutter. `FirstAgentController` keeps the last
confirmed snapshot, retries failed saves explicitly, and ignores late or
superseded reads. The page opens before loading completes. Current checklist
gaps remain visible despite historical verification. Add-ons offers Agents or
Providers and preserves return through nested setup pages. Existing reviewed
installation, sign-in, download, connection and terminal-test actions remain
the operation paths.

Related checks only:

- **33 Flutter tests pass:** 9 controller, 12 recovery widgets, 3 existing
  first-agent action tests, 1 hosted-view test and 8 selected app journeys.
  After the final handoff fix, reran only the 3 affected navigation cases.
  Strengthened and reran the 4 German/Polish layout tests to scroll their
  actual action/manual-state widgets into view at 150% and 200% text.
- **2 translation checks pass.** The asset generator validates and emits all
  eight language bundles. JSON validation, formatting, changed-file analysis
  and `git diff --check` pass.
- **8 light/dark fixture renders pass and were inspected:** loading at
  960 × 640, empty/failed states at 540 × 400 with 150% German/Polish text,
  and a manual prerequisite at 540 × 400 with 200% German text. These use
  Noto Sans and private fixtures. Captures are excluded from commits in
  `.flutter-previews/task-080/`.
- The first-start paragraph is translated and stamped in all seven translated
  manuals. The manual checker still reports the same eight unrelated stale
  sections per language as the base; this task adds no new stale section.
- Independent **Codex source review: CLEAN**, after fixing retry busy state,
  provider-add-on recovery, malformed saved choices and the nested handoff.
  External Claude/agy reviews remain unavailable under the existing sandbox
  socket/network restrictions and are not credited as completed reviews.

The ordinary Flutter runner requires sockets unavailable in this sandbox.
Scoped tests use the headless Flutter engine with its VM service disabled,
standard test assets/Ahem fonts and `test_core`'s direct runner. The harness
and writable SDK copy are outside commits. No core, protocol, live settings
or installed SDK changes were needed. No full suites, build, push or release
was run.

Evidence: `/tmp/maprisma-080-related.log`, `/tmp/maprisma-080-final.log`,
`/tmp/maprisma-080-layout-final.log`, `/tmp/maprisma-080-analysis.log`,
`/tmp/maprisma-080-i18n.log`, `/tmp/maprisma-080-manual.log`.
The initial capture-only lookup failures in the final log were corrected by
scrolling lazy content before finding it; the two affected captures then pass
in the layout-final log. Application source did not change for that fix.
