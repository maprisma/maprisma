# 057 Settings: sections on the left, Find in Settings

Author: Claude · Reviewer: Antigravity · Branch: task/057-settings-layout (on top of task/056-add-cards)

## Goal
Uwe, 2026-11-05, with a screenshot of a mail program's settings: "take this layout for maprisma setting
page". Settings was one long column of cards. Now the sections are a list on the left (General,
Appearance, Map, Agents, Local LLMs, Dictation, Recent changes), the chosen one's groups are on the right
under bold headings, and **Find in Settings** above them shows the groups of every section that mention
what is typed.

## Routes
None.

## UI
- `settings_view.dart`: every existing control unchanged. Each `_Heading` names its section; the texts a
  group shows are recorded while it is built (`_t`) and are what Find in Settings searches (translated).
  The last section chosen is kept while the app runs. `SettingsView.section` opens one ('all': every
  group at once, which the tests use).
- New texts: Appearance, Find in Settings, No setting matches “{0}” (8 languages, appended).
- Manual, Settings: one sentence (8 languages).

## Acceptance
- `settings_layout_test.dart`: a section shows only its groups; the chosen one is marked; a search finds
  Notify when red under Agents › Costs from General; no match says so; Clear goes back.
- The other Settings tests pass, scrolling the page's own list (`settings-content`); accessibility
  (both themes) passes.
