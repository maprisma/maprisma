"""Persistent read-only map scanner. No PTYs or configuration migration here."""
from __future__ import annotations

import contextlib
import json
from pathlib import Path
import sys
from types import SimpleNamespace
from typing import Any, cast

import addons
import ai_core
import i18n
import settings_schema
from flutter_addons import AdapterRegistry
from flutter_backend import Service

MAX_REQUEST = 64 * 1024


def registry_key(saved):
    stamps = []
    for folder in addons.find():
        try:
            info = folder.stat()
            stamps.append((str(folder), info.st_ino, info.st_mtime_ns))
        except OSError:
            continue
    return (tuple(sorted(settings_schema.value(saved, 'addons_enabled'))), tuple(stamps))


def main():
    output = sys.stdout
    service = None
    key = None
    location = None
    cache = {}
    while raw := sys.stdin.buffer.readline(MAX_REQUEST + 1):
        if len(raw) > MAX_REQUEST:
            return
        try:
            request = json.loads(raw)
            if request['operation'] != 'map.snapshot' or set(request['params']) != {'settings_path', 'owned', 'force'}:
                raise ValueError('Invalid scan request')
            params = request['params']
            chosen = params['settings_path']
            if service is None:
                location = chosen
                service = Service(Path(chosen) if chosen else None)
                service.adapters = AdapterRegistry()
            if chosen != location:
                raise ValueError('Scan settings location changed')
            with contextlib.redirect_stdout(sys.stderr):
                saved = ai_core.load_settings(service.settings_path)
                i18n.SETTINGS_FILE = service.settings_path or ai_core.settings_file()
                i18n._lang = None
                current = registry_key(saved)
                if current != key:
                    assert service.adapters is not None
                    service.adapters.reload(set(settings_schema.value(saved, 'addons_enabled')))
                    key = current
                    cache.clear()
                service.sessions = cast(Any, SimpleNamespace(items={
                    str(i): SimpleNamespace(command=row['command'],
                        process=SimpleNamespace(pid=row['pid'], poll=lambda: None))
                    for i, row in enumerate(params['owned'])}))
                targets = None if params['force'] else settings_schema.value(saved, 'map_scan_targets')
                result = service.build_map(cache, targets)
            response = {'type': 'result', 'result': result}
        except Exception:
            response = {'type': 'error', 'code': 'operation_failed'}
        output.write(json.dumps(response, ensure_ascii=True, allow_nan=False) + '\n')
        output.flush()


if __name__ == '__main__':
    main()
