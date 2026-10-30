"""Development parity: whether an agent or a local LLM is ready (agent_status.agent_checks,
runtime_checks, summary_line) in the Python reference and the Dart core, over sign-in states (usage
records, credential files and variables, expired, paused), models and providers, local LLMs in every
state, failed connections, start problems, MCP servers and skills, on the generic and the Omarchy
desktop. Skipped without a native Dart SDK."""
import itertools
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
try:
    from dart_sdk import resolve_dart
    DART = resolve_dart()
except (OSError, ValueError, RuntimeError):
    DART = None

PYTHON = r'''
import json, sys
from types import SimpleNamespace as NS
sys.path.insert(0, sys.argv[1])
import agent_status, agent_details, inventory
out = []
for case in json.loads(sys.stdin.read()):
    rts = [inventory.Runtime(r['key'], r['name'], installed=r['installed'], running=r['running'],
                             service=r['service'], address=r['address'], models_dir=r['models_dir'],
                             models=r['models'], agents=r['agents'], active_agents=r['active_agents'],
                             server_off=r['server_off']) for r in case['runtimes']]
    if case.get('agent'):
        a = case['agent']
        access = case.get('access')
        agent_status.access_table = lambda a=a, access=access: (
            {a['command']: agent_status.Access(access['how'], access.get('login', ''), tuple(access.get('files', ())),
                                               tuple(access.get('env', ())), local_ok=access.get('local_ok', False))}
            if access else {})
        info = agent_details.Details(model=case['info']['model'],
                                     providers=[agent_details.Provider(**p) for p in case['info']['providers']])
        inv = NS(runtimes=rts, agent_mcp={a['command']: case['mcp']}, agent_skills={a['command']: case['skills']})
        checks = agent_status.agent_checks(NS(**a), info, case['record'], inv, case['hints'], case['logged_in'],
                                           issue=case['issue'])
    else:
        checks = agent_status.runtime_checks(rts[0], case['hints'], case['names'], case['login'])
    out.append({'checks': [vars(c) for c in checks], 'summary': list(agent_status.summary_line(checks))})
print(json.dumps(out))
'''


def runtime(key, name, installed=True, running=False, service='', models=(), agents=(), active=(), off=False):
    return {'key': key, 'name': name, 'installed': installed, 'running': running, 'service': service,
            'address': '127.0.0.1:8080' if installed else '', 'models_dir': '~/models' if models else '',
            'models': list(models), 'agents': list(agents), 'active_agents': list(active), 'server_off': off,
            'can_control': bool(installed and service)}


RUNTIMES = [runtime('llamacpp', 'llama.cpp', running=True, models=['qwen'], agents=['pi'], active=['pi'],
                    service='llama-server'),
            runtime('ollama', 'Ollama', service='ollama', models=['gemma']),
            runtime('jan', 'Jan'), runtime('lmstudio', 'LM Studio', models=['m'], off=True),
            runtime('vllm', 'vLLM', installed=False), runtime('koboldcpp', 'KoboldCpp', models=['k'])]
HINTS = {'agent:pi|runtime:ollama': {'kind': 'provider', 'hints': [{'level': 'error', 'text': 'It does not answer.'}]},
         'agent:pi|mcp:files': {'kind': 'mcp', 'hints': [{'level': 'warning', 'text': 'Check it.'}]},
         'agent:claude|skills:~/s': {'kind': '', 'hints': [{'level': 'error', 'text': 'Odd.'}]},
         'agent:codex|runtime:jan': {'kind': 'provider', 'hints': []}}
RECORDS = [{}, {'ready': True, 'tierLabel': 'prolite'}, {'ready': False, 'authHelpText': 'Run claude /login',
                                                          'usageStatusText': 'Waiting for something'},
           {'usageStatusText': 'Sign-in expired'}, {'usageStatusText': 'Waiting for auth', 'ready': True},
           {'usageStatusText': 'Waiting for auth'}, {'usageStatusText': 'Limits paused', 'ready': True, 'tierLabel': 'Pro'}]
ACCESS = [None, {'how': 'A Claude account or an API key.', 'login': 'claude /login', 'files': ['.creds/key.json'],
                 'env': ['FAKE_KEY']},
          {'how': 'Works with a local LLM.', 'local_ok': True},
          {'how': 'An OpenAI key.', 'env': ['MISSING_KEY'], 'local_ok': True}]
INFOS = [{'model': '', 'providers': []},
         {'model': 'qwen (llama.cpp)', 'providers': [
             {'name': 'llama.cpp', 'local': True, 'runtime': 'llama.cpp', 'models': 1, 'active': True},
             {'name': 'Ollama', 'local': True, 'runtime': 'Ollama', 'models': 1, 'active': False},
             {'name': 'Jan', 'local': True, 'runtime': 'Jan', 'models': 0, 'active': True},
             {'name': 'LM Studio', 'local': True, 'runtime': 'LM Studio', 'models': 1, 'active': True},
             {'name': 'vLLM', 'local': True, 'runtime': 'vLLM', 'models': 0, 'active': True},
             {'name': 'Other', 'local': True, 'runtime': '', 'models': 0, 'active': False},
             {'name': 'OpenAI', 'local': False, 'runtime': '', 'models': 0, 'active': True}]},
         {'model': 'anthropic/claude-sonnet', 'providers': [
             {'name': 'Ollama', 'local': True, 'runtime': 'Ollama', 'models': 1, 'active': True}]},
         {'model': '', 'providers': [{'name': 'KoboldCpp', 'local': True, 'runtime': 'KoboldCpp', 'models': 1,
                                      'active': True}]}]


