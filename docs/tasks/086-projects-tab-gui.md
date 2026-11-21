# 086 Projects tab, part 2: tabs and navigation

Author: Claude · Reviewer: Codex and Antigravity · Branch: task/086-projects-tab-gui

Step 1 of `docs/plan-main-layout.md`, GUI part, on top of task 085 (core contract, merged
ed2a0ac1). Uwe's defaults (2026-11-21): tabs **Projects** and **AI Map**, start on the last used
tab, Reports stays a header symbol, Phases view later. The board (cards, filters) is step 2:
meanwhile the Projects tab shows today's Project Center page, without its own Back button.

## UI
- Header: `[ Projects ]  [ AI Map ]` at the left (`main_tabs.dart`), the actions on the right as
  before; the Project Center symbol and its badge are gone. The Projects tab carries the counts:
  running (`running + pausing`), needs you (`needs_you`; an older backend's `waiting`), attention
  (`attention_projects`; an older backend's `attention`), each with its own symbol, a warning mark
  for the store fault (`error`) and a crossed cloud with "status unavailable" when disconnected;
  one dot when narrow (< 760 px), with the full description as tooltip and accessible label.
- Legend and the map's Undo only on the AI Map. Narrow: Reports, Help, Settings and Refresh in a
  "More" menu; the tabs scale down instead of wrapping.
- Start tab, once after the startup data loaded (a loading state meanwhile): setup needed → AI Map;
  else the saved `main_tab`; else Projects when `total > 0`; a summary not read within 3 s → AI
  Map, and a late answer switches nothing. A start on Projects makes no map scan.
- A tab chosen by the user is saved as `main_tab`.

## Navigation and keys
- The Projects page lives in its own retained slot while Projects is the main tab: Settings,
  Reports and Help over it return to the same page (selection, fields, scroll).
- Every way out of the page with unsaved changes asks Save / Discard / Cancel (AI Map tab, Ctrl+2,
  Settings, Reports, Help, Ask AI, problems, window close); Cancel or a failed save stays. One
  departure at a time; while the page saves, starts or pauses, leaving says "Wait for the current
  step". Window close: "Discard" takes effect only after "stop running agents?" was confirmed
  (`prepareLeave` returns the commit).
- Ask AI and the problems list switch to the AI Map first (through the guard).
- Esc on the Projects tab: a text field first, then closes or hides the window as on the map.
- Ctrl+1 / Ctrl+2 in the window's own shortcuts (not above dialogs), not while keys are blocked
  (a task, a card, a terminal).
- Refresh and F5 on Projects refresh the page; the next `list` carries `refresh: true`, as does
  the first one after the window regained focus.
- While Projects is shown, the hidden map's live scans, usage and traffic polls pause (the summary
  poll, limit notifications and the minutely badges stay).

## Texts and manual
New texts in all 8 languages (appended). Manual (English; the Project Center chapter is not
translated yet): the tabs, the start tab, the counts, Ctrl+1/2 and F5.

## Acceptance
Widget tests: counts, fault mark, narrow dot, disconnected, older-backend summary; start-tab rule;
deferred discard. App tests (real window, Python service): start on Projects without map scans or
map polls, saved tab wins, no projects → map, Ctrl+1/2 and F5 with `refresh`, unsaved changes ask
(Cancel stays, keys do nothing under the dialog, Discard leaves), Settings returns to the same
page, Ask AI switches to the map, closing with Discard then Cancel keeps the draft, counts and
fault mark on the map. Codex and agy review CLEAN.
