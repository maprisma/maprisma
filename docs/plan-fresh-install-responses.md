# Responses to the reviews of plan-fresh-install.md (task 073)

## Codex, round 1 (2026-11-14), plan review — all findings checked in the code

1. **High, Control can't start /usr/local or AppImage installs** — confirmed: `src/lib.rs:13`
   (`~/.local/bin/maprisma`, else `/usr/bin/maprisma`). Plan step 1: Maprisma writes
   `launch.json` at start (`$APPIMAGE` or its executable); Control searches `~/.local/bin`, PATH,
   `launch.json`, `/usr/bin`.
2. **High, glibc baseline unproven** — confirmed: `readelf` shows `acosf@GLIBC_2.43`,
   `atan2f@GLIBC_2.43` in the applet. Plan step 4: symbol-version audit of every shipped ELF in the
   builds (Maprisma ≤ 2.34, already true; Control built in an Ubuntu 24.04 container, ≤ 2.39); the
   installer reads the archive's baseline and also catches loader version errors.
3. **High, ownership** — agreed. Receipts with SHA-256 and link targets, parsed as data; refuse
   foreign or changed files and Settings-managed installs; no `--force` over ownership; a system
   receipt must be root-owned and not writable by others.
4. **High, not atomic** — agreed. flock, same-filesystem staging, validation of the staged copy,
   `mv --exchange` or renames with rollback, old folder removed only after the receipt; refuse while
   this install's GUI runs (no live upgrade of the GUI); the watcher's exit-75 restart covers the core.
5. **High, system uninstall and user services** — agreed. System uninstall removes system files only
   and prints the per-user cleanup; user uninstall cleans its own service the way the app does
   (disable --now, remove, daemon-reload).
6. **Medium, ldd misses dependencies** — confirmed for libsqlite3/libzstd (dlopen). Essentials are
   checked (`ldconfig -p`), feature tools listed as warnings with the feature they serve.
7. **Medium, pacman coexistence** — agreed: package ownership via the package manager, foreign
   directories left alone and reported, ownership not overridable. Reverse order (package after tar)
   documented: uninstall the tar install first.
8. **Medium, desktop chosen at install time** — agreed: Control installs both integrations, each
   restricted to its session; the tray starts now only in a usable KDE/Hyprland session.
9. **Medium, VM sequence** — agreed: separate clean snapshots per scenario, plain Hyprland and uwsm,
   Control actions per install form, upgrade/uninstall, missing libraries and FUSE, system install with
   a second user, spaces/XDG dirs, assertions beyond screenshots, pinned image and recorded versions.
   Not taken now: reboot loops beyond one logout/login, concurrent installers (covered by the lock and a
   unit test of the scripts), file chooser/clipboard/notification checks beyond a smoke test.
10. **Low, facts** — corrected in the plan (tar runs in place, `WatchService`, AppImage exclusion by
    execution path, FUSE extract-and-run fallback, portal→fuse3 on Arch only).

Open questions answered as Codex suggested: per-user default and `/opt` for `--system`; refuse on
missing essentials with an explicit dependency-only override; Hyprland `exec-once` printed, never
written; portals tested, not required.

## Codex, round 2 (2026-11-14) — not CLEAN, 6 findings, all taken

1. **High, receipt as a deletion boundary** — outer paths are fixed by the mode, never read from the
   receipt; it holds only hashes for fixed names; malformed receipts remove nothing; root checks
   ownership/permissions/no symlinks of folder, parents and receipt.
2. **High, rollback incomplete** — whole transaction: outer files staged and backed up, folder swap,
   restore on failure, recovery of an interrupted run on the next one; `mv --exchange` tried on the
   real filesystem, renames as fallback.
3. **High, `/proc` check is racy** — replaced by a lock the GUI holds shared for its lifetime and the
   installer exclusively; a GUI started during an install exits with a message. Covers every user.
4. **Medium, `launch.json` trust** — reader-side checks of file, folder, executable and ancestors;
   direct exec; stated as user configuration.
5. **Medium, no-FUSE AppImage** — mode `appimage-extract`; Control adds the one fixed argument.
6. **Medium, baselines not run** — container smoke tests on Rocky 9 (glibc 2.34) and Ubuntu 24.04.
