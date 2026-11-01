# 010 Open points of 006

Author: Claude · Reviewer: Antigravity · Branch: task/010-status-open-points

## Goal
Close what 006 left open: the protocol version, the use cases after the welcome page, the header's old "!" in the manuals.

## Routes
`addons.hints.column` went from int to string in 006: `"protocol"` is now 2 in routes.json, both cores, tools and tests.

## UI
Help gets a tab **What you can do with it**, with the welcome page's use case cards (`UseCaseCards`), shown once `health.report` has answered. Manuals in 8 languages: the header's symbol, and the column's status instead of Updates and suggestions or the open problems page.

## Acceptance
- A request with protocol 1 is refused, one with 2 answered.
- The use cases can be reached from Help after the welcome page has gone.
- Screenshot `images/main-window.jpg` still shows the old header: left out, it needs a new picture from Uwe's desktop.
