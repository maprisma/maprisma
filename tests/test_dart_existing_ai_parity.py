"""Development parity: finding and reconnecting AI programs on a mounted data disk (existing.scan,
preview, check, apply) through the Python backend and the Dart core. The "other distro" is a temporary
folder on the data disk this checkout lives on (/tmp is not a data disk by design): an Ollama install
with its model store, a llama.cpp program and a GGUF folder; the programs are copies of /usr/bin/true.
Reconnect files go to a temporary HOME per side. Skipped without a native Dart SDK or when this
checkout is not on a supported mounted disk."""
import json
import re
import os
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tests'))
try:
    from dart_sdk import resolve_dart
    DART = resolve_dart()
except (OSError, ValueError, RuntimeError):
    DART = None

import existing_ai  # noqa: E402
from test_dart_agent_start_parity import PYTHON_SERVICE, Side  # noqa: E402

# The production service has no settings path: its System Map cache is in XDG_CACHE_HOME.
SERVICE = PYTHON_SERVICE.replace('flutter_backend.Service(ai_core.settings_file())', 'flutter_backend.Service()')
assert SERVICE != PYTHON_SERVICE
ON_DISK = any(ROOT.parent.is_relative_to(m['path']) for m in existing_ai.mounts())


def seed_disk(disk: Path):
    true = Path(shutil.which('true')).read_bytes()
    def program(path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(true)
        os.chmod(path, 0o755)
    program(disk / 'distro/ollama/v0.40/bin/ollama')
    (disk / 'distro/ollama/current').symlink_to('v0.40')
    for name in ('manifests/registry.ollama.ai/library/qwen3', 'blobs'):
        (disk / 'distro/ollama-store' / name).mkdir(parents=True)
    (disk / 'distro/ollama-store/manifests/registry.ollama.ai/library/qwen3/8b').write_text('{}')
    program(disk / 'distro/llama/llama-server')
    (disk / 'distro/gguf').mkdir()
    for name in ('a-Q4.gguf', 'b-Q8.gguf'):
        (disk / 'distro/gguf' / name).write_text(f'GGUF {name}')
    (disk / 'distro/.hidden').mkdir()
    (disk / 'distro/notes.txt').write_text('notes')


def home_files(home: Path) -> dict:
    found = {}
    for path in sorted(home.rglob('*')):
        rel = str(path.relative_to(home))
        if rel.startswith(('.cache', '.local/share', '.local/state', '.config/asterism')) or path.is_dir():
            continue
        found[rel] = (path.read_text(errors='replace'), oct(path.stat().st_mode & 0o777))
    settings = home / '.config/asterism/settings.json'
    found['model_folders'] = json.loads(settings.read_text()).get('model_folders') if settings.exists() else None
    # The backups' manifests by content: the reference's production service keeps them in
    # ~/.local/state/ai-agents-map/backups, the core in its config folder (phase 3).
    roots = [home / '.local/state/ai-agents-map/backups', home / '.config/asterism/connection-backups']
    found['backups'] = [(folder / 'manifest.json').read_text() for root in roots if root.is_dir()
                        for folder in sorted(root.iterdir())]
    return found


@unittest.skipIf(DART is None or not ON_DISK, 'native Dart SDK or a mounted data disk not available')
class DartExistingAiParityTest(unittest.TestCase):
    def test_same_discovery_and_reconnect(self):
        sides = {}
        with tempfile.TemporaryDirectory(prefix='.asterism-parity-', dir=ROOT.parent) as disk_name, \
                tempfile.TemporaryDirectory() as temp:
            disk = Path(disk_name)
            seed_disk(disk)
            for side in ('python', 'dart'):
                home = Path(temp) / side
                (home / '.config/asterism').mkdir(parents=True)
                (home / '.config/asterism/settings.json').write_text(json.dumps({'setup_done': True}))
                env = {'HOME': str(home), 'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8',
                       'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_CACHE_HOME': str(home / '.cache'),
                       'XDG_DATA_HOME': str(home / '.local/share'), 'ASTERISM_DESKTOP': 'generic',
                       'ASTERISM_FLUTTER_DEVEL': '1'}
                runner = (Side([sys.executable, '-c', SERVICE, str(ROOT)], ROOT, env) if side == 'python' else
                          Side([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                'bin/asterism-core.dart'], ROOT / 'packages/asterism_core', env))
                answers = []

                def wait(reply):
                    if 'task' not in reply:
                        return reply
                    for _ in range(300):
                        status = runner.call('tasks.status', {'task': reply['task']})
                        if status.get('state') != 'running':
                            break
                        time.sleep(0.1)
                    return [status.get('state'), status.get('result')]

                try:
                    answers.append(runner.call('existing.scan', {'path': '/tmp'}))
                    answers.append(runner.call('existing.scan', {'path': str(disk / 'nowhere')}))
                    state, scanned = wait(runner.call('existing.scan', {'path': str(disk)}))
                    found = {item['path'].replace(str(disk), '$DISK') + ':' + item['kind']: item['found']
                             for item in scanned['items']}
                    answers.append([state, {**scanned, 'items': [{**i, 'found': '<handle>'} for i in scanned['items']]}])
                    def preview(record, models):
                        reply = runner.call('existing.preview', {'found': found.get(record, 'x'),
                                                                 'models': found.get(models) if models else None})
                        return reply
                    plans = {}
                    for label, record, models in (
                            ('ollama', '$DISK/distro/ollama/v0.40/bin/ollama:runtime', '$DISK/distro/ollama-store:store'),
                            ('ollama wrong models', '$DISK/distro/ollama/v0.40/bin/ollama:runtime', '$DISK/distro/gguf:models'),
                            ('llama', '$DISK/distro/llama/llama-server:runtime', '$DISK/distro/gguf:models'),
                            ('gguf folder', '$DISK/distro/gguf:models', None),
                            ('store alone', '$DISK/distro/ollama-store:store', None),
                            ('unknown', 'nothing', None)):
                        reply = preview(record, models)
                        if 'plan' in reply:
                            plans[label] = reply['plan']
                            reply = {**reply, 'plan': '<plan>'}
                        answers.append([label, reply])
                    answers.append(runner.call('existing.preview', {'found': 'x'}))
                    answers.append(['check', wait(runner.call('existing.check',
                                                              {'found': found['$DISK/distro/llama/llama-server:runtime']}))])
                    for label in ('llama', 'gguf folder', 'llama'):
                        result = wait(runner.call('existing.apply', {'plan': plans[label]}))
                        if isinstance(result, list) and isinstance(result[1], dict):
                            result = [result[0], {k: '<handle>' if k == 'undo' else v for k, v in result[1].items()}]
                        answers.append([label, result])
                    # A file changed after the scan: its record no longer holds.
                    (disk / 'distro/ollama-store/new').write_text('x')
                    answers.append(['changed', wait(runner.call('existing.apply', {'plan': plans['ollama']}))])
                finally:
                    runner.close()
                (disk / 'distro/ollama-store/new').unlink(missing_ok=True)
                text = json.dumps([answers, home_files(home)]).replace(str(home), '$HOME').replace(str(disk), '$DISK')
                sides[side] = json.loads(re.sub(r'"(core-)?[0-9a-f]{32}"', '"<handle>"', text))
        self.maxDiff = None
        self.assertEqual(sides['python'], sides['dart'])
        answers, files = sides['dart']
        self.assertEqual(answers[2][0], 'done')
        self.assertEqual(len(answers[2][1]['items']), 4)
        self.assertIn('.local/bin/llama-server', files)
        self.assertEqual(files['model_folders'], ['$DISK/distro/gguf'])
        self.assertEqual(answers[0], {'error': 'refused'})                     # /tmp is no data disk
        self.assertEqual(answers[10][1], ['done', {'ok': True, 'checked': True}])
        self.assertEqual(answers[11][1][0], 'done')
        self.assertEqual(answers[13][1], {'error': 'refused'})                 # a plan is used once
        self.assertEqual(answers[14][1][0], 'failed')                          # changed since the scan
        self.assertEqual(len(files['backups']), 2)


if __name__ == '__main__':
    unittest.main()
