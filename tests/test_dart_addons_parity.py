"""Development parity: add-ons (verification, addons.list, addons.set_enabled and what they hide and
show) through the Python backend and the Dart core, with Uwe's real signed add-ons from
asterism-addons plus tampered copies. The Dart core takes add-ons as data only: code the app has
built in (its providers, the online providers, the built-in agents' hooks) is its own, other code is
refused; the one intended difference is a feature add-on with code (Insights). Skipped without a
native Dart SDK or the asterism-addons checkout."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
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

from test_dart_agent_start_parity import Side  # noqa: E402

PYTHON_SERVICE = r'''
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import addons
addons.find.__defaults__ = ((addons.USER_DIR, Path('/nonexistent-system-addons')),)
import flutter_backend, ai_core
from flutter_addons import AdapterRegistry
service = flutter_backend.Service(ai_core.settings_file())
service.adapters = AdapterRegistry()
service.adapters.reload(service.enabled_addons())
for line in sys.stdin:
    request = json.loads(line)
    try:
        reply = {'id': request['id'], 'result': service.dispatch(request['method'], request['params'])}
    except Exception as error:
        reply = {'id': request['id'], 'error': type(error).__name__}
    print(json.dumps(reply), flush=True)
'''

REAL = ['agent-claude', 'agent-hermes', 'agent-goose', 'llm-jan', 'providers-online', 'insights']


def seed(home: Path):
    user = home / '.local/share/maprisma/addons'
    user.mkdir(parents=True)
    for name in REAL:
        shutil.copytree(ADDONS / name, user / name)
    shutil.copytree(ADDONS / 'agent-grok', user / 'agent-grok')
    with open(user / 'agent-grok/agent.toml', 'a') as handle:
        handle.write('\n# changed\n')
    shutil.copytree(ADDONS / 'agent-crush', user / 'agent-crush')
    (user / 'agent-crush/extra.txt').write_text('x')
    for path in user.rglob('*'):
        os.chmod(path, 0o755 if path.is_dir() else 0o644)
    (home / '.config/maprisma').mkdir(parents=True)
    (home / '.config/maprisma/settings.json').write_text(json.dumps(
        {'addons_enabled': ['agent-claude', 'agent-hermes', 'providers-online'], 'setup_done': True}))


def summary(result):
    if not isinstance(result, dict) or 'addons' not in result:
        return result
    return [{k: a[k] for k in ('id', 'name', 'version', 'kind', 'state', 'enabled', 'loaded', 'supported',
                               'verified', 'provides', 'sign_ins', 'removable', 'privacy', 'capabilities')}
            for a in result['addons']]


def visible(runner):
    snapshot = runner.call('app.snapshot', {})
    providers = runner.call('providers.snapshot', {})
    return [[a['command'] for a in snapshot.get('agents', [])],
            [p['key'] for p in providers.get('local', [])], [p['key'] for p in providers.get('online', [])]]


@unittest.skipIf(DART is None or not ADDONS.is_dir(), 'native Dart SDK or asterism-addons not available')
class DartAddonsParityTest(unittest.TestCase):
    def test_same_add_ons(self):
        sides = {}
        with tempfile.TemporaryDirectory() as temp:
            for side in ('python', 'dart'):
                home = Path(temp) / side
                home.mkdir()
                seed(home)
                env = {'HOME': str(home), 'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8',
                       'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_CACHE_HOME': str(home / '.cache'),
                       'XDG_DATA_HOME': str(home / '.local/share'), 'ASTERISM_DESKTOP': 'generic',
                       'ASTERISM_FLUTTER_DEVEL': '1'}
                runner = (Side([sys.executable, '-c', PYTHON_SERVICE, str(ROOT)], ROOT, env) if side == 'python' else
                          Side([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                'bin/asterism-core.dart'], ROOT / 'packages/asterism_core', env))
                answers = []
                try:
                    answers.append(summary(runner.call('addons.list', {})))
                    answers.append(visible(runner))
                    for ident, on in (('agent-goose', True), ('llm-jan', True), ('insights', True),
                                      ('agent-grok', True), ('providers-online', False), ('agent-hermes', False)):
                        answers.append(summary(runner.call('addons.set_enabled', {'id': ident, 'enabled': on})))
                        answers.append(visible(runner))
                finally:
                    runner.close()
                settings = json.loads((home / '.config/maprisma/settings.json').read_text())
                sides[side] = json.loads(json.dumps([answers, settings.get('addons_enabled')]).replace(str(home), '$HOME'))
        python, dart = sides['python'], sides['dart']
        # The intended difference: Insights brings code; the Dart core takes it as data only.
        def insights(listing):
            return next(a for a in listing if a['id'] == 'insights')
        self.assertEqual(insights(python[0][0])['state'], 'verified')
        self.assertEqual(insights(dart[0][0])['state'], 'refused')
        for listing in (python[0], dart[0]):
            for index, answer in enumerate(listing):
                if isinstance(answer, list) and answer and isinstance(answer[0], dict):
                    listing[index] = [a for a in answer if a['id'] != 'insights']
        self.assertEqual(python, dart)
        listing = {a['id']: a for a in dart[0][0]}
        self.assertEqual(listing['agent-grok']['state'], 'refused')
        self.assertEqual(listing['agent-crush']['state'], 'refused')
        self.assertEqual(listing['agent-hermes']['state'], 'loaded')
        agents, local, online = dart[0][1]
        self.assertIn('claude', agents)
        self.assertNotIn('goose', agents)          # verified but off: hidden, as the reference does
        self.assertNotIn('jan', local)
        self.assertTrue(online)


if __name__ == '__main__':
    unittest.main()
