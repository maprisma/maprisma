"""Strata: a local inference engine (github.com/Niko1221/Strata) with its own terminal app.

`strata launch` (its screens, or a saved launch preset with --no-tui) downloads the engine and a model
and serves it on 127.0.0.1:8080 (OpenAI and Anthropic APIs); `strata launch --stop` stops it. There is
no user service: the app starts the most recently used launch preset and stops through the same CLI.
Its models are its run configs (strata-<id>.json in its install folder); it serves one at a time.
Model downloads and setup stay in Strata's own screens (Configure… → Set up a model).
"""

import json
import os
import re
from pathlib import Path

import llm_engine
from harnesses import Configure, Way
from providers import Provider

# As Strata's own model ids (strata_control/models.py MODEL_ID) and launch preset slugs.
MODEL_ID = re.compile(r"[a-z0-9](?:[a-z0-9_-]|\.(?!\.)){0,127}")
PRESET_NAME = re.compile(r"[a-z][a-z0-9_-]{0,47}")
MAX_ITEMS = 128                      # Strata lists at most 128 run configs itself
MAX_JSON = 256 * 1024
DEFAULT_PORT = 8080
START_TIMEOUT = 900                  # a launch loads the model before it returns (large models: minutes)


def _home() -> Path:
    return Path.home()


def _xdg(name: str, default: str) -> Path:
    value = os.environ.get(name, "")
    return Path(value) if value.startswith("/") else _home() / default


def data_dir() -> Path:
    """$XDG_DATA_HOME/strata: terminal/, components/, install/."""
    return _xdg("XDG_DATA_HOME", ".local/share") / "strata"


def install_dir() -> Path:
    """Where the app and the terminal keep the run configs (discovery.app_install_dir)."""
    return data_dir() / "install"


def presets_dir() -> Path:
    """Saved launch presets (strata_cli/launch/store.py: <profiles>/../launch-presets)."""
    return _xdg("XDG_CONFIG_HOME", ".config") / "strata" / "launch-presets"


def strata_binary() -> str | None:
    """Strata's own `strata`: on PATH or in ~/.local/bin, but only one that resolves into its terminal
    folder ($XDG_DATA_HOME/strata/terminal/…). Another program of that name (the Strata file manager,
    /usr/bin/strata) is not it."""
    import shutil
    terminal = data_dir() / "terminal"
    try:
        root = terminal.resolve()
    except OSError:
        return None
    for candidate in (shutil.which("strata"), str(_home() / ".local/bin/strata"),
                      str(terminal / "current/bin/strata")):
        if not candidate:
            continue
        try:
            real = Path(candidate).resolve()
        except OSError:
            continue
        if real.is_relative_to(root) and real.is_file() and os.access(real, os.X_OK):
            return candidate
    return None


def _json(path: Path) -> dict:
    """A small JSON object file, never a link; {} otherwise."""
    try:
        if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_JSON:
            return {}
        data = json.loads(path.read_bytes())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _port(value) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) and 0 < value < 65536 else 0


def model_ids() -> list[str]:
    """Its installed models: the ids of strata-<id>.json run configs, sorted."""
    found = []
    try:
        entries = sorted(install_dir().iterdir())[:4 * MAX_ITEMS]
    except OSError:
        return []
    for path in entries:
        name = path.name
        if not name.startswith("strata-") or not name.endswith(".json") or name.endswith(".shared-settings.json"):
            continue
        value = name[len("strata-"):-len(".json")]
        if MODEL_ID.fullmatch(value) and not path.is_symlink() and path.is_file():
            found.append(value)
    return found[:MAX_ITEMS]


def last_preset() -> tuple[str, int]:
    """(slug, port) of the launch preset used last (by its last_used, else created); ("", 0) for none.
    Only these two fields are read: a preset file may hold the API key."""
    best, best_time = ("", 0), ""
    try:
        paths = sorted(presets_dir().glob("*.json"))[:MAX_ITEMS]
    except OSError:
        return best
    for path in paths:
        slug = path.name[:-len(".json")]
        if not PRESET_NAME.fullmatch(slug):
            continue
        data = _json(path)
        if not data:
            continue
        last = data.get("last_used")
        stamp = last if isinstance(last, str) and last else data.get("created")
        stamp = stamp if isinstance(stamp, str) and len(stamp) <= 40 else ""
        if not best[0] or stamp > best_time:
            best, best_time = (slug, _port(data.get("port")) or DEFAULT_PORT), stamp
    return best


