# 013 Terminal in a centred window

Author: Claude · Reviewer: Antigravity · Branch: task/013-terminal-overlay (on 012)

Uwe, 2026-11-01: a terminal runs in a centred, not maximized overlay window; a symbol in a footer takes the screenshot, because F9 stays with the program in the terminal.

## Routes
None.

## UI
The terminal opens at 80% × 85% of the map area, over a dimmed map; clicks on the map do nothing until Back. A camera symbol in its footer saves the picture, not shown when `screenshot_key` is off. Terminal tabs stay above.

## Acceptance
- The map stays mounted under the overlay; no page in the view slot is lost.
- The symbol saves a picture that includes the terminal.
- Manual in 8 languages, PDFs.
