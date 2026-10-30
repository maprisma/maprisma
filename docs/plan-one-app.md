# Plan: one app for every Linux distribution (Asterism), the Omarchy plugin as a thin launcher

**2026-10-27 user update:** the final application will use Flutter. Follow
`docs/plan-flutter.md` for the active UI migration; identity, one-time settings
migration, the thin launcher and no automatic publication remain requirements.

Handoff from a Claude Code session (2026-10-27) for the next agent (Codex). Uwe decided everything under
"Decisions"; the open items are under "Next steps". Read "House rules" before changing anything.

## Goal

AI Agents Map (the Omarchy plugin, `ubruckhaus.ai-agents-map`) and Asterism (this repo) are the same code.
Asterism is the stand-alone app and has outgrown the plugin. There should be **one app, Asterism**, for any
distribution, Omarchy included; the Omarchy plugin becomes a **thin launcher** (bar button + toggle) that starts
or focuses the installed Asterism and offers to install it when it is missing.

## Decisions (Uwe, 2026-10-27)

| Question | Decision |
|---|---|
| How the thin plugin installs Asterism when missing | **Both**: the AUR (`yay -S asterism` / paru) when yay or paru is there, else the AppImage from the GitHub release (SHA-256 checked). Always shown first, run in a terminal the user watches; nothing silent. |
| The plugin's name afterwards | **Rename to Asterism**: a new marketplace plugin `ubruckhaus.asterism`; the old AI Agents Map plugin points its users to it. |
| Order | **Ask the marketplace first** (question in issue #11928, draft below), and meanwhile do steps 1–2, which Asterism needs anyway. |
| The plugin's settings | **Moved into Asterism once, automatically, with a backup** on Asterism's first start; the originals stay untouched. |

## Facts (checked in the code on 2026-10-27)

- **Identity and desktop are coupled.** `desktop.py` picks `desktop_omarchy` or `desktop_generic` (env
  `ASTERISM_DESKTOP=omarchy|generic`, else Omarchy when its files exist). Each backend carries the app's identity
  too: `desktop_omarchy.APP_NAME = "AI Agents Map"`, `APP_ID = "org.omarchy.aiagentsmap"`,
  `CONFIG_DIR = ~/.config/omarchy/ai-agents-map`; `desktop_generic`: Asterism, `io.github.ubruckhaus.Asterism`,
  `~/.config/asterism`.
- **`bin/asterism` forces the generic desktop** (`: "${ASTERISM_DESKTOP:=generic}"`), so Asterism on Omarchy runs
  without the Omarchy integration (theme, agent menu `/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc`,
  Omarchy's usage records `~/.local/state/omarchy/agents/usage`, Hyprland window rules, floating terminal).
- **Shared data**: both editions use `~/.local/state/ai-agents-map/` (backups, jobs.json, protocol `ai-help/`,
  reorganize journal) and `~/.cache/ai-agents-map/`. Only the config folder differs. Uwe's PC has both config
  folders (settings.json, mcp-servers.json, failed-links.json, providers-with-agents.json, backups of them).
- **Agents and providers**: the plugin has every agent/provider built in (`adapters/*.toml`, `provider_*.py`);
  Asterism ships them as **signed add-ons** (`addons/`, `addons.py`, `addon_store.py`; only Uwe signs) that the
  welcome page switches on. Signed add-ons older than a fact get it from the built-in adapters
  (`harnesses.NEWER_FACTS`, `llm_engine._with_newer_facts`, `providers.online_names`). `edition.py`: the plugin
  has no add-on loader.
- **Plugin-only files** (in `~/.config/omarchy/plugins/ubruckhaus.ai-agents-map`, not synced from here):
  `manifest.json` (0.26.1, kind bar-widget), `BarWidget.qml` (62 lines: an icon, tooltip, click runs the toggle
  via `Quickshell.execDetached`), `I18n.js`, `ai-agents-map-toggle` (177 lines: singleton, PID file in
  XDG_RUNTIME_DIR, strict process identity check, SIGUSR1/show), `README.md`, `ARCHITECTURE.md`, `preview.png`,
  `assets/`. Everything else is copied from this repo by `tools/sync-plugin.py <plugin folder>`.
- **On Uwe's PC the thin launcher already exists** as an uncommitted "LOCAL ONLY" block at the top of
  `ai-agents-map-toggle`: when `~/.local/bin/asterism` exists it focuses the Asterism window (`hyprctl dispatch
  'hl.dsp.focus({ window = "class:^(io[.]github[.]ubruckhaus[.]Asterism)$" })'`) or starts it
  (`setsid uwsm app -- ~/.local/bin/asterism`). That block must never be committed to the plugin repo.
- **Packaging**: `packaging/aur/PKGBUILD` exists (depends python, python-gobject, gtk4, libadwaita, curl,
  openssh, ttf-nerd-fonts-symbols; optdepends vte4, xdg-terminal-exec, mise, bubblewrap); **asterism is not on
  the AUR yet** (AUR RPC: 0 results). AppImage build under `packaging/`. Omarchy ships `yay`.
- **Launcher entry**: `app_entry.py` writes the plugin's own `org.omarchy.aiagentsmap.desktop` (TryExec = the
  plugin's toggle). Asterism's package brings its own desktop file.
- **Marketplace**: issue https://github.com/omacom/omarchy-plugin-marketplace/issues/11928 is open,
  "[Verify]: AI Agents Map 0.26.1", labels validated + security-review-required + plugin-update. The skill
  `~/.agents/skills/omarchy-plugin-publishing` has the review history and rules (capabilities `installer`,
  `package-manager` must be documented up front; "nothing from a file becomes an executable path").

## Next steps

1. **Separate identity from desktop.** Asterism always has its own identity (name "Asterism", app id
   `io.github.ubruckhaus.Asterism`, `~/.config/asterism`); the desktop integration is detected (Omarchy where it
   exists, else generic). Move APP_NAME/APP_ID/CONFIG_DIR out of the desktop backends into one identity module
   (the plugin build keeps "AI Agents Map" while it still exists), and stop `bin/asterism` from forcing generic.
   Check every user of `desktop.app_name()`, `app_id()`, `config_dir()`, `NAME == "omarchy"` and
   `desktop.use_identity` leftovers; window rules and layer names; the launcher entry (`app_entry.py` is the
   plugin's).
2. **Move the plugin's settings once.** On Asterism's first start (no `~/.config/asterism/settings.json`, but
   `~/.config/omarchy/ai-agents-map/settings.json` exists): copy settings.json, mcp-servers.json,
   failed-links.json, providers-with-agents.json, `agents/` into `~/.config/asterism`, keep a backup, leave the
   originals, record that it was done (a setting), and switch on the signed add-ons for the agents and local LLMs
   that are installed (the welcome page's logic: `addons_page.installed_adapters`, `setup_page.finish_setup`),
   so the map looks the same at once. Tests in a temporary HOME.
3. **The thin plugin `ubruckhaus.asterism`** (new folder/repo, QML + bash only): BarWidget.qml + toggle that
   focuses or starts Asterism (`asterism` on PATH or `~/.local/bin/asterism`, an AppImage in `~/Applications`);
   when missing, a small panel/dialog with the exact command: AUR via yay/paru in a terminal
   (`omarchy-launch-floating-terminal-with-presentation` / `xdg-terminal-exec`), else the AppImage download with
   SHA-256 check. No Python in the plugin. Old AI Agents Map: a last update whose bar button says it moved and
   offers the same install.
4. **Publish Asterism on the AUR** (`packaging/aur/PKGBUILD`, maintainer account is Uwe's) and keep the AppImage
   release. Releases, signing and pushing only after Uwe says so.
5. **Marketplace**: post the question (draft below) **only after Uwe approves it**; then the new plugin
   submission ("[Plugin]: Asterism") with capabilities documented, per the publishing skill.

### Draft question for #11928 (not posted yet; Uwe must approve)

> **Question before the next update: AI Agents Map becoming a thin launcher for Asterism**
>
> AI Agents Map and Asterism (https://github.com/uBruckhaus/asterism) are the same code. Asterism is the
> stand-alone app for any Linux distribution and has grown well beyond what fits a plugin (signed add-ons, a
> first-agent guide, local LLM help). Instead of two copies, I would like to ship one app and make the plugin
> small:
> - A new plugin **Asterism** (`ubruckhaus.asterism`): a bar button (QML) and a toggle script that starts or
>   focuses the installed Asterism app, nothing else. The current AI Agents Map plugin would point its users to it.
> - When Asterism is not installed, the button offers to install it — never silently: it shows the exact command
>   and runs it in a terminal the user watches: with yay/paru `yay -S asterism` (AUR; sudo is typed there),
>   otherwise the AppImage from the GitHub release, its SHA-256 checked before it is made executable.
> - Capabilities declared up front: `package-manager` (the AUR install) and `installer` (the AppImage download).
>
> Would a launcher plugin like this be accepted, or would you rather it only *link* to the install instructions
> without running anything?

## State of the repos (2026-10-27, ~15:15)

- Asterism `~/Projects/asterism`: main is **14 commits ahead of origin, not pushed** (today's work: agent_guard
  and Codex fixes, progress box + protocol, local helper, Performance card, layout pass, Ollama tuning, page
  headers, manual in 8 languages, online models for all harnesses, first-agent guide + GPU stack, header name).
  Untracked `docs/technical/` (Uwe has not decided about it; do not commit it).
- Plugin `~/.config/omarchy/plugins/ubruckhaus.ai-agents-map`: synced from Asterism `b38f423`, local commits not
  pushed; `ai-agents-map-toggle` has the uncommitted LOCAL ONLY block (keep it uncommitted).
- Open besides this plan: re-sign the claude/codex add-ons with `[closed]` and the llama.cpp/Ollama/online
  provider add-ons (newer facts are filled in from the app until then); a real install run of the first-agent guide
  in the edge VM `~/VMs/omarchy-edge`; a manual chapter for the first-agent guide; version bump and release notes
  before any marketplace update.

## House rules (from Uwe, keep them)

- **One source**: edit shared code only here (`~/Projects/asterism`), then `tools/sync-plugin.py
  ~/.config/omarchy/plugins/ubruckhaus.ai-agents-map`; the plugin's pre-commit hook refuses drift.
- **Before committing here**: `python3 -m unittest discover -s tests -q` (≈1084 tests) and `tools/typecheck.sh`
  (pyright, 0 errors; GTK page mixins are listed in `pyrightconfig.json`).
- **The core names no agent and no local LLM** (tests `test_the_core_names_no_agent`,
  `test_the_core_names_no_local_llm`): agent/provider facts belong in `adapters/*.toml|py` and `provider_*.py`.
- **Every new UI text in 8 languages** (`translations/{de,es,fr,it,nl,pl,pt}.json`; `tests/test_i18n.py`
  collects msgids with ast). Feature changes need the manual (`docs/manual/manual.html` + 7 translations,
  `docs/manual/translations.py check|stamp`, `python3 docs/manual/build.py --all`).
- **Credential files are never read** (auth.json, .credentials.json): only whether they exist.
- **Nothing outward-facing without Uwe**: no push, no release, no marketplace post/retarget, no AUR upload
  unless he says so. Commit locally when asked.
- **Never** commit the toggle's LOCAL ONLY block; never run Omarchy edge/quattro code on Uwe's desktop (use the
  edge VM); do not open popups or move the real mouse for tests (use the off-screen Broadway recipe).
- After a change that is synced into the plugin, restart the running app (check first that no agent runs in its
  terminal and `~/.local/state/ai-agents-map/jobs.json` is empty), via
  `setsid -f ~/.config/omarchy/plugins/ubruckhaus.ai-agents-map/ai-agents-map-toggle`.


## Prepared implementation in the writable checkout (2026-10-27)

Steps 1–2 are implemented in `/mnt/Data/Projects/asterism-flutter`; the original
`/mnt/Data/Projects/asterism` is still read-only to this Codex session. Nothing has been
committed, installed, synced to the live plugin, pushed or published.

- `identity.py` separates build identity from desktop integration. The legacy plugin build omits
  the add-on loader and retains its own name/config/id. Standalone Asterism uses its own identity
  on both desktops. Both launchers now allow automatic desktop detection.
- Log identity, watcher-unit names and PID filenames follow the edition. Standalone Asterism
  does not offer or overwrite the legacy plugin launcher entry. Desktop-specific theme and
  window behavior still follows the selected desktop backend.
- `config_migration.py` performs the first-start import with bounded reads, no symlinks, a
  private independent backup, existing-target preservation and settings published last. New
  files are rolled back if the commit fails. Original plugin files are never modified.
- Pending adapter activation reuses the welcome page's verified-adapter and installed-program
  detection, enables the online-provider group, and retries when signed adapters are absent.
- The user's per-agent Start submenu, complete project history, pins and history-only deletion
  are included and apply to embedded and separate-terminal sessions. Starting needs no pin.
- Manual source text is updated in all eight languages. GUI/PDF checks remain blocked by this
  session's display/socket restrictions. Run the complete suite and rebuild manuals on the host
  before any commit or release.

The cumulative review patch is `/home/uwe/Work/asterism-one-app.patch` (includes the earlier
project-folder feature). The earlier folder-only patch remains available separately. Apply only
the cumulative patch to a clean original checkout, not both patches.

Next is the marketplace question already drafted above; it has not been posted. The new thin
launcher, AUR publication, add-on signing and releases remain outstanding. Codex subagent
detection research/unfinished work is separate in `/home/uwe/Work/asterism-subagents`.


## Continued preparation and Claude review attempt (2026-10-27)

Uwe instructed continuation, then a Claude recheck, with no automatic marketplace publication.
The private preparation now also contains:

- `/home/uwe/Work/omarchy-asterism-launcher`: new `ubruckhaus.asterism` QML/JS/Bash launcher.
  Fixed app discovery/focus, explicitly confirmed AUR or bounded SHA-256 AppImage installation,
  eight languages, no Python runtime.
- `/home/uwe/Work/omarchy-ai-agents-map-handoff`: final legacy thin snapshot, version 0.27.0,
  with the moved notice and same installation path. The LOCAL ONLY block is not included.
  Finish all old embedded agents/jobs and end the legacy process before switching snapshots;
  the new launcher does not terminate them. The original live checkout was not touched.
- `/home/uwe/Work/aur-asterism-staging`: PKGBUILD and generated .SRCINFO for staging; the new
  application version, archive digests and a clean VM install must precede any AUR upload.
- AppImage builder emits versioned + stable `Asterism-x86_64.AppImage` assets and SHA256SUMS.
  Missing/unmatched checksum assets fail closed in the launcher. All release uploads remain pending.
- sync-plugin.py refuses both thin launcher ids/markers, preventing accidental app duplication.
- Settings writes refuse to exceed the reader's byte cap, preserving existing settings as history grows.

Validation: 1,092 app tests pass with the same five display/socket-restricted test modules excluded;
pyright has zero errors (five existing PyYAML-source warnings). Both launcher snapshots pass
`omarchy plugin validate`, 35 fixture-only launcher checks each and eight-language checks. QML
lint resolves shell imports; dynamic QObject property warnings remain. Source/manifest preflight
passes on disposable non-Git copies; commit/push/upstream publication gates are deliberately pending.
GUI/VM checks, actual network installer runs, real screenshots and manual PDF rebuilds are not done.

Claude was invoked read-only after preparation, with no Bash/edit/MCP tools. It returned no report
within 180 seconds: NOT REVIEWED, no CLEAN verdict. The saved prompt, output/status and host runner
are in `/home/uwe/Work/asterism-review`. Run `review-with-claude.sh` from a normal host terminal,
inspect and resolve its findings, then recheck before treating this as release-ready.

The final cumulative app patch is `/home/uwe/Work/asterism-one-app.patch`. Nothing was committed,
installed into the original `/mnt/Data` tree, synced to the live desktop, pushed, released, uploaded
to AUR or posted to the marketplace. The original tree remains read-only to this session.
