"""Development parity: the whole health report (health.check: This PC, Agents, Local LLMs and models,
Tools, and the use cases) in the Python reference and the Dart core, over PCs (no card, a small and a
big one, little memory, full and empty disks), agents with and without problems, local LLMs, idle model
folders, models in two local LLMs, failed connections, MCP servers and skills, and the programs on PATH.
Without model_slots' warnings (not ported: the graph's edges are left empty). Skipped without a native
Dart SDK."""
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

GIB = 1024 ** 3

PYTHON = r'''
import dataclasses, json, sys
from types import SimpleNamespace as NS
sys.path.insert(0, sys.argv[1])
import agent_status, health, inventory
out = []
for case in json.loads(sys.stdin.read()):
    facts = case['facts']
    health.harnesses.get = lambda c, facts=facts: NS(**facts[c]) if c in facts else None
    agents = [NS(**a) for a in case['agents']]
    details = {c: NS(providers=[NS(**p) for p in ps]) for c, ps in case['providers'].items()}
    rts = [inventory.Runtime(r['key'], r['name'], installed=r['installed'], running=r['running'], models=r['models'],
                             agents=r['agents'], active_agents=r['active_agents']) for r in case['runtimes']]
    inv = NS(runtimes=rts, mcp=[NS(**m) for m in case['mcp']], skill_sets=[NS(**s) for s in case['skill_sets']])
    nodes = [NS(**n) for n in (case['graph'] or {}).get('nodes', [])]
    built = None if case['graph'] is None else NS(nodes=nodes, edges=[],
                                                   column=lambda c, nodes=nodes: [n for n in nodes if n.column == c])
    checks = lambda m: {k: [agent_status.Check(**c) for c in v] for k, v in m.items()}
    report = health.check(agents, details, inv, built, health.PC(**case['pc']), checks(case['agent_checks']),
                          checks(case['runtime_checks']), case['failed_links'])
    data = dataclasses.asdict(report)
    data.update(level=report.level, summary=report.summary())
    out.append(data)
print(json.dumps(out))
'''


def chk(state, title, detail='', step=''):
    return {'state': state, 'title': title, 'detail': detail, 'step': step, 'command': '', 'sign_in': ''}


def rt(key, name, installed=True, running=False, models=(), agents=(), active=()):
    return {'key': key, 'name': name, 'installed': installed, 'running': running, 'models': list(models),
            'agents': list(agents), 'active_agents': list(active)}


def node(ident, kind, group='', active=False, column=3):
    return {'id': ident, 'kind': kind, 'group': group, 'active': active, 'column': column}


