"""Development parity: agent actions (agents.action_preview / action_apply: install, update, uninstall
recipes run in a terminal, sign-in and sign-out sessions, the first-agent guide's test) through the
Python backend and the Dart core, with a fake agent, a fake mise and a fake terminal that only logs
what it would run. Skipped without a native Dart SDK."""
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tests'))
try:
    from dart_sdk import resolve_dart
    DART = resolve_dart()
except (OSError, ValueError, RuntimeError):
    DART = None

from test_dart_agent_start_parity import PYTHON_SERVICE, Side  # noqa: E402

CLAUDE = '#!/bin/sh\nif [ "$1" = --version ]; then echo "2.1.0 (Claude Code)"; exit 0; fi\n' \
         'echo "claude $* in $(pwd) providers=$AI_AGENTS_MAP_NO_PROVIDERS"\n'
TERMINAL = '#!/bin/sh\nfor a in "$@"; do printf "[%s]" "$a" >> "$HOME/term.log"; done\necho >> "$HOME/term.log"\n'


def seed(home: Path):
    bin_dir = home / '.local/bin'
    bin_dir.mkdir(parents=True)
    for name, text in (('claude', CLAUDE), ('mise', '#!/bin/sh\nexit 0\n'), ('xdg-terminal-exec', TERMINAL)):
        (bin_dir / name).write_text(text)
        os.chmod(bin_dir / name, 0o700)
    (home / '.config/maprisma').mkdir(parents=True)
    (home / '.config/maprisma/settings.json').write_text(json.dumps({'setup_done': True}))


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartAgentActionsParityTest(unittest.TestCase):
    def test_same_actions(self):
        sides = {}
        with tempfile.TemporaryDirectory() as temp:
            for side in ('python', 'dart'):
                home = Path(temp) / side
                home.mkdir()
                seed(home)
                env = {'HOME': str(home), 'PATH': f'{home}/.local/bin:/usr/bin:/bin', 'LANG': 'C.UTF-8',
                       'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_CACHE_HOME': str(home / '.cache'),
                       'XDG_DATA_HOME': str(home / '.local/share'), 'ASTERISM_DESKTOP': 'generic',
                       'ASTERISM_FLUTTER_DEVEL': '1', 'CLAUDECODE': '1'}
                runner = (Side([sys.executable, '-c', PYTHON_SERVICE, str(ROOT)], ROOT, env) if side == 'python' else
                          Side([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                'bin/asterism-core.dart'], ROOT / 'packages/asterism_core', env))
                answers = []

                def preview(**params):
                    reply = runner.call('agents.action_preview', params)
                    answers.append({k: v for k, v in reply.items() if k not in ('preview', 'focus')})
                    return reply.get('preview')

                def read_all(session):
                    text = ''
                    for _ in range(100):
                        read = runner.call('sessions.read', {'session': session})
                        text += read.get('text', '')
                        if read.get('ended') or 'error' in read:
                            break
                        time.sleep(0.05)
                    return text

                try:
                    install = preview(command='claude', action='install')
                    preview(command='claude', action='update')
                    preview(command='claude', action='uninstall')
                    preview(command='claude', action='login')
                    login = preview(command='claude', action='login', login=1)
                    preview(command='claude', action='login', login=5)
                    preview(command='claude', action='logout')
                    verify = preview(command='claude', action='verify')
                    preview(command='nobody', action='install')
                    preview(command='node', action='install', kind='tool')
                    answers.append(runner.call('agents.action_apply', {'preview': install}))
                    answers.append(runner.call('agents.action_apply', {'preview': install}))
                    started = runner.call('agents.action_apply', {'preview': verify})
                    answers.append([started.get('command'), read_all(started['session']).replace(started['path'], '<tmp>')])
                    runner.call('sessions.stop', {'session': started['session']})
                    started = runner.call('agents.action_apply', {'preview': login})
                    answers.append([started.get('command'), started.get('path'), read_all(started['session'])])
                    runner.call('sessions.stop', {'session': started['session']})
                finally:
                    runner.close()
                settings = json.loads((home / '.config/maprisma/settings.json').read_text())
                log = (home / 'term.log').read_text() if (home / 'term.log').exists() else ''
                sides[side] = json.loads(json.dumps([answers, settings.get('first_agent'), log]).replace(str(home), '$HOME'))
        self.assertEqual(sides['python'], sides['dart'])
        answers, first_agent, log = sides['dart']
        self.assertEqual(first_agent, {'verified': ['claude']})
        self.assertIn('mise --yes use -g claude', log)
        self.assertEqual(answers[10], {'external': True})
        self.assertIn('error', answers[11])                      # a preview is used once
        self.assertIn('providers=1', answers[12][1])             # the test runs without its providers


if __name__ == '__main__':
    unittest.main()
