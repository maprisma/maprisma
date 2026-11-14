# Fresh-install VM tests (task 073, step 7), 2026-11-14

Test builds: `maprisma-0.14.5-x86_64.tar.gz`, `Maprisma-0.14.5-x86_64.AppImage` (new installers, version
string still 0.14.5) and `maprisma-control-0.2.1-x86_64.tar.gz`, all from `dist/` as of 10:48.

**Setup.** `/mnt/Data/VMs/fresh-install` (see its README): Arch Linux cloud image v20261101.620452,
`pacman -Syu` on 2026-11-14 (kernel 7.3.4), then only the desktop. VMs `cosmic` (cosmic 1.11.0),
`plasma` (plasma-desktop 6.8.2), `hyprland-uwsm` (Hyprland 0.57.2 + uwsm 0.27.2 + Quickshell 0.3.2 tray
bar), `hyprland-plain` (same, started without uwsm). 4 vCPU, 6 GB, virtio-vga-gl (virgl on the host
GPU), headless. Package lists: `/mnt/Data/VMs/fresh-install/<vm>/packages.txt`.

**Method.** Every scenario started from a fresh overlay of the clean snapshot (`vm.sh start <vm> --fresh`),
user `tester`, autologin into the graphical session. GUI programs and the installers were started over
ssh inside the session's environment (WAYLAND_DISPLAY, XDG_RUNTIME_DIR, DBUS_SESSION_BUS_ADDRESS,
XDG_CURRENT_DESKTOP, HYPRLAND_INSTANCE_SIGNATURE … taken from the session's panel/shell process),
detached with `setsid`. Screenshots: `/mnt/Data/VMs/fresh-install/results/<vm>-<scenario>.png`.
Scripts and full logs: `/mnt/Data/VMs/fresh-install/build/t073/` (`a.sh`, `b.sh`, `c.sh`, `d.sh`,
`logs/*.log`). Not tested here: the 0.14.5→0.14.6 upgrade with a changed outer file, paths with spaces
and custom XDG directories (step 7 e), the baseline containers.

## Summary

| Scenario | cosmic | plasma | hyprland-uwsm | hyprland-plain |
|---|---|---|---|---|
| A refusal without gtk3 | n/a (gtk3 present, installed directly) | **pass** | **pass** | **pass** |
| A … nothing written | n/a | **fail** (lock file, see P1) | **fail** (P1) | **fail** (P1) |
| A install after libraries | pass | pass | pass | pass |
| A start, window, launch.json, menu entry | pass | pass | pass | pass |
| A reinstall, no leftovers | pass | pass | pass | pass |
| A refuse while running, then retry | pass | pass | pass | pass |
| A uninstall | pass (lock file stays, P1) | pass (P1) | pass (P1) | pass (P1) |
| B AppImage (fuse3) | pass | pass | pass | pass |
| B without fuse3 / extract-and-run | – | – | – | pass |
| C on A: install both integrations | pass | pass | pass | pass |
| C on A: tray / applet shown | pass (applet in panel) | pass | pass | pass |
| C on A: Start/Toggle/Stop via tray D-Bus | – (see C on B) | pass | pass | pass |
| C on A: autostart after re-login | – | pass | pass | pass (not started, as expected) |
| C on B: Start from launch.json (AppImage) | pass (VNC click in applet) | pass | pass | pass |
| C uninstall | **partial** (applet keeps running, P3) | pass | pass | pass |
| D `--system` + second user | – | pass (message bug P2) | – | – |

## What `install.sh` asked for

The hint line is the same on every Arch system: `sudo pacman -S --needed gtk3 sqlite zstd libglvnd`;
the missing list differs:

| VM | `✗ missing libraries:` | pacman actually installed (with `--needed`) |
|---|---|---|
| cosmic | – (first run installed) | nothing (gtk3, sqlite, zstd, libglvnd already there) |
| plasma | `libgdk-3.so.0 libgtk-3.so.0` | gtk3 + 13 deps (76 MiB): adwaita-cursors, adwaita-icon-theme(-legacy), desktop-file-utils, glib-networking, gtk-update-icon-cache, libcloudproviders, libcolord, libsoup3, libxcomposite, libxdamage, libxinerama, tinysparql |
| hyprland-uwsm | `libatk-1.0.so.0 libgdk-3.so.0 libgtk-3.so.0` | gtk3 + 20 deps (95 MiB), among them **adwaita-fonts**, at-spi2-core, dconf, gsettings-desktop-schemas |
| hyprland-plain | same as hyprland-uwsm | same as hyprland-uwsm |

**Fonts on Hyprland:** the "No font is installed" warning did **not** appear: gtk3 pulls in
`adwaita-fonts`, so after installing what install.sh asked for, `fc-list` is no longer empty and Maprisma's
text renders (see `hyprland-plain-A.png`). noto-fonts was **not needed** and not installed. (The
Quickshell bar keeps showing boxes because it started before any font existed.)

## A — archive, per user

Per VM: `~/Downloads/maprisma-0.14.5`, `./install.sh` → libraries → `./install.sh` → start → reinstall →
running-refusal → uninstall. Logs: `build/t073/logs/A-<vm>.log`.

**A1 first run** (plasma; both Hyprland VMs identical except the list above):

```
Maprisma 0.14.5: checking this system
  ✗ missing libraries: libgdk-3.so.0 libgtk-3.so.0
    Install them with:  sudo pacman -S --needed gtk3 sqlite zstd libglvnd
Nothing was installed. Install the libraries, or install anyway with --ignore-missing.
INSTALL_EXIT=1
--- new paths after first install.sh:
/home/tester/.local/lib
/home/tester/.local/lib/.maprisma-install.lock
```

The bundle, command, menu entry, metainfo and icon were not written, but the refusal **created
`~/.local/lib/` and `~/.local/lib/.maprisma-install.lock`** (P1). cosmic: the first run installed
directly (exit 0).

