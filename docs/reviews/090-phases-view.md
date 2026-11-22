# Review: 090 Phases view

Reviewers: Codex and Antigravity (read-only), rounds until both say CLEAN. Artifacts:
`.flutter-previews/task-090-checks/`.

## Deviations from the plan
- The Cards | Phases choice is page state like the filter (kept across an open project and under
  Settings/Reports/Help), not a saved setting: no new settings key in both cores for this step.
- An unknown stage is shown under Goal so a project is never missing from the view.
- The summary row's limits grow with the text size (New project as a symbol below 600 px × text
  scale; the switch's names from 1000 px × text scale), so the row fits at 640–800 px with large
  text and long words (a 088 test caught this).

## Checks
- `flutter analyze lib` clean; `test/project_phases_test.dart` (9) plus the board, page, page-parts,
  translation and main-tab tests (116 in all). Reveal test fails without the scroll (mutation
  checked). Only affected tests per round; `tools/test-changed` once before the commit.

## Round 1 → fixes
- Compact cards: the Semantics + ExcludeSemantics now sit inside the InkWell, so screen readers
  keep its tap and focus (test: isButton, isFocusable, tap action, and a semantics tap opens).
- Phases reveal: a focus node is only looked up for a shown card (no node for '' or a gone id).
- Translation guard covers BoardView labels.
- Tests (11): switch by keyboard (Space), card by Space, no Review in Phases, same 1200 px width
  gives columns at normal and a list at 1.5× text, reveal + focus in the stacked list.

## Round 2
Codex CLEAN, agy CLEAN.
