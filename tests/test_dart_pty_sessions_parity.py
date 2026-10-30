"""Development parity: terminal_sessions.Sessions and the Dart core's PtySessions run the same
scripted program in a PTY: the same output (its size after a resize, ignored and blocked signals,
session leader, controlling terminal, working folder, environment, echoed input) and exit code; and
stopping a session ends its whole process group. Skipped without a native Dart SDK."""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'tools'))

import terminal_sessions  # noqa: E402

try:
    from dart_sdk import resolve_dart
    DART = resolve_dart()
except (OSError, ValueError, RuntimeError):
    DART = None

SCRIPT = r'''echo WAIT; read a; stty size
grep -E '^(SigIgn|SigBlk)' /proc/$$/status
[ "$(cut -d' ' -f6 /proc/$$/stat)" = "$$" ] && echo LEADER
(echo CTTY > /dev/tty) 2>/dev/null || echo NOCTTY
pwd; echo "VAR=$PROBE_VAR"; echo READY; read b; echo "got $b"; printf 'ü\n'; exit 3
'''
STEPS = [{'until': 'WAIT'}, {'resize': [120, 40]}, {'write': 'go\n'}, {'until': 'READY'},
         {'write': 'hello\n'}, {'until': 'ended'}]


def python_side(argv, cwd, env):
    sessions = terminal_sessions.Sessions()
    ident = sessions.start('probe', argv, cwd, env)
    out, last = '', {}
    for step in STEPS:
        if 'write' in step:
            sessions.write(ident, step['write'].encode())
        elif 'resize' in step:
            sessions.resize(ident, *step['resize'])
        else:
            until = time.monotonic() + 10
            while time.monotonic() < until:
                last = sessions.read(ident)
                out += last['text']
                if (last['ended'] if step['until'] == 'ended' else step['until'] in out):
                    break
                time.sleep(0.05)
    sessions.stop(ident)
    return {'text': out, 'exit_code': last.get('exit_code'), 'ended': last.get('ended')}


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartPtySessionsParityTest(unittest.TestCase):
    def test_same_terminal_behaviour(self):
        with tempfile.TemporaryDirectory() as cwd:
            argv = ['/bin/sh', '-c', SCRIPT]
            env = {'PATH': '/usr/bin:/bin', 'PROBE_VAR': 'ünï', 'TERM': 'xterm-256color', 'HOME': cwd}
            expected = python_side(argv, cwd, env)
            request = {'id': 1, 'protocol': 1, 'method': 'dev.pty',
                       'params': {'argv': argv, 'cwd': cwd, 'env': env, 'steps': STEPS}}
            out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                  'bin/fixture_probe.dart'], input=(json.dumps(request) + '\n').encode(),
                                 capture_output=True, cwd=ROOT / 'packages/maprisma_core', timeout=120, check=True)
            actual = json.loads(out.stdout.splitlines()[-1])['result']
        self.assertEqual(expected, actual)
        text = actual['text']
        for line in ('40 120', 'LEADER', 'CTTY', 'VAR=ünï', 'got hello', 'ü'):
            self.assertIn(line, text)
        # The shell ignores SIGQUIT itself; SIGPIPE (13) must not come ignored from the Dart VM.
        ignored = int(next(l for l in text.splitlines() if l.startswith('SigIgn:')).split()[1], 16)
        self.assertFalse(ignored & (1 << 12))
        self.assertNotIn('NOCTTY', text)
        self.assertEqual((actual['exit_code'], actual['ended']), (3, True))


if __name__ == '__main__':
    unittest.main()