def agent_cases():
    cases = []
    agents = [{'command': 'claude', 'name': 'Claude Code', 'installed': True, 'version': '2.1.0'},
              {'command': 'pi', 'name': 'Pi', 'installed': True, 'version': ''},
              {'command': 'openclaw', 'name': 'OpenClaw', 'installed': True, 'version': '1'},
              {'command': 'codex', 'name': 'Codex', 'installed': False, 'version': ''}]
    for agent, record, access, info, logged_in, issue in itertools.product(
            agents, RECORDS, ACCESS, INFOS, (None, True, False), (None, {'kind': 'vte4'}, {'kind': 'terminal'},
                                                                  {'kind': 'other'})):
        if (hash(json.dumps([agent, record, access, info, logged_in, issue], sort_keys=True)) % 7) and \
                not (record == {} and access is None and logged_in is None and issue is None):
            continue                     # a spread of the combinations, every axis covered
        cases.append({'agent': agent, 'record': record, 'access': access, 'info': info, 'logged_in': logged_in,
                      'issue': issue, 'runtimes': RUNTIMES, 'hints': HINTS,
                      'mcp': ['files'] if agent['command'] == 'pi' else [],
                      'skills': ['~/s'] if agent['command'] == 'claude' else []})
    return cases


def runtime_cases():
    names = {'pi': 'Pi', 'claude': 'Claude Code'}
    cases = []
    for rt, login in itertools.product(RUNTIMES + [runtime('ollama', 'Ollama', agents=['pi', 'x'], active=['x'])],
                                       (None, True, False)):
        cases.append({'runtimes': [rt], 'hints': {**HINTS, 'agent:x|runtime:ollama': {'hints': [{'text': 'x'}]}},
                      'names': names, 'login': login})
    return cases


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartSetupChecksParityTest(unittest.TestCase):
    def test_same_checks(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            tools = home / 'bin'
            tools.mkdir()
            for name in ('dnf',):
                (tools / name).write_text('#!/bin/sh\n')
                (tools / name).chmod(0o755)
            (home / '.creds').mkdir()
            cases = agent_cases() + runtime_cases()
            self.assertGreater(len(cases), 150)
            results = {}
            for desktop, creds in (('generic', False), ('omarchy', True)):
                if creds:
                    (home / '.creds/key.json').write_text('{}')
                env = {k: v for k, v in os.environ.items() if not k.startswith('XDG_')}
                env.update(HOME=str(home), PATH=f'{tools}:/usr/bin:/bin', LANG='C.UTF-8', ASTERISM_DESKTOP=desktop,
                           FAKE_KEY='' if not creds else 'x')
                # The core names the app Asterism in its texts (ServiceI18n), as the reference renamed.
                python = json.loads(subprocess.run([sys.executable, '-c', PYTHON, str(ROOT)], input=json.dumps(cases),
                                                   capture_output=True, check=True, text=True, env=env,
                                                   timeout=300).stdout)
                lines = []
                for i, c in enumerate(cases, 1):
                    params = {**c, 'desktop': desktop}
                    if 'agent' not in c:
                        params = {'agent': None, 'runtime': c['runtimes'][0], **params}
                    lines.append(json.dumps({'id': i, 'protocol': 1, 'method': 'dev.setupchecks', 'params': params}))
                out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                      'bin/fixture_probe.dart'], input=('\n'.join(lines) + '\n').encode(),
                                     capture_output=True, cwd=ROOT / 'packages/asterism_core', timeout=300, env=env)
                dart = [json.loads(line)['result'] for line in out.stdout.splitlines() if line.startswith(b'{')]
                self.assertEqual(len(dart), len(cases), out.stderr.decode()[-2000:])
                results[desktop] = (python, dart)
        self.maxDiff = None
        for desktop, (python, dart) in results.items():
            for case, py, da in zip(cases, python, dart):
                self.assertEqual(py, da, (desktop, case))
        titles = {c['title'] for py, _ in results.values() for r in py for c in r['checks']}
        for title in ('Sign-in expired', 'Signed in', 'Not signed in', 'No account needed', 'No account set up',
                      'No model set up', 'Sign-in unknown', 'Limits paused', 'No model chosen',
                      'Start ran into a problem', 'Jan has no models', "LM Studio's server is off",
                      'vLLM is not installed', 'No agent connected', 'The connection from Pi does not work',
                      'Start at login', 'Not installed'):
            self.assertIn(title, titles)
        commands = {c['command'] for py, _ in results.values() for r in py for c in r['checks']}
        self.assertIn('sudo dnf install vte291-gtk4', commands)
        self.assertIn('sudo pacman -S xdg-terminal-exec', commands)


if __name__ == '__main__':
    unittest.main()
