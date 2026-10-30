# Plan: names, repositories and folders

Uwe's decisions (2026-10-28):

- **Asterism** is the name of the Flutter app only (Linux, later macOS), free and open source (MIT), not
  commercial.
- **AI Agents Map** is the name of the GTK app. There is only one GTK app, the Omarchy plugin, and no
  standalone GTK version for other desktops any more.
- GitHub follows the names: the existing publications belong to AI Agents Map, and Asterism gets the Flutter
  app.
- Search is helped by metadata, not by a different name. AgentHome, AgentHaven, AILodge and others were
  checked and dropped.
- The project folders are renamed to match.

Nothing outward-facing (push, release, AUR upload, marketplace post, domain) without Uwe's go-ahead for that
step.

## Checks done (2026-10-28)

- **Name collisions:** no AI app called Asterism.
  - GitHub: the namesakes are unrelated (`robb/Asterism`, an Objective-C library).
  - AUR, Flathub, Homebrew (cask and formula) and pub.dev: free.
  - PyPI, npm, crates.io: taken, which matters only for a library under that name.
- **Domains:**
  - `asterism.app`, `.com`, `.dev`, `.ai` and `.org` are taken.
  - `asterismai.app`, `asterism-ai.app`, `asterismai.dev` and `asterism-ai.dev` are free; registering one is
    Uwe's choice.
- **Trademarks (TMview, 46 entries):** no EU (EUIPO) and no German (DPMA) "Asterism" mark. In the software
  classes:
  - "ASTERISMS" by Object Computing, Inc., US, class 42: an enterprise cloud/AI platform.
  - "ASTERISM", China, class 9.
  - "ASTERISME", France, classes 35/38/41/42; details not visible.
  - For a free open-source desktop app the risk is very low. A database search is not legal advice.

## Step 1: project folders (done 2026-10-28)

| Before | Now | What |
|---|---|---|
| `/mnt/Data/Projects/asterism-flutter` | `/mnt/Data/Projects/asterism` | Asterism (Flutter), this repo |
| `/mnt/Data/Projects/asterism` | `/mnt/Data/Projects/ai-agents-map` | AI Agents Map (GTK), frozen |
| (none) | `~/Projects/ai-agents-map` → `/mnt/Data/Projects/ai-agents-map` | New link |
| `~/Projects/asterism` → `/mnt/Data/Projects/asterism` | unchanged | Now points to the Flutter app |

`asterism-addons` and `aur-asterism` keep their names: both belong to Asterism.

Done with the move:
- This repo's remote `gtk` now points to `/mnt/Data/Projects/ai-agents-map`.
- Both `AGENTS.md` files and `plan-flutter.md` now use the new paths.
- Everything still passes after the move: Dart, Flutter and Python tests and the differential cases.
  `docs/history/` keeps the old paths as a record.

Still to do:
- **CachyOS:** shares `/mnt/Data`. Check its `~/Projects` links and its launchers on its next start: a link to
  `/mnt/Data/Projects/asterism` now reaches the Flutter app.
- **GTK repo remote:** its `origin` still points to `github.com/uBruckhaus/Asterism`. Change it in step 3, and
  push nothing from there before that.

## Step 2: metadata for search (Asterism)

- **Subtitle** everywhere (README, metainfo `<summary>`, desktop file `Comment=`, AUR `pkgdesc`, Flathub,
  GitHub description): *Map and connect your AI agents, local LLMs, MCP servers and skills.*
- **Keywords:** AI; agents; LLM; local LLM; MCP; Model Context Protocol; Claude Code; Codex; Ollama;
  llama.cpp; LM Studio; skills.
  - In `data/io.github.ubruckhaus.Asterism.metainfo.xml`: `<keywords>`.
  - In `data/io.github.ubruckhaus.Asterism.desktop`: `Keywords=`.
  - Both in the 8 languages, where a translation exists.
- **GitHub topics:** add `local-llm`, `model-context-protocol`, `ollama`, `llama-cpp`, `claude-code`, `codex`
  and `flutter`. Keep `ai-agents`, `llm`, `mcp` and `linux`. Drop `gtk4` and `libadwaita` at the switch in
  step 4.
