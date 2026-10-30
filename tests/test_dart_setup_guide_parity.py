"""Development parity: first-run setup (setup.detect / apply / later) and the first-agent guide
(guide.snapshot / choose) through the Python backend and the Dart core, with Uwe's signed add-ons from
asterism-addons installed in a temporary HOME, a fake agent and a fake local LLM. Skipped without a
native Dart SDK or the asterism-addons checkout."""
import json
import os
import shutil
import sys
import tempfile
import time
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ADDONS = ROOT.parent / 'asterism-addons'
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tests'))
try:
    from dart_sdk import resolve_dart
    DART = resolve_dart()
except (OSError, ValueError, RuntimeError):
    DART = None

from test_dart_agent_start_parity import PYTHON_SERVICE, Side  # noqa: E402

# The reference builds its add-on registry in initialize(), as its server does at start.
SERVICE = PYTHON_SERVICE.replace('service = flutter_backend.Service(ai_core.settings_file())\n',
                                 'service = flutter_backend.Service(ai_core.settings_file())\nservice.initialize()\n')
assert SERVICE != PYTHON_SERVICE
INSTALLED = ('agent-claude', 'agent-goose', 'agent-codex', 'agent-pi', 'llm-ollama', 'llm-llamacpp',
             'providers-online')
TOOLS = ('sh', 'bash', 'python3', 'cat', 'env', 'uname', 'dart', 'ssh-keygen')


def seed(home: Path):
    bin_dir = home / '.local/bin'
    bin_dir.mkdir(parents=True)
    for name, text in (('claude', '#!/bin/sh\necho "2.1.0 (Claude Code)"\n'),
                       ('llama-server', '#!/bin/sh\nexit 0\n')):
        (bin_dir / name).write_text(text)
        os.chmod(bin_dir / name, 0o700)
    (home / '.claude').mkdir()
    (home / '.claude/.credentials.json').write_text('{}')    # only whether it exists is looked at
    (home / '.config/maprisma').mkdir(parents=True)
    (home / '.config/maprisma/settings.json').write_text(json.dumps({'first_agent': {'verified': ['claude']}}))
    user = home / '.local/share/maprisma/addons'
    user.mkdir(parents=True)
    for aid in INSTALLED:
        with zipfile.ZipFile(ADDONS / 'dist' / f'{aid}-0.11.1.zip') as archive:
            archive.extractall(user)
    tools = home / 'tools'
    tools.mkdir()
    for name in TOOLS:
        found = shutil.which(name)
        if found:
            (tools / name).symlink_to(found)
    return f'{bin_dir}:{tools}'


@unittest.skipIf(DART is None or not ADDONS.is_dir(), 'native Dart SDK or asterism-addons not available')
class DartSetupGuideParityTest(unittest.TestCase):
    def test_same_setup_and_guide(self):
        sides = {}
        with tempfile.TemporaryDirectory() as temp:
            for side in ('python', 'dart'):
                home = Path(temp) / side
                home.mkdir()
                path = seed(home)
                env = {'HOME': str(home), 'PATH': path, 'LANG': 'C.UTF-8',
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
                    for _ in range(600):
                        status = runner.call('tasks.status', {'task': reply['task']})
                        if status.get('state') != 'running':
                            break
                        time.sleep(0.1)
                    return [status.get('state'), status.get('result')]

                def call(method, params=None):
                    answers.append([method, wait(runner.call(method, params or {}))])

                try:
                    call('setup.detect')
                    call('guide.snapshot')
                    call('setup.detect', {'x': 1})
                    call('guide.choose', {'route': 'claude'})
                    call('guide.choose', {'route': 'nowhere'})
                    call('guide.choose', {'route': 'claude', 'x': 1})
                    call('setup.apply', {'enabled': ['agent-claude', 'agent-claude']})
                    call('setup.apply', {'enabled': ['agent-nobody']})
                    call('setup.apply', {'enabled': ['agent-claude', 'agent-pi', 'llm-llamacpp', 'providers-online']})
                    call('guide.snapshot')
                    call('setup.detect')
                    call('setup.later', {'x': 1})
                    call('setup.later')
                finally:
                    runner.close()
                settings = json.loads((home / '.config/maprisma/settings.json').read_text())
                kept = {key: settings.get(key) for key in ('addons_enabled', 'setup_done', 'first_agent')}
                sides[side] = json.loads(json.dumps([answers, kept]).replace(str(home), '$HOME'))
        self.maxDiff = None
        self.assertEqual(sides['python'], sides['dart'])
        answers, kept = sides['dart']
        self.assertEqual(answers[0][1][0], 'done')
        self.assertIn('agent-claude', answers[0][1][1]['installed'])
        self.assertIn('llm-llamacpp', answers[0][1][1]['installed'])
        self.assertEqual(kept['first_agent'], {'verified': ['claude'], 'route': 'claude', 'later': False})
        self.assertTrue(kept['setup_done'])
        # A local route with its runtime and no model: the starter model to download.
        steps = [step for answer in answers for item in [answer[1][1] if isinstance(answer[1], list) and
                                                           len(answer[1]) > 1 and isinstance(answer[1][1], dict)
                                                           else {}]
                 for route in item.get('routes', []) for step in route['steps']]
        starters = [step for step in steps if step['action'] == 'download-starter']
        self.assertTrue(starters, [s['action'] for s in steps])
        self.assertTrue(starters[0]['starter']['file'].endswith('.gguf'))
        self.assertTrue(starters[0]['detail'].startswith('Suggested: '))


if __name__ == '__main__':
    unittest.main()
