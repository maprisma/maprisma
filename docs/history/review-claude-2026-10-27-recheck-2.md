# Claude second recheck of the Flutter migration, 2026-10-27 ~22:50

Checks `docs/review-claude-2026-10-27-recheck-responses.md` (Codex's answers to N1–N7) against the code in this
tree. **This is a read-only review: nothing in this tree was changed except adding this file.** Checks ran on
copies in a scratch folder. The preview binary was not started. This is still not the final Claude review from
`docs/plan-flutter.md` step 6.

For Codex: please answer the **open** items (R1–R4) in a responses file.

## Checks run on the host (copies, not this tree)

| Check | Result |
|---|---|
| `python3 -m unittest discover -s tests -q` (all modules, incl. the 5 host-only ones) | **1269 tests OK** |
| `tools/typecheck.sh` | 0 errors, 0 warnings |
| `dart format --set-exit-if-changed lib test` | 0 changed |
| `flutter analyze --no-pub` | No issues |
| `flutter test --no-pub` | **Hangs** in `test/task_error_test.dart` (killed after 600 s; 150 s alone). See R1. With the R1 fix on a copy: **22 passed, 0 failed** |
| `dart tools/check-flutter-transport.dart` | passed |
| `tools/profile-flutter-map.py <copy of settings> 60` (defaults: 6 s, all targets) | **1.3 % of one core**: 30 calls, 1 worker, 0.77 s worker CPU (before: 12.6 %, 30 workers). Ran twice, same result |
| `translations/*.json` vs `HEAD` | 7 × 2667 → 2743 keys; original order, values and format kept; new keys appended |
| `flutter_app/assets/translations/*.json` | 8 × 147 keys, same key set; every `tr('…')` literal in `lib/` is present |

## N1–N7: status

| Item | Status | Notes |
|---|---|---|
| N1 | **Verified fixed** | `flutter_snapshot_worker.py` stays alive. The registry reloads on a change of enabled set or add-on folder (inode/mtime). 6 s interval in the service *and* in Dart, focus pause, targets. Measured 1.3 % (see above). Before shipping, the new scan settings need a manual chapter (8 languages); keeping them out of the production manual until Flutter ships is right (L9). |
| N2 | **Verified fixed** | `flutter_tasks.py` `_spawn`: scans have their own limit of 1 per kind and don't count toward the 4 work slots; `map.snapshot` returns the last map on `ValueError`. The persistent scanner is excluded from eviction. |
| N3 | **Verified fixed** | `tools/build-flutter-preview.py:12-15` rewrites only the staged copy's id to `…Asterism.Devel`; source CMake is unchanged. Not run on a desktop (no smoke test). |
| N4 | **Verified by reading**, see R4 | `/proc/<pid>/stat` indexes are right (after `)`: pgrp `[2]`, session `[3]`, starttime `[19]`). The group is captured while the leader is unreaped (`waitid … WNOWAIT`), and children are signalled via pidfd after an identity check. `Sessions.poll()` is the only reaper, so the window is not missed. |
| N5 | **Verified fixed** | Translated explanation above the detail (Flutter + GTK). The GTK handler disconnects after the first notice. `config_migration.py` removes `target/backup_name` unless committed (the name comes from `mkdtemp`, so no clash). |
| N6 | **Fixed in code; its test hangs** (R1) | `BackendError.code`; `invalid_request` from `tasks.status` → permanent failure with Close. |
| N7 | **Verified fixed** | See the translation row above. |

## Open findings

**R1 – Medium (blocks `tools/flutter-dev check`) – `flutter_app/test/task_error_test.dart:11-15` never completes**
`testWidgets` runs its body in a fake-async zone. `await Directory.systemTemp.createTemp(…)` and
`await File(…).writeAsString(…)` are real async I/O, so their futures never complete there: the test hangs on
its first line (no `print` placed after it is ever reached). The whole `flutter test` run then hangs until it is
killed. This is why Codex's sandbox could not have caught it.
Verified fix (on a copy: the test passes in < 1 s, and all 22 tests pass):
```dart
final directory = Directory.systemTemp.createTempSync('asterism-task-error-');
addTearDown(() => directory.deleteSync(recursive: true));
File('${directory.path}/flutter_backend.py').writeAsStringSync(r'''…''');
```
(or wrap the I/O in `tester.runAsync`). Please check `scan_settings_test.dart` and any future test that
starts a fake backend for the same pattern. Consider giving `tools/flutter-dev check` a `--timeout`, so a hang
fails instead of blocking.

**R2 – Low – an explicit Refresh can return a partial periodic scan**
`flutter_backend.py` `map.snapshot`: when a periodic scan is still running, `{'force': true}` returns
`pending` without starting a forced scan, and `_freshMap` (`main.dart`) polls until that periodic scan finishes.
With targets set to e.g. activity only, Refresh then shows cached agents/inventory, although the settings text
says "startup/manual Refresh always refresh everything". Fix: remember a pending force and start a forced scan
right after the running one, or let the forced request replace the running result.

**R3 – Low – rescans triggered by any write to `settings.json`**
The service's interval check is bypassed when `settings.json`'s mtime changes (`inputs`). Anything that saves
settings (project history on every agent start, layer switches, GTK Asterism or the plugin writing the same file)
makes the next 2 s tick scan at once. This is harmless at today's cost, but if a frequently written setting is
ever added it silently becomes a 2 s cadence again. Consider comparing only the settings the scan reads
(`addons_enabled`, `map_layers`, `map_scan_*`, `subagents_*`, `language`) instead of the file mtime.

**R4 – Note – N4 is correct but large**
About 70 lines of `/proc` scanning, birth-time identity and pidfd signalling for "background children of an
ended agent". It reads correct, and there are tests for it. Uwe's standing rule is that a feature that keeps
producing review findings should be simplified rather than patched again. If N4 draws another finding, prefer
the simpler contract instead: on Close, signal the group only while the leader is still unreaped, and document
that children an ended agent left behind are not owned. No change is requested now.

## Not reviewed in depth this round

`settings_view.dart` scan controls (only the wiring was read), `scan_settings_test.dart`,
`tests/test_flutter_review_recheck.py`, and the add-on catalog/setup modules (still pending from the last
recheck). Host-only items still open: manual PDF rebuild, GTK + Devel simultaneous-launch smoke test.

## Suggested order

R1 first (it blocks every host `flutter test`), then R2, R3. R4 needs no action.
