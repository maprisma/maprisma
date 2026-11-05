# 059 Programs to install on the map

Author: Claude · Reviewer: Antigravity · Branch: task/059-missing-programs

## Goal
From Uwe's screenshot note of 2026-11-05 (`maprisma-2026-11-05-10-35-55`: "i have switched on the codex addon,
but how to install it in the map"). An agent add-on that is on while its program is not on this PC showed
nowhere on the map. Its install was reachable only through Help › Agents or Ask AI. Now the map shows it
directly, in the Agents card, with a menu that installs it. The other ways stay.

## Routes
None. The GUI combines what it already has: `addons.list` (an agent add-on that is `enabled` and `loaded`,
and its `provides`) and `app.snapshot` `agents` (`installed` false). It leaves out what is already a box on
the map.

## UI
- `_mapGraph` gains `missing` (`command`, `name`, `addon`), computed in the GUI only. It never goes into
  `nodes`, edges, counts, the cache or AI help. `mapGeometry` and `mapAppearance` include it, so a change
  makes a new layout.
- `MapLayout`: the first Agents card ends with one dashed row per missing program (`MapCardLayout.missing`,
  `mapAddStep` each). There are none when the card is folded, set to used only, or empty.
- `MapMissingCard` (map_groups.dart): a download icon, then "Codex · Not installed". A click runs Install;
  ⋮ offers **Install {0}…**, **Add-on…** and **Switch off**. Main maps these to `_agentAction(command,
  'install')` (the normal review, then a terminal), `_addonMenu` and `_toggleAddon(id, false)`.
- Texts: all exist already in 8 languages.
- Manual, Expand a category: one paragraph (8 languages).

## Acceptance
- `map_layout_test.dart`: the rows come after the last box with the box's left edge and width; the card grows
  by one step per row; none in other cards, folded or used-only ones; a new `missing` is a new layout.
- `map_editor_test.dart`: the card shows. A click and the three menu items report install, details and off
  with the add-on. There is none without a handler.
- `task_cards_app_test.dart`: an enabled, loaded agent add-on whose program is not installed shows
  `card-missing-codex`. A click asks `agents.action_preview` with `install` and shows the review.
