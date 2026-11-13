"""Any other desktop (GNOME, KDE, …): the generic implementation of desktop.py's interface.

- app identity and configuration paths: identity.py, independently of this backend
- theme: libadwaita's colours for the system's light or dark style and accent
  colour (Adw.StyleManager, else `gsettings` org.gnome.desktop.interface
  color-scheme / accent-color; light and blue when unknown); windows have
  libadwaita's 12 px corners
- windows: GTK itself (the window is handed over with attach_window); the
  desktop draws the title bar
- terminals: xdg-terminal-exec, $TERMINAL, then the usual ones (Console, Ptyxis,
  GNOME Terminal, Konsole, COSMIC Terminal, Xfce Terminal, foot, Alacritty, kitty, WezTerm, xterm)
- agents: the built-in list (agents.FALLBACK), no default agent, no usage
  records (agents' own stores still count, agent_status)
- install hints: the command of the package manager found (apt, dnf, zypper,
  pacman), with that distribution's package name.

Programs are run as argv lists with bounded output; a command that waits at the end
runs through `bash -c` with every word quoted (shlex.join).
"""

import json
import os
import re
import shlex
import shutil
import subprocess
from pathlib import Path

NAME = "generic"
HOME = Path.home()
RADIUS = 12          # libadwaita's window corners

# libadwaita's palette (Adwaita named colours), light and dark.
ACCENTS = {"blue": "#3584e4", "teal": "#2190a4", "green": "#3a944a", "yellow": "#c88800", "orange": "#ed5b00",
           "red": "#e62d42", "pink": "#d56199", "purple": "#9141ac", "slate": "#6f8396"}
LIGHT = {"background": "#fafafb", "foreground": "#323233", "muted": "#77767b", "selection": "#dedddf",
         "red": "#e01b24", "yellow": "#e5a50a", "orange": "#ff7800", "green": "#2ec27e", "magenta": "#9141ac",
         "cyan": "#2190a4"}
DARK = {"background": "#222226", "foreground": "#ffffff", "muted": "#9a9996", "selection": "#3a3a3e",
        "red": "#ff7b63", "yellow": "#f8e45c", "orange": "#ffa348", "green": "#8ff0a4", "magenta": "#dc8add",
        "cyan": "#93ddc2"}

# Terminals: (program, how argv follows it).
TERMINALS = (("xdg-terminal-exec", []), ("kgx", ["--"]), ("ptyxis", ["--"]), ("gnome-terminal", ["--"]),
             ("konsole", ["-e"]), ("cosmic-term", ["--"]), ("xfce4-terminal", ["-x"]), ("foot", []), ("alacritty", ["-e"]),
             ("kitty", []), ("wezterm", ["start", "--"]), ("xterm", ["-e"]))

# Package names per package manager.
PACKAGES = {"vte4": {"apt": "gir1.2-vte-3.91", "dnf": "vte291-gtk4", "zypper": "typelib-1_0-Vte-3_91",
                     "pacman": "vte4"},
            "xdg-terminal-exec": {"pacman": "xdg-terminal-exec"}}
MANAGERS = (("apt", "sudo apt install {0}"), ("dnf", "sudo dnf install {0}"), ("zypper", "sudo zypper install {0}"),
            ("pacman", "sudo pacman -S {0}"))

_window = None


# --- theme ----------------------------------------------------------------------------------------

def _gsetting(key: str) -> str:
    import ai_core
    gsettings = shutil.which("gsettings")
    if gsettings is None:
        return ""
    out, ok = ai_core.read_bounded_output([gsettings, "get", "org.gnome.desktop.interface", key],
                                          max_bytes=1024, timeout=2)
    return out.decode("utf-8", "replace").strip().strip("'") if ok else ""


def theme_dir():
    return None             # the style is read on start (and on reload)


