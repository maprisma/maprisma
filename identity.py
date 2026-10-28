"""Application identity is independent of the desktop integration.

Asterism packages include the add-on loader; the legacy plugin build omits it
(tools/sync-plugin.py). This build fact, rather than the current desktop, selects
the identity. Both editions may use either desktop backend.
"""

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent
HOME = Path.home()


def is_plugin() -> bool:
    return not (ROOT / "addons.py").is_file()


def name() -> str:
    return "AI Agents Map" if is_plugin() else "Asterism"


def app_id() -> str:
    return "org.omarchy.aiagentsmap" if is_plugin() else "io.github.ubruckhaus.Asterism"


def short_name() -> str:
    return "ai-agents-map" if is_plugin() else "asterism"


def config_dir() -> Path:
    if is_plugin():
        return HOME / ".config/omarchy/ai-agents-map"
    configured = os.environ.get("XDG_CONFIG_HOME", "")
    root = Path(configured) if configured and Path(configured).is_absolute() else HOME / ".config"
    return root / "asterism"


def cache_dir() -> Path:
    configured = os.environ.get('XDG_CACHE_HOME', '')
    root = Path(configured) if configured and Path(configured).is_absolute() else HOME / '.cache'
    return root / short_name()
