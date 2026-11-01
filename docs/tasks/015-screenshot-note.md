# 015 A note with the screenshot

Author: Claude · Reviewer: Antigravity · Branch: task/015-screenshot-note

Uwe, 2026-11-01: F9 and the camera symbol ask for a comment, as they did in recorded tests.

## Goal
After the picture is saved, a dialog shows where it went and takes an optional note. The note goes to a text file with the picture's name, next to it; no note, no file. A recorded test keeps writing its note to the protocol.

## Folder
Setting `screenshot_folder` (null|string, default null: `~/Pictures/Maprisma`), additive, protocol stays 2. A folder that cannot be written falls back to the default, so no picture is lost. A recorded test keeps its own folder.

## Map (Uwe's screenshot note, same branch)
Column gaps about 12% of the window, as far as the 266 px column minimum leaves room; columns at most 360 px, the rest goes to the gaps. Pin is a symbol at the card's bottom right, no longer in its menu.

## Ask AI helper (Uwe's screenshot notes)
The helper chosen in one Ask AI window holds for all four cards and after a restart (setting `smart_helper`, null|string), with a green check mark next to it. The status symbol stays what it was: the column's findings. Choosing a helper changes none of them.

## Column widths (Uwe)
A column's left or right border drags its width, and its boxes follow. Saved in `flutter_map_layout`: `column_widths` (current) and `column_defaults`, by column name, 200 to 900 px, in both validators; protocol unchanged. Nothing set means today's automatic width. A double click drops the current width. Settings › Map shows both for each column. The status symbol left the Ask AI window's title; the bars keep theirs (Uwe's choice).

## Texts
`What is wrong? (optional)` in 7 languages; the dialog is translated now that it is not only a test tool. Manual: the F9 row of the keys table.

## Acceptance
- App test: F9, note, Done gives a .png and a .txt.
- The terminal gets the keyboard back after the dialog.
- Tests write nothing to ~/Pictures/Maprisma.
