# 054 Even column gaps, plan limits outside Omarchy

Author: Claude · Reviewer: Antigravity · Branch: task/054-map-columns-online

## Goal
From Uwe's screenshot note of 2026-11-05 (`maprisma-2026-11-05-03-35-54`):

1. The map's columns in a wide window sit in the middle with the same gap left of the first column,
   between the columns and right of the last one. Before, the edges kept 16 px and all the room went
   between the columns.
2. Online providers and models were missing on the map. Cause: the `providers-online` add-on was off in
   Uwe's settings, so the core hid them (`hiddenProviders`). No code change; switched on in his
   settings through `addons.set_enabled`.
3. No battery (plan limits) on an agent's card on COSMIC. The Dart port read usage records on Omarchy
   only, while the Python reference (`desktop_generic.has_usage_collector`) also uses Omarchy's records
   on another desktop. Now a desktop other than Omarchy uses Omarchy's collector
   (`omarchy-agent-usage-<agent>`) when it is in Omarchy's bin folder, /usr/bin or on PATH. Without
   OMARCHY_PATH the core runs the collector itself and writes what it prints (one JSON object, at most
   4 MiB) to `~/.local/state/omarchy/agents/usage/<agent>.json`. Maprisma still reads no credential
   file: the collector does, as it does on Omarchy.

## Routes
None changed. `agents.usage_refresh` and `map.badges` now give results on other desktops too.

## UI
- `map_layout.dart`: an even share of the free width (`(width - columns) / (count + 1)`) as the gap,
  never less than the old gap or 140 px, whichever is smaller. A narrow window stays as it was.
  Line hooks therefore keep their room.
- Manual, Costs in the Flutter preview: where the limits come from (8 languages).

## Acceptance
- `flutter_app/test/map_layout_test.dart`: the same gap left, between and right for 2, 3 and 4 columns
  in a wide window; `map_editor_test.dart` unchanged and green.
- `packages/maprisma_core/test/usage_refresh_test.dart`: a generic desktop with a collector on PATH
  writes the record, and ignores output that is not JSON or a failed run; no collector, no record.
