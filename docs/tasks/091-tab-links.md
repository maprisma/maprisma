# 091 Links between the tabs: Show on map, Used in N projects

Author: Claude · Reviewer: Codex and Antigravity · Branch: task/091-tab-links

Step 5 of `docs/plan-main-layout.md` ("AI Map tab: setup and monitoring", links), first part. The
issue links (reason, target, fixable → fix link on the map, else the project's Team or Goal tab)
need a contract change and follow as task 092.

## UI
- **Show on map** on every member box of the project page's Team graph (a symbol button, its
  name and the agent's for screen readers): through the departure guard (unsaved changes ask
  first; busy waits) to the AI Map, which pans that agent's box into view and marks it for a few
  seconds. Temporary: no saved layout, pins or view change. A removed or hidden agent (not on the
  map, e.g. its layer off) says "This agent is not on the map." and nothing moves.
- **Used in N projects** on an agent box of the map (a small badge with the number, its text as
  tooltip and for screen readers; also in the box's Actions menu): from `features.summary`'s
  `by_agent` (no extra request; absent or 0: no badge). It opens the Projects tab (through the same
  guard as the tabs) with an **agent chip** ("Claude Code ×") in the summary row that combines with
  the status filter: the board and its counts show only projects whose planning or execution names
  that agent; the header's counts stay global. × clears it, **All** clears both. Back from a
  project that the chip would hide clears the chip (as the filter).

## Not in this step
Issue links (092), screenshots (step 6).

## Acceptance
Widget tests: reveal pans an off-screen box into view and marks it, the mark goes, the layout and
saved view are not written; a missing agent says so; the badge with its count and menu entry; the
chip filters board and counts with and without a status filter, × and All clear; the page's Show
on map with unsaved changes asks first and Cancel stays; a completed project whose runtime stopped
stays Agents finished under the chip. Texts in 8 languages; manual. Codex and agy CLEAN. Only
affected tests per round; tools/test-changed once before the commit.
