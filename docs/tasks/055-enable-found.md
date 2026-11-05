# 055 Everything installed is on the map at the start

Author: Claude · Reviewer: Antigravity · Branch: task/055-enable-found (on top of task/054-map-columns-online)

## Goal
Uwe, 2026-11-05: "when starting maprisma all installed agents and provider, online and offline, must be
detected and shown on the map". Until now, after first-run setup, a newly found agent, local LLM or the
online providers only showed as "N found on this PC · Expand" until switched on by hand. Uwe chose to have
his own off switch respected: an add-on he switched off is never switched on again by itself.

## Routes
- New `addons.enable_found` (change): `ids` (the add-ons setup.detect found). Switches on those that are
  verified, supported, off and not in `addons_off`; one that cannot be loaded is left out alone. Never
  switches one off. Result: the add-on snapshot and `switched_on`. Action rules: `install` per new id.
- `setup.apply`: optional `declined`, the found add-ons left unticked. They go into `addons_off`; the ones
  ticked come out of it. Result shape described (`addons`).
- `addons.set_enabled`: switching off adds the id to `addons_off`, switching on removes it.
- New setting `addons_off` (list, not shown in Settings).

## UI
- At the first snapshot, once setup is done, the GUI passes setup.detect's result to `addons.enable_found`
  and reads the map again when something was switched on. During first-run setup nothing is switched on
  (the welcome page already ticks what it found).
- Finishing setup sends `declined` = found but unticked.
- Manual, Setting up Maprisma: one paragraph (8 languages).

## Acceptance
- `packages/maprisma_core/test/enable_found_test.dart` (with the installed signed add-ons): found ones are
  switched on, switched-off ones stay off until switched on again, setup's `declined` counts as off,
  malformed requests are refused.
- `flutter_app/test/task_cards_app_test.dart`: at the start the found add-on is asked for and the map read
  again; during first-run setup nothing is asked for.
- `action_rules_test.dart`: the new route gives `install` per add-on.
