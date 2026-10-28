"""Opaque, expiring model-removal previews with fresh worker-side file checks."""
from __future__ import annotations

import os
from pathlib import Path
import time
import uuid
import json

import flutter_providers
import inventory
import llm_engine
import models_ctl
import providers

MAX_RECORD_BYTES = 1024 * 1024


def _identity(path: Path) -> list:
    info = path.lstat()
    return [str(path), str(path.resolve()), info.st_dev, info.st_ino, info.st_mode,
            info.st_size, info.st_mtime_ns, os.readlink(path) if path.is_symlink() else None]


def _record(key: str, model: str) -> tuple[dict, inventory.Runtime]:
    rt = flutter_providers.runtime(key)
    if not rt.installed or not isinstance(model, str) or not model or len(model) > 300 or model not in rt.models:
        raise ValueError('Model unavailable')
    engine = llm_engine.of(rt)
    if engine.removable not in ('file', 'api'):
        raise ValueError('This provider cannot remove models here')
    root = None
    if rt.models_dir:
        directory = Path(rt.models_dir).expanduser()
        if directory.is_dir():
            info = directory.stat()
            root = [str(directory.resolve()), info.st_dev, info.st_ino]
    result = {'version': 1, 'key': key, 'provider_name': rt.name, 'model': model, 'mode': engine.removable,
              'address': rt.address, 'models_dir': rt.models_dir, 'root': root,
              'files': [], 'size': 0, 'links_only': False, 'shared': []}
    if engine.removable == 'file':
        if root is None:
            raise ValueError('Model folder unavailable')
        processes = inventory.own_processes()
        others = {}
        for provider in providers.local():
            if provider.key != key and provider.detect is not None:
                other = provider.detect(processes)
                if other.models_dir:
                    others[other.name] = (other.key, other.models_dir)
        removal = models_ctl.removal(key, Path(rt.models_dir).expanduser(), model, others)
        result.update(files=[_identity(path) for path in sorted(removal.paths)], size=removal.size,
                      links_only=removal.links_only, shared=sorted(removal.shared or []))
    return result, rt


def record(key: str, model: str) -> dict:
    return _record(key, model)[0]


class Removals:
    def __init__(self):
        self.items: dict[str, tuple[float, dict]] = {}

    def preview(self, params: dict) -> dict:
        if set(params) != {'key', 'model'} or not isinstance(params['key'], str) or not isinstance(params['model'], str):
            raise ValueError('Invalid model removal')
        snapshot = record(params['key'], params['model'])
        if len(json.dumps(snapshot, ensure_ascii=False).encode()) > MAX_RECORD_BYTES:
            raise ValueError('Removal preview too large')
        now = time.monotonic()
        self.items = {key: value for key, value in self.items.items() if now - value[0] < 300}
        while len(self.items) >= 8:
            self.items.pop(next(iter(self.items)))
        token = uuid.uuid4().hex
        self.items[token] = (now, snapshot)
        return {'removal': token, 'model': snapshot['model'], 'provider': snapshot['provider_name'],
                'address': snapshot['address'], 'mode': snapshot['mode'],
                'files': [entry[0] for entry in snapshot['files']], 'size': snapshot['size'],
                'links_only': snapshot['links_only'], 'shared': snapshot['shared']}

    def apply(self, token: str, queue) -> dict:
        if token not in self.items:
            raise ValueError('Unknown removal preview')
        created, snapshot = self.items[token]
        if time.monotonic() - created >= 300:
            raise ValueError('Removal preview expired')
        result = queue(snapshot)
        del self.items[token]
        return result


def execute(snapshot: dict) -> dict:
    if not isinstance(snapshot, dict) or snapshot.get('version') != 1:
        raise ValueError('Invalid private removal')
    current, rt = _record(snapshot['key'], snapshot['model'])
    if current != snapshot:
        raise ValueError('The model or its shared references changed; preview again')
    engine = llm_engine.of(rt)
    if snapshot['mode'] == 'file':
        models_ctl.trash([Path(entry[0]) for entry in snapshot['files']])
    else:
        engine.remove(rt, snapshot['model'])
    engine.refresh(rt)
    return {'ok': True, 'recoverable': snapshot['mode'] == 'file'}
