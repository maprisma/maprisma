# 023 One look for windows and pages

Author: Claude · Reviewer: Antigravity · Branch: task/023-common-look

Uwe, 2026-11-02: one recognisable layout for the whole app, especially the windows and the side pages: the same gaps, header, window style, controls and text styles, with the map's category cards as one of the shared patterns. The rules window to be laid out anew. Antigravity's audit, docs/reviews/023-layout-audit.md, proposes the parts and the order; several names in its inventory do not exist in the code, so each step checks the real code.

## Parts (app_look.dart)
- `AppSpace`: 4, 8, 12, 16, 24. Every gap and padding is one of them.
- `WindowHeader`: title (`titleLarge`), an optional line under it (`bodySmall`, muted), actions, Back at the right, a divider.
- `WindowFooter`: a divider, the buttons at the right with the main one last, an optional item at the left.
- `SectionCard`: the map's category card for everything else: `surfaceContainerLow`, the corners of Settings, an outline, an optional title band (`titleSmall`) with a control at its right.
- `SettingRow`: words at the left, the control at the right.

## Steps
1. The parts; `TaskHost` and `TaskReview` use them. Done.
2. The rules window: header with its rule and Restore defaults, Allow and Deny as section cards with + in the band, the hint switch as a row, the test as its own card with the deciding rule. Rows without underlines. No second shade over the window. Done.
3. Settings and the side pages.
4. Ask AI, the terminal window, the welcome view.
5. The remaining dialogs, and hard-coded sizes and colours.
