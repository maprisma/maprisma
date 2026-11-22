# Review: 089 Project page (large stage rail and Team graph)

Reviewers: Codex and Antigravity (read-only), rounds until both say CLEAN. Artifacts:
`.flutter-previews/task-089-checks/`.

## Deviations from the plan
- Rail and graph read the open project's board card (the same facts as its card); a new, unsaved
  project has neither yet. The graph shows the saved team (read only); edits show after saving.
- The graph's boxes are laid out with Flutter widgets (boxes and a line each), not the map's
  renderer; one row per phase, wrapping.

## Checks
- `flutter analyze lib` clean; `test/project_page_parts_test.dart` (11), the board, page, setup and
  translation tests. Per Uwe: only affected tests per round, `tools/test-changed` once before the
  commit.

## Round 1 → fixes
- Member box: initials, role and state on separate lines, state with its symbol (never cut off
  behind a long role, never colour alone); all member issues (Map entries only), two lines.
- A model alone keeps "Agent default · <model>"; line and tint only for an explicit runtime/provider.
- Rail: unknown stage/second add no stray text; shouldRepaint compares every field.
- Wide layout: form and graph share the width 3:2 (no fixed 380 px column).
- Boxes use corners(context).
- "Plan" in de/fr/nl meant the subscription: the usage page now uses the new key
  "Subscription plan" (Tarif/Forfait/Abonnement), "Plan" is the project plan everywhere.
- Polish manual: "Zatwierdzanie" as in the app.
- Tests (19): current stop is the only bold one, all four marked states with long words at 1.5×,
  launch order and rows, model-only/explicit/default targets, unknown stage, rail between
  breadcrumb and tabs, graph below the form (scrolled), new project and no-board backend; the fake
  `get` has no projection fields.

## Round 2 → fixes
agy CLEAN. Codex: the compact rail cut off the next step. Now stage · activity on one line (up
to two), the next step on its own wrapping line (key large-rail-second); test at 480 px, 1.5×,
long German text checks the paragraph is not cut (didExceedMaxLines false).

## Round 3 → fixes
Codex CLEAN. agy: the wide rail's activity line was still one ellipsized line. It now wraps;
test at 600 × 700, 2× text, Dutch strings, checks didExceedMaxLines false (fails on the old code).

## Round 4
Codex CLEAN, agy CLEAN.
