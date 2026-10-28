# Flutter appearance and map-light frame rate — response (2026-10-28)

Implemented the [requested settings](plan-flutter-appearance.md).

- Settings offers **20 fps (default), 30 fps and 60 fps** for map lights. The
  service persists and strictly validates `map_light_fps`; booleans, null,
  unsupported numbers and numeric strings are rejected before any settings write.
  Existing configurations default to 20. The clock keeps its sleeping, hidden,
  Lights-off and reduced-motion behavior. Light travel speed stays unchanged.
- Settings offers **System / Light / Dark**, with a miniature map preview and
  selected-state indicator for each choice. `flutter_theme_mode` persists
  independently of the old GTK look preference. System uses the existing desktop
  palette route, falling back to platform brightness. Explicit choices use the
  selected brightness without inheriting an incompatible desktop background.
  The preview and app share the theme factory; changes apply immediately.
- Preview controls wrap on narrow settings pages and disable while saving.
  New strings are included in all eight languages. Existing source translation
  keys, their order and their values are preserved. All eight HTML manuals and
  PDFs describe the choices.

## Cadence and the accepted performance gate

The default preserves the observed 20 fps cadence. A half-vsync timestamp
allowance lets the explicitly selected 30/60 settings reach their intended
cadence rather than losing frames to the old strict threshold. Synthetic-time
regressions cover slightly early 60 Hz ticks at all three rates, changing the
rate while running, invalid rates and disabling animation. Actual delivery
still depends on the display and renderer.

No new CPU/GPU measurement was performed, as Uwe requested. Claude's accepted
GPU results remain historical measurements of the earlier 19–21 fps version:
lights off 0.05% CPU, lights on 9.57% at zoom .53 and 9.07% at zoom 1.25,
Hyprland about 2%, GPU busy about 8%, at 3792×1958 and DPR 2. They passed the
map-editor performance gate against GTK's 8–11% reference. They do not establish
CPU costs for the optional 30/60 settings.

## Validation

- Flutter format/analyzer: clean; **89 Flutter tests pass**, including service
  integration that saves Dark/60 and verifies the app theme and map receive them.
- **1,415 Python tests pass** on a private Xvfb display, including defaults,
  persisted choices and atomic invalid-setting rejection. The suite emits
  resource warnings but exits successfully.
- Python typecheck: **0 errors, 0 warnings, 0 informations**.
- All eight manual PDFs rebuilt. The pre-existing translation-fingerprint
  warnings for `about` and `running-agents` remain; the new section is stamped.
- Source translation preservation and `git diff --check` pass.
- Isolated Devel build succeeds, without launching it:
  `.flutter-previews/preview-qie1i3w8/flutter_app/build/linux/x64/release/bundle/asterism`.

## Next migration steps

Review this settings slice alongside the existing uncommitted map-editor work.
The next suggested parity slice is online MCP/skill catalogs and tool checks,
then web skill installation. After that: remaining provider/setup/settings/help
parity, keyboard/recovery checks and clean-VM validation. Later come the planned
Omarchy integration, Linux packaging and the new thin launcher plugin
`ubruckhaus.asterism` in its own repository. macOS stays deferred until Linux is
finished and Uwe agrees. No later slice was started here.

Nothing committed, pushed or synced. No real-desktop app launch or benchmark.
