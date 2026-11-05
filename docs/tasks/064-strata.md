# 064 Strata as a local LLM

Author: Claude · Reviewer: Codex (the parent session runs it before any release) · Branch: task/064-strata

## Goal
Strata (github.com/Niko1221/Strata, MIT) on the map like the other local LLMs: found, its models listed, started
and stopped, agents connected to it, installed and uninstalled. Strata is a local inference engine with a terminal
app (`strata launch`) that serves one model on `127.0.0.1:8080` with OpenAI (`/v1/chat/completions`,
`/v1/responses`, `/v1/models`) and Anthropic (`/v1/messages`) APIs; local access needs no API key. It is a provider,
not an agent (it has no coding agent of its own; `strata connect` configures other agents, which Maprisma does its
own way).

## Design and decisions
- **Provider** `strata` (`provider_strata.py`, registered last in `providers.LOCAL_ORDER`), connect key
  `strata-local`, label `Strata (local)`, port 8080, homepage, data folders `~/.local/share/strata/install`,
  `~/.local/share/strata/components`, `~/.strata` (never removed by the app).
- **Its own `strata` only.** `/usr/bin/strata` is also the GTK Strata file manager (installed on Uwe's desktop).
  `strata_binary()` / `StrataFacts.binary()` accept a `strata` on PATH, in `~/.local/bin` or in its terminal
  folder only when it resolves into `$XDG_DATA_HOME/strata/terminal/`. The add-on's `detect.commands` is empty for
  the same reason (its folders detect it).
- **Running and port.** Its server is its terminal's Python running `-m serve.server … --config <run config>`
  (`strata_control/runtime.py`). Its server and its engine are only executables that resolve, as real paths (links
  followed, the file must exist), into this user's own `$XDG_DATA_HOME/strata/terminal` (server and supervisor)
  or `…/strata/components` (engine); a path that merely contains `/strata/terminal/` elsewhere is not
  (`provider_strata.owns` / `is_server`, `StrataFacts.owns` / `isServer`; review 064 #2). They are Strata's
  `BY_PATH`, so llama.cpp's claim by name never takes them. The port is the first `--port` that is 1-5 ASCII digits
  in 1..65535, else the run config's `"port"` (bounded JSON, no links), else 8080. The same rule for every port read
  from text (`gpu_usage.port_number` / `portNumber`: scans, the scan's port map, `port_of`, the watcher config,
  `traffic.split_address`; review 064 #1).
- **Models** are its run configs `strata-<id>.json` in `$XDG_DATA_HOME/strata/install` (Strata's own `MODEL_ID`
  rule, at most 128, no links, not `*.shared-settings.json`), read from disk; the CLI is not run on every scan.
  No Models… page, no own model folder, `can_load` False: choosing, downloading and tuning a model stays in Strata's
  own screens (`strata launch`); the add-model step says so.
- **Start / stop.** No user service. Start runs the launch preset used last
  (`$XDG_CONFIG_HOME/strata/launch-presets/*.json`, newest `last_used`, else `created`; only slug, port and
  times are read: a preset may hold the API key): `strata launch --preset <slug> --yes --no-tui` (returns when the
  model serves; 900 s bound). Stop: `strata launch --stop`. `can_control` needs its own `strata` and a preset. While
  it is off, its address is that preset's port (else 8080).
- **Not started with its agents.** The provider watcher has no control for it (`provider_watch.CONTROLS` is `lms`
  only), so `Engine.starts_with_agents` is False and the link hints say to start it (Python `link_check`). Its
  `stays_up` / `unload` facts are unset. `Engine.unload_all` (POST `/v1/unload`) exists for `runtime_ctl.unload`;
  the map has no per-model unload for it (`model.unload` needs `can_load`, refused on both cores).
- **Two LLMs on port 8080.** An agent's provider named by a connect key (`strata-local`, `llama-local`) now names
  that runtime (`agent_details.local_names`, Dart `DetailReaders.provider`), and `local_runtime` / `localRuntime`
  prefers the named runtime among the installed ones detected on the port; otherwise the first one, as before.
- **Installer** (`install_ctl.Strata`, Dart `StrataInstaller`): the latest release's `install.sh` (tag
  `v<digits>(.<digits>){1,3}`, exactly one asset of that name at `…/releases/download/<tag>/install.sh`, the
  GitHub-listed SHA-256 checked) into a private temp folder, run with `sh` (256 KiB output, 1800 s), with the
  user's `STRATA_*` variables removed and `STRATA_FEED` set to that release's download folder, so what was checked
  is what installs (install.sh itself checks the terminal's checksum and the feed's signature). It installs only
  into `$XDG_DATA_HOME/strata/terminal`; refused when `~/.local/bin/strata` exists and is not ours, or a terminal is
  there without the app's marker (then `strata update`). Afterwards the absolute `current` link's version is
  recorded in the marker (`current_version_in` reads the basename). `versions()` also counts version folders
  Strata's own update put there (bin/strata + VERSION), so uninstall removes them too.
- **Removal.** The shipped app (Dart core, Flutter) has no route that uninstalls a local LLM, for any of them, and
  none is added: the manual says how to remove Strata by hand (its terminal folder and the `~/.local/bin/strata`
  link; engines, run configs, models and the desktop app's chats are named, to keep or delete) and that Maprisma
  offers no Uninstall… for it (review 064 #5). The Python reference's `install_ctl.Strata.uninstall` removes only the
  terminal versions, `current`, the marker and the link.
- **Configure…** (Python reference): "Set up a model" (`strata launch`) and "What is serving"
  (`strata launch --status`), run with Strata's verified path: a local LLM's program is resolved through its engine
  (`Engine.resolve_program`; by name for the others as before, Strata only `strata_binary()`), also for the `--help`
  fallback, so `/usr/bin/strata` never runs (review 064 #3). The Flutter map has no Configure… for local LLMs; texts
  and the manual name `~/.local/bin/strata launch` and the ▶ button.
- **Replies of another shape.** `loaded_models` / `unload_all` read every server's list through `llm_engine.rows`
  (the Python twin of the Dart core's `_rows`): a list reply, `{"data": {}}` or a text status give no models instead of
  an exception, for every built-in engine (review 064 #4).

## Routes
None (`routes.json` untouched). `boundedOutput` (Dart) gained `inheritEnvironment` for the installer.

## UI
No new views. Texts: the add-model step, the start step, the two Configure labels and their note (7 languages).
Manual: Strata in the local LLM list, the install table, the Flutter install paragraph, a note under "Starting and
stopping with agents" and a new section `#strata`, in all 8 languages; PDFs rebuilt (plugin version 0.26.1).

## Checked
- **Edge VM** (Strata 0.2.11, build 0.1.57, no GPU): the real install.sh layout (`terminal/<version>`, absolute
  `current`, the `~/.local/bin` link), `strata launch --status --output json` (`{"running": []}`),
  `--list-presets --output json`, `models list --output json`, `strata launch --stop` with nothing running (exit 0),
  `--plan … --output json`. **Maprisma's own Python installer** against the real release: `latest()` → v0.2.11 with
  the install.sh digest, install → marker `{"runtime": "strata", "versions": ["0.1.57"]}`, found by
  `inventory.strata`, then uninstall → link and terminal gone, `components/` and `install/` kept.
- **Only from Strata's source, not run** (no GPU in the VM): the server's command line and `--config` port, the
  launch preset folder and fields, `strata launch --preset … --no-tui` serving, `/v1/models` and `/v1/unload` of a
  running server, the engine binary's path.
- **Tests:** `tests/test_strata.py` (the file manager is not Strata, a link out of its terminal, run configs only,
  the preset used last and never its key, server port parsing, ownership, the shared port, installer refusals
  before any download, versions and uninstall). `tests/test_dart_strata_parity.py` (a fake terminal, presets, run
  configs, a `/usr/bin/strata` stand-in first on PATH and a fake server started like Strata's own: both cores give
  the same snapshot and the same start/stop/refused unload; the stand-in never runs; the key never appears).
  `tests/test_dart_installers_parity.py` installs a fake Strata release on both cores (the feed it was given, the
  link, the marker).

## Review 064 (Codex round 1 on the merged main fa278c5)

Five Mediums, all fixed on this branch with tests in both cores where they apply: #1 oversized `--port` (and the
port-text class), #2 ownership by real path, #3 Configure… by name, #4 odd JSON replies, #5 Uninstall… in the
manual. See the commits after 29677c2.

## Open
- Release: the signed add-on `llm-strata` (25th) must be built, signed and published with the next version; until
  an add-on for it is installed, the built-in provider shows.
- Configure… in the Flutter app does not exist for local LLMs (all of them).
