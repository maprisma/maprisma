# Task-card implementation response — 2026-10-28

Scope: Flutter UI and its service metadata in `/mnt/Data/Projects/asterism-flutter`.
The original GTK checkout and live plugin were not changed. No commit, live launch,
sync, install or publication was performed.

## Plan steps

1. **Service anchors:** `flutter_task_focus.resolve` maps validated operation
   parameters and registered add-on `provides` metadata onto existing IDs from
   `Service._map_result`. Dispatch enriches connection and agent previews, model
   and add-on removal previews, provider starts, runtime review records and connection snapshots. Signed
   catalog entries receive focus in the existing worker-finalization callback.
   This uses no new scans, credentials, command execution or network requests.
   Unknown/unrepresented components deliberately return an empty list.
2. **Focused graph:** `task_focus.dart` keeps the original seeds plus one hop in
   either direction, includes their edges, compacts columns and preserves labels
   and original facts without mutating the source graph.
3. **Read-only map:** `AgentMap` now supports `readOnly` and `anchors`. Its task
   variant has no interactive viewer, groups, active taps, menus or drag targets.
   It fits to the available area and paints static primary-colour anchor curves.
4. **Frame:** `TaskCardSpec`/`TaskHost` provide themed half/full cards, matching
   anchor dots, Back/Esc and the 900-logical-pixel fallback. Empty focus uses full.
5. **Runner:** `TaskProgress` replaces `ProviderTaskDialog`; all five former
   dialog call sites use `_runTask`. Polling, cancellation and service handles stay
   the same. Running tasks are nonclosable and retain `_taskActive` protection.
   A GlobalKey preserves the polling state when focus arrives or the window
   switches between half/full layouts; a subprocess-backed regression checks
   that the operation starts exactly once.
6. **Reviews/results:** Connection, agent, model removal and add-on reviews are
   widgets with explicit confirm/cancel callbacks. Sign-in method selection is
   inline too. Review, progress and result share the host. Direct synchronous
   changes show a guarded progress frame while awaiting their reply. Undo is on
   the result card where supported, with repeat activation and close guarded
   while Undo runs. External installers report that the terminal must finish,
   rather than claiming installation completion. Terminal sign-in/test still
   opens the existing terminal view, as specified.
7. **Views:** The all-runtimes Providers overview uses a full-card spec;
   Connections uses a half-card spec (the all-connections overview has no anchors
   and falls back to full). Per-runtime actions use their service-supplied focus.
   ModelBrowser, MapAddonsFocus and FirstAgentView are full cards. Model-name
   input is inline. The three underlying view booleans became one retained route;
   active task state is one `_card` spec. The source ternary still selects
   underlying view widgets so their existing data/refresh callbacks are retained.
   Explicit refresh after completion rebuilds the focused map from fresh graph
   facts. Main-map transform/focus/category remain external and unchanged.
8. **Checks:** See validation below. Tests cover graph focus, read-only interaction,
   card width/fallback, close guards, review consent and task lifetime through
   responsive reparenting. Existing provider/connection/review tests use cards.
9. **Docs/text:** Added the task-card manual chapter in all eight languages,
   stamped that new chapter, rebuilt all eight PDFs, updated layout guidance and
   the Flutter checklist. Success/cancel labels are included in all eight Flutter
   assets; the seven source translation files preserve existing order/values.

## Validation

- Full Python suite: **1,381 tests passed**, including host-only modules.
- `UV_OFFLINE=1 tools/typecheck.sh`: **0 errors, 0 warnings**.
- Final `tools/flutter-dev check`: format/analyzer clean; **43 tests passed**,
  including the subprocess-backed lifecycle regression.
- `dart tools/check-flutter-transport.dart`: passed.
- Final native Linux Devel build succeeded, without launching or installing it:
  `/mnt/Data/Projects/asterism-flutter/.flutter-previews/preview-8m7ft_h3/flutter_app/build/linux/x64/release/bundle/asterism`.
- All eight manual PDFs rebuilt with the existing Chromium/pdfcraft toolchain.
  `pdftotext` confirms the new chapter is present in the English deliverable.

## Remaining verification / existing limits

The existing manual fingerprint drift in `about` and `running-agents` remains
reported by `docs/manual/translations.py check` in seven translations. The new
`task-cards` chapter is current and all markup checks pass. No blanket stamping
of unrelated sections was performed.

No real installer, download, model removal, add-on change or AI request was run.
Desktop appearance/interaction review and final Claude review remain external
validation; only widget tests and the isolated Devel build were used. Existing
System Map consent/details dialogs, Settings, terminals, usage and subagent
details keep their current flows; its worker progress now uses full task cards.
The overall Flutter migration remains in progress.
