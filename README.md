# Maprisma

Your AI agents, models and tools on one map: a Flutter app with its service written in Dart.

Maprisma was called Asterism until 2026-10-30; its settings move over by themselves at the first start.

![An agent is connected to a local LLM, a model, an MCP server and a skill folder by drawing lines; then its pin and right-click menu](docs/drawing-demo.gif)

Maprisma shows the AI setup on your computer as cards and a map:

- **coding agents** (Claude Code, Codex, Copilot, Cursor CLI, Gemini, OpenCode, Pi, …) with their
  plan, limits, usage and what each still needs, with the command that fixes it;
- **local LLMs** (llama.cpp, Ollama, LM Studio, vLLM, Jan, KoboldCpp) and their models: install
  them (every download checked against its release's SHA-256), download models, set the context
  size that fits your graphics card, start them with their agents;
- **MCP servers and skills**, found on your computer or on the web: recommended servers (the MCP
  project's reference servers and official ones from GitHub, Microsoft, Google, Brave, Upstash),
  a search of the official MCP registry that says who published each server and how it runs, and a
  short explanation on each page of what servers and skills are for;
- **Setup**: one page of cards to switch on, install, update, sign in to and remove everything the
  map shows, with what the setup is good for and five steps for someone new;
- **open problems**: a red **!** in the header lists what to fix, each with a button to where it is
  fixed, plus updates and suggestions; online agents show a battery for what is left of their
  limits, running local LLMs one for the GPU memory still free;
- a **Healthy & Security check** on every agent's and local LLM's details page: what the agent may
  do without asking you (Claude Code, Codex, Copilot, Cursor CLI, Hermes, OpenCode, Pi), every
  choice explained with its risk and changeable with a preview and Undo, risk management with what
  lowers each risk, and the words (sandbox, approval, allow rules, prompt injection, …) explained;
- **disk space** in Help: how much room agents, local LLMs and models take, where, and on which disk.

Connect an agent to a local LLM, an MCP server or a skill folder by drawing a line on the map:
a preview shows every change first, and Undo puts it back. The **ⓘ** in the header explains every
dot, line and mark of the map; the map shows only what is set up on **Setup**. Pin a box
to keep its connections lit, right-click boxes for the cards' actions, and drag a model onto
another models folder to move it.

The user manual (a PDF in eight languages, also under **?** in the app, in its language) explains
everything step by step: [docs/manual](docs/manual).

Maprisma also runs on [Omarchy](https://omarchy.org), automatically using its theme and Hyprland
window integration while keeping the Maprisma name and `~/.config/maprisma` settings. On its first
start, if it has no settings yet, it copies the legacy **AI Agents Map** plugin's configuration
with a private backup, leaving the originals untouched. Verified add-ons for installed agents and
local LLMs are enabled automatically. The legacy plugin remains supported during the transition.

Settings › **Corners** follows the desktop's window rounding (**Like windows**) or is **Slightly
rounded (6 px)**, **Rounded (12 px)** or **Square**; every control follows in three sizes (cards,
dialogs and menus the full radius, buttons, drop-downs, fields and chips at most 8 px, check boxes
and progress bars at most 4 px).

## Install

Maprisma runs on x86_64 Linux with glibc 2.34 and GLib 2.68 or newer (Arch, Fedora, Debian 12+,
Ubuntu 22.04+, Pop!_OS, Rocky/Alma 9 …); tested on fresh Arch installs of COSMIC, KDE Plasma and
Hyprland, and on Rocky Linux 9. Download from
the [releases](https://github.com/maprisma/maprisma/releases) and check the download:
`sha256sum -c <file>.sha256`.

**What your system needs.** GTK 3, SQLite, zstd, EGL/GLES and a font. A fresh KDE Plasma or
Hyprland install lacks GTK 3 (COSMIC brings it), and a bare Hyprland has no font at all (add e.g.
`noto-fonts`).

| Distribution | Command |
|---|---|
| Arch, CachyOS, EndeavourOS | `sudo pacman -S --needed gtk3 sqlite zstd libglvnd` |
| Debian, Ubuntu, Pop!_OS | `sudo apt install libgtk-3-0t64 libsqlite3-0 libzstd1 libegl1 libgles2` (before 24.04: `libgtk-3-0`) |
| Fedora, Rocky, Alma | `sudo dnf install gtk3 sqlite-libs libzstd libglvnd-egl libglvnd-gles` |
| openSUSE | `sudo zypper install libgtk-3-0 libsqlite3-0 libzstd1 libEGL1 libGLESv2-2` |

No icon font is needed: the icons are in the app. `install.sh` checks all of this and names the
command for your distribution.

**The archive (recommended).** `maprisma-<version>-x86_64.tar.gz`:

```sh
tar -xzf maprisma-<version>-x86_64.tar.gz
cd maprisma-<version>
./install.sh                 # for you: ~/.local/lib/maprisma, the command maprisma, the app menu
sudo ./install.sh --system   # or for every user: /opt/maprisma, /usr/local/bin, /usr/local/share
```

`install.sh` checks the system first and changes nothing when something is missing; it tells you the
command for your distribution. It never replaces files that are not its own, nor a Maprisma installed
as a package or by Maprisma Settings. Running it again with a newer archive updates Maprisma (close
Maprisma first). Remove it with `~/.local/lib/maprisma/uninstall.sh` (or `sudo
/opt/maprisma/uninstall.sh`); `--purge` also removes your settings in `~/.config/maprisma`. Only this
install starts local LLMs together with their agents in the background (the providers service).

**The AppImage.** `Maprisma-<version>-x86_64.AppImage` runs without installing:
`chmod +x Maprisma-*.AppImage && ./Maprisma-*.AppImage`. It needs the same libraries, and FUSE 3
(`fusermount3`, from the `fuse3` package; most desktops have it); without FUSE start it with
`--appimage-extract-and-run`. It does not add a menu entry and does not run the providers service.

**The bar icon** is [Maprisma Control](https://github.com/maprisma/control), a release of its own: a
COSMIC panel applet and a tray icon for KDE Plasma and Hyprland (in a bar with a system tray, e.g.
Waybar or Quickshell). It starts and stops Maprisma, whether installed from the archive, in `/opt`, or
an AppImage (after its first start).

**Switching to a package later** (`maprisma-bin`, or through Maprisma Settings): run
`~/.local/lib/maprisma/uninstall.sh` first, so there are not two menu entries.

**Features that need a program** (Maprisma says so when it is missing): `curl` (downloads),
`tar` (local LLMs), `xdg-open` (links, the manual), `notify-send` (limit warnings), `wl-paste` (pasting
into agent terminals), `ss` (the traffic view), `pw-record`, `arecord` or `ffmpeg` (dictation), a
terminal (agent terminals). Optional: `bubblewrap` (`bwrap`) for unpacking AppImages (MCP server
apps, Jan): they are unpacked closed in, and without it not at all.

**From source:** `tools/flutter-dev build` makes a development bundle in `.flutter-previews/` (not
installed, not started); `tools/build-release.py` the release archive (needs the signed add-ons);
`tools/check-bundle.py` checks that it has no Python in it and needs at most glibc 2.34.

Settings live in `~/.config/maprisma/`. Light or dark and the accent colour follow your system.

## Privacy

Maprisma never asks for root. It reads your agents' settings (never their credential files) and
your own processes, and contacts the web only for what you ask (searching models, MCP servers or
skills, installing) plus an update check every few hours (npm, the release pages of what it
installed, `mise outdated`). Every program runs without a shell, every answer with a size and
time limit.

The **Healthy & Security check** reads only the security keys of the agents' settings files and
changes one key at a time, after a preview, with a backup and Undo. **Disk space** only looks at
file sizes (`lstat`, links not followed, bounded); nothing is opened or deleted.

**F12** (alone, not with Ctrl, Shift, Alt or Super; off in Settings › F12 saves a screenshot; in a
terminal the camera symbol instead) saves a picture of Maprisma's own window, drawn by the app
itself (no screenshot program, nothing uploaded), with an optional note (at most 4000 characters)
as a `.txt` next to it. It goes to `~/Pictures/Maprisma` (the pictures folder from
`user-dirs.dirs`, read bounded and never through a link) or the folder chosen in Settings, only
when that is a real folder of yours that others cannot write to (made `0700` when missing, checked
on its opened handle). Each file is new (`0600`, never through a link, never over an existing
picture or note), written completely and synced, or removed again.

**Session numbers per project** (Projects, last 30 days, on an agent's details): numbers only (tokens,
working time, sessions, lines changed, API value, subagent runs), from each agent's own session files
or databases (opened read-only), as its adapter names them; Claude Code's files are read bounded and
incrementally. No message text, title or prompt is read.

## Add-ons

Agents and LLM providers beyond the built-in ones come as add-ons, from the author only. An add-on is a
folder in `~/.local/share/maprisma/addons/` (or `/usr/lib/maprisma/addons/`), loads only when it is
switched on, and only when it is **signed with the author's key** (the SSHSIG signature, checked by the
Dart core; fingerprint `SHA256:e5cC634Ke3Our5LAeSc88qs22NKZEHTncBW5Ig3amWQ`). Every file must match the
signed list and nothing may be added. Add-ons are **data only**: an agent is described in `agent.toml`
(format in [docs/adapter-format.md](docs/adapter-format.md)), a provider in `provider.toml`, read by
built-in named readers; nothing of an add-on runs. Each one states in plain words what it reads and
sends. A built-in agent or provider cannot be replaced. Feature add-ons with code of their own (the GTK
app's Insights) are not possible in the Flutter app.

## Development

- `tools/flutter-dev check`: the Dart core's analyzer and tests, the differential cases against the
  Python reference (`tools/diff-core.py`), the release transport check, the Flutter analyzer and tests.
- `python3 -m unittest discover -s tests` and `tools/typecheck.sh`: the Python reference and the
  Python ↔ Dart parity tests. Every `*.py` here is the reference implementation only; nothing of it runs
  in the app (see AGENTS.md). `MAPRISMA_DESKTOP=omarchy|generic` picks the desktop integration.

The AI Agents Map plugin is its own GTK source since 2026-10-28; nothing is synced into it from here
(`tools/sync-plugin.py` is retired).

The user manual is `docs/manual/manual.html` (English) and `manual.<lang>.html` (the translations);
`python3 docs/manual/build.py --all` makes the PDFs. After an edit of the English one,
`docs/manual/translations.py check` names the parts each translation still has in the earlier
English; translate those, then `docs/manual/translations.py stamp <lang> <part id …>`.

## License

MIT
