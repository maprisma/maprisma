"""The application's identity: Maprisma (called Asterism until 2026-10-30).

Maprisma knows nothing of the GTK app AI Agents Map (docs/plan-naming.md, step 7).
"""

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent
HOME = Path.home()


def name() -> str:
    return "Maprisma"


def app_id() -> str:
    return "com.maprisma.Maprisma"


def short_name() -> str:
    return "maprisma"


def config_dir() -> Path:
    configured = os.environ.get("XDG_CONFIG_HOME", "")
    root = Path(configured) if configured and Path(configured).is_absolute() else HOME / ".config"
    return root / short_name()


def cache_dir() -> Path:
    configured = os.environ.get('XDG_CACHE_HOME', '')
    root = Path(configured) if configured and Path(configured).is_absolute() else HOME / '.cache'
    return root / short_name()
