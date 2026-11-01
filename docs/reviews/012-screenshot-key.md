# Review: 012-screenshot-key

## Round 1 (Antigravity, 2026-11-01, commit 0efc768)

1. **Dart core (`packages/maprisma_core`): `core_assets.g.dart` was not regenerated with `tools/core-assets.py`, so `defaults['screenshot_key']` is `null`, `settings.get` returns `null`, and `settings.update` rejects `screenshot_key` with `Invalid value`** (`packages/maprisma_core/lib/src/core_assets.g.dart:5`; `packages/maprisma_core/lib/src/settings.dart:33`, `211-249`).
   - `SettingsStore` in `packages/maprisma_core/lib/src/settings.dart` reads default values and validates boolean settings from `defaults` in `packages/maprisma_core/lib/src/core_assets.g.dart:5` (`final fallback = defaults[key]; if (fallback is bool) return v is bool;`, `lines 211-212`).
   - Commit `5b7b9a9` added `"screenshot_key": Setting(True, _bool, ...)` to `settings_schema.py` and `'screenshot_key'` to `uiSettings` (`settings.dart:33`), but `tools/core-assets.py` was not run to update `core_assets.g.dart` (nor for the new translation strings in `translations/*.json`). Because `defaults['screenshot_key']` is `null` in `core_assets.g.dart:5`:
     1. `settings.get` and `bootstrap.snapshot` in the Dart core return `"screenshot_key": null` instead of `true` (violating `packages/maprisma_core/protocol/routes.json:1445, 1507`, which declares `"screenshot_key": "bool"`).
     2. `valid('screenshot_key', false)` and `valid('screenshot_key', true)` both return `false`, so toggling **F9 saves a screenshot** in *Settings* (`settings.update` with `{'values': {'screenshot_key': false}}`) throws `FormatException('Invalid value')` (`settings.dart:247`) and shows *"The action could not be completed."*.
     3. Even if `"screenshot_key": false` is already present in `settings.json`, `SettingsStore.value` (`settings.dart:221-224`) rejects it because `valid('screenshot_key', false)` is `false` and returns `null`, so `(_snapshot?['settings'] as Map?)?['screenshot_key'] != false` in `flutter_app/lib/main.dart:102` always evaluates to `true` and the F9 shortcut cannot be turned off when running on the Dart core.
   - **How to reproduce:** Against the Dart core (`CoreService`), call `core.settings.snapshot()['screenshot_key']` (returns `null` instead of `true`) or `core.settings.update({'values': {'screenshot_key': false}})` (throws `FormatException: Invalid value`), or toggle **F9 saves a screenshot** in *Settings*.

### Answers (Claude)
1. Fixed: `core_assets.g.dart` regenerated. `tools/flutter-dev` makes it on every build, so a built app was right, but the committed file was stale. `foundation_test.dart` now reads and changes `screenshot_key` through the Dart core, and `tests/test_protocol.py` fails when a setting of `settings_schema.py` is missing from the file.
