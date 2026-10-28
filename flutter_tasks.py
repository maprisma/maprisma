"""Bounded process jobs; keeps the stdio service single-threaded for PTY spawn."""
from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import uuid
import tempfile
import time
from typing import Callable
from dataclasses import dataclass, field

import flutter_providers

MAX_FRAME = 1024 * 1024
SCANS = ('map.snapshot', 'setup.detect', 'guide.snapshot', 'system.refresh')
COMMITS = ('connections.apply', 'models.remove', 'addons.install', 'installers.install', 'existing.apply', 'system.move_apply', 'system.move_undo')


@dataclass
class Task:
    process: subprocess.Popen
    operation: str
    state: str = 'running'
    fraction: float = 0.0
    text: str = ''
    result: dict = field(default_factory=dict)
    buffer: bytes = b''
    finalize: Callable[[dict], dict] | None = None


class Tasks:
    def __init__(self, worker: Path | None = None):
        self.worker = worker or Path(__file__).with_name('flutter_worker.py')
        self.items: dict[str, Task] = {}
        self.snapshot_worker = worker or Path(__file__).with_name('flutter_snapshot_worker.py')
        self._snapshot_id: str | None = None

    def start(self, operation: str, params: dict) -> dict:
        flutter_providers.validate(operation, params)
        return self._spawn(operation, params)

    def start_catalog(self, settings_path, finalize) -> dict:
        return self._spawn('addons.catalog', {'settings_path': str(settings_path) if settings_path else None}, finalize=finalize)

    def start_addon_install(self, record: dict, settings_path, finalize) -> dict:
        import flutter_addon_catalog
        body = json.dumps({'record': record, 'settings_path': str(settings_path) if settings_path else None},
                          ensure_ascii=True, allow_nan=False).encode()
        if len(body) > flutter_addon_catalog.MAX_PLAN:
            raise ValueError('Add-on plan too large')
        return self._private('addons.install', body, finalize)

    def start_installer_preview(self, selection: dict, settings_path, finalize) -> dict:
        return self._spawn('installers.preview', {'selection':selection,
            'settings_path':str(settings_path) if settings_path else None}, finalize=finalize)

    def start_installer(self, plan: dict) -> dict:
        import flutter_installers
        body = json.dumps(plan,ensure_ascii=True,allow_nan=False).encode()
        if len(body)>flutter_installers.MAX_PLAN:
            raise ValueError('Installer plan too large')
        return self._private('installers.install',body)

    def start_system(self, settings_path, search, finalize) -> dict:
        return self._spawn('system.refresh', {'settings_path': str(settings_path) if settings_path else None, 'search': search}, finalize=finalize)

    def start_system_analysis(self, record: dict) -> dict:
        body = json.dumps(record,ensure_ascii=True,allow_nan=False).encode()
        if len(body)>128*1024:
            raise ValueError('System analysis request too large')
        return self._private('system.analyze',body)

    def start_existing_scan(self, path: str, finalize) -> dict:
        return self._spawn('existing.scan', {'path': path}, finalize=finalize)

    def start_existing_check(self, record: dict) -> dict:
        return self._private('existing.check', json.dumps(record).encode())

    def start_existing_apply(self, record: dict, finalize) -> dict:
        import flutter_existing
        body = json.dumps(record, ensure_ascii=True, allow_nan=False).encode()
        if len(body) > flutter_existing.MAX_BYTES:
            raise ValueError('Reconnect plan too large')
        return self._private('existing.apply', body, finalize)

    def start_guide(self, settings_path) -> dict:
        return self._spawn('guide.snapshot', {'settings_path':str(settings_path) if settings_path else None})

    def start_setup(self, settings_path) -> dict:
        return self._spawn('setup.detect', {'settings_path': str(settings_path) if settings_path else None})

    def start_snapshot(self, settings_path, owned, force=False) -> dict:
        self.poll()
        params = {'settings_path': str(settings_path) if settings_path else None, 'owned': owned, 'force': force}
        ident = self._snapshot_id
        if ident in self.items:
            item = self.items[ident]
            if item.state == 'running':
                return {'task': ident}
            if item.process.poll() is None and item.state == 'done':
                assert item.process.stdin is not None
                try:
                    item.process.stdin.write((json.dumps({'operation': 'map.snapshot', 'params': params}) + '\n').encode())
                    item.process.stdin.flush()
                    item.state, item.result = 'running', {}
                    return {'task': ident}
                except OSError:
                    pass
            self._close(ident)
            del self.items[ident]
        result = self._spawn('map.snapshot', params)
        self._snapshot_id = result['task']
        return result

    def start_plan(self, plan, backup_root: Path, finalize) -> dict:
        import flutter_plan_wire
        if not callable(finalize):
            raise ValueError('A private result handler is required')
        body = flutter_plan_wire.encode(plan, backup_root)
        return self._private('connections.apply', body, finalize)

    def start_removal(self, record: dict) -> dict:
        import flutter_removals
        body = json.dumps(record, ensure_ascii=False, allow_nan=False).encode()
        if len(body) > flutter_removals.MAX_RECORD_BYTES:
            raise ValueError('Removal preview too large')
        return self._private('models.remove', body)

    def _private(self, operation: str, body: bytes, finalize=None) -> dict:
        # TemporaryFile is unlinked/private; only this child inherits the FD.
        with tempfile.TemporaryFile() as private:
            private.write(body)
            private.seek(0)
            return self._spawn(operation, {}, private.fileno(), finalize)

    def _spawn(self, operation: str, params: dict, private_fd: int | None = None, finalize=None) -> dict:
        self.poll()
        limit = 1 if operation in SCANS else 4
        active = sum(item.process.poll() is None for item in self.items.values()
                     if (item.operation == operation if operation in SCANS else item.operation not in SCANS))
        if active >= limit:
            raise ValueError('Too many active operations')
        while len(self.items) >= 32:
            done = next((key for key, item in self.items.items() if item.state != 'running' and key != self._snapshot_id), None)
            if done is None:
                raise ValueError('Too many operations')
            self._close(done)
            del self.items[done]
        worker = self.snapshot_worker if operation == 'map.snapshot' else self.worker
        argv = [sys.executable, '-u', str(worker)]
        if private_fd is not None:
            argv += ['--plan-fd', str(private_fd)]
        process = subprocess.Popen(argv, cwd=worker.parent,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   start_new_session=True, pass_fds=() if private_fd is None else (private_fd,))
        assert process.stdin is not None and process.stdout is not None
        try:
            process.stdin.write((json.dumps({'operation': operation, 'params': params}) + '\n').encode())
            process.stdin.flush()
        except BaseException:
            process.kill()
            process.wait()
            process.stdin.close()
            process.stdout.close()
            raise
        os.set_blocking(process.stdout.fileno(), False)
        ident = uuid.uuid4().hex
        self.items[ident] = Task(process, operation, finalize=finalize)
        return {'task': ident}

    def poll(self):
        for ident, item in self.items.items():
            if item.state != 'running':
                item.process.poll()
                continue
            assert item.process.stdout is not None
            try:
                data = os.read(item.process.stdout.fileno(), 64 * 1024)
            except BlockingIOError:
                continue
            item.buffer += data
            if len(item.buffer) > MAX_FRAME:
                item.state = 'failed'
                self._close(ident)
                continue
            try:
                while b'\n' in item.buffer:
                    line, item.buffer = item.buffer.split(b'\n', 1)
                    message = json.loads(line)
                    if message['type'] == 'progress':
                        item.fraction = float(message['fraction'])
                        item.text = str(message.get('text', ''))[:300]
                    elif message['type'] == 'result' and isinstance(message['result'], dict):
                        result = message['result']
                        if callable(item.finalize):
                            result = item.finalize(result)
                        item.result, item.state = result, 'done'
                    else:
                        item.state = 'failed'
                if not data and item.state == 'running':
                    item.state = 'failed'
            except Exception:
                item.state = 'failed'
            if item.state == 'failed':
                self._close(ident)

    def status(self, ident: str) -> dict:
        self.poll()
        item = self.items[ident]
        return {'task': ident, 'operation': item.operation, 'state': item.state,
                'fraction': item.fraction, 'text': item.text, 'result': item.result}

    def _close(self, ident: str):
        item = self.items[ident]
        if item.process.poll() is None:
            try:
                os.killpg(item.process.pid, signal.SIGTERM)
                item.process.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(item.process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                item.process.wait(timeout=2)
            except ProcessLookupError:
                item.process.wait()
        if item.process.stdin:
            item.process.stdin.close()
        if item.process.stdout:
            item.process.stdout.close()

    def cancel(self, ident: str) -> dict:
        self.poll()
        if self.items[ident].state != 'running':
            return self.status(ident)
        if self.items[ident].operation in COMMITS:
            raise ValueError('A commit cannot be cancelled')
        self._close(ident)
        self.items[ident].state = 'stopped'
        return self.status(ident)

    def close(self):
        for ident, item in self.items.items():
            if item.operation in COMMITS:
                # The private worker owns everything needed to finish. Drain while
                # waiting so progress output cannot block its commit. Never signal it.
                deadline = time.monotonic() + 30
                while item.process.poll() is None and time.monotonic() < deadline:
                    self.poll()
                    time.sleep(0.02)
                self.poll()
                if item.process.poll() is None:
                    continue  # detached worker completes even after the UI exits
            try:
                self._close(ident)
            except (OSError, subprocess.TimeoutExpired):
                continue
