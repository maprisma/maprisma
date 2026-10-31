# 009 System Map filter persistence and translated manuals

Author: Antigravity · Reviewer: Claude · Branch: task/009-system-map-rest

## Goal
Keep the System Map's column filters across app restarts, and bring `my-setup`, `system-map-start` and `troubleshooting` in the 7 translated manuals in step with the English manual.

## Routes
- `settings.get` and `settings.update`: result shape includes `system_map_columns: ["string"]`.

## UI
- `SystemMapView` (`flutter_app/lib/system_map_view.dart`) and `main.dart`: filter chips read and save `system_map_columns` (`['pc', 'disks', 'programs', 'tools', 'folders']`); columns forced on in a smaller window (`_forcedColumns`) stay transient.
- Manual (`docs/manual/manual*.html`, all 8 languages): `system-map-cards` says the column filters are remembered; `my-setup`, `system-map-start` and `troubleshooting` in the 7 translations match the English and are stamped; PDFs rebuilt.

## Acceptance
- `packages/maprisma_core/test/foundation_test.dart`, `tests/test_settings_schema.py`, `tests/test_flutter_backend.py`: `system_map_columns` default, saving, restoring and rejecting invalid values in both cores.
- `flutter_app/test/system_map_test.dart`: saving and restoring `system_map_columns` through the filter chips without saving forced columns.
- `docs/manual/translations.py check` exits 0 for all 7 translated manuals.
