#!/usr/bin/env python3
"""Dev-only differential oracle: isolated fixture homes, responses, bytes, modes.

Only fixture HOME prefixes are normalized. No blanket masking of error codes,
handles, times or PIDs: add route-specific normalizers when later phases need
those. Never initialize adapters or inspect the user's real configuration.
"""
from __future__ import annotations
import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import re
from contextlib import contextmanager
from dart_sdk import resolve_dart
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
BACKUP = re.compile(r'^\d{8}-\d{6}-\d{6}$')
HANDLE = re.compile(r'^(core-)?[0-9a-f]{32}$')


def masked(value, key=None):
    """Opaque handles (plan, undo, task) are random on each side: compare them as placeholders."""
    if isinstance(value, dict):
        return {k: masked(v, k) for k, v in value.items()}
    if isinstance(value, list):
        return [masked(v) for v in value]
    if key in ('plan', 'undo', 'task') and isinstance(value, str) and HANDLE.match(value):
        return '<handle>'
    return value


def interactive(command, case, home, env):
    """Requests one at a time: "refs" take a parameter from an earlier reply ({"plan": [3,
    "result", "plan"]}), "until_done" repeats a tasks.status until it no longer runs."""
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               env=env, cwd=ROOT / 'packages/asterism_core')
    replies = []
    try:
        for i, request in enumerate(case['requests']):
            body = {k: v for k, v in expand(request, home).items() if k not in ('refs', 'until_done')}
            params = dict(body.get('params', {}))
            for name, path in request.get('refs', {}).items():
                value = replies[path[0]]
                for step in path[1:]:
                    value = value[step]
                params[name] = value
            body['params'] = params
            for attempt in range(600):
                process.stdin.write((json.dumps({'id': i, 'protocol': 1, **body}, ensure_ascii=False) + '\n').encode())
                process.stdin.flush()
                reply = json.loads(process.stdout.readline())
                if not request.get('until_done') or reply.get('result', {}).get('state') != 'running':
                    break
                time.sleep(0.05)
            replies.append(reply)
    finally:
        process.stdin.close()
        process.wait(timeout=60)
    return replies


def fixture_mounts(home):
    root = Path(os.path.abspath(home))
    mounts = []
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        fields = line.split()
        if len(fields) < 6:
            raise RuntimeError('Invalid mountinfo; refusing fixture traversal')
        decoded = re.sub(r'\\([0-7]{3})', lambda match: chr(int(match[1], 8)), fields[4])
        mount = Path(decoded)
        if mount == root or root in mount.parents:
            mounts.append(str(mount))
    return mounts


def assert_no_mounts(home):
    mounts = fixture_mounts(home)
    if mounts:
        raise RuntimeError('Unexpected fixture mount(s); stop and unmount explicitly: ' + ', '.join(mounts))


@contextmanager
def fixture_root():
    root = Path(tempfile.mkdtemp(prefix='asterism-diff-'))
    try:
        yield root
    finally:
        # Never recurse into a mounted SDK during cleanup, even on subprocess
        # failure or timeout. Preserve the fixture and report the mount paths.
        assert_no_mounts(root)
        shutil.rmtree(root)


