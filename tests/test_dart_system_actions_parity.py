"""Development parity: the System Map's actions on supporting tools, the GPU stack and model folders
(system.tool_check, system.stack_preview / stack_apply, system.folder_preview and its connection)
through the Python backend and the Dart core, in a temporary HOME. A fake terminal only logs what it
would run (the GPU stack's sudo step never runs); the model folder is a temporary folder on the data
disk of this checkout. Skipped without a native Dart SDK or a mounted data disk."""
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
TERMINAL = '#!/bin/sh\nfor a in "$@"; do printf "[%s]" "$a" >> "$HOME/term.log"; done\necho >> "$HOME/term.log"\n'


def seed(home: Path):
    bin_dir = home / '.local/bin'
    bin_dir.mkdir(parents=True)
    (home / 'models').mkdir()
    # A llama.cpp connected by Asterism earlier: its wrapper names the model folder.
    (bin_dir / 'llama-server').write_text(
        f'#!/bin/sh\n# Connected by Asterism\nset -eu\nexec /bin/true --models-dir {home}/models --port 8080\n')
    (bin_dir / 'xdg-terminal-exec').write_text(TERMINAL)
    for name in ('llama-server', 'xdg-terminal-exec'):
        os.chmod(bin_dir / name, 0o700)
    (home / '.config/llama.cpp').mkdir(parents=True)
    (home / '.config/llama.cpp/server.env').write_text(f'LLAMA_ARG_MODELS_DIR={home}/models\nLLAMA_ARG_PORT=8080\n')
    units = home / '.config/systemd/user'
    units.mkdir(parents=True)
    (units / 'llama-server.service').write_text(
        f'[Service]\nEnvironmentFile={home}/.config/llama.cpp/server.env\nExecStart={bin_dir}/llama-server\n')
    (home / '.config/maprisma').mkdir(parents=True)
    (home / '.config/maprisma/settings.json').write_text(json.dumps({'setup_done': True}))


@unittest.skipIf(DART is None or not ON_DISK, 'native Dart SDK or a mounted data disk not available')
class DartSystemActionsParityTest(unittest.TestCase):
    def test_same_actions(self):
        sides = {}
        with tempfile.TemporaryDirectory(prefix='.asterism-parity-', dir=ROOT.parent) as disk_name, \
                tempfile.TemporaryDirectory() as temp:
            disk = Path(disk_name)
            (disk / 'gguf').mkdir()
            (disk / 'gguf/found-Q4.gguf').write_text('GGUF found')
            for side in ('python', 'dart'):
                home = Path(temp) / side
                seed(home)
                env = {'HOME': str(home), 'PATH': f'{home}/.local/bin:/usr/bin:/bin', 'LANG': 'C.UTF-8',
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

                def call(label, method, params=None):
                    reply = wait(runner.call(method, params or {}))
                    answers.append([label, reply])
                    return reply

                try:
                    call('tool check', 'system.tool_check', {'node': 'tool:git'})
                    call('unknown tool', 'system.tool_check', {'node': 'tool:nothing'})
                    call('not a tool', 'system.tool_check', {'node': 'agent:claude'})
                    stack = runner.call('system.cached', {})        # nothing saved yet: no GPU node needed
                    preview = call('stack preview', 'system.stack_preview', {'part': 'rocm'})
                    call('stack part not wanted', 'system.stack_preview', {'part': 'vulkan-radeon'})
                    if 'preview' in preview:
                        call('stack apply', 'system.stack_apply', {'preview': preview['preview']})
                        call('stack apply again', 'system.stack_apply', {'preview': preview['preview']})
                    scanned = wait(runner.call('existing.scan', {'path': str(disk)}))
                    found = {i['path']: i['found'] for i in scanned[1]['items']}
                    connect = call('folder preview', 'system.folder_preview',
                                   {'found': found[str(disk / 'gguf')], 'runtime': 'llamacpp'})
                    call('folder for ollama', 'system.folder_preview',
                         {'found': found[str(disk / 'gguf')], 'runtime': 'ollama'})
                    call('folder shape', 'system.folder_preview', {'found': 'x'})
                    if 'plan' in connect:
                        call('connect', 'connections.apply', {'plan': connect['plan']})
                finally:
                    runner.close()
                log = (home / 'term.log').read_text() if (home / 'term.log').exists() else ''
                files = {name: (home / name).read_text() for name in
                         ('.config/llama.cpp/server.env', '.local/bin/llama-server')}
                settings = json.loads((home / '.config/maprisma/settings.json').read_text())
                text = json.dumps([answers, log, files, settings.get('model_folders'), bool(stack)])
                text = text.replace(str(home), '$HOME').replace(str(disk), '$DISK')
                text = re.sub(r'"(core-)?[0-9a-f]{32}"', '"<handle>"', text)
                sides[side] = json.loads(text)
        self.maxDiff = None
        self.assertEqual(sides['python'], sides['dart'])
        answers, log, files, folders, _ = sides['dart']
        results = dict((a[0], a[1]) for a in answers)
        self.assertEqual(results['tool check'], ['done', {'ok': True, 'checked': True}])
        self.assertIn('$DISK/gguf', files['.config/llama.cpp/server.env'])
        self.assertIn('--models-dir $DISK/gguf', files['.local/bin/llama-server'])
        self.assertEqual(folders, ['$DISK/gguf'])
        if 'stack apply' in results:                          # ROCm is missing on this PC
            self.assertEqual(results['stack apply'], {'external': True})
            self.assertIn('rocm-hip-runtime', log)            # only the fake terminal saw it
            self.assertEqual(results['stack apply again'], {'error': 'refused'})


if __name__ == '__main__':
    unittest.main()