def theme_colors(path=None) -> dict:
    """libadwaita's colours for the system style; path: a TOML file instead (tests)."""
    if path is not None:
        import desktop_omarchy
        return desktop_omarchy.theme_colors(path)
    style = _adw_style()
    if style is not None:
        dark, accent = style
    else:
        dark = _gsetting("color-scheme") == "prefer-dark"
        accent = ACCENTS.get(_gsetting("accent-color"), ACCENTS["blue"])
    colors = dict(DARK if dark else LIGHT)
    colors["accent"] = accent
    return colors


def desktop_palette(environ=None) -> dict:
    """The desktop's colours as every Maprisma app reads them (Dart: desktop_palette.dart): COSMIC's
    theme, Plasma's kdeglobals, Maprisma Shell's scheme.json on Hyprland; {} elsewhere."""
    env = os.environ if environ is None else environ
    names = env.get("XDG_CURRENT_DESKTOP", "").upper().split(":")
    home = env.get("HOME", "")

    def xdg(key, fallback):
        value = env.get(key)
        return value if value and os.path.isabs(value) else os.path.join(home, fallback)

    if "COSMIC" in names:
        colors = cosmic_palette(xdg("XDG_CONFIG_HOME", ".config"))
    elif "KDE" in names:
        colors = kde_palette(_read_small(os.path.join(xdg("XDG_CONFIG_HOME", ".config"), "kdeglobals"), 1 << 20) or "")
    elif "HYPRLAND" in names:
        colors = shell_palette(_read_small(os.path.join(xdg("XDG_STATE_HOME", ".local/state"), "maprisma-shell",
                                                        "scheme.json"), 256 * 1024) or "")
    else:
        return {}
    return {key: value for key, value in colors.items() if value is not None}


def _read_small(path, limit):
    try:
        if not os.path.isfile(path) or os.path.getsize(path) > limit:
            return None
        with open(path, "rb") as handle:
            return handle.read().decode("utf-8", "replace")
    except OSError:
        return None


def shell_palette(text: str) -> dict:
    try:
        data = json.loads(text)
    except ValueError:
        return {}
    colours = data.get("colours") if isinstance(data, dict) else None
    if not isinstance(colours, dict):
        return {}

    def c(key):
        value = colours.get(key)
        if isinstance(value, str) and re.fullmatch(r"#?[0-9a-fA-F]{6}", value):
            return "#" + value.lstrip("#").lower()
        return None

    return {"accent": c("primary"), "background": c("surface") or c("background"), "foreground": c("onSurface"),
            "muted": c("outline"), "selection": c("surfaceContainerHighest"), "red": c("error") or c("red"),
            "yellow": c("yellow"), "orange": c("peach"), "green": c("green")}


def _ini(text, group, key):
    current = found = None
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
        elif current == group and "=" in line and line.index("=") > 0:
            name, value = line.split("=", 1)
            if name.strip() == key:
                found = value.strip()
    return found


def _rgb(value):
    if value is None:
        return None
    parts = [int(v.strip()) if v.strip().lstrip("-").isdigit() else None for v in value.split(",")]
    if len(parts) not in (3, 4) or any(v is None or not 0 <= v <= 255 for v in parts):
        return None
    return "#" + "".join("%02x" % v for v in parts[:3])


def kde_palette(text: str) -> dict:
    def c(group, key):
        return _rgb(_ini(text, group, key))
    return {"accent": c("General", "AccentColor") or c("Colors:View", "DecorationFocus")
            or c("Colors:Selection", "BackgroundNormal"),
            "background": c("Colors:Window", "BackgroundNormal"), "foreground": c("Colors:Window", "ForegroundNormal"),
            "selection": c("Colors:Selection", "BackgroundNormal"), "muted": c("Colors:Window", "ForegroundInactive"),
            "red": c("Colors:View", "ForegroundNegative"), "yellow": c("Colors:View", "ForegroundNeutral"),
            "green": c("Colors:View", "ForegroundPositive")}


