"""One-time, local migration from the legacy plugin. Originals are never changed.

Copy only the named configuration files and agent profiles, with a private backup
of the original bytes. Publish settings last and never replace existing Asterism
files. Failure rolls back files and the backup created by this attempt; originals remain.
No migration runs at import time.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import shutil
import stat
import tempfile
from pathlib import Path

import identity

FILES = ("settings.json", "mcp-servers.json", "failed-links.json", "providers-with-agents.json")
MAX_FILE = 1024 * 1024
MAX_SETTINGS = 256 * 1024
MAX_TOTAL = 8 * 1024 * 1024
MAX_PROFILES = 128
PROFILE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,80}\.json\Z")


def _directory(path: Path, create: bool = False) -> int:
    """Walk every component without following links, optionally creating private directories."""
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("Migration paths must be absolute")
    home = Path.home()
    anchor = home / '.config' if path.is_relative_to(home / '.config') else home
    parts = path.parts[1:]
    start = Path('/')
    if path.is_relative_to(anchor):
        start = anchor.resolve()
        if not start.exists() and create:
            start.mkdir(mode=0o700, parents=True, exist_ok=True)
        parts = path.relative_to(anchor).parts
    fd = os.open(start, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for part in parts:
            try:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    raise
                try:
                    os.mkdir(part, mode=0o700, dir_fd=fd)
                except FileExistsError:
                    pass                  # another first start may have created this component
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd)
            fd = child
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise ValueError("Migration directory must belong to this user and not be writable by others")
        return fd
    except BaseException:
        os.close(fd)
        raise


def _read(fd: int, name: str, limit: int = MAX_FILE) -> bytes | None:
    try:
        opened = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=fd)
    except FileNotFoundError:
        return None
    with os.fdopen(opened, "rb") as handle:
        info = os.fstat(handle.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o022 or info.st_size > limit):
            raise ValueError("Migration source must be this user's bounded regular file")
        data = handle.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Migration file exceeds its size limit")
    return data


def _snapshot(source: Path) -> dict[str, bytes]:
    try:
        root = _directory(source)
    except FileNotFoundError:
        return {}
    try:
        data = {}
        for name in FILES:
            value = _read(root, name, MAX_SETTINGS if name == "settings.json" else MAX_FILE)
            if name == "settings.json" and value is None:
                return {}
            if value is not None:
                data[name] = value
        if "settings.json" not in data:
            return {}
        try:
            profiles = os.open("agents", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=root)
        except FileNotFoundError:
            profiles = None
        if profiles is not None:
            try:
                info = os.fstat(profiles)
                if info.st_uid != os.getuid() or info.st_mode & 0o022:
                    raise ValueError("Migration profile folder has unsafe ownership or permissions")
                with os.scandir(profiles) as entries:
                    names = [e.name for _, e in zip(range(MAX_PROFILES + 1), entries)]
                if len(names) > MAX_PROFILES:
                    raise ValueError("Too many agent profiles to migrate")
                for name in sorted(names):
                    if not PROFILE.fullmatch(name) or name == "auth.json":
                        continue
                    value = _read(profiles, name)
                    if value is not None:
                        data[f"agents/{name}"] = value
                    if sum(map(len, data.values())) > MAX_TOTAL:
                        raise ValueError("Migration exceeds its total size limit")
            finally:
                os.close(profiles)
        if sum(map(len, data.values())) > MAX_TOTAL:
            raise ValueError("Migration exceeds its total size limit")
        return data
    finally:
        os.close(root)


def _exists(fd: int, name: str) -> bool:
    try:
        os.stat(name, dir_fd=fd, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def migrate(source: Path | None = None, target: Path | None = None) -> bool:
    if identity.is_plugin():
        return False
    source = source or identity.HOME / ".config/omarchy/ai-agents-map"
    target = target or identity.config_dir()
    if os.path.lexists(target / "settings.json"):
        return False                       # never merge into an existing standalone setup
    snapshot = _snapshot(source)
    if not snapshot:
        return False
    settings = json.loads(snapshot["settings.json"])
    if not isinstance(settings, dict):
        raise ValueError("Plugin settings must be a JSON object")
    destination = _directory(target, create=True)
    lock = profiles = None
    created = []
    stage = None
    backup_name = None
    committed = False
    try:
        lock = os.open(".plugin-migration.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC,
                       0o600, dir_fd=destination)
        info = os.fstat(lock)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("Unsafe migration lock")
        fcntl.flock(lock, fcntl.LOCK_EX)
        if _exists(destination, "settings.json"):
            return False                   # another first start finished while this one waited
        stage = Path(tempfile.mkdtemp(prefix=".plugin-migration-", dir=target))
        backup_name = "plugin-backup-" + stage.name.removeprefix(".plugin-migration-")
        backup = stage / "backup"
        for relative, value in snapshot.items():
            saved = backup / relative
            saved.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with saved.open("xb") as handle:
                os.fchmod(handle.fileno(), 0o600)
                handle.write(value)
        settings["plugin_migration"] = {"version": 1, "backup": backup_name, "addons_pending": True}
        published = json.dumps(settings, ensure_ascii=False, indent=2).encode() + b"\n"
        if len(published) > MAX_SETTINGS:
            raise ValueError("Migrated settings exceed the app's size limit")
        settings_path = stage / "settings.json"
        with settings_path.open("xb") as handle:
            os.fchmod(handle.fileno(), 0o600)
            handle.write(published)
        os.rename(backup, backup_name, dst_dir_fd=destination)
        for relative in snapshot:
            if relative == "settings.json":
                continue
            parent, leaf = destination, relative
            if relative.startswith("agents/"):
                if profiles is None:
                    profiles = _directory(target / "agents", create=True)
                parent, leaf = profiles, relative.split("/", 1)[1]
            staged_file = stage / relative
            staged_file.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with staged_file.open("xb") as handle:
                os.fchmod(handle.fileno(), 0o600)
                handle.write(snapshot[relative])
            try:
                os.link(staged_file, leaf, dst_dir_fd=parent, follow_symlinks=False)
            except FileExistsError:
                continue                   # leave a standalone file alone, even without settings.json
            created.append((parent, leaf))
        os.link(settings_path, "settings.json", dst_dir_fd=destination, follow_symlinks=False)
        committed = True
        created.clear()                    # settings commits the migration; repeat starts do nothing
        return True
    finally:
        if backup_name is not None and not committed:
            shutil.rmtree(target / backup_name, ignore_errors=True)
        for parent, name in reversed(created):
            os.unlink(name, dir_fd=parent)
        if stage is not None:
            shutil.rmtree(stage)
        if profiles is not None:
            os.close(profiles)
        if lock is not None:
            os.close(lock)
        os.close(destination)