def is_server(argv: list) -> bool:
    """Strata's API server: its own Python (`… -m serve.server …`) from its terminal folder."""
    exe = argv[0] if argv else ""
    return "/strata/terminal/" in exe and "serve.server" in argv[1:4]


def server_port(argv: list) -> int:
    """The port of a running server: --port, else its run config's "port" (--config), else 8080."""
    try:
        port = llm_engine.arg_number(argv, "--port")
    except ValueError:                   # "--port --8080"
        port = None
    if port and 0 < port < 65536:
        return port
    for i, arg in enumerate(argv):
        if arg == "--config" and i + 1 < len(argv) and argv[i + 1].startswith("/"):
            return _port(_json(Path(argv[i + 1])).get("port")) or DEFAULT_PORT
    return DEFAULT_PORT


def _detect(processes):
    import inventory
    return inventory.strata(processes)


def _installer():
    import install_ctl
    return install_ctl.Strata()


class Engine(llm_engine.Engine):
    """No user service: its own CLI starts the last launch preset and stops it."""
    ports = (DEFAULT_PORT,)
    start_command = "strata launch"
    models_page = False                 # models come from Strata's own screens
    own_model_folder = False
    starts_with_agents = False          # the provider watcher has no control for it: started on the map

    def owns_process(self, comm, argv):
        exe = argv[0] if argv else ""
        # Its terminal's Python (the server, the supervisor) and its engine binary.
        return llm_engine.BY_PATH if "/strata/terminal/" in exe or "/strata/components/" in exe else 0

    def can_control(self, rt):
        return bool(rt.installed and strata_binary() and last_preset()[0])

    def start(self, rt):
        import ai_core
        binary, preset = strata_binary(), last_preset()[0]
        if not binary:
            return False, "strata not found"
        if not preset:
            return False, "no saved launch preset; start one model with `strata launch` first"
        out, ok = ai_core.read_bounded_output([binary, "launch", "--preset", preset, "--yes", "--no-tui"],
                                              max_bytes=64 * 1024, timeout=START_TIMEOUT, merge_stderr=True)
        lines = out.decode("utf-8", "replace").strip().splitlines()
        return ok, (lines[-1] if lines else "")[:300]

    def stop(self, rt):
        binary = strata_binary()
        return llm_engine._run([binary, "launch", "--stop"]) if binary else (False, "strata not found")

    def unload_all(self, rt):
        """POST /v1/unload frees the graphics memory; the server stays up (no key on this computer).
        (runtime_ctl.unload; the map has no per-model unload for it: it cannot load models itself.)"""
        if not self.loaded_models(rt):
            return True, ""
        reply = llm_engine._http(rt, "/v1/unload", "POST", {}, timeout=30)
        return (True, "") if isinstance(reply, dict) else (False, "Strata did not unload")

    def add_model_step(self, rt):
        from i18n import _
        return _("set one up in Strata's own screens: run strata launch in a terminal.")

    def start_step(self, rt, agent_name):
        from i18n import _
        return _("start a model in Strata (strata launch) before working with {0}.").format(agent_name)


PROVIDER = Provider("strata", "Strata", "local", detect=_detect, installer=_installer, engine=Engine(),
                    connect_key="strata-local", connect_label="Strata (local)",
                    install=(Way("installer"), Way("manual", url="https://github.com/Niko1221/Strata#install")),
                    data=("~/.local/share/strata/install", "~/.local/share/strata/components", "~/.strata"),
                    configure=(Configure("Set up a model", ("strata", "launch"),
                                         note="Strata's own screens: choose a model, download it and serve it."),
                               Configure("What is serving", ("strata", "launch", "--status"))),
                    homepage="https://github.com/Niko1221/Strata")