- **Name clause** in the README, the first paragraph after the license: "The name Asterism and its logo
  identify the official project by Uwe Bruckhaus. Forks are welcome under the MIT license; please give them a
  different name."
- **Homepage:** the GitHub page, or `asterismai.app` if Uwe registers it.

## Step 3: AI Agents Map, the only GTK app

The GTK tree has two identities:
- **Omarchy edition:** `desktop_omarchy`, app ID `org.omarchy.aiagentsmap`, config
  `~/.config/omarchy/ai-agents-map`. The marketplace plugin uses it.
- **Generic edition:** `desktop_generic`, app ID `io.github.ubruckhaus.Asterism`, config `~/.config/asterism`.
  This is the standalone app for other desktops.

The generic edition is dropped. Its ID and config folder belong to Asterism (Flutter) from now on, so the two
apps never clash. Because the plugin already has its own ID and folder, it needs no migration.

1. **Where the GTK code lives.** Decided 2026-10-28: (a), done the same day. The plugin repo's local commit `4493a20`
   on `dev` (not pushed) carries the final sync from `b38f423`, including the 14 unpublished commits and
   `data/first-agent.json`, which the sync tool never copied. Its 909 tests pass and `omarchy plugin validate` passes. The
   archive's remote is renamed `archived-github-asterism`. The original choice:
   - **(a) Recommended:** the plugin repo `uBruckhaus/omarchy-ai-agents-map` becomes the only GTK source, with
     a fresh clone at `/mnt/Data/Projects/omarchy-ai-agents-map`.
     - `tools/sync-plugin.py` and the plugin's drift hook are retired. The rule "edit only in Asterism, then
       sync" ends.
     - `/mnt/Data/Projects/ai-agents-map` stays as a read-only archive.
   - **(b)** Keep `/mnt/Data/Projects/ai-agents-map` as the source and sync into the plugin, as now. Its
     `origin` then needs a home of its own on GitHub (`uBruckhaus/ai-agents-map`, private or public).
2. **Remove the generic edition:**
   - `desktop_generic.py`, the edition switch in `desktop.py` and `packaging/`.
   - The AppImage and AUR files.
   - The `Asterism` desktop and metainfo files in `data/`.
   - Do this only in the GTK source chosen in 1. Tests first; the shared modules stay.
3. **The plugin's texts:**
   - README and manifest description: "AI Agents Map".
   - One line saying that Asterism is the standalone app, for every desktop, with a link.
   - No mention of the old standalone GTK app.
4. **Shared state:** keep `~/.local/state/ai-agents-map`.
   - It holds the connection backups (`backups/`) and `no-usage/`, and both apps read it.
   - Renaming it would break Undo across the apps.
   - Asterism keeps reading it under that name.
