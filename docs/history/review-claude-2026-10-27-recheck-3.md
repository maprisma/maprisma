# Claude third recheck of the Flutter migration, 2026-10-27 ~23:05

Checks `docs/review-claude-2026-10-27-recheck-2-responses.md` (R1–R4) against the code in this tree.
**This is a read-only review: nothing in this tree was changed except adding this file.** Checks ran on a copy
in a scratch folder. The preview binary was not started. This is still not the final Claude review from
`docs/plan-flutter.md` step 6.

## Checks run on the host (copy, not this tree)

| Check | Result |
|---|---|
| `python3 -m unittest discover -s tests -q` (all modules, incl. the 5 host-only ones) | **1271 tests OK** |
| `tools/typecheck.sh` | 0 errors, 0 warnings |
| `dart format --output=none --set-exit-if-changed lib test` | 0 changed |
| `flutter analyze --no-pub` | No issues |
| `flutter test --no-pub --timeout 60s` (as `tools/flutter-dev check`) | **22 passed, 0 failed**, ~1 s, no hang |
| `dart tools/check-flutter-transport.dart` | passed |
| `tools/profile-flutter-map.py <copy of settings> 60` | **1.3 % of one core**, 30 calls, 1 worker (unchanged by R2/R3) |

## R1–R4: status

| Item | Status | Notes |
|---|---|---|
| R1 | **Verified fixed** | Synchronous temp folder, script write and cleanup; the widget suite now completes on the host. `--timeout 60s` in `tools/flutter-dev check`. |
| R2 | **Verified fixed** | A force during a running periodic scan sets `_map_force_pending`; the next poll after it ends starts the forced scan (also with manual-only), and `pending` stays true until it ends. A force during a running forced scan is merged into it. Traced by hand: if the forced start hits the capacity limit, the flag stays set and the next poll retries; `_freshMap` gives up after 10 s. |
| R3 | **Verified fixed** | The interval is bypassed only when the scan-relevant settings (`MAP_SCAN_SETTINGS`, all valid schema keys) or the owned sessions change. Project history and `setup_done` writes no longer trigger a scan (tested). |
| R4 | Acknowledged | No change, as agreed. |

## Open findings

None blocking.

Note only (no action needed): `agent_details` also reads `warn_yellow`/`warn_red` (limit colours), which are not
in `MAP_SCAN_SETTINGS`. A change shows at the next interval scan, or on Refresh in manual-only mode, which
matches the documented behaviour. Add them to the list only if they should show at once.

## Still open (unchanged, host only)

- Rebuild the manual PDFs (`data/user-manual*.pdf` are still from 15:35).
- Desktop smoke test: GTK Asterism and the Devel preview at the same time, with care for the shared live settings.
- Final Claude review (plan step 6) once feature parity is reached. The add-on catalog/setup modules and the
  scan-settings view still need a full pass there.
