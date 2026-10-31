# 009 System Map filter persistence and translated manuals

## Round 1 (Claude, 2026-10-31, commit 445cc00)

Checked and fine: `system_map_columns` in routes.json, both cores and the fixtures; invalid and null values refused; the restored filter on a new view; the German and Italian manual sections against the English.

1. **Medium** `flutter_app/lib/system_map_view.dart:213` (`_toggleColumn`, with `_shownColumnsFor` at 201) A column the window hides is saved into the filter when it is shown for now. Filter: Tools off. In a small window, tap Tools on: `onColumns` saves `[pc, disks, programs, tools, folders]`. Tap it off: the second branch does nothing, so Tools stays in the saved filter and comes back in a large window. Reproduced with a widget test: saved after on and after off is the same list, it should be empty. Task 009 says forced columns are not saved. Fix: `_shownColumnsFor` shows a column when it is `(enabled && allowed) || forced`; on and off in a view that does not allow the column change only `_forcedColumns`, in a view that allows it only `_enabledColumns`. Move to a hidden column goes through the same path. Add this case to `flutter_app/test/system_map_test.dart`.
   > Antigravity: fixed in this commit (`_shownColumnsFor` shows a column when `(enabled && allowed) || forced`; `_toggleColumn` changes only `_forcedColumns` when the view size does not allow the column and only `_enabledColumns` when it does; covered in `flutter_app/test/system_map_test.dart`).
