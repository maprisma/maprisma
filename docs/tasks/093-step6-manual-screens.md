# 093 Step 6: screenshots and manual review

Author: Claude · Reviewer: Codex and Antigravity · Branch: task/093-step6

Step 6 of `docs/plan-main-layout.md` after tasks 086–092.

## Done
- Screenshots of the current app (Devel preview, demo projects): board, Phases, project page with
  stage rail, Team graph, page issues with link, AI Map with Used in badges, board with the agent
  chip. The manual's two Projects images are replaced (`images/projects-tab.jpg`: the board,
  `images/project-center.jpg`: an open project with the Team graph).
- Manual review by Codex and agy (`.flutter-previews/task-093-checks/*-manual-r1.txt`): the
  "Planning and running a project" section is rewritten in a reader's order (tabs and navigation →
  leaving a project → board → Phases → project page → issues → links between the tabs → creating a
  project and its team → plan and run → counts and recovery) in all 8 languages with the app's
  labels; the Setup section's first sentence names the project's Setup tab; a Projects-keys
  paragraph in "Keyboard use in the Flutter preview"; Reports opens from the header (More in a
  narrow window).
- Bug found while taking the screenshots: a map tooltip ("Used in N projects") stayed over the
  Projects tab after its badge was clicked. Cause: the hidden view's `TickerMode` stopped at once,
  so the tooltip's fade-out never ended. `RetainedTaskView` now keeps its tickers running 400 ms
  after it becomes hidden (on its own ticker, no pending timer) and closes all tooltips once the
  switch is drawn; its subtree (focus, state) stays as it is.
- Uwe (2026-11-22): the performance settings entry on a local provider's map box (its menu sheet
  and the speed symbol's tooltip) is named **Setup** instead of "Configure for this PC"; the
  Providers page keeps "Configure for this PC". Manual sentence in 8 languages.
- Uwe (2026-11-22): "The window at a glance" shows the Flutter window: a new AI Map screenshot
  (`images/main-window.jpg`) with six numbered areas (tabs, header actions, column filters and zoom,
  group card, an agent's box, the lines), in 8 languages.

## Not in this step
- The "Setup" part of "The window at a glance" (`#my-setup`, a page of the GTK app) still describes
  that page; the Flutter app does this in the map's group cards. Own task.
- Translation sections that were already stale before this step (map, agent-updates,
  flutter-appearance, omarchy-data-flutter, provider-configuration, shortcuts, glossary,
  project-center-setup, feature-plugin-updates) are unchanged debt.
