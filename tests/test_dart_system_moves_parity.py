"""Development parity: moving a model folder from the System Map (the workers' system.move_preview,
system.move_apply, system.move_undo) in the Python reference and the Dart core. Each side gets its own
copy of the same layout: a model folder with its own GGUF files (a split model and a vision file
too), a llama.cpp router folder of links to them, a models.ini naming one, and the app's settings.
Moved once on one disk (hard links) and once to another (from /tmp, a checked copy), then undone. The
destination is a temporary folder on the data disk of this checkout. Skipped without a native Dart SDK
or a mounted data disk."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORE = ROOT / 'packages/asterism_core'
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'tools'))
try:
    from dart_sdk import resolve_dart
    DART = resolve_dart()
except (OSError, ValueError, RuntimeError):
    DART = None

import existing_ai  # noqa: E402

ON_DISK = any(ROOT.parent.is_relative_to(m['path']) for m in existing_ai.mounts())
FILES = ('a-Q4.gguf', 'big-00001-of-00002.gguf', 'big-00002-of-00002.gguf', 'mmproj-a.gguf')


def seed(home: Path, source: Path):
    source.mkdir(parents=True)
    for name in FILES:
        (source / name).write_bytes(name.encode() * 200)
    (source / 'notes.txt').write_text('stays')
    router = home / 'router'
    router.mkdir(parents=True)
    for name in FILES[:3]:
        (router / name).symlink_to(source / name)
    bin_dir = home / '.local/bin'
    bin_dir.mkdir(parents=True)
    (bin_dir / 'llama-server').write_text('#!/bin/sh\nexit 0\n')
    os.chmod(bin_dir / 'llama-server', 0o700)
    units = home / '.config/systemd/user'
    units.mkdir(parents=True)
    (units / 'llama-server.service').write_text(
        f'[Service]\nEnvironment=LLAMA_ARG_MODELS_DIR={router}\nExecStart={bin_dir}/llama-server\n')
    (home / '.config/llama.cpp').mkdir(parents=True)
    (home / '.config/llama.cpp/models.ini').write_text(f'[a-Q4]\nmodel = {router}/a-Q4.gguf\nmmproj = {source}/mmproj-a.gguf\n')
    (home / '.config/asterism').mkdir(parents=True)
    (home / '.config/asterism/settings.json').write_text(json.dumps({'setup_done': True, 'model_folders': [str(source)]}))


def tree(*roots: Path) -> dict:
    found = {}
    for root in roots:
        for path in sorted(root.rglob('*')):
            rel = str(path)
            if '/.config/asterism/model-moves' in rel or '/.cache' in rel or '/.local/state' in rel:
                continue
            if path.is_symlink():
                found[rel] = ('link', os.readlink(path))
            elif path.is_dir():
                found[rel] = ('dir', oct(path.stat().st_mode & 0o777))
            else:
                found[rel] = ('file', path.read_bytes()[:4000], oct(path.stat().st_mode & 0o777), path.stat().st_nlink)
    return found


def run(command, env, operation, body: bytes) -> dict:
    with tempfile.TemporaryFile() as private:
        private.write(body)
        private.seek(0)
        os.fchmod(private.fileno(), 0o600)
        out = subprocess.run(command + ['--plan-fd', str(private.fileno())],
                             input=json.dumps({'operation': operation, 'params': {}}).encode() + b'\n',
                             capture_output=True, pass_fds=(private.fileno(),), timeout=120, env=env,
                             cwd=CORE if command[0] == DART else ROOT)
    lines = [json.loads(line) for line in out.stdout.splitlines() if line.startswith(b'{')]
    return lines[-1] if lines else {'type': 'none', 'stderr': out.stderr.decode()[-500:]}


def projection(record: dict) -> dict:
    """What the preview shows and what the move does, without the private signature."""
    facts = record['facts']
    move = facts['move']
    return {'source': record['source'], 'disk': record['disk'], 'steps': move['steps'], 'size': move['size'],
            'copy': move['copy'], 'root': move['root'], 'back': move['back'], 'lost': facts['lost'],
            'changes': sorted((c['path'], c['new']) for c in facts['config']['changes']),
            'links_add': sorted(map(tuple, facts['config']['links_add']))}


@unittest.skipIf(DART is None or not ON_DISK, 'native Dart SDK or a mounted data disk not available')
class DartSystemMovesParityTest(unittest.TestCase):
    def check(self, source_root: Path, disk_root: Path):
        sides = {}
        for side, command in (('python', [sys.executable, '-u', str(ROOT / 'flutter_worker.py')]),
                              ('dart', [DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                        'bin/asterism-core.dart', 'worker'])):
            home, source, disk = disk_root / side / 'home', source_root / side / 'models', disk_root / side / 'dest'
            seed(home, source)
            disk.mkdir(parents=True)
            env = {**os.environ, 'HOME': str(home), 'PATH': f'{home}/.local/bin:/usr/bin:/bin',
                   'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_CACHE_HOME': str(home / '.cache'),
                   'XDG_DATA_HOME': str(home / '.local/share'), 'ASTERISM_DESKTOP': 'generic',
                   'ASTERISM_FLUTTER_DEVEL': '1'}
            settings = str(home / '.config/asterism/settings.json')
            selection = {'source': str(source), 'disk': str(disk),
                         'mount': existing_ai.root_for(str(disk), existing_ai.mounts()), 'settings_path': settings}
            answers = []
            preview = run(command, env, 'system.move_preview', json.dumps(selection).encode())
            self.assertEqual(preview['type'], 'result', preview)
            record = preview['result']
            answers.append(projection(record))
            applied = run(command, env, 'system.move_apply', json.dumps(record).encode())
            answers.append([applied['type'], applied.get('result', {}).get('ok')])
            moved = tree(home, source, disk)
            again = run(command, env, 'system.move_apply', json.dumps(record).encode())
            answers.append(again['type'])                    # the files are gone: the preview changed
            undo = run(command, env, 'system.move_undo',
                       json.dumps({'undo': applied['result']['move_undo'], 'settings_path': settings}).encode())
            answers.append([undo['type'], undo.get('result')])
            back = tree(home, source, disk)
            text = json.dumps([answers, moved, back], default=str)
            for path, name in ((home, '$HOME'), (source, '$SRC'), (disk, '$DISK')):
                text = text.replace(str(path), name)
            sides[side] = json.loads(text)
        self.maxDiff = None
        self.assertEqual(sides['python'], sides['dart'])
        return sides['dart']

    def test_same_moves(self):
        with tempfile.TemporaryDirectory(prefix='.asterism-parity-', dir=ROOT.parent) as on_disk, \
                tempfile.TemporaryDirectory() as in_tmp:
            answers, moved, back = self.check(Path(on_disk) / 'same', Path(on_disk) / 'same')
            self.assertFalse(answers[0]['copy'])
            self.assertEqual(answers[1], ['result', True])
            self.assertEqual(answers[2], 'error')
            self.assertEqual(answers[3], ['result', {'ok': True, 'remaining': 0}])
            self.assertEqual(moved['$DISK/models/a-Q4.gguf'][0], 'file')
            self.assertEqual(moved['$HOME/router/a-Q4.gguf'], ['link', '$DISK/models/a-Q4.gguf'])
            self.assertEqual(back['$SRC/a-Q4.gguf'][0], 'file')
            answers, moved, back = self.check(Path(in_tmp) / 'other', Path(on_disk) / 'other')
            self.assertTrue(answers[0]['copy'])
            self.assertEqual(answers[3], ['result', {'ok': True, 'remaining': 0}])


if __name__ == '__main__':
    unittest.main()
