# 015 A note with the screenshot

Author: Claude · Reviewer: Antigravity · Branch: task/015-screenshot-note

Uwe, 2026-11-01: F9 and the camera symbol ask for a comment, as they did in recorded tests.

## Goal
After the picture is saved, a dialog shows where it went and takes an optional note. The note goes to a text file with the picture's name, next to it; no note, no file. A recorded test keeps writing its note to the protocol.

## Folder
Setting `screenshot_folder` (null|string, default null: `~/Pictures/Maprisma`), additive, protocol stays 2. A folder that cannot be written falls back to the default, so no picture is lost. A recorded test keeps its own folder.

## Map (Uwe's screenshot note, same branch)
Column gaps about 8% of the window, as far as the 266 px column minimum leaves room.

## Texts
`What is wrong? (optional)` in 7 languages; the dialog is translated now that it is not only a test tool. Manual: the F9 row of the keys table.

## Acceptance
- App test: F9, note, Done gives a .png and a .txt.
- The terminal gets the keyboard back after the dialog.
- Tests write nothing to ~/Pictures/Maprisma.
