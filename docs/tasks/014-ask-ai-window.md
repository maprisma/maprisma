# 014 Ask AI in the overlay window

Author: Claude · Reviewer: Antigravity · Branch: task/014-ask-ai-window (on 013)

Uwe, 2026-11-01: the Ask AI dialog moves into the terminal's overlay window, agent selection in the header, action buttons in the footer.

## Routes
None.

## UI
`overlay_window.dart` is the one window for the terminal and Ask AI: centred, 80% × 85%, over the dimmed app, what is below takes no clicks. The column's bar stays; opening it shows the window through an `OverlayPortal`, so the card keeps its state. Header: status symbol, title, helper menu with its cost, Collapse; the helper can change while nothing is under way. Footer: the buttons of the step. Reviews keep their own buttons.

## Acceptance
- Every step works as before, its buttons in the footer.
- A column hidden while its window is open hides the window and keeps the prompt.
- Esc closes; work under way keeps its rules (`_atWork`).