def cosmic_palette(config_home: str) -> dict:
    def config(component, key):
        # The newest schema first in each: COSMIC 1.x keeps its themes in v2 (v1 empty or stale).
        for base in (os.path.join(config_home, "cosmic"), "/usr/share/cosmic"):
            for version in ("v2", "v1"):
                text = _read_small(os.path.join(base, component, version, key), 256 * 1024)
                if text is not None:
                    return text
        return None

    dark = (config("com.system76.CosmicTheme.Mode", "is_dark") or "true").strip() != "false"
    theme = "com.system76.CosmicTheme.Dark" if dark else "com.system76.CosmicTheme.Light"

    def field(key, name):
        text = config(theme, key)
        return None if text is None else ron_color(ron_field(text, name))

    return {"accent": field("accent", "base") or ron_color(config(theme, "accent")),
            "background": field("background", "base"), "foreground": field("background", "on"),
            "green": field("success", "base"), "yellow": field("warning", "base"), "red": field("destructive", "base")}


def ron_field(text: str, key: str):
    depth, i = 0, 0
    while i < len(text):
        c = text[i]
        if c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif depth == 1 and text.startswith(key, i) and (i == 0 or not re.match(r"\w", text[i - 1])):
            j = i + len(key)
            while j < len(text) and text[j] == " ":
                j += 1
            if j < len(text) and text[j] == ":":
                start = j = j + 1
                d = 0
                while j < len(text):
                    cj = text[j]
                    if cj in "([":
                        d += 1
                    if cj in ")]":
                        if d == 0:
                            break
                        d -= 1
                    if cj == "," and d == 0:
                        break
                    j += 1
                return text[start:j].strip()
        i += 1
    return None


def ron_color(value):
    if value is None:
        return None
    # COSMIC 1.x (schema v2) writes colours as "#RRGGBBAA" strings.
    m = re.fullmatch(r'"?#([0-9a-fA-F]{6})(?:[0-9a-fA-F]{2})?"?', value.strip())
    if m:
        return "#" + m.group(1).lower()

    def part(name):
        m = re.search(name + r":\s*([0-9.eE+-]+)", value)
        try:
            v = float(m.group(1)) if m else None
        except ValueError:
            v = None
        return None if v is None else int(min(max(v, 0.0), 1.0) * 255 + 0.5)  # as Dart's round()

    r, g, b = part("red"), part("green"), part("blue")
    return None if None in (r, g, b) else "#%02x%02x%02x" % (r, g, b)


def _adw_style():
    """(dark, accent hex) from libadwaita's style manager (the system's style, also through
    the desktop portal on KDE), or None before there is a display (tests, the watcher)."""
    try:
        import gi
        gi.require_version("Adw", "1")
        from gi.repository import Adw, Gdk
        if Gdk.Display.get_default() is None:
            return None
        manager = Adw.StyleManager.get_default()
        rgba = manager.get_accent_color_rgba()
        accent = "#%02x%02x%02x" % tuple(round(c * 255) for c in (rgba.red, rgba.green, rgba.blue))
        return manager.get_dark(), accent
    except (ImportError, ValueError, AttributeError):
        return None


def window_rounding() -> int:
    """The windows' corner radius: on Hyprland its own rounding (square on Omarchy unless a theme or
    the user rounds it), elsewhere libadwaita's."""
    hypr = _hyprland()
    rounding = hypr.window_rounding() if hypr is not None else None
    return RADIUS if rounding is None else rounding


def rounding_source() -> str:
    return "hyprland" if _hyprland() is not None else "desktop"


def corners_note() -> str:
    from i18n import _
    if _hyprland() is not None:
        return _("Corners of the window, its cards and the map's boxes. “Like windows” follows Hyprland's "
                 "window rounding.")
    return _("Your windows have the desktop's rounded corners.")


def stays_in_background() -> bool:
    """Closing quits, as other apps do (unless agents or downloads still run in it)."""
    return False


def decorated() -> bool:
    return True             # the desktop (or GTK) draws the title bar with its buttons


