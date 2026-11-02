# 022 The map's look: lines, colours, corners, a filter per card

Author: Claude · Reviewer: Antigravity · Branch: task/022-map-look

Uwe, 2026-11-02: with a border around the category cards, lines must not cross the cards. Settings colour each kind of line. A symbol in a card's header switches between all boxes and only what is connected or pinned. The cards' corners follow Settings › Corners. The border's colours include the theme's.

## How
- With a border on, `_MapPaint` clips the lines to the space outside the cards: a line shows between cards and stops at their border. Without a border nothing changes.
- `flutter_map_layout.line_colors`: provider (uses, available), model (default, live), serves, mcp, skills; failed lines stay the error colour. A coloured line not in focus is that colour, fainter.
- A colour is `#rrggbb` or `theme:primary|secondary|tertiary|outline`, for the border too; `mapColor` resolves it, `mapColorValue` and `_color` check it in both cores.
- `flutter_map_layout.used_only`: card ids that show only boxes with a line (not an offer) or a pin.
- The cards' corners are `corners(context)`.

## Manual
flutter-map-editor, 8 languages.
