"""Project-folder choices for individual agents, independent of the terminal UI.

Resolve links before launch: a project outside the home folder must become the
agent's actual working directory, rather than a link inside another workspace.
"""

from __future__ import annotations

from pathlib import Path


def folder(value) -> str | None:
    if not isinstance(value, str) or not value or "\0" in value:
        return None
    try:
        path = Path(value).expanduser()
        if not path.is_absolute():
            return None
        path = path.resolve(strict=True)
        return str(path) if path.is_dir() else None
    except (OSError, ValueError, RuntimeError):
        return None


def selected(command: str, saved, default: str) -> str:
    value = saved.get(command) if isinstance(saved, dict) else None
    return folder(value) or folder(default) or str(Path.home())


def pin(command: str, chosen: str | None, saved) -> dict[str, str]:
    """One optional pinned default per agent, independent of its launch history."""
    kept = dict(saved) if isinstance(saved, dict) else {}
    if chosen is None:
        kept.pop(command, None)
    else:
        resolved = folder(chosen)
        if resolved is None:
            raise ValueError("The project folder is unavailable")
        kept[command] = resolved
    return kept


def history(command: str, saved) -> list[str]:
    """All recorded folders, newest first; retain missing folders so they can be removed."""
    values = saved.get(command, []) if isinstance(saved, dict) else []
    if not isinstance(values, list):
        return []
    found = []
    seen = set()
    for value in values:
        if (isinstance(value, str) and value and "\0" not in value and Path(value).is_absolute()
                and value not in seen):
            found.append(value)
            seen.add(value)
    return found


def used(command: str, chosen: str, saved) -> dict[str, list[str]]:
    resolved = folder(chosen)
    if resolved is None:
        raise ValueError("The project folder is unavailable")
    kept = dict(saved) if isinstance(saved, dict) else {}
    kept[command] = ([resolved] + [p for p in history(command, saved) if p != resolved])[:50]
    return kept


def forget(command: str, chosen: str, saved, pinned) -> tuple[dict, dict]:
    """Remove only a history entry and its optional pin; never touch the filesystem."""
    kept = dict(saved) if isinstance(saved, dict) else {}
    kept[command] = [p for p in history(command, saved) if p != chosen]
    pins = dict(pinned) if isinstance(pinned, dict) else {}
    if pins.get(command) == chosen:
        pins.pop(command, None)
    return kept, pins
