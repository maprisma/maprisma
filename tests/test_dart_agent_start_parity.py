"""Development parity: sessions.start (an installed agent in a PTY, read until it ends, its project
history saved), projects.pin and projects.forget through the Python backend and the Dart core
service, on two identical homes: the same answers, the same output, the same settings file.
Skipped without a native Dart SDK."""
import json
import os
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

PYTHON_SERVICE = r'''
import json, sys
sys.path.insert(0, sys.argv[1])
import flutter_backend, ai_core
service = flutter_backend.Service(ai_core.settings_file())
for line in sys.stdin:
    request = json.loads(line)
    try:
        reply = {'id': request['id'], 'result': service.dispatch(request['method'], request['params'])}
    except Exception as error:
        reply = {'id': request['id'], 'error': type(error).__name__}
    print(json.dumps(reply), flush=True)
'''


def seed(home: Path):
    bin_dir = home / '.local/bin'
    bin_dir.mkdir(parents=True)
    (bin_dir / 'opencode').write_text('#!/bin/sh\necho "hello from $(pwd) $TERM $CLAUDECODE"\nexit 0\n')
    os.chmod(bin_dir / 'opencode', 0o700)
    for name in ('work', 'other'):
        (home / name).mkdir()
    (home / 'link-to-work').symlink_to(home / 'work')
    (home / '.config/asterism').mkdir(parents=True)


class Side:
    def __init__(self, command, cwd, env):
        self.process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.count = 0

    def call(self, method, params):
        self.count += 1
        self.process.stdin.write(json.dumps({'id': self.count, 'protocol': 1, 'method': method,
                                             'params': params}) + '\n')
        self.process.stdin.flush()
        reply = json.loads(self.process.stdout.readline())
        return reply['result'] if 'result' in reply else {'error': 'refused'}

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=30)
        self.process.stdout.close()


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartAgentStartParityTest(unittest.TestCase):
    def test_same_start_and_projects(self):
        sides = {}
        with tempfile.TemporaryDirectory() as temp:
            for side in ('python', 'dart'):
                home = Path(temp) / side
                home.mkdir()
                seed(home)
                env = {'HOME': str(home), 'PATH': f'{home}/.local/bin:/usr/bin:/bin', 'LANG': 'C.UTF-8',
                       'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_CACHE_HOME': str(home / '.cache'),
                       'XDG_DATA_HOME': str(home / '.local/share'), 'ASTERISM_DESKTOP': 'generic',
                       'CLAUDECODE': '1', 'ASTERISM_FLUTTER_DEVEL': '1'}
                runner = (Side([sys.executable, '-c', PYTHON_SERVICE, str(ROOT)], ROOT, env) if side == 'python' else
                          Side([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                'bin/asterism-core.dart'], ROOT / 'packages/asterism_core', env))
                answers = []
                try:
                    answers.append(runner.call('projects.pin', {'command': 'opencode', 'path': str(home / 'link-to-work')}))
                    started = runner.call('sessions.start', {'command': 'opencode', 'path': None, 'outside': False})
                    session = started.get('session')
                    answers.append({**started, 'session': '<session>' if session else session})
                    text = ''
                    for _ in range(100):
                        read = runner.call('sessions.read', {'session': session})
                        text += read.get('text', '')
                        if read.get('ended') or 'error' in read:
                            break
                        time.sleep(0.05)
                    answers.append([text, read.get('ended'), read.get('exit_code')])
                    answers.append(runner.call('sessions.stop', {'session': session}))
                    answers.append(runner.call('sessions.start', {'command': 'opencode', 'path': str(home / 'other'),
                                                                  'outside': False}).get('path'))
                    answers.append(runner.call('projects.forget', {'command': 'opencode', 'path': str(home / 'work')}))
                    answers.append(runner.call('projects.pin', {'command': 'opencode', 'path': None}))
                    answers.append(runner.call('projects.pin', {'command': 'nobody', 'path': None}))
                    answers.append(runner.call('sessions.start', {'command': 'opencode', 'path': str(home / 'gone'),
                                                                  'outside': False}))
                finally:
                    runner.close()
                settings = json.loads((home / '.config/asterism/settings.json').read_text())
                sides[side] = json.loads(json.dumps([answers, {k: settings.get(k) for k in
                                                               ('agent_projects', 'agent_project_history')}])
                                         .replace(str(home), '$HOME'))
        self.assertEqual(sides['python'], sides['dart'])
        answers, saved = sides['dart']
        self.assertIn('hello from $HOME/work xterm-256color \r\n', answers[2][0])   # no CLAUDECODE inherited
        self.assertEqual(saved['agent_project_history'], {'opencode': ['$HOME/other']})


if __name__ == '__main__':
    unittest.main()
