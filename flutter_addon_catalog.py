"""Signed catalog previews and worker-only installation of service adapters.

The frontend receives metadata and expiring opaque previews, never archive URLs,
archive hashes, destination directories or commands. A worker resolves the signed
catalog again and requires the complete reviewed entry to match before download.
"""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import asdict
import fcntl
import os
import stat
import json
from pathlib import Path
import time
import uuid

import addon_store
import addons
import ai_core
from flutter_addons import SUPPORTED
import settings_schema

MAX_BYTES = 768 * 1024
MAX_PLAN = 64 * 1024
TTL = 600


def installed() -> dict[str, addons.Addon]:
    found = {}
    for path in addons.find():
        item = addons.verify(path)
        if item.id and item.state == 'verified':
            found[item.id] = item
    return found


def catalog_records(settings_path: Path | None) -> dict:
    online = settings_schema.value(ai_core.load_settings(settings_path), 'addons_online') is True
    entries = addon_store.catalog(online=online)
    known = installed()
    records = []
    used = 0
    for entry in entries[:addon_store.MAX_ENTRIES]:
        record = {'entry': asdict(entry), 'installed_version': known[entry.id].version if entry.id in known else ''}
        size = len(json.dumps(record, ensure_ascii=True).encode())
        if used + size + 4096 > MAX_BYTES:
            break
        used += size + 2
        records.append(record)
    return {'records': records, 'online': online}


class Catalog:
    def __init__(self):
        self.previews: dict[str, tuple[float, dict]] = {}

    def register(self, result: dict) -> dict:
        records = result.get('records')
        if (not isinstance(records, list) or len(records) > addon_store.MAX_ENTRIES
                or type(result.get('online')) is not bool or len(json.dumps(result).encode()) > MAX_BYTES):
            raise ValueError('Invalid catalog result')
        previews, public = {}, []
        for record in records:
            entry = addon_store.Entry(**record['entry'])
            old = record['installed_version']
            if not isinstance(old, str):
                raise ValueError('Invalid installed version')
            supported = entry.kind in SUPPORTED
            action = 'install' if not old else ('update' if addon_store.newer(entry.version, old) else '')
            token = uuid.uuid4().hex
            if supported and action:
                previews[token] = (time.monotonic(), record)
            public.append({'id': entry.id, 'name': entry.name, 'version': entry.version,
                           'kind': entry.kind, 'summary': entry.summary, 'description': entry.description,
                           'reads': entry.reads, 'sends': entry.sends, 'capabilities': entry.capabilities, 'privacy': entry.privacy,
                           'supported': supported, 'installed_version': old, 'action': action,
                           'preview': token if token in previews else None,
                           'present': addon_store.present(entry)})
        self.previews = previews
        return {'entries': public, 'online': result['online']}

    def apply(self, token: str, queue) -> dict:
        if token not in self.previews:
            raise ValueError('Unknown add-on preview')
        created, record = self.previews[token]
        if time.monotonic() - created >= TTL:
            raise ValueError('Add-on preview expired')
        result = queue(record)
        del self.previews[token]
        return result


@contextmanager
def install_lock():
    # The lock is outside the add-ons directory so discovery never treats it as
    # an add-on. It also serializes a detached install with a restarted UI.
    root = addons.USER_DIR.parent.resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(directory)
        if info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise ValueError('Untrusted add-on storage directory')
        fd = os.open('.catalog-install.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC,
                     0o600, dir_fd=directory)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ValueError('Untrusted add-on installation lock')
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            os.close(fd)
    finally:
        os.close(directory)


def execute(body: bytes) -> dict:
    """Private worker handoff; signatures/hashes remain addon_store's responsibility."""
    if len(body) > MAX_PLAN:
        raise ValueError('Add-on plan too large')
    plan = json.loads(body)
    if not isinstance(plan, dict) or set(plan) != {'record', 'settings_path'}:
        raise ValueError('Invalid private add-on plan')
    with install_lock():
        return _execute_locked(plan)


def _execute_locked(plan: dict) -> dict:
    chosen = plan['settings_path']
    path = Path(chosen) if chosen else None
    if settings_schema.value(ai_core.load_settings(path), 'addons_online') is not True:
        raise ValueError('Online add-on access disabled')
    record = plan['record']
    reviewed = record['entry']
    entries = addon_store.catalog(online=True)
    entry = next((item for item in entries if asdict(item) == reviewed), None)
    if entry is None or entry.kind not in SUPPORTED:
        raise ValueError('Catalog changed; review again')
    current = installed().get(entry.id)
    version = current.version if current else ''
    if version != record['installed_version']:
        raise ValueError('Installed add-on changed; review again')
    if version and not addon_store.newer(entry.version, version):
        raise ValueError('Only a newer version may replace an installed add-on')
    item = addon_store.install(entry)
    return {'ok': True, 'id': item.id, 'version': item.version}