def header_moves_window() -> bool:
    """The header drags the window like a title bar (and double-click maximizes): on desktops whose
    windows are moved by hand. Not on a tiling one (Hyprland): there a drag would only float it."""
    return _hyprland() is None


# --- windows --------------------------------------------------------------------------------------

def attach_window(window):
    global _window
    _window = window


def _on_window(action):
    from gi.repository import GLib
    if _window is None:
        return False
    GLib.idle_add(lambda: action(_window) and False)
    return True


def focus_window(app_id: str) -> bool:
    return _on_window(lambda w: w.present())


def focus_process(pids: list[int]) -> bool:
    """Under Hyprland (any distribution) the compositor brings the program's window (or its
    terminal's) to the front; other programs' windows cannot be raised from here on most other
    desktops (Wayland)."""
    hypr = _hyprland()
    return hypr is not None and hypr.focus_process(pids)


def windows() -> dict:
    """Under Hyprland its windows; other desktops do not tell (Wayland)."""
    hypr = _hyprland()
    return hypr.windows() if hypr is not None else {}


def _hyprland():
    """desktop_omarchy's window actions when the session is Hyprland (any distribution, not only
    Omarchy): Hyprland ignores a window's own maximize request (Omarchy suppresses the event for
    every window) and reports every tiled window as maximized, so ask the compositor itself."""
    if not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") or shutil.which("hyprctl") is None:
        return None
    import desktop_omarchy
    return desktop_omarchy


def is_maximized(app_id: str):
    hypr = _hyprland()
    if hypr is not None:
        return hypr.is_maximized(app_id)
    return _window.is_maximized() if _window is not None else None


def maximize(app_id: str) -> bool:
    hypr = _hyprland()
    if hypr is not None and hypr.maximize(app_id):
        return True
    return _on_window(lambda w: w.maximize())



# --- terminals ------------------------------------------------------------------------------------

def _resolves(launcher: str) -> bool:
    try:
        return subprocess.run([launcher, "--print-id"], stdin=subprocess.DEVNULL, capture_output=True,
                              check=False).returncode == 0
    except OSError:
        return False


def terminal() -> list | None:
    """The terminal to start programs in: [program, argument before argv…], or None."""
    own = os.environ.get("TERMINAL", "")
    if own and re.fullmatch(r"[A-Za-z0-9._+-]{1,64}", own) and shutil.which(own):
        known = dict(TERMINALS).get(own, ["-e"])
        return [shutil.which(own), *known]
    for program, follow in TERMINALS:
        path = shutil.which(program)
        # It exits with an error when it finds no terminal entry, and a detached
        # start would hide that: then the next one on the list.
        if path and program == "xdg-terminal-exec" and not _resolves(path):
            continue
        if path:
            return [path, *follow]
    return None


