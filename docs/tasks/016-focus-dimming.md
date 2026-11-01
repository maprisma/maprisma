# 016 A selection grays out the rest

Author: Claude · Reviewer: Antigravity · Branch: task/016-focus-dimming

Uwe, 2026-11-01, screenshot note: when a card is selected, all other cards and their connection lines gray out, except the pinned ones.

## Goal
With a box selected, every box outside the lit set fades to 30% and every line outside it to 20%. The lit set: selected and hovered boxes with what connects to them, and pinned boxes with their own lines only (Uwe, so a neighbour of a pin no longer looks selected). A selected box has a 3 px outline. Pins alone select nothing, so they gray out nothing. Fading is look only: faded boxes stay clickable. A faded box keeps a solid backing, so a line passing under it stays hidden.

## Clicks (Uwe)
A click on a box only selects it and ends the former selection; a pinned box stays lit. A second click on the only selected box ends the selection. The shortcut "agent selected, then click a model" is gone, by Uwe's choice: connecting is drawing or Connect in the box's menu.

## Manual
Sentence after the Pin sentence in chapter flutter-map-editor, 8 languages.
