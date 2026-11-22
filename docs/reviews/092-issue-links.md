# Review: 092 Issue links (reason, target, where to fix)

Reviewers: Codex and Antigravity (read-only), rounds until both say CLEAN. Artifacts:
`.flutter-previews/task-092-checks/`.

## Deviations from the plan
- No new capability: the issue keys are additive (`target`, `node`, `fix`); a GUI meeting an issue
  without `fix` treats it as Team (no map link), so an older backend still works.
- The card shows the first issue's link only (its height is fixed); the project page lists every
  issue (project-level and every assignment's, each code and box once) at the top of its scrolling
  body.
- The Team graph's member problem line stays text; its issues are in the page's list with links.
- Fix on map reuses Show on map's path (`_revealOnMap(id)`: guard, one map read, reveal after the
  fit, mark; leaving or a failed read forgets it); a box not on the map says "This is not on the
  map." (agents keep their own text).

## Checks
- Protocol: routes.json note, `tools/protocol.py doc|client|check`.
- Core: `packages/maprisma_core/test/ai_project_center_test.dart` (101; new: target/node/fix per
  code, Goal/Team project issues, two stopped runtimes are two issues).
- GUI: new `test/project_issue_links_test.dart` (10), a shell test (Fix on map from a card reveals
  `runtime:fixture`), affected board/page/links/main-tab tests (153). Only affected tests per round;
  `tools/test-changed` once before the commit.

## Round 1 → fixes
- Fix on map only where the map shows the box and can act on it (core, contract, table, manual):
  agent_unavailable → Team (an uninstalled agent has no box; an installed one the map cannot make
  project-capable); runtime_stopped → map only for an installed runtime, else Team;
  model_unavailable → the runtime's box (a model it does not serve has no box of its own);
  provider_unavailable → map only when the agent is not connected to that runtime and has a
  provider option, else Team (another provider than the connection names, or no option). Core
  test covers each branch, plus model_unsupported and subagents_unsupported.
- The page's issue list scrolls with the editor body (every issue reachable, no overflow, the
  tabs stay); the compact "+N" form is gone.
- `issueFix` needs a non-empty node; `collect` keys like the core (`node ?? ''`); the card's link
  is as tall as the issue line (shrink-wrapped tap target).
- New GUI tests: every issue reachable and its link working at 480 × 360 with 1.5× text, 20 issues
  without overflow, Enter on a link, a card with every line at three widths, empty node; shell test
  for the save question on Fix on map (Cancel stays, Discard goes) and "This is not on the map.";
  the translation guard covers that text. 157 affected GUI tests, 101 core tests.

## Round 2 → fixes
- model_unavailable without a chosen model (a runtime saved before it served models) goes to the
  Team tab, where the model is chosen; a chosen model the runtime does not serve keeps the runtime's
  box (contract, table; core test for both).
- Core tests now also cover folder_changed and empty_goal (Goal) and access_unsupported (Team).
  launch_unavailable is the fallback for an unexpected launch error; it has no reachable trigger
  with valid profile data (a non-JSON subagent definition is dropped by the profile copy), so it is
  covered by its one-line classification only.
- Manual (8 languages): the issues are listed at the top of the project's page (they scroll with
  it), not under the stage rail; the review note's stale "+N" line is corrected.

## Round 3
Codex CLEAN, agy CLEAN.
