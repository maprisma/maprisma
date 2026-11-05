# 058 Headings for the General groups of Settings

Author: Claude · Reviewer: Antigravity · Branch: task/058-general-headings (on top of task/057-settings-layout)

## Goal
Uwe, 2026-11-05, after seeing task 057 installed: "yes add the headings". The groups of Settings ›
General had no titles; now they are Language, Agents, Rules and Terminals and screenshots, like the other
sections' groups.

## Routes
None.

## UI
- `settings_view.dart`: the four headings; the language field loses its own "Language" label (its heading
  names it).
- New texts: Rules, Terminals and screenshots (8 languages, appended).

## Acceptance
- `settings_layout_test.dart`: General shows the four headings in bold.
