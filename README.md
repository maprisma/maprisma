# Asterism

Your AI agents, models and tools on one map: a GTK 4 / libadwaita app.

![An agent is connected to a local LLM, a model, an MCP server and a skill folder by drawing lines; then its pin and right-click menu](docs/drawing-demo.gif)

Asterism shows the AI setup on your computer as cards and a map:

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

Asterism also runs on [Omarchy](https://omarchy.org), automatically using its theme and Hyprland
window integration while keeping the Asterism name and `~/.config/asterism` settings. On its first
start, if it has no settings yet, it copies the legacy **AI Agents Map** plugin's configuration
with a private backup, leaving the originals untouched. Verified add-ons for installed agents and
local LLMs are enabled automatically. The legacy plugin remains supported during the transition.

## Install

- **Arch Linux (AUR):** `asterism` (`packaging/aur/PKGBUILD`).
- **AppImage:** `Asterism-<version>-x86_64.AppImage` from the releases. It uses your distribution's
  Python 3 with PyGObject, GTK 4 and libadwaita:
  - Fedora: `sudo dnf install python3-gobject gtk4 libadwaita`
  - Ubuntu/Debian: `sudo apt install python3-gi gir1.2-gtk-4.0 gir1.2-adw-1`
  - Arch: `sudo pacman -S python-gobject gtk4 libadwaita`

  Agent icons need a Nerd Font (Symbols Nerd Font). Optional: `vte4` for agents in a terminal
  inside the window, `bubblewrap` (`bwrap`) for unpacking AppImages (MCP server apps, Jan): they
  are unpacked closed in, and without it not at all.
- **From source:** `bin/asterism` in a checkout.

Settings live in `~/.config/asterism/`. Light or dark and the accent colour follow your system.

## Privacy

Asterism never asks for root. It reads your agents' settings (never their credential files) and
your own processes, and contacts the web only for what you ask (searching models, MCP servers or
skills, installing) plus an update check every few hours (npm, the release pages of what it
installed, `mise outdated`). Every program runs without a shell, every answer with a size and
time limit.

The **Healthy & Security check** reads only the security keys of the agents' settings files and
changes one key at a time, after a preview, with a backup and Undo. **Disk space** only looks at
file sizes (`lstat`, links not followed, bounded); nothing is opened or deleted.

**Session numbers per project** for Claude Code, OpenCode and Hermes (one adapter per harness,
`harness_<name>.py`, registered in `harnesses.py`; more harnesses are added there):

- per project, numbers only (tokens, working time, sessions, lines changed, API value, subagent
  runs): Claude Code from its session files (`~/.claude/projects`, its replies and cost summaries,
  bounded and incremental); OpenCode and Hermes from their own databases, opened read-only, only the
  folder, time, token and cost columns and the message times; no message text;
- with the **Insights** add-on: **Topics**, the title each harness gave its sessions itself (Claude
  Code's `ai-title` lines, cached owner-only; OpenCode's and Hermes's title column), which topics
  took the most tokens, and **Summarize with Claude…** (only on a click, after showing exactly what is sent): those titles and
  numbers, never the conversations, go to your own `claude -p`, which runs in plan mode without
  MCP servers or a saved session, in an empty folder.

(Without add-ons, and always in the AI Agents Map plugin, only the numbers: `edition.py` takes the
level from the loaded add-ons.)

## Add-ons

Features beyond the numbers come as add-ons, from the author only. An add-on is a folder in
`~/.local/share/asterism/addons/` (or `/usr/lib/asterism/addons/`) and loads only when it is
switched on in Settings and **signed with the author's key** (checked with OpenSSH's
`ssh-keygen -Y verify`; fingerprint `SHA256:e5cC634Ke3Our5LAeSc88qs22NKZEHTncBW5Ig3amWQ`). Every
file must match the signed list, nothing may be added, and nothing of it runs before those checks.
Each add-on states in plain words what it reads and sends, and its privacy level (numbers, titles
or summary) is the most it can do. Add-ons build on a small, versioned API (`addon_api.py`), so a
new add-on needs no new Asterism. An add-on can also bring a **new agent or LLM provider**: every
agent is described as data (`adapters/<command>.toml`, format in
[docs/adapter-format.md](docs/adapter-format.md), plus a small `adapters/<command>.py` for the few
facts data cannot say), every provider is an adapter (`provider_<key>.py`); an add-on that declares
the capability ("agent", "provider", and "installer" for one that installs something) adds its own
(`agent.toml`, mostly with no code at all), and it then appears on the map, in the cards and on its
details page like the built-in ones. An **extension add-on** adds facts to an agent another one
brings, without replacing it. A built-in agent or provider cannot be
replaced, and an add-on's agent cannot bring an updater of its own. The AI Agents Map plugin has no
add-ons.

## Development

`python3 -m unittest discover -s tests`. `ASTERISM_DESKTOP=omarchy|generic` picks the desktop
integration.

This tree is the one source of both editions: the Omarchy plugin (AI Agents Map) gets its shared
files (the Python modules but the add-on ones, `tests/`, `icons/`, `translations/`, the manuals)
from here and keeps only its own (`BarWidget.qml`, `I18n.js`, `manifest.json`, its README and
assets). Never edit a shared file in the plugin:

- `tools/sync-plugin.py <plugin checkout>` copies what changed and removes what is gone here
  (`--release`: only from a committed tree);
- `tools/sync-plugin.py --check <plugin checkout>` lists every difference;
- `tools/sync-plugin.py --install-hook <plugin checkout>` makes the plugin refuse commits whose
  shared files differ from this tree.

The user manual is `docs/manual/manual.html` (English) and `manual.<lang>.html` (the translations);
`python3 docs/manual/build.py --all` makes the PDFs. After an edit of the English one,
`docs/manual/translations.py check` names the parts each translation still has in the earlier
English; translate those, then `docs/manual/translations.py stamp <lang> <part id …>`.

## License

MIT
