# 016 A selection grays out the rest

Author: Claude · Reviewer: Antigravity · Branch: task/016-focus-dimming

Uwe, 2026-11-01, screenshot note: when a card is selected, all other cards and their connection lines gray out, except the pinned ones.

## Goal
With a box selected, every box outside the lit set fades to 30% and every line outside it to 20%. The lit set stays what it was: selected and pinned boxes, what connects to them, and the hovered box. Pins alone select nothing, so they gray out nothing. Fading is look only: faded boxes stay clickable.

## Manual
Sentence after the Pin sentence in chapter flutter-map-editor, 8 languages.
