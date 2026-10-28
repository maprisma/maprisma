"""Owned PTY sessions for a non-GTK frontend (Linux/Unix).

Only the service supplies argv from a registered adapter. No shell, sockets,
credential files, unbounded output queue or transcript storage.
"""

from __future__ import annotations

import codecs
import errno
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import termios
import uuid
import time
from dataclasses import dataclass, field
from pathlib import Path


def _controlling_terminal():
    # The service is deliberately single-threaded: preexec_fn is used only here.
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


@dataclass
class Session:
    process: subprocess.Popen
    master: int
    decoder: object
    command: str
    cwd: str
    eof: bool = False
    exited_at: float | None = None
    children: dict[int, str] = field(default_factory=dict)


def _identity(pid: int) -> tuple[int, int, str] | None:
    try:
        fields = (Path('/proc') / str(pid) / 'stat').read_text().rsplit(')', 1)[1].split()
        return int(fields[2]), int(fields[3]), fields[19]
    except (OSError, ValueError, IndexError):
        return None


def _group_members(pgid: int) -> dict[int, str]:
    found = {}
    try:
        paths = list(Path('/proc').iterdir())
    except OSError:
        return found
    for path in paths:
        if path.name.isdigit() and int(path.name) != pgid:
            identity = _identity(int(path.name))
            if identity and identity[:2] == (pgid, pgid):
                found[int(path.name)] = identity[2]
    return found


def _remember_group(session: Session):
    # While the leader is alive or unreaped, its group cannot have been reused.
    session.children.update(_group_members(session.process.pid))


def _refresh_group(session: Session):
    # A surviving known member anchors the original group through this scan.
    anchors = {pid: birth for pid, birth in session.children.items()
               if _identity(pid) == (session.process.pid, session.process.pid, birth)}
    if anchors:
        found = _group_members(session.process.pid)
        if any(_identity(pid) == (session.process.pid, session.process.pid, birth)
               for pid, birth in anchors.items()):
            session.children.update(found)


def _stop_children(session: Session):
    handles = []
    try:
        for pid, birth in session.children.items():
            try:
                fd = os.pidfd_open(pid)
            except ProcessLookupError:
                continue
            if _identity(pid) == (session.process.pid, session.process.pid, birth):
                handles.append(fd)
            else:
                os.close(fd)
        for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGKILL):
            for fd in handles:
                try:
                    signal.pidfd_send_signal(fd, sig)
                except ProcessLookupError:
                    pass
            ready = set(select.select(handles, [], [], 0.2)[0]) if handles else set()
            for fd in ready:
                os.close(fd)
            handles = [fd for fd in handles if fd not in ready]
            if not handles:
                break
    finally:
        for fd in handles:
            os.close(fd)


class Sessions:
    def __init__(self):
        self.items: dict[str, Session] = {}

    def start(self, command: str, argv: list[str], cwd: str, env: dict[str, str]) -> str:
        if len(self.items) >= 32:
            raise ValueError('Too many terminal sessions')
        master, slave = pty.openpty()
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
            process = subprocess.Popen(argv, cwd=cwd, env=env, stdin=slave, stdout=slave, stderr=slave,
                                       close_fds=True, preexec_fn=_controlling_terminal)
        except BaseException:
            os.close(master)
            raise
        finally:
            os.close(slave)
        os.set_blocking(master, False)
        ident = uuid.uuid4().hex
        self.items[ident] = Session(process, master, codecs.getincrementaldecoder('utf-8')('replace'), command, cwd)
        _remember_group(self.items[ident])
        return ident

    def poll(self, session: Session):
        if session.process.returncode is None:
            try:
                exited = os.waitid(os.P_PID, session.process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                if exited is not None:
                    _remember_group(session)
            except ChildProcessError:
                pass
        return session.process.poll()

    def read(self, ident: str) -> dict:
        session = self.items[ident]
        data = b''
        if not session.eof:
            try:
                data = os.read(session.master, 64 * 1024)
                if not data:
                    session.eof = True
            except BlockingIOError:
                pass
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                session.eof = True
        text = session.decoder.decode(data, final=session.eof)  # type: ignore[attr-defined]
        # Do not finalize the incremental decoder a second time.
        if session.eof:
            session.decoder = codecs.getincrementaldecoder('utf-8')('replace')
        code = self.poll(session)
        if code is not None and session.exited_at is None:
            session.exited_at = time.monotonic()
        drained = session.eof or (session.exited_at is not None and time.monotonic() - session.exited_at >= 1)
        return {'text': text, 'exit_code': code, 'ended': drained and code is not None}

    def write(self, ident: str, data: bytes) -> dict:
        session = self.items[ident]
        if self.poll(session) is not None:
            return {'accepted': 0, 'ended': True}
        if len(data) > 16 * 1024:
            raise ValueError('Terminal input unavailable')
        # Bounded input; report accepted bytes so the client never silently loses a suffix.
        if not select.select([], [session.master], [], 0.1)[1]:
            return {'accepted': 0}
        try:
            return {'accepted': os.write(session.master, data)}
        except BlockingIOError:
            return {'accepted': 0}

    def resize(self, ident: str, cols: int, rows: int) -> dict:
        if type(cols) is not int or type(rows) is not int or not (2 <= cols <= 1000 and 2 <= rows <= 1000):
            raise ValueError('Invalid terminal dimensions')
        fcntl.ioctl(self.items[ident].master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
        return {}

    def stop(self, ident: str) -> dict:
        session = self.items.pop(ident)
        try:
            # A completed tab may stay open for hours. Its PID can be reused;
            # never signal a process group after we have reaped its leader.
            if self.poll(session) is not None:
                _refresh_group(session)
                return {}
            _remember_group(session)
            # The group is owned by this still-unreaped leader.
            for sig, timeout in ((signal.SIGHUP, 0.3), (signal.SIGTERM, 0.3), (signal.SIGKILL, 0.3)):
                try:
                    os.killpg(session.process.pid, sig)
                except ProcessLookupError:
                    break
                try:
                    session.process.wait(timeout=timeout)
                    break
                except subprocess.TimeoutExpired:
                    continue
            session.process.wait(timeout=1)
        finally:
            try:
                _stop_children(session)
            finally:
                os.close(session.master)
        return {}

    def close(self):
        for ident in list(self.items):
            try:
                self.stop(ident)
            except (OSError, subprocess.TimeoutExpired):
                pass