def oracle():
    sys.path.insert(0, str(ROOT))
    import flutter_backend
    import i18n
    i18n.set_name('AI Agents Map', 'Asterism')
    import ai_core
    if os.environ.get('ASTERISM_DIFF_COMPONENT') == 'scans':
        import core_scan_oracle
        service=core_scan_oracle.service()
        for line in sys.stdin:
            request=json.loads(line)
            try:
                result=core_scan_oracle.dispatch(service,request['method'],request.get('params',{}))
                response={'id':request['id'],'result':result}
            except Exception:
                response={'id':request.get('id'),'error':{'code':'invalid_request'}}
            print(json.dumps(response,default=str),flush=True)
        return
    ai_core.migrate_settings()
    if os.environ.get('ASTERISM_DIFF_COMPONENT') == 'adapters':
        import adapter_data
        import tomllib
        for line in sys.stdin:
            request = json.loads(line)
            ident = request.get('id')
            try:
                if request['method'] != 'adapter.validate':
                    raise ValueError('Invalid component')
                params = request['params']
                if set(params) not in ({'file'}, {'facts'}):
                    raise ValueError('Invalid fields')
                if 'file' in params:
                    path = Path(params['file'])
                    if path.is_absolute() or '..' in path.parts:
                        raise ValueError('Escaping path')
                    import ai_core
                    fd = ai_core.open_regular(Path.home() / path, follow=False)
                    try:
                        if os.fstat(fd).st_uid not in (0, os.getuid()):
                            raise ValueError('Foreign owner')
                        with os.fdopen(fd, 'rb', closefd=False) as handle:
                            raw = handle.read(adapter_data.MAX_BYTES + 1)
                        if len(raw) > adapter_data.MAX_BYTES:
                            raise ValueError('Oversized')
                        facts = tomllib.loads(raw.decode('utf-8'))
                    finally:
                        os.close(fd)
                else:
                    facts = params['facts']
                adapter_data.check(facts, 'fixture')
                response = {'id':ident, 'result':{'command':facts['command'], 'name':facts['name']}}
            except Exception:
                response = {'id':ident, 'error':{'code':'invalid_request'}}
            print(json.dumps(response), flush=True)
        return
    service = flutter_backend.Service()
    flutter_backend.serve(service, sys.stdin.buffer, sys.stdout)


def expand(value, home):
    if isinstance(value, str):
        return value.replace('$HOME', str(home))
    if isinstance(value, list):
        return [expand(v, home) for v in value]
    if isinstance(value, dict):
        return {k: expand(v, home) for k, v in value.items()}
    return value