def cases(home):
    full = {
        'agents': [{'command': 'claude', 'name': 'Claude Code', 'installed': True},
                   {'command': 'pi', 'name': 'Pi', 'installed': True},
                   {'command': 'bionic', 'name': 'Bionic', 'installed': True},
                   {'command': 'codex', 'name': 'Codex', 'installed': False}],
        'agent_checks': {'claude': [chk('ok', 'Installed'), chk('missing', 'Not signed in', 'An account.', 'Sign in')],
                         'pi': [chk('ok', 'Installed'), chk('warn', 'No model chosen', '', 'Pick one')],
                         'bionic': [chk('ok', 'Installed')]},
        'runtime_checks': {'llamacpp': [chk('ok', 'Installed')],
                           'ollama': [chk('missing', 'No agent connected', '', 'Draw a line')],
                           'jan': [chk('warn', 'Not running', 'no user service starts it')]},
        'runtimes': [rt('llamacpp', 'llama.cpp', running=True, models=['Qwen3-Coder-30B', 'gemma-4-E2B', 'whisper-large'],
                        agents=['pi']),
                     rt('ollama', 'Ollama', running=True, models=['qwen3-coder-30b:latest', 'flux-dev'], agents=['pi'],
                        active=['pi']),
                     rt('jan', 'Jan'), rt('vllm', 'vLLM', installed=False)],
        'mcp': [{'name': 'filesystem', 'target': 'npx', 'agents': ['claude']},
                {'name': 'photocraft', 'target': '~/x', 'agents': []},
                {'name': 'brave-search', 'target': 'https://x', 'agents': ['pi']},
                {'name': 'Kokoro-TTS', 'target': '', 'agents': []}],
        'skill_sets': [{'path': '/home/u/.agents/skills', 'skills': ['pdf', 'tts-voice']},
                       {'path': '/mnt/Data/Skills', 'skills': ['review']}],
        'providers': {'claude': [{'local': False}], 'pi': [{'local': True}], 'bionic': []},
        'facts': {'claude': {'chat_app': False, 'web_search': True}, 'bionic': {'chat_app': True, 'web_search': False}},
        'graph': {'nodes': [node('model:a', 'model', f'{home}/models', False), node('model:b', 'more', f'{home}/models'),
                            node('model:c', 'model', '/mnt/Big', True), node('model:d', 'model', '/mnt/Idle'),
                            node('model:e', 'model', '', False), node('agent:x', 'agent', 'g', column=1)]},
        'pc': {'vendor': 'amd', 'gpu': 'Advanced Micro Devices, Inc. [AMD/ATI] Navi 31 [Radeon RX 7900 XT/7900 XTX] (rev c8)',
               'vram': 24 * GIB, 'ram': 64 * GIB, 'cpus': 32,
               'free': {f'{home}/models': 15 * GIB, '/mnt/Big': 40 * GIB, '/mnt/Huge': 500 * GIB}},
        'failed_links': {'agent:pi|runtime:jan': {'kind': 'provider', 'hints': []},
                         'agent:ghost|mcp:x': {'kind': 'mcp', 'hints': []}},
    }
    empty = {'agents': [], 'agent_checks': {}, 'runtime_checks': {}, 'runtimes': [], 'mcp': [], 'skill_sets': [],
             'providers': {}, 'facts': {}, 'graph': None,
             'pc': {'vendor': 'cpu', 'gpu': '', 'vram': 0, 'ram': 8 * GIB, 'cpus': 4, 'free': {}}, 'failed_links': {}}
    small = {**full, 'pc': {'vendor': 'nvidia', 'gpu': 'NVIDIA Corporation GA107 [GeForce RTX 3050]', 'vram': int(5.25 * GIB),
                            'ram': 12 * GIB, 'cpus': 8, 'free': {}},
             'agent_checks': {c: [chk('ok', 'Installed')] for c in ('claude', 'pi', 'bionic')},
             'runtime_checks': {}, 'failed_links': {}, 'mcp': [], 'skill_sets': [],
             'runtimes': [rt('llamacpp', 'llama.cpp', models=[]), rt('ollama', 'Ollama', running=True, models=['m'],
                                                                       agents=['pi'])]}
    coders = {**small, 'pc': {**small['pc'], 'vram': 12 * GIB, 'gpu': 'odd card name'}, 'providers': {},
              'runtimes': [rt('llamacpp', 'llama.cpp', models=['plain'], agents=[])], 'facts': {}}
    return [full, empty, small, coders]


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartHealthReportParityTest(unittest.TestCase):
    def test_same_report(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            tools = home / 'bin'
            tools.mkdir()
            for name in ('krita', 'whisper-cli'):
                (tools / name).write_text('#!/bin/sh\n')
                (tools / name).chmod(0o755)
            all_cases = cases(str(home))
            results = []
            for desktop in ('generic', 'omarchy'):
                env = {k: v for k, v in os.environ.items() if not k.startswith('XDG_')}
                env.update(HOME=str(home), PATH=f'{tools}:/usr/bin:/bin', LANG='C.UTF-8', ASTERISM_DESKTOP=desktop)
                python = json.loads(subprocess.run([sys.executable, '-c', PYTHON, str(ROOT)], input=json.dumps(all_cases),
                                                   capture_output=True, check=True, text=True, env=env,
                                                   timeout=300).stdout.replace('AI Agents Map', 'Maprisma'))
                lines = [json.dumps({'id': i, 'protocol': 1, 'method': 'dev.healthreport',
                                     'params': {**c, 'desktop': desktop}}) for i, c in enumerate(all_cases, 1)]
                out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                      'bin/fixture_probe.dart'], input=('\n'.join(lines) + '\n').encode(),
                                     capture_output=True, cwd=ROOT / 'packages/asterism_core', timeout=300, env=env)
                dart = [json.loads(line)['result'] for line in out.stdout.splitlines() if line.startswith(b'{')]
                self.assertEqual(len(dart), len(all_cases), out.stderr.decode()[-2000:])
                results.append((python, dart))
        self.maxDiff = None
        for python, dart in results:
            for py, da in zip(python, dart):
                self.assertEqual(py, da)
        full = results[0][0][0]
        titles = [f['title'] for a in full['areas'] for f in a['findings']]
        self.assertIn('AMD Radeon RX 7900 XT with 24 GB video memory', titles)
        self.assertIn('Little free space for models: 15 GB', titles)
        self.assertIn('Claude Code: Not signed in', titles)
        self.assertIn('2 model folders no agent uses', titles)
        self.assertIn('A connection does not work: Pi → jan', titles)
        self.assertEqual({u['key']: u['level'] for u in full['uses']}['images'], 'ready')
        empty = results[0][0][1]
        self.assertEqual(empty['level'], 'warn')             # no agent installed
        self.assertTrue(empty['summary'].startswith('1 thing to fix'))
        self.assertEqual([f['action'] for f in empty['areas'][2]['findings']], [['install', 'llamacpp']])


if __name__ == '__main__':
    unittest.main()