5. **Marketplace:** the AI Agents Map listing (#11928, 0.26.1) stays. Steps 1–3 change no behaviour, so no
   update is needed. If one is made later, it follows the publishing skill (Codex, then Uwe's OK).

## Step 4: GitHub `uBruckhaus/Asterism` → the Flutter app (at the first Flutter release)

The switch waits for the first Flutter release (after phase 7 of `plan-flutter-dart-core.md`). Before that,
people with v0.11 would land on an unfinished app.

1. **The last GTK release:**
   - The current releases v0.10.0–v0.11.0 are AppImages of the GTK app.
   - Tag the last GTK commit `gtk-final` (`b38f423`).
   - Add to the v0.11.0 notes: "Last release of the GTK edition; it continues as AI Agents Map for Omarchy.
     Asterism is now the Flutter app."
2. **Push `main`:**
   - This repo's `main` is the GTK `main` plus its own commits, so the push to `origin` is a fast-forward:
     no force, and the GTK history stays.
   - Never push to the remote `gtk`.
3. **README, description, topics and homepage** as in step 2. The README says what happened to the GTK app,
   with a link to the AI Agents Map plugin.
4. **Release:** `v1.0.0`, a new major version for the new app.
   - Linux: AppImage and AUR.
   - macOS later (`plan-macos.md`): notarized `.dmg`, then a Homebrew cask `asterism`.
5. **AUR:**
   - `asterism` is not yet on the AUR; `aur-asterism` is private.
   - The first upload is the Flutter build from `packaging/aur/PKGBUILD`, with the subtitle as `pkgdesc`.
6. **Add-ons:**
   - `uBruckhaus/asterism-addons` belongs to Asterism.
   - Signed GTK add-ons up to 0.11.0 stay for the GTK edition.
   - Flutter add-ons come with phase 5 of `plan-flutter-dart-core.md` (data-only add-ons need Uwe's OK).

## Step 5: texts and manuals

- **Asterism manual** (`docs/manual`, 8 languages and PDFs):
  - Title and screenshots of the Flutter app, with the subtitle as the first sentence.
  - No GTK-only chapters.
  - Built when the Flutter UI is final (feature rule: new features go into all 8 languages before
    publishing).
- **AI Agents Map:** its manual and the technical manual (`~/Documents/AI-Agents-Map-*.pdf`) keep their
  names. Their sentences about "Asterism, the same app for other desktops" go.
- **Omarchy plugin for Asterism:** the new marketplace plugin `ubruckhaus.asterism` (thin launcher) comes
  later, at step 7 of `plan-flutter.md`, under the name Asterism.

## Step 6: notes outside the repos (done with step 1)

- Claude's memory and the shared skills (`/mnt/Data/Ai/Skills`, e.g. `omarchy-plugins`, `omarchy-disk`) use
  the new folder names.
- Old paths in `docs/history/` stay as they were.

## Open decisions for Uwe

1. ~~Where the GTK code lives~~: the plugin repo (decided and done 2026-10-28).
2. Registering `asterismai.app` (or `.dev`), and whether the README links to it.
3. The moment of the GitHub/AUR switch. Recommended: the first Flutter release, `v1.0.0`.

## Step 7: the rename to Maprisma (Uwe, 2026-10-30: "rename first", before packaging)

The Flutter app is called **Maprisma** (decided 2026-10-29; maprisma.com and the GitHub org `maprisma`
are Uwe's). The rename comes before step 6 of plan-flutter.md, so the packages are built once under
the final name. Nothing is published.

| What | Before | After |
|---|---|---|
| App ID | `io.github.ubruckhaus.Asterism` (Devel: `….Devel`) | `com.maprisma.Maprisma` (Devel: `….Devel`): the reverse of Uwe's domain, as Flathub wants |
| Name in the interface | Asterism | Maprisma |
| Program, core | `asterism`, `lib/asterism-core` | `maprisma`, `lib/maprisma-core` |
| Toggle | `asterism --toggle` | `maprisma --toggle` |
| Folders | `~/.config/asterism`, `~/.local/share/asterism`, `~/.local/state/asterism`, `~/.cache/asterism` | the same with `maprisma` |
| User unit | `asterism-providers.service` | `maprisma-providers.service` (follows the short name) |
| Desktop file, metainfo | `data/io.github.ubruckhaus.Asterism.*` | `data/com.maprisma.Maprisma.*` |

**Existing data moves over once, nothing is deleted.** At the first start of Maprisma, while
`~/.config/maprisma` does not exist yet: the config folder (settings, the MCP server list, connection
backups), the installed add-ons and the state folder (jobs, notices) are copied from the Asterism folders,
modes kept, links not followed. The cache is not copied (it is rebuilt). The Asterism folders stay as they
were. A failed copy shows as `migration_error`, and the app starts with defaults.

**Kept on purpose** (invisible, or changing them would break something):
- the add-on signature namespace `asterism-addon` (every add-on signed so far would fail its check);
- the Dart package `asterism_core`, the `ASTERISM_*` environment variables of the tools and tests, the
  repository folder `/mnt/Data/Projects/asterism` and the add-on repository `asterism-addons` (renamed at the
  GitHub switch, with Uwe);
- the marker `# Connected by Asterism` in files the app wrote: still recognised; new files get
  `# Connected by Maprisma`.

Parts: **R1** identity, folders and the move of existing data (with the tools that build the bundle);
**R2** the name in the texts: interface, eight translations, manual, README, metainfo; **R3** tools and docs.