**A3 install after the libraries** (all four): `Done: Maprisma 0.14.5 is in your app menu.`, exit 0, then
`Start it from the menu or with: /home/tester/.local/lib/maprisma/maprisma (/home/tester/.local/bin is not
in your PATH)` (Arch's default bash has no ~/.local/bin in PATH), warnings `! notify-send is not installed`
and `! wl-paste is not installed`.

**A4 start in the session** (`~/.local/bin/maprisma`), after 18 s, all four:

| check | result (identical on all VMs) |
|---|---|
| process | `/home/tester/.local/bin/maprisma` running after 18 s |
| window | Hyprland: `hyprctl clients` → `class: com.maprisma.Maprisma`, `title: Maprisma`, `mapped: 1`; cosmic/plasma: screenshot |
| launch.json | `{"exec":"/home/tester/.local/lib/maprisma/maprisma","mode":"bundle"}`, `600 tester`, folder `700` |
| menu entry | `Exec="/home/tester/.local/lib/maprisma/maprisma"`, `TryExec=/home/tester/.local/lib/maprisma/maprisma`, `X-Maprisma-Install=/home/tester/.local/lib/maprisma` |
| providers service | not created within 18 s (`maprisma-providers.service: not-found`), see O1 |

Screenshots: `results/cosmic-A.png`, `results/plasma-A.png`, `results/hyprland-uwsm-A.png`,
`results/hyprland-plain-A.png` (welcome page with the agent list; virgl renders it, Flutter uses Impeller
OpenGLES).

**A5 close + reinstall:** `pkill -x maprisma` → `REINSTALL_EXIT=0`; leftovers search (`*.old.*`,
`*.new.*`, `.maprisma-backup.*`, `.maprisma-new.*`, `*.journal*`) under ~/.local: none, on all four.

**A6 running refusal:** with Maprisma running,
`Maprisma: Maprisma is running (for you or another user): close it first; nothing was changed`,
`INSTALL_WHILE_RUNNING_EXIT=1`; after `pkill` → `INSTALL_AFTER_CLOSE_EXIT=0`. All four.

**A7 uninstall** (`~/.local/lib/maprisma/uninstall.sh`): `Maprisma was removed. Your settings stay in
~/.config/maprisma (--purge removes them).`, exit 0; `~/.local/bin/maprisma`, the desktop file, the
metainfo, the icon and `~/.local/lib/maprisma` are gone on all four. Left behind:
`~/.local/lib/.maprisma-install.lock` (P1).

## B — AppImage alone

Fresh overlay, `sudo pacman -S --needed gtk3 sqlite zstd libglvnd` (no fonts needed, see above), AppImage
in `~/Downloads`, `chmod +x`, started in the session. Logs: `build/t073/logs/B-<vm>.log`.

| check | cosmic | plasma | hyprland-uwsm | hyprland-plain |
|---|---|---|---|---|
| running after 18 s | `/tmp/.mount_MaprisOAHLpK/usr/lib/maprisma/maprisma` | `/tmp/.mount_MaprisFLDNCP/…` | `/tmp/.mount_MaprisCCLElb/…` | `/tmp/.mount_MaprisoPoCgB/…` |
| window | `cosmic-B.png` | `plasma-B.png` | hyprctl: Maprisma, mapped 1; `hyprland-uwsm-B.png` | hyprctl: mapped 1; `hyprland-plain-B.png` |
| launch.json | `{"exec":"/home/tester/Downloads/Maprisma-0.14.5-x86_64.AppImage","mode":"appimage"}`, 0600 — on all four |
| menu entry / providers unit | none (as documented) — on all four |

**Without fuse3** (hyprland-plain, `sudo pacman -Rdd fuse3`; afterwards neither `fusermount3` nor
`fusermount` exists):

```
PLAIN_START_EXIT=127
Error: No suitable fusermount binary found on the $PATH
Error: $FUSERMOUNT_PROG not set

Cannot mount AppImage, please check your FUSE setup.
You might still be able to extract the contents of this AppImage
if you run it with the --appimage-extract option.
See https://github.com/AppImage/AppImageKit/wiki/FUSE
for more information
open dir error: No such file or directory
```

`--appimage-extract-and-run`: running after 22 s as
`/tmp/appimage_extracted_07b4adc808c1fa7bf8754afdb4f3bba8/usr/lib/maprisma/maprisma`, window mapped
(hyprctl), launch.json `{"exec":"/home/tester/Downloads/Maprisma-0.14.5-x86_64.AppImage","mode":"appimage-extract"}`.
Screenshot `results/hyprland-plain-B-nofuse.png`. After `pkill -x maprisma` the extracted folder
`/tmp/appimage_extracted_07b4…` was still there (O4).

## C — Maprisma Control

Fresh overlay, libraries, then either A's install (`CA`) or B's AppImage started once for launch.json
(`CB`), then `maprisma-control-0.2.1/install.sh` run inside the session environment. Logs:
`build/t073/logs/CA-<vm>.log`, `CB-<vm>.log`.

**Install** (all eight runs): exit 0, output

```
Installed both COSMIC applet and KDE/Hyprland tray integrations.
COSMIC: add it in COSMIC Settings > Desktop > Panel > Applets. An already-placed applet restarts at the next login or when the panel restarts.
The tray needs a bar with a system tray.
```

On both Hyprland VMs additionally:

```
Hyprland without XDG autostart/uwsm: add this to your config (never added automatically):
exec-once = "/home/tester/.local/lib/maprisma-control/maprisma-control-tray"
Plain command: "/home/tester/.local/lib/maprisma-control/maprisma-control-tray"
Lua exec-once syntax is not verified here; use the plain command with your configuration's startup API.
```

(P4: Hyprland 0.57 on Arch uses `hyprland.lua`; the printed line is hyprlang only.)
Files: `~/.local/share/applications/io.github.ubruckhaus.CosmicMaprisma.desktop`
(`Exec="/home/tester/.local/lib/maprisma-control/maprisma-applet"`),
`~/.config/autostart/com.maprisma.Control.Tray.desktop` (`OnlyShowIn=KDE;Hyprland;`,
`Exec="/home/tester/.local/lib/maprisma-control/maprisma-control-tray"`), binaries + install.sh,
uninstall.sh, glibc in `~/.local/lib/maprisma-control/`, links `~/.local/bin/maprisma-applet`,
`~/.local/bin/maprisma-control-tray`.

### plasma, hyprland-uwsm, hyprland-plain (tray)

The tray (`/home/tester/.local/lib/maprisma-control/maprisma-control-tray`) was started by the installer,
owns `com.maprisma.Control.Tray` and is registered: `RegisteredStatusNotifierItems` → `as 1
":1.46/StatusNotifierItem"` (watcher: kded6 on Plasma, quickshell on Hyprland), objects `/MenuBar` and
`/StatusNotifierItem`, `IconName` `io.github.ubruckhaus.CosmicMaprisma-off-symbolic`, `Status` `Active`.
The robot is in the tray: `results/plasma-CA-tray.png`, `results/hyprland-uwsm-CA-tray.png`,
`results/hyprland-plain-CA-tray.png` (and `-CB-tray.png`).

Calls (`busctl --user call com.maprisma.Control.Tray …`), identical results on the three VMs:

| action | CA (tar install) | CB (AppImage) |
|---|---|---|
| `/StatusNotifierItem Activate ii 0 0` (stopped) | Maprisma starts: `exe=/home/tester/.local/lib/maprisma/maprisma`; icon → `…-active-symbolic`; window shown (`<vm>-CA-started.png`, hyprctl mapped) | starts from the AppImage: `exe=/tmp/.mount_MaprisIiKojN/usr/lib/maprisma/maprisma`; `<vm>-CB-started.png` |
| `Activate` (running) | window hidden: process stays, no client in `hyprctl clients`, no window in `plasma-CA-toggled.png` | same |
| `Activate` again | window back (hyprctl: Maprisma) | same |
| `SecondaryActivate ii 0 0` | Maprisma stopped | stopped |
| `/MenuBar com.canonical.dbusmenu Event isvu 8 clicked s "" 0` (Start) | started (new pid, same exe) | started from a new `/tmp/.mount_*` |
| `Event … 7` (Stop) | stopped | stopped |
| `Event … 13` (Open Maprisma Control) | `maprisma-applet --window` opens (`<vm>-CA-control.png`, `-CB-control.png`) | same |

**Re-login** (`vm.sh stop` + `vm.sh start` without `--fresh`, CA):

- plasma: tray running, `app-com.maprisma.Control.Tray@autostart.service loaded active running`, registered
  (`as 1 ":1.27/StatusNotifierItem"`), `results/plasma-CA-relogin.png`.
- hyprland-uwsm: same through uwsm's XDG autostart (`app-com.maprisma.Control.Tray@autostart.service …
  running`, `as 1 ":1.11/StatusNotifierItem"`), `results/hyprland-uwsm-CA-relogin.png`.
- hyprland-plain: **not started**, as expected (no XDG autostart): no tray process,
  `RegisteredStatusNotifierItems` → `as 0`, `results/hyprland-plain-CA-relogin.png`.

**Uninstall** (`~/.local/lib/maprisma-control/uninstall.sh`): `Maprisma Control uninstalled.`, exit 0; the two
links, three icons, the applet entry, the autostart entry and `~/.local/lib/maprisma-control` are gone; the
tray process ended. Left: `~/.local/lib/.maprisma-control-install.lock` (P1).

### cosmic (applet)

No user `plugins_wings` existed; copied `/usr/share/cosmic/com.system76.CosmicPanel.Panel/v1/plugins_wings`
and appended `"io.github.ubruckhaus.CosmicMaprisma"` to the right list, then `pkill -x cosmic-panel`
(cosmic-session restarted it). The applet runs as a child of the panel (`1806 1786
/home/tester/.local/lib/maprisma-control/maprisma-applet`, 1786 = cosmic-panel) and the robot shows at the
right end of the top panel: `results/cosmic-CA-panel.png`, `results/cosmic-CB-panel.png`.

Clicks through the VM's own VNC server (127.0.0.1:5951, absolute USB tablet; no host input), CB (AppImage):

- click on the applet → popup "Maprisma · Stopped" with Start Maprisma, Start a recorded test session,
  …, Language, Corners: `results/cosmic-CB-applet-popup.png`.
- "Start Maprisma" → Maprisma starts from the AppImage via launch.json:
  `exe=/tmp/.mount_MaprisHPebaE/usr/lib/maprisma/maprisma`, runtime `/home/tester/Downloads/Maprisma-0.14.5-x86_64.AppImage`;
  window `results/cosmic-CB-started.png`, applet icon turns active.
- applet again → "Running since 10:00", Show / hide window, Stop Maprisma: `results/cosmic-CB-applet-running.png`.
- "Stop Maprisma" → `maprisma stopped`, AppImage runtime gone, no `.mount_Mapris*` left.

**Uninstall on COSMIC** (P3): files gone, exit 0, but the panel's applet keeps running from the deleted
binary: `1806 1786 /home/tester/.local/lib/maprisma-control/maprisma-applet`,
`/proc/1806/exe -> /home/tester/.local/lib/.maprisma-control-cleanup/maprisma-applet (deleted)`; the
panel config still lists `io.github.ubruckhaus.CosmicMaprisma` (`results/cosmic-CB-after-uninstall.png`).

## D — system install (plasma)

Log: `build/t073/logs/D-plasma.log`.

- Without sudo: `Maprisma: a system install needs root: sudo ./install.sh install --system`, exit 1 (P2).
- `sudo ./install.sh --system`: `Done: Maprisma 0.14.5 is in your app menu.`, `Start it with: maprisma`,
  `Remove it with: /opt/maprisma/uninstall.sh   (as root)`, exit 0.
- `sudo find /opt/maprisma ! -user root` → empty; `find /opt/maprisma -perm /022 ! -type l` → empty.
- `/usr/local/bin/maprisma -> /opt/maprisma/maprisma` (root), `/usr/local/share/applications/com.maprisma.Maprisma.desktop`
  with `Exec="/opt/maprisma/maprisma"`, `TryExec=/opt/maprisma/maprisma`, `X-Maprisma-Install=/opt/maprisma`;
  metainfo and icon in /usr/local/share; receipt `bin link /opt/maprisma/maprisma` + three sha256 lines.
  Nothing in `~/.local/lib`.
- tester starts `/usr/local/bin/maprisma` in the session: `exe=/opt/maprisma/maprisma`, launch.json
  `{"exec":"/opt/maprisma/maprisma","mode":"bundle"}`, window `results/plasma-D-tester.png`.
- second user `u2` (`useradd -m u2`): `printf '{"id":1,"protocol":2,"method":"settings.get","params":{}}\n' |
  sudo -u u2 timeout 10 /opt/maprisma/lib/maprisma-core` → `CORE_EXIT=0`,
  `{"id":1,"result":{"flutter_theme_mode":"system","map_light_fps":20,…`. `sudo -u u2 /usr/local/bin/maprisma`
  (u2 has no graphical session) gets as far as GTK: `Gtk-WARNING **: cannot open display:`, exit 1, i.e.
  the loader and libraries are fine.
- `sudo ./install.sh --system` while tester's Maprisma runs: `Maprisma: Maprisma is running (for you or
  another user): close it first; nothing was changed`, exit 1; after closing: exit 0.
- `sudo /opt/maprisma/uninstall.sh`: prints the per-user providers-service cleanup hint, `Maprisma was
  removed.`, exit 0; /opt/maprisma, the command and the three share files gone. Left:
  `/opt/.maprisma-install.lock` (root, 0644, P1).

## Problems found

- **P1: lock files written on refusal and left after uninstall.** A refused install (missing libraries)
  creates `~/.local/lib/` and `~/.local/lib/.maprisma-install.lock`. That contradicts "Checks first,
  nothing written before they pass" (`mkdir -p "$parent"` and the `flock` file come before the checks in
  `install.sh`). The lock also stays after uninstall: `~/.local/lib/.maprisma-install.lock` and, for
  `--system`, `/opt/.maprisma-install.lock`. Control behaves the same way:
  `~/.local/lib/.maprisma-control-install.lock` stays after its uninstall. These are empty files, but they
  are not removed.
- **P2: wrong command in the `--system` root message.**
  `Maprisma: a system install needs root: sudo ./install.sh install --system`. The `install` word comes
  from `${action/uninstall/--uninstall}` with action=install. Running the suggested command would fail
  with "unknown option install".
- **P3: Control uninstall on COSMIC leaves the applet running.** The panel's `maprisma-applet` keeps
  running from the deleted binary
  (`/home/tester/.local/lib/.maprisma-control-cleanup/maprisma-applet (deleted)`). The panel entry
  `io.github.ubruckhaus.CosmicMaprisma` also stays in `plugins_wings`. The uninstaller says nothing
  about either. The tray is stopped correctly on KDE and Hyprland.
- **P4: the Hyprland hint is hyprlang only.** The plan asks for "Lua and hyprlang form". The installer
  prints `exec-once = "…"` plus a plain command, and says the Lua syntax is not verified. Arch's Hyprland
  0.57 uses `~/.config/hypr/hyprland.lua`, so a working form there is:
  `hl.on("hyprland.start", function () hl.exec_cmd('"/home/tester/.local/lib/maprisma-control/maprisma-control-tray"') end)`.
  The test VMs use the same pattern for Quickshell.

## Observations (not failures)

- O1: no `maprisma-providers.service` was created during an 18 s first start of the tar install on any VM
  (`~/.config/systemd/user` absent). This is probably because nothing is configured yet on a fresh
  account. The service path (enable on start, removal by uninstall) was therefore not exercised.
- O2: COSMIC: the Maprisma window opens small (about 855×465) and the "Agents" card on the welcome page
  shows no rows. Its list area has no height between the card header and Later / Switch on
  (`cosmic-A.png`, `cosmic-B.png`, `cosmic-CB-started.png`). Plasma and Hyprland show the
  "Not installed" list.
- O3: COSMIC dock shows a generic gear icon for the running Maprisma (tar install with
  `com.maprisma.Maprisma.svg` in ~/.local/share/icons), Plasma's task manager shows the robot.
- O4: after `--appimage-extract-and-run` and `pkill -x maprisma`, `/tmp/appimage_extracted_<hash>` stays
  (≈ the bundle size) until reboot.
- O5: the tray's symbolic robot is dark grey on Quickshell's dark bar (low contrast,
  `hyprland-uwsm-CA-tray.png`). The applet popup's header has an empty slot where an icon would be
  (`cosmic-CB-applet-popup.png`).
- O6: harmless log lines on every start: `Gdk-Message: Unable to load  from the cursor theme` (empty
  cursor name), on COSMIC and Plasma also `CRITICAL **: Failed to read XDG desktop portal settings:
  GDBus.Error:org.freedesktop.portal.Error.NotFound`.
- O7: Arch's default PATH has no `~/.local/bin`; the installer says so correctly and Control finds
  `~/.local/bin/maprisma` anyway.
