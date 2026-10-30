"""Development parity: agents.halt_preview / agents.halt_apply through the Python backend and the
Dart core service: an agent instance outside the app is listed (one in the app's own terminal is
not), stopped through the worker (SIGTERM; SIGKILL for one that ignores it), and a used or unknown
preview is refused. Skipped without a native Dart SDK."""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
try:
    from dart_sdk import resolve_dart
    DART = resolve_dart()
except (OSError, ValueError, RuntimeError):
    DART = None

sys.path.insert(0, str(ROOT / 'tests'))
from test_dart_agent_start_parity import PYTHON_SERVICE, Side  # noqa: E402


def alive(pid: int) -> bool:
    try:
        state = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[0]
    except OSError:
        return False
    return state != 'Z'


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartAgentHaltParityTest(unittest.TestCase):
    def test_same_halts(self):
        sides = {}
        with tempfile.TemporaryDirectory() as temp:
            for side in ('python', 'dart'):
                home = Path(temp) / side
                (home / '.local/bin').mkdir(parents=True)
                (home / '.config/maprisma').mkdir(parents=True)
                agent = home / '.local/bin/opencode'
                agent.write_text('#!/bin/sh\n[ "$1" = stubborn ] && trap "" TERM\nwhile :; do sleep 1; done\n')
                os.chmod(agent, 0o700)
                env = {'HOME': str(home), 'PATH': f'{home}/.local/bin:/usr/bin:/bin', 'LANG': 'C.UTF-8',
                       'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_CACHE_HOME': str(home / '.cache'),
                       'XDG_DATA_HOME': str(home / '.local/share'), 'ASTERISM_DESKTOP': 'generic',
                       'ASTERISM_FLUTTER_DEVEL': '1'}
                runner = (Side([sys.executable, '-c', PYTHON_SERVICE, str(ROOT)], ROOT, env) if side == 'python' else
                          Side([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                'bin/asterism-core.dart'], ROOT / 'packages/asterism_core', env))
                outside = subprocess.Popen([str(agent)], env=env, cwd=home)
                stubborn = None
                answers = []
                try:
                    inside = runner.call('sessions.start', {'command': 'opencode', 'path': str(home), 'outside': False})
                    time.sleep(1.5)
                    preview = runner.call('agents.halt_preview', {'command': 'opencode'})
                    rows = preview.get('instances', [])
                    answers.append([re.sub(r' · \d+ · ', ' · <pid> · ', r['label']) for r in rows])
                    answers.append([str(outside.pid) in r['label'] for r in rows])
                    task = runner.call('agents.halt_apply', {'preview': rows[0]['preview']})
                    for _ in range(100):
                        status = runner.call('tasks.status', {'task': task['task']})
                        if status.get('state') != 'running':
                            break
                        time.sleep(0.1)
                    outside.wait(timeout=10)
                    answers.append([status.get('state'), status.get('result'), outside.returncode])
                    answers.append(runner.call('agents.halt_apply', {'preview': rows[0]['preview']}))
                    stubborn = subprocess.Popen([str(agent), 'stubborn'], env=env, cwd=home)
                    time.sleep(1.5)
                    rows = runner.call('agents.halt_preview', {'command': 'opencode'}).get('instances', [])
                    task = runner.call('agents.halt_apply', {'preview': rows[0]['preview']})
                    for _ in range(100):
                        status = runner.call('tasks.status', {'task': task['task']})
                        if status.get('state') != 'running':
                            break
                        time.sleep(0.1)
                    stubborn.wait(timeout=10)
                    answers.append([status.get('state'), status.get('result'), stubborn.returncode])
                    answers.append(runner.call('agents.halt_preview', {'command': 'nobody'}))
                    runner.call('sessions.stop', {'session': inside['session']})
                finally:
                    for process in (outside, stubborn):
                        if process is not None and process.poll() is None:
                            process.kill()
                            process.wait()
                    runner.close()
                sides[side] = json.loads(json.dumps(answers).replace(str(home), '$HOME'))
        self.assertEqual(sides['python'], sides['dart'])
        answers = sides['dart']
        self.assertEqual(answers[0], ['opencode · <pid> · $HOME'])       # the one in the app is left out
        self.assertEqual(answers[1], [True])
        self.assertEqual(answers[2], ['done', {'ok': True}, -15])
        self.assertEqual(answers[3], {'error': 'refused'})
        self.assertEqual(answers[4], ['done', {'ok': True}, -9])


if __name__ == '__main__':
    unittest.main()
