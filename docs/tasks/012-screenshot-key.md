# 012 F9 screenshot for everyone

Author: Claude · Reviewer: Antigravity · Branch: task/012-screenshot-key (on 011)

Uwe, 2026-11-01: the F9 of recorded tests becomes permanent, optional in Settings, on by default.

## Goal
F9 saves a picture of the app's window, without any test setup.

## Routes
`settings.get` / `settings.set`: new `screenshot_key` (bool, default true). Additive, protocol stays 2.

## UI
Settings: **F9 saves a screenshot**. A picture goes to `~/Pictures/Maprisma/maprisma-<date>-<time>.png`, a message names the file. F9 is left to the program while a terminal shows. A recorded test keeps its own folder and note, whatever the setting.

## Acceptance
- Off: F9 does nothing. On: one new file, never an overwritten one.
- Manual in 8 languages, PDFs.
