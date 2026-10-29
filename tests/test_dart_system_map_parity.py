"""Development parity: the System Map (system.cached / refresh / view / forget_disk, and a disk scan
merged into the saved map) through the Python backend and the Dart core, in a temporary HOME. Both
sides read the same real hardware, mounts and system tools; a disk that went missing is made by
editing the saved map. Skipped without a native Dart SDK or a mounted data disk for the scan."""
import json
import os
import re
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
from test_dart_agent_start_parity import Side  # noqa: E402
from test_dart_existing_ai_parity import SERVICE  # noqa: E402

ON_DISK = any(ROOT.parent.is_relative_to(m['path']) for m in existing_ai.mounts())
IDENTITY = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]


def seed(home: Path):
    bin_dir = home / '.local/bin'
    bin_dir.mkdir(parents=True)
    (bin_dir / 'llama-server').write_text('#!/bin/sh\nexit 0\n')
    os.chmod(bin_dir / 'llama-server', 0o700)
    units = home / '.config/systemd/user'
    units.mkdir(parents=True)
    (units / 'llama-server.service').write_text(
        f'[Service]\nEnvironment=LLAMA_ARG_MODELS_DIR={home}/models\nExecStart={bin_dir}/llama-server\n')
    (home / 'models').mkdir()
    (home / 'models/small-Q4.gguf').write_bytes(b'GGUF' + b'x' * 5000)
    (home / '.config/asterism').mkdir(parents=True)
    (home / '.config/asterism/settings.json').write_text(json.dumps({
        'setup_done': True, 'model_folders': [str(home / 'more-models'), str(home / 'models')]}))


def add_missing_disk(cache: Path):
    """A disk the map saw before that is not mounted now."""
    data = json.loads(cache.read_text())
    data['mounts'].append({'path': '/mnt/Gone', 'filesystem': 'ext4', 'identity': '1:2:3'})
    data['nodes'].append({'id': 'disk:/mnt/Gone', 'label': '/mnt/Gone', 'detail': '1 / 2 GiB', 'column': 1,
                          'kind': 'disk', 'path': '/mnt/Gone', 'status': '', 'info': 'ext4'})
    data['nodes'].append({'id': 'folder:/mnt/Gone/models', 'label': 'Models folder', 'detail': '/mnt/Gone/models',
                          'column': 4, 'kind': 'folder', 'path': '/mnt/Gone/models', 'status': 'available', 'info': ''})
    data['edges'] += [{'source': 'pc', 'target': 'disk:/mnt/Gone'},
                      {'source': 'disk:/mnt/Gone', 'target': 'folder:/mnt/Gone/models'}]
    cache.write_text(json.dumps(data))
    os.chmod(cache, 0o600)


@unittest.skipIf(DART is None or not ON_DISK, 'native Dart SDK or a mounted data disk not available')
class DartSystemMapParityTest(unittest.TestCase):
    def test_same_system_map(self):
        sides = {}
        with tempfile.TemporaryDirectory(prefix='.asterism-parity-', dir=ROOT.parent) as disk_name, \
                tempfile.TemporaryDirectory() as temp:
            disk = Path(disk_name)
            (disk / 'gguf').mkdir()
            (disk / 'gguf/found-Q4.gguf').write_text('GGUF found')
            for side in ('python', 'dart'):
                home = Path(temp) / side
                seed(home)
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
                    for _ in range(900):
                        status = runner.call('tasks.status', {'task': reply['task']})
                        if status.get('state') != 'running':
                            break
                        time.sleep(0.1)
                    return [status.get('state'), status.get('result')]

                def call(label, method, params=None):
                    answers.append([label, wait(runner.call(method, params or {}))])

                try:
                    call('empty', 'system.cached')
                    call('view on nothing', 'system.view', {'selected': None, 'transform': IDENTITY})
                    call('refresh', 'system.refresh')
                    call('cached', 'system.cached')
                    call('view', 'system.view', {'selected': 'gpu', 'transform': [2, *IDENTITY[1:5], 2, *IDENTITY[6:]]})
                    call('bad view', 'system.view', {'selected': None, 'transform': [0] * 16})
                    call('unknown node', 'system.view', {'selected': 'nothing', 'transform': IDENTITY})
                    call('bad refresh', 'system.refresh', {'search': 'yes'})
                    call('forget present', 'system.forget_disk', {'node': 'disk:' + str(home)})
                    add_missing_disk(home / '.cache/asterism/system-map.json')
                    call('refresh with a missing disk', 'system.refresh')
                    call('forget', 'system.forget_disk', {'node': 'disk:/mnt/Gone'})
                    call('scan', 'existing.scan', {'path': str(disk)})
                    call('cached after scan', 'system.cached')
                    call('search', 'system.refresh', {'search': True})
                finally:
                    runner.close()
                cache = json.loads((home / '.cache/asterism/system-map.json').read_text())
                text = json.dumps([answers, cache.get('view'), sorted(cache)])
                text = text.replace(str(home), '$HOME').replace(str(disk), '$DISK')
                text = re.sub(r'"(core-)?[0-9a-f]{32}"', '"<handle>"', text)
                text = re.sub(r'"(checked_at|searched_at)": [0-9.e+]+', r'"\1": 0', text)
                sides[side] = json.loads(text)
        self.maxDiff = None
        self.assertEqual(sides['python'], sides['dart'])
        answers, view, keys = sides['dart']
        results = dict((a[0], a[1]) for a in answers)
        self.assertEqual(results['empty']['nodes'], [])
        self.assertEqual(results['view on nothing'], {'ok': False})
        self.assertEqual(results['view'], {'ok': True})
        self.assertEqual(view['selected'], 'gpu')
        nodes = {n['id']: n for n in results['refresh with a missing disk'][1]['nodes']}
        self.assertEqual(nodes['disk:/mnt/Gone']['status'], 'missing')
        self.assertNotIn('disk:/mnt/Gone', {n['id'] for n in results['forget']['nodes']})
        self.assertIn('found:$DISK/gguf', {n['id'] for n in results['cached after scan']['nodes']})
        self.assertTrue(any('size' in n for n in results['search'][1]['nodes']))


if __name__ == '__main__':
    unittest.main()
