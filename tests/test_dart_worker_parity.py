"""Development parity: the Python and Dart workers apply the same private plan to identical homes
and leave identical trees; each side undoes the other's backup. Skipped without a native Dart SDK."""
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'tools'))

import connect  # noqa: E402
import flutter_plan_wire  # noqa: E402

try:
    from dart_sdk import resolve_dart
    DART = resolve_dart()
except (OSError, ValueError, RuntimeError):
    DART = None

CORE = ROOT / 'packages/maprisma_core'
STAMP = re.compile(r'^\d{8}-\d{6}-\d{6}$')


def seed(home: Path):
    (home / '.codex').mkdir(parents=True)
    (home / '.codex/config.toml').write_text('model = "a"\n# kept\n')
    os.chmod(home / '.codex/config.toml', 0o644)
    for name in ('set-a', 'set-b'):
        (home / f'skills/{name}').mkdir(parents=True)
        (home / f'skills/{name}/SKILL.md').write_text('---\nname: x\n---\n')
    (home / '.claude/skills').mkdir(parents=True)
    os.symlink(home / 'skills/set-b', home / '.claude/skills/set-b')


def plan_for(home: Path) -> connect.Plan:
    return connect.Plan('codex', 'llamacpp', 'llama-local', changes=[
        connect.Change(home / '.codex/config.toml', 'model = "a"\n# kept\n', 'model = "b"\n# kept\n'),
        connect.Change(home / '.config/new/deep/settings.json', '', '{"ünïcode": "✓"}\n'),
    ], links_add=[(home / '.claude/skills/set-a', home / 'skills/set-a')],
       links_remove=[(home / '.claude/skills/set-b', home / 'skills/set-b')])


def tree(home: Path) -> dict:
    found = {}
    for path in sorted(home.rglob('*')):
        rel = '/'.join('<backup>' if STAMP.match(part) else part for part in path.relative_to(home).parts)
        mode = os.lstat(path).st_mode & 0o7777
        if path.is_symlink():
            found[rel] = ('link', os.readlink(path).replace(str(home), '$HOME'), mode)
        elif path.is_dir():
            found[rel] = ('dir', mode)
        else:
            text = path.read_bytes().replace(str(home).encode(), b'$HOME')
            found[rel] = ('file', text, mode)
    return found


def run_worker(command, home: Path, body: bytes) -> dict:
    with tempfile.TemporaryFile() as private:
        private.write(body)
        private.seek(0)
        os.fchmod(private.fileno(), 0o600)
        argv = command + ['--plan-fd', str(private.fileno())]
        out = subprocess.run(argv, input=b'{"operation": "connections.apply", "params": {}}\n',
                             capture_output=True, pass_fds=(private.fileno(),), timeout=120,
                             env={**os.environ, 'HOME': str(home)}, cwd=CORE if command[0] == DART else ROOT)
    lines = [json.loads(line) for line in out.stdout.splitlines() if line.startswith(b'{')]
    return lines[-1]


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartWorkerParityTest(unittest.TestCase):
    def test_same_plan_same_tree_and_cross_undo(self):
        with tempfile.TemporaryDirectory() as temp:
            homes = [Path(temp) / side for side in ('python', 'dart')]
            results = []
            for home, command in zip(homes, ([sys.executable, '-u', str(ROOT / 'flutter_worker.py')],
                                             [DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                              'bin/maprisma-core.dart', 'worker'])):
                home.mkdir()
                seed(home)
                body = flutter_plan_wire.encode(plan_for(home), home / '.backups')
                results.append(run_worker(command, home, body))
            self.assertEqual([r['type'] for r in results], ['result', 'result'], results)
            self.assertEqual(tree(homes[0]), tree(homes[1]))
            # Undo crossed: Python undoes the Dart backup, the Dart probe the Python backup.
            python_backup, dart_backup = (Path(r['result']['backup']) for r in results)
            env = {**os.environ, 'HOME': str(homes[1])}
            undo = subprocess.run([sys.executable, '-c', 'import sys,connect,json;'
                                   'print(json.dumps([str(p) for p in connect.undo(__import__("pathlib").Path(sys.argv[1]))]))',
                                   str(dart_backup)], capture_output=True, env=env, cwd=ROOT, timeout=60, check=True)
            probe = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                    'bin/fixture_probe.dart'], capture_output=True, cwd=CORE, timeout=120,
                                   env={**os.environ, 'HOME': str(homes[0])},
                                   input=json.dumps({'id': 1, 'protocol': 2, 'method': 'dev.undo',
                                                     'params': {'folder': str(python_backup)}}).encode() + b'\n')
            restored_py = json.loads(undo.stdout)
            restored_dart = json.loads(probe.stdout.splitlines()[-1])['result']['restored']
            self.assertEqual([p.replace(str(homes[1]), '$HOME') for p in restored_py],
                             [p.replace(str(homes[0]), '$HOME') for p in restored_dart])
            self.assertEqual(tree(homes[0]), tree(homes[1]))
            self.assertEqual((homes[0] / '.codex/config.toml').read_text(), 'model = "a"\n# kept\n')
            self.assertFalse((homes[0] / '.config/new').exists())

    def test_refuses_a_changed_file_and_a_shared_plan_file(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            seed(home)
            body = flutter_plan_wire.encode(plan_for(home), home / '.backups')
            (home / '.codex/config.toml').write_text('model = "edited meanwhile"\n')
            result = run_worker([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                 'bin/maprisma-core.dart', 'worker'], home, body)
            self.assertEqual(result, {'type': 'error', 'code': 'operation_failed'})
            self.assertFalse((home / '.backups').exists())
            self.assertFalse((home / '.claude/skills/set-a').exists())


if __name__ == '__main__':
    unittest.main()
