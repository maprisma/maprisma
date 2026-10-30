# 006 Status in the smart cards

Core: Claude · GUI: Antigravity · each reviews the other · Branch: task/006-status-in-smart-cards

After 004. Uwe, 2026-10-30: the smart cards are the centre of the map, so the Open problems page goes and its results
move into the cards. A problem then stands where it is solved.

## Goal
Each column's smart card shows that column's state: a symbol at the left of its bar. A click on the symbol opens the
card on the findings of that column; a click on the rest of the bar opens the prompt. No tokens: the checks are local.

## Symbol
| State | Symbol | Level in `health.report` |
|---|---|---|
| All fine | check mark in a green circle | no finding |
| Something to look at | `!` in a yellow triangle | `hint` |
| Something needs fixing | `!` in a red circle | `warn` |

Different shapes as well as colours, and a text for screen readers (`"{0}: {1} to fix"`, `"{0}: all fine"`). The worst
level of the column decides; an update or suggestion counts as `hint`.

## Where the findings go
| Today | Column |
|---|---|
| Agents | Agents |
| Local LLMs | Providers |
| Models | Models |
| Tools | MCP servers and skills, or Agents when the tool is for agents |
| This PC (memory, card, disk) | Models |
| Updates and suggestions | the column of what they are about |

The use cases ("What you can do with it") move to the **welcome page** (Uwe), with their Ready, Almost and Not yet.

## Core (Claude)
`health.report` gives every finding, update and hint a `column` (mcp · agents · providers · models). The checks do not
change. `routes.json` first.

## GUI (Antigravity)
1. The card is **always visible**, also with no helper ready: the status is what a new user needs most. Without a
   helper the status view works and the prompt says what is missing, with a way to it. This replaces state 1
   ("Hidden") of 004.
2. The symbol in the bar, and the status view in the card: findings of the column, worst first, each with its
   existing button that opens where it is fixed, then its updates. **Check again** as today. Nothing to show: one line.
3. **Ask AI** on a finding: fills in the card's prompt with the finding and shows the prompt step. Only the click on
   Ask sends: tokens stay the user's decision.
4. A small overall state stays in the header, because a column can be hidden on the map and the System Map has no
   columns: it shows the worst level and a click goes to the first card concerned (on the System Map, back to the map).
5. The use cases on the welcome page.
6. Then remove `open_problems_view.dart`, the page's route in the GUI and its texts where nothing else uses them.

## Manual
The chapter on Open problems becomes part of the smart card chapter, in 8 languages; the PDFs at the end.

## Acceptance
- Every finding of `health.report` appears in exactly one card (test against a report with all kinds), with its button.
- A hidden column's red problem is still visible in the header's state.
- No token is spent by opening, checking or showing anything.
- The welcome page shows the use cases.
- The three suites from AGENTS.md green; review by the other agent until CLEAN.
