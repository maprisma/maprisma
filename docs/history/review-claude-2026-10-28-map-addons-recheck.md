# Claude recheck of A1–A5, 2026-10-28

Checks `docs/review-claude-2026-10-28-map-addons-responses.md` against the code in this tree. **This is a read-only
review: nothing in this tree was changed except adding this file.** Checks ran on a copy. The preview binary was
not started, and no add-on was switched, installed or removed.

## Checks run on the host (copy, not this tree)

| Check | Result |
|---|---|
| `python3 -m unittest discover -s tests -q` (all modules, incl. the 5 host-only ones) | **1376 tests OK** |
| `tests.test_terminal_sessions` repeated | **10/10 OK** (A4) |
| `tools/typecheck.sh` | 0 errors, 0 warnings |
| `dart format` / `flutter analyze --no-pub` | 0 changed / No issues |
| `flutter test --no-pub --timeout 60s` | **35 passed, 0 failed**: the first fully green host widget run since the System Map work |
| `dart tools/check-flutter-transport.dart` | passed |
| AI Map CPU (`tools/profile-flutter-map.py`, 60 s) | **1.3 % of one core** (unchanged) |

## A1–A5: status

| Item | Status | Notes |
|---|---|---|
| A1 | **Verified fixed** | `guard_addon_changes()` (`flutter_backend.py:622`) checks only owned sessions and running installs; `provider_watch` is no longer queried. The Claude/Codex processes running on this PC no longer block add-on changes. |
| A2 | **Verified fixed (host)** | `onDoubleTap` is gone from `MapGroupCard`; `map_groups_test.dart` passes with `pumpAndSettle`. |
| A3 | **Accepted** | The removal preview says it also removes the add-on from GTK, and the catalog confirmation says the same for installs. Backup pruning (30 days, ≤200 entries, 32-hex directories owned by the user, active Undo backups excluded) runs only after a confirmed removal. On Linux, `rename` updates the moved directory's ctime, so `max(mtime, ctime)` dates a backup from its removal, as intended. Only this module uses `addon-backups/`. |
| A4 | **Verified fixed** | Reads `/proc/<pid>/stat` directly and treats `FileNotFoundError`/`ProcessLookupError` as gone; 10/10 runs. |
| A5 | **Accepted** | Wiring as described; covered by the new widget test, which passes on the host. |

## Open findings

None.

## Still open (host)

- **Desktop smoke test:** run the Devel preview. Check first start (four dummies, Agents focus, Switch on / Later),
  group expand and collapse with the real mouse and keyboard, idle CPU with a group expanded, the System Map groups,
  and add-on removal plus Undo with a throwaway user add-on.
- **Manual:** rebuild the PDFs. The `about`/`running-agents` fingerprint drift is still unresolved.
- **Final review:** the final Claude review at feature parity.