def launch_app(argv: list) -> bool:
    """An app window of its own (LM Studio)."""
    try:
        subprocess.Popen([str(a) for a in argv], cwd=str(HOME), stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        return False
    return True


def open_terminal(argv: list, cwd: str) -> bool:
    launcher = terminal()
    if launcher is None:
        return False
    try:
        subprocess.Popen([*launcher, *argv], cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        return False
    return True


def run_in_terminal(argv: list, env: dict | None = None) -> bool:
    """argv in a terminal that stays open until Enter (every word quoted for bash)."""
    from i18n import _
    words = (["env", *(f"{k}={v}" for k, v in env.items())] if env else []) + list(argv)
    prompt = _("Done. Press Enter to close.")
    script = f"{shlex.join(words)}; echo; read -r -p {shlex.quote(prompt)} _"
    return open_terminal(["bash", "-c", script], str(HOME))


def run_steps_in_terminal(steps: list) -> bool:
    """Several commands, one after the other while each succeeds, in one terminal that stays open
    until Enter (every word quoted for bash)."""
    from i18n import _
    steps = [list(map(str, s)) for s in steps if s]
    if not steps:
        return False
    prompt = _("Done. Press Enter to close.")
    script = " && ".join(shlex.join(s) for s in steps) + f"; echo; read -r -p {shlex.quote(prompt)} _"
    return open_terminal(["bash", "-c", script], str(HOME))


# --- agents ---------------------------------------------------------------------------------------

def agent_catalog():
    """The built-in list; glyphs from Omarchy's own font (not installed here) become the robot."""
    import agents
    return [(command, label, icon if font != "omarchy" else agents.ROBOT, "" if font == "omarchy" else font)
            for command, label, icon, font in agents.FALLBACK]


def default_agent() -> str:
    return ""


# A PC that also runs Omarchy keeps usage records per agent (plan, limits and when they reset, tokens per
# day) and the tool that refreshes them: used here too, read only, the way the Omarchy edition does.
OMARCHY_USAGE = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "omarchy/agents/usage"
USAGE_TIMEOUT = 60


def usage_collector(command: str) -> str | None:
    """Omarchy's collector of this agent's usage: in Omarchy's bin folder, /usr/bin or anywhere on PATH."""
    if not re.fullmatch(r"[a-z0-9-]{1,64}", command):
        return None
    root = Path(os.environ.get("OMARCHY_PATH") or "/usr/share/omarchy")
    for folder in (root / "bin", Path("/usr/bin")):
        if (folder / f"omarchy-agent-usage-{command}").is_file():
            return str(folder / f"omarchy-agent-usage-{command}")
    return shutil.which(f"omarchy-agent-usage-{command}")


def usage_dir():
    return OMARCHY_USAGE if OMARCHY_USAGE.is_dir() else None


def has_usage_collector(command: str) -> bool:
    return usage_collector(command) is not None


USAGE_LIMIT = 4 * 1024 * 1024   # the most a collector may print


def refresh_usage(command: str) -> bool:
    """Fresh usage of this agent (blocking; run it on a thread): Omarchy's update tool where Omarchy is,
    else the collector itself, whose one JSON object becomes the record. No credential is read here."""
    collector = usage_collector(command)
    if collector is None:
        return False
    update = shutil.which("omarchy-agent-usage-update") if os.environ.get("OMARCHY_PATH") else None
    try:
        result = subprocess.run([update, command] if update else [collector], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=USAGE_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return False
    if result.returncode != 0:
        return False
    if update:
        return True
    if len(result.stdout) > USAGE_LIMIT:
        return False
    try:
        record = json.loads(result.stdout)
    except ValueError:
        return False
    if not isinstance(record, dict):
        return False
    OMARCHY_USAGE.mkdir(parents=True, exist_ok=True)
    temporary = OMARCHY_USAGE / f".{command}.json.tmp"
    temporary.write_text(json.dumps(record) + "\n", encoding="utf-8")
    temporary.replace(OMARCHY_USAGE / f"{command}.json")
    return True


# --- texts that name the desktop -------------------------------------------------------------------

def text(key: str) -> str:
    from i18n import _
    return {
        "install_agent": _("Install it with its own installer (see the agent's website)."),
        "install_agent_first": _("Install one with its own installer (Claude Code, Codex or OpenCode to start with)."),
        "install_agent_short": _("Each agent has its own installer (see its website)."),
        "install_coding_agent": _("Claude Code, Codex or OpenCode, each with its own installer."),
        "install_terminal": _("Install a terminal app (Console, Konsole, …):"),
    }[key]


# --- packages -------------------------------------------------------------------------------------

def package_manager() -> str:
    return next((name for name, _cmd in MANAGERS if shutil.which(name)), "")


def install_command(package: str) -> str:
    """The command that installs one of the packages in PACKAGES ("" when unknown here)."""
    manager = package_manager()
    name = PACKAGES.get(package, {}).get(manager)
    template = dict(MANAGERS).get(manager)
    return template.format(name) if name and template else ""
