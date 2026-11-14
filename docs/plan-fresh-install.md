# Plan: Maprisma on a fresh desktop install (task 073)

Uwe, 2026-11-14: Maprisma and Maprisma Control must install on a **fresh** COSMIC, KDE Plasma and
Hyprland (+ Quickshell) system from GitHub releases only: the **.tar.gz** or the **AppImage**. The AUR
is not available for now. Codex reviews this plan and every step (round 1:
`plan-fresh-install-responses.md`); nothing is pushed, tagged, released or uploaded until Uwe says so
(AGENTS.md). Release *preparation* only: artifacts in `dist/`, release notes as files.

## Facts (checked 2026-11-14 on v0.14.5)

- Release assets: `maprisma-0.14.5-x86_64.tar.gz` (+ .sha256), `Maprisma-0.14.5-x86_64.AppImage`
  (+ .sha256). Not on the AUR. The tar.gz has `app/` (bundle, `app/maprisma` runs from where it is
  unpacked), `share/`, `LICENSE`, but **no installer**: no menu entry, no command, no icon.
- The bundle links GTK 3 (+ glib2, pango, cairo, at-spi2-core …) from the system; the AppImage does not
  carry it either. No COSMIC, Plasma or Hyprland package depends on gtk3: a minimal install may lack it.
- The core also **dlopens** `libsqlite3.so.0` (usage readers, `sqlite_numbers.dart:94`) and
  `libzstd.so.1` (compressed sessions, `session_readers.dart:347`): `ldd` does not show them.
- Highest glibc symbol versions: Maprisma bundle 2.34 (built on CachyOS, glibc 2.44); Control's
  `maprisma-applet` **2.43** (`acosf`, `atan2f`), the tray 2.39. A host build proves nothing: each
  shipped ELF gets a symbol-version audit against a baseline.
- AppImage (type2 runtime 20251108): mounts with `fusermount3`; without FUSE it can still run with
  `--appimage-extract-and-run`. On Arch, xdg-desktop-portal depends on fuse3 (COSMIC and Plasma pull
  the portal in; a bare Hyprland may not).
- No Nerd Font needed: glyphs are SVGs in the bundle (`tools/make-glyph-icons.py`). README is wrong.
- Providers user service: `WatchService.binary` (`provider_watch.dart:818`) only for a core at an
  absolute path named maprisma-core outside /tmp, /var/tmp, TMPDIR, previews and build folders. A tar
  install under `~/.local/lib` or `/opt` qualifies; an AppImage run from its `/tmp/.mount_*` does not
  (an extracted one elsewhere would). The unit is per user (`~/.config/systemd/user`), enabled and
  started by the app; a binary change makes the watcher exit 75 and systemd restart it.
- **Maprisma Control** (`/mnt/Data/Projects/maprisma-applet`, public `maprisma/control`, v0.2.0, no
  release): `maprisma-applet` (COSMIC applet; `--window` opens the same UI as a window, used by the
  tray's "Open Control") and `maprisma-control-tray` (StatusNotifierItem; needs the session bus and an
  `org.kde.StatusNotifierWatcher`). It starts Maprisma from `~/.local/bin/maprisma` or else
  `/usr/bin/maprisma` only (`src/lib.rs:13`): it **cannot** start an /opt install or an AppImage.
  `install.sh` builds with cargo. Maprisma Settings installs the same Control files with its own
  receipts (`maprisma-settings` catalog).
- Runtime tools by feature (not install blockers; reported, never assumed): `curl` + CA certificates
  (downloads), `tar`/`gzip`/`zstd` (provider archives), `setsid` (subprocess runner), `xdg-open` (links,
  manual), `notify-send` + a notification service (limit warnings), `wl-paste` (terminal paste), a
  terminal (agent terminals), `pw-record`/`arecord`/`ffmpeg` (dictation), `ss` (traffic view).

## Steps

1. **Launch path for Control** (Maprisma GUI + Control):
   - Maprisma writes, at every start, `$XDG_STATE_HOME/maprisma/launch.json` (0600, atomic, folder
     0700): `{"exec": "<absolute path>", "mode": "bundle|appimage|appimage-extract"}`: `$APPIMAGE` when
     set and a regular file (`appimage-extract` when it runs extracted: `APPIMAGE_EXTRACT_AND_RUN=1` or
     `$APPDIR` under `appimage_extracted_`), else its own executable. User launch configuration, never a
     privileged source.
   - Control `binary()`: `~/.local/bin/maprisma` → `maprisma` on `PATH` → `launch.json` → `/usr/bin`.
     `launch.json` only when it is a regular file (no symlink), owned by the user, not group/other
     writable, in a folder owned by the user; `exec` only when absolute, a regular executable file owned
     by the user or root, not group/other writable, and no ancestor folder writable by others (except
     root-owned sticky ones). Started directly (no shell, as now, `lib.rs:135`); `appimage-extract` adds the
     one fixed first argument `--appimage-extract-and-run` (Start and Toggle). Tests for each rule.