def seed(home, fixtures):
    for item in fixtures:
        relative = Path(item['path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Fixture path escapes HOME')
        if relative.name in ('auth.json', '.credentials.json'):
            raise ValueError('Credential fixtures are not needed in phase 1')
        path = home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        kind = item.get('type', 'file')
        if kind == 'symlink':
            path.symlink_to(expand(item['target'], home))
        elif kind == 'fifo':
            os.mkfifo(path, 0o600)
        elif kind == 'directory':
            path.mkdir(exist_ok=True)
        else:
            content = item.get('content', '')
            if 'content_repeat' in item:
                char, count = item['content_repeat']
                content = item.get('content_prefix', '') + char * count + item.get('content_suffix', '')
            if 'base64' in item:
                path.write_bytes(base64.b64decode(item['base64'],validate=True))
            else:
                path.write_text(expand(content, home))
        if 'mode' in item and kind != 'symlink':
            path.chmod(int(item['mode'], 8))


def tree(home):
    result = {}
    # os.walk does not traverse symlink directories; stat is always lstat.
    for folder, dirs, files in os.walk(home, followlinks=False):
        for name in sorted(dirs + files):
            path = Path(folder) / name
            if name in ('auth.json', '.credentials.json'):
                raise ValueError('Unexpected credential file in fixture')
            st = path.lstat()
            mode = stat.S_IMODE(st.st_mode)
            if stat.S_ISLNK(st.st_mode):
                data = ('link', os.readlink(path).replace(str(home), '$HOME'))
            elif stat.S_ISREG(st.st_mode):
                data = ('file', path.read_bytes().replace(os.fsencode(home), b'$HOME'))
            elif stat.S_ISDIR(st.st_mode):
                data = ('directory',)
            else:
                data = ('special', stat.S_IFMT(st.st_mode))
            # Backup folders are named by the time of the apply: compare them by place.
            key = '/'.join('<backup>' if BACKUP.match(part) else part for part in path.relative_to(home).parts)
            result[key] = (mode, *data)
    return result


def run_side(command, case, home):
    seed(home, case.get('files', []))
    timestamp=case.get('environment', {}).get('ASTERISM_SCAN_NOW')
    if timestamp is not None:
        timestamp=float(timestamp)
        for folder, dirs, files in os.walk(home, topdown=False, followlinks=False):
            for name in dirs+files:
                os.utime(Path(folder)/name,(timestamp,timestamp),follow_symlinks=False)
            os.utime(folder,(timestamp,timestamp),follow_symlinks=False)
        # A file may be older than the pinned clock ("age" in seconds), e.g. a finished subagent.
        for item in case.get('files', []):
            if 'age' in item:
                older = timestamp - float(item['age'])
                os.utime(home / item['path'], (older, older), follow_symlinks=False)
    env = {**os.environ, 'HOME': str(home), 'XDG_CONFIG_HOME': str(home / '.config'),
           'XDG_CACHE_HOME': str(home / '.cache'), 'XDG_STATE_HOME': str(home / '.local/state'),
           'XDG_DATA_HOME': str(home / '.local/share'), 'ASTERISM_DESKTOP': 'generic',
           'LANG': 'en_US.UTF-8', 'LC_ALL': '', 'LC_MESSAGES': '', 'PYTHONDONTWRITEBYTECODE': '1'}
    env.update(expand(case.get('environment', {}), home))
    script = []
    for i, request in enumerate(case['requests']):
        if 'raw_repeat' in request:
            char, count = request['raw_repeat']
            script.append(char * count)
        elif 'raw' in request:
            script.append(request['raw'])
        else:
            script.append(json.dumps({'id': i, 'protocol': 1, **expand(request, home)}, ensure_ascii=False))
    if any('refs' in r or 'until_done' in r for r in case['requests']):
        try:
            replies = interactive(command, case, home, env)
        finally:
            assert_no_mounts(home)
        text = json.dumps(replies, ensure_ascii=False).replace(str(home), '$HOME')
        return masked(json.loads(text)), tree(home)
    try:
        output = subprocess.run(command, input=('\n'.join(script)+'\n').encode(),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                                cwd=ROOT / 'packages/asterism_core', timeout=30, check=True)
    finally:
        assert_no_mounts(home)
    responses = [json.loads(line.replace(os.fsencode(home), b'$HOME')) for line in output.stdout.splitlines()]
    if len(responses) != len(script):
        raise AssertionError('Reply count differs from request count')
    return responses, tree(home)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--oracle', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--dart', help='Native SDK executable; shell wrappers are refused')
    parser.add_argument('fixtures', nargs='*', type=Path)
    args = parser.parse_args()
    if args.oracle:
        oracle()
        return
    try:
        args.dart = resolve_dart(args.dart)
    except (OSError, ValueError, RuntimeError) as error:
        parser.error(str(error))
    cases = args.fixtures or sorted((ROOT / 'tests/core-fixtures').glob('*.json'))
    count = 0
    for fixture in cases:
        document = json.loads(fixture.read_text())
        for case in document['cases']:
            with fixture_root() as temp:
                homes = [Path(temp) / side for side in ('python', 'dart')]
                for home in homes:
                    home.mkdir(mode=0o700)
                expected = run_side([sys.executable, str(Path(__file__).resolve()), '--oracle'], case, homes[0])
                entry = 'bin/fixture_probe.dart' if case.get('environment', {}).get('ASTERISM_DIFF_COMPONENT') in ('adapters','scans') else 'bin/asterism-core.dart'
                actual = run_side([args.dart, '--disable-dart-dev', '--packages=.dart_tool/package_config.json', entry], case, homes[1])
                if expected != actual:
                    label = 'responses' if expected[0] != actual[0] else 'file bytes/modes'
                    raise AssertionError(f'{fixture.name}: {case["name"]}: {label} differ\nPython: {expected!r}\nDart: {actual!r}')
                count += 1
                print(f'PASS {fixture.name}: {case["name"]}', flush=True)
    if not count:
        raise SystemExit('No differential cases found')
    print(f'{count} differential cases passed')


if __name__ == '__main__':
    main()
