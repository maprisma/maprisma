# 067 F12 and Corners as in Maprisma Playground: reviews

## Round 1 (Antigravity, 2026-11-10, commit 7e847b4)

1. **Medium** `flutter_app/lib/test_shots.dart:181` `_posix.unlinkAt(_fd, name)` is called with two arguments, while `unlinkat` takes three (the flags are missing).
   > Author: not a bug. `unlinkAt(int dir, String name)` is the wrapper in `packages/maprisma_core/lib/src/posix_ffi.dart:384`, which calls the native `unlinkat` with three arguments, `_unlink(dir, native, 0)`. (The call is at `test_shots.dart:203`; the file has 266 lines, so the cited line 331 does not exist there.)
2. **Low** `flutter_app/test/test_shots_test.dart:119` In `WindowShots.note`, a failing `writeNew` closes the local folder handle in `finally`; the test only checks that nothing half-written is left.
   > Author: as intended: the handle belongs to that call and is closed on every path; the test checks the visible outcome (no file), which is the promise.
3. **Low** `flutter_app/lib/test_shots.dart:36` The `user-dirs.dirs` fallback is stricter than it needs to be (an absolute value equal to `$HOME` counts as no folder of its own).
   > Author: stays: the same rule as Maprisma Playground; a pictures folder equal to the home folder falls back to `~/Pictures` rather than writing into `$HOME` itself.
4. **Low** `flutter_app/lib/app_theme.dart:28` `'slight' => 6` uses a literal instead of `slightRadius`.
   > Author: stays: `slightRadius` is an `int` constant and the function returns `double?`; Dart converts the literal `6` to `double` but not the constant (`flutter analyze`: return_of_invalid_type). `'rounded' => 12` is written the same way.

CLEAN
