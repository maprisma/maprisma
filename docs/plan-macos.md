# Plan: Asterism for macOS — LATER (2026-10-28)

**Do not start this.** It begins only after the Linux version is completely done (plan-flutter.md steps 1–8,
including packaging and the new Omarchy launcher plugin) **and Uwe gives his OK**. Until then, keep new Linux
code adapter-friendly: no new direct `/proc`, systemd, pacman or XDG-path calls in the core; put them behind
the desktop adapter (`desktop.py`) so a `desktop_macos.py` can be added later.

This replaces the earlier idea (2026-10-17) of a separate SwiftUI front end: the Flutter UI runs natively on
macOS (Metal), so the Mac version shares the interface and needs a macOS backend for the Python service.
Uwe has an M4 MacBook Pro (arm64, real-Mac testing) and a paid Apple Developer membership.

## What carries over (little or no work)

- The Flutter UI: map editor, task cards, views, eight languages, manual.
- Agents and their terminals (Unix PTYs exist on macOS), online providers, MCP servers, skills, usage and
  costs, signed add-ons, backups and Undo. Only config paths differ (`~/Library/Application Support/...`).
- Local models: Ollama, LM Studio and llama.cpp on Apple Silicon (Metal, unified memory). MLX as a new
  provider add-on is a natural addition.

## What needs a macOS backend

| Area | Linux today | macOS |
|---|---|---|
| Processes (running agents, ancestors, start times) | `/proc` | `psutil` / `sysctl` / libproc |
| Safe stop guard | PID + start time + `pidfd` | PID + start time with another race guard (kqueue `EVFILT_PROC`) |
| Own-UID port check (security) | `/proc/net/tcp` | libproc / `lsof`-equivalent; must keep the same guarantee |
| GPU and performance | amdgpu sysfs, ROCm/PyTorch installs, llama.cpp device list | unified memory and Metal; no ROCm/PyTorch installs |
| Installing | pacman, yay/AUR, AppImage, mise | Homebrew or verified direct downloads |
| System Map (disks, mounts, moving model folders) | `/proc/mounts`, `lsblk` | `diskutil` |
| Sandbox for AppImage extraction | bubblewrap | none comparable (`sandbox-exec` is deprecated): limit or drop the features that need it |
| Sign-in status | credential files (existence only) | some agents use the Keychain: check presence without reading secrets |
| Services | systemd | launchd |
| Desktop integration | Omarchy/Hyprland, layer-shell popup | menu-bar icon with a popover, macOS light/dark + accent colour |

## Not possible

- The Mac App Store for the full app: its sandbox blocks starting other CLIs, editing other apps' configs
  and watching their processes. A reduced store edition is possible at most.
- Omarchy-only features (bar plugin, Omarchy theme, agent menu, usage records).

## Delivery

Developer ID signed and notarized DMG, a Homebrew cask, an update mechanism (e.g. Sparkle). The hardest part
is packaging: the bundled Python and every native library inside it must be signed and notarized.

## Order when it starts

1. The macOS backend in the Python service (`desktop_macos.py` and the table above), with tests.
2. A macOS build of the Flutter app with the bundled service; menu-bar mode.
3. Signing, notarization, DMG and cask; a clean-Mac install test on the M4.
4. An independent review, then release decisions by Uwe.