2. **Maprisma tar.gz installer** (`packaging/install.sh`, `packaging/uninstall.sh`, copied into the archive
   by `tools/build-release.py`):
   - Per user by default (no root): `~/.local/lib/maprisma/`, link `~/.local/bin/maprisma`, desktop
     entry (absolute, quoted Exec + TryExec + `X-Maprisma-Install=<folder>`), metainfo, icon.
     `--system` (root only): `/opt/maprisma`, `/usr/local/bin`, `/usr/local/share`.
   - **Checks first, nothing written before they pass**: x86_64; glibc ≥ the bundle's highest symbol
     version (a `glibc` file the build writes into the archive); `ldd` of every ELF for "not found" **and**
     loader version errors; `ldconfig -p` for the dlopened libsqlite3.so.0 and libzstd.so.1. Missing
     essentials → refuse, naming the package for the distribution (`/etc/os-release`).
     `--ignore-missing` installs anyway (dependencies only).
   - **Fixed paths, never read from a file**: the four outer files (command link, desktop entry,
     metainfo, icon) are derived from the mode (user/system and XDG_DATA_HOME); the receipt
     `<folder>/.install-receipt` only holds `name<TAB>sha256` (or the link target) for those fixed names.
     Unknown names, duplicates, tabs/newlines → the receipt is invalid and nothing is removed. Root
     acts only when the folder, its parent chain and the receipt are root-owned regular files/folders,
     not group/other writable, no symlinks.
   - **Ownership, never overridable**: refuse when a target exists and is not ours (no receipt, or the
     hash differs); refuse when a package owns Maprisma (`pacman -Qqo`, `dpkg -S`, `rpm -qf` of
     `/usr/lib/maprisma/maprisma`) or Maprisma Settings has a receipt for `maprisma`. A non-package
     `/usr/lib/maprisma` is reported and left alone.
   - **Running GUI, by lock**: the GUI holds a shared `flock` on `<bundle>/data/instance.lock` (opened
     read-only; works in a root-owned folder) for its lifetime; when it can't take it (an install holds
     it exclusively) it says "Maprisma is being installed — start it again in a moment" and exits. The
     installer takes it exclusively (non-blocking) for the whole transaction: refused while any user's
     Maprisma of this install runs. No `/proc` scan.
   - **Transaction** (with the installer lock `<parent>/.maprisma-install.lock`): stage the bundle with
     its new receipt in `<folder>.new.XXXX` (same filesystem) and check it (ldd, `maprisma-core --version`);
     write new outer files to temp names beside their targets and back the old ones up; swap the folder
     (`mv --exchange` if it succeeds on this filesystem, else two renames); rename the outer files in; on
     any failure restore folder and outer files. Old folder and backups go last. A later run finds a
     leftover `<folder>.old.*`/`.new.*` (interrupted) and restores the complete old state, or finishes the
     new one when its receipt matches. The watcher's exit-75 restart covers the providers core.
   - **Uninstall**: same locks; removes an outer file only when it still matches the receipt; keeps
     changed ones and says so; user install: also this user's providers service when its ExecStart is
     this install's core (disable --now, remove, daemon-reload); `--system`: system files only, prints the
     per-user service cleanup. `--purge` (user only) removes `~/.config|.local/share|.cache|.local/state/
     maprisma` after listing them.
   - Feature tools (see Facts) are listed as warnings after a successful install.
   - Version 0.14.6.
3. **AppImage**: stays portable. README: `chmod +x`, needs gtk3, sqlite, zstd (and FUSE or
   `--appimage-extract-and-run`); Control finds it through `launch.json` after its first start; no
   providers service (use the tar.gz for that). The build gets the same glibc audit.
4. **Build baselines**: Maprisma bundle ≤ glibc 2.34 (audit in `tools/check-bundle.py`, fails the build
   when exceeded). Control is built in a container (`podman`, Ubuntu 24.04, glibc 2.39) by
   `tools/build-release` in maprisma-applet; audit ≤ 2.39.
5. **Maprisma Control prebuilt release**: `maprisma-control-<version>-x86_64.tar.gz` with `bin/`,
   `share/` and `install.sh`/`uninstall.sh` that copy (no cargo), same receipt/ownership/lock rules
   (refuse files from Maprisma Settings' Control install). Installs **both** integrations, each limited
   to its session: the COSMIC applet entry (shown only in COSMIC's applet list) and the tray autostart
   (`OnlyShowIn=KDE;Hyprland;`). Starts the tray now only in a running KDE/Hyprland session with a session
   bus. Hyprland: prints an absolute, quoted `exec-once` line (Lua and hyprlang form) for sessions that do
   not run XDG autostart; never edits the user's config. Needs a bar with an SNI tray. Version 0.2.1.
6. **READMEs**: Maprisma "Install" rewritten (AppImage, tar.gz user/system, requirements per
   distribution, feature tools, bar icon = Control, pacman/Settings coexistence: remove the tar install
   before switching, no Nerd Font). Control README "Install from a release".
7. **Fresh-VM tests** (qemu + KVM; Arch Linux cloud image pinned by date + SHA-256; package versions
   recorded; virtio-gpu with software rendering): VMs `cosmic`, `plasma`, `hyprland-uwsm`,
   `hyprland-plain` (Quickshell bar with SystemTray). Each scenario starts from the clean snapshot:
   (a) tar.gz user install: refusal without gtk3 (nothing written), install after gtk3, start, providers
   service, upgrade 0.14.5→0.14.6 tar, uninstall (receipt honoured, edited file kept); (b) AppImage alone
   (with and without fuse3); (c) Control on top of (a) and of (b): applet/tray shown, Start/Stop/Toggle/
   Open Control; logout/login autostart; (d) `--system` install + a second user; (e) paths with spaces /
   custom XDG dirs. Assertions on exit codes, logs and files, plus QMP screenshots of the rendered window.
   **Baseline containers** (podman): the Maprisma bundle on Rocky Linux 9 (glibc 2.34) — ldd, core
   `--version`, the window under Xvfb; both Control binaries on Ubuntu 24.04 — ldd, tray with a session
   bus, `maprisma-applet --window` under Xvfb.
   Results: `docs/history/fresh-install-vms.md`.
8. **Release preparation**: artifacts + SHA-256 in `dist/`, notes `docs/releases/v0.14.6.md` and in
   Control `docs/releases/v0.2.1.md`. Uwe publishes.
