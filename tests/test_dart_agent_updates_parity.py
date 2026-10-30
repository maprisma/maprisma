"""Development parity: updates for the installed agents and local LLMs (agent_updates.check and
still_open) in the Python reference and the Dart core: mise's outdated tools (odd names and versions
dropped), Claude Code's own channel (stable from its settings), the app's own llama.cpp install (a
newer release, the same, an older one), the cache (fresh, stale, odd entries, updates installed
since). The web and mise are given. Skipped without a native Dart SDK."""
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
import dataclasses, json, sys
from pathlib import Path
from types import SimpleNamespace as NS
sys.path.insert(0, sys.argv[1])
import agent_updates, install_ctl, inventory
out = []
for case in json.loads(sys.stdin.read()):
    agents = [NS(**a) for a in case['agents']]
    rts = [inventory.Runtime(r['key'], r['name'], installed=r['installed']) for r in case['runtimes']]
    mise = {k: tuple(v) for k, v in case['mise'].items()}
    sources = {'mise': lambda mise=mise: mise, 'gpu': lambda: install_ctl.Gpu(),
               'installer': lambda inst, gpu, v=case['installer_latest']: v}
    # Never the web: an agent's channel comes from the case, also when it has none.
    sources['claude'] = lambda c, case=case: case['latest'].get(f'claude:{c}')
    found = agent_updates.check(agents, rts, now=case['now'], cache=Path(case['cache']), sources=sources)
    out.append({'updates': [dataclasses.asdict(u) for u in found]})
print(json.dumps(out))
'''


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartAgentUpdatesParityTest(unittest.TestCase):
    def test_same_updates(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            tools = home / 'bin'
            tools.mkdir()
            for name in ('mise', 'claude'):
                (tools / name).write_text('#!/bin/sh\n')
                (tools / name).chmod(0o755)
            # The app's own llama.cpp: ~/.local/bin link into <folder>/current, the folder marked.
            folder = home / '.local/share/maprisma/llamacpp'
            (folder / 'b9000-vulkan').mkdir(parents=True)
            (folder / 'b9000-vulkan/llama-server').write_text('')
            (folder / 'current').symlink_to('b9000-vulkan')
            (folder / '.maprisma').write_text('{}')
            (home / '.local/bin').mkdir(parents=True)
            (home / '.local/bin/llama-server').symlink_to(folder / 'current/llama-server')
            (home / '.claude').mkdir()
            (home / '.claude/settings.json').write_text(json.dumps({'autoUpdatesChannel': 'stable'}))
            agents = [{'command': 'claude', 'name': 'Claude Code', 'installed': True, 'version': '2.1.0', 'source': 'own'},
                      {'command': 'codex', 'name': 'Codex', 'installed': True, 'version': '0.40.0', 'source': 'mise'},
                      {'command': 'pi', 'name': 'Pi', 'installed': True, 'version': '1.0', 'source': 'mise'},
                      {'command': 'gemini', 'name': 'Gemini', 'installed': False, 'version': '', 'source': 'mise'}]
            runtimes = [{'key': 'llamacpp', 'name': 'llama.cpp', 'installed': True},
                        {'key': 'ollama', 'name': 'Ollama', 'installed': True}]
            mise = {'npm:@openai/codex': ['0.40.0', '0.41.2'], 'pi': ['1.0', '1.0'], 'bad name!': ['1', '2'],
                    'gemini': ['0.1', '0.2'], 'aqua:x/claude': ['2.0', '2.2'], 'http:weird': ['1 0', '2']}
            base = {'agents': agents, 'runtimes': runtimes, 'mise': mise,
                    'latest': {'claude:stable': '2.1.5', 'claude:latest': '2.2.0'}}
            cases = []
            for side in ('py', 'dart'):
                cache = home / f'{side}-updates.json'
                cases.append([
                    {**base, 'now': 1000.0, 'cache': str(cache), 'installer_latest': 'b9100-vulkan'},
                    # within six hours: the cache, with what is still open
                    {**base, 'now': 1000.0 + 3600, 'cache': str(cache), 'installer_latest': 'b9999',
                     'agents': [{**agents[0], 'version': '2.1.5'}, *agents[1:]]},
                    {**base, 'now': 1000.0 + 7 * 3600, 'cache': str(cache), 'installer_latest': 'b9000-vulkan',
                     'latest': {}},
                    {**base, 'now': 1000.0 + 15 * 3600, 'cache': str(cache), 'installer_latest': 'b8000-vulkan',
                     'mise': {}},
                ])
            odd = home / 'odd.json'
            odd.write_text(json.dumps({'checked': 1000, 'updates': [
                {'kind': 'agent', 'key': 'codex', 'name': 'Codex', 'current': '0.40.0', 'available': '9',
                 'command': ['rm', '-rf', '/'], 'page': False},
                {'kind': 'agent', 'key': 'codex', 'name': 'Codex', 'current': '0.40.0', 'available': '9',
                 'command': ['mise', 'upgrade', 'codex'], 'page': False},
                {'kind': 'other', 'key': 'x', 'name': 'x', 'current': '1', 'available': '2', 'command': [], 'page': False},
                {'kind': 'runtime', 'key': 'jan', 'name': 'Jan', 'current': '1', 'available': '2', 'command': [],
                 'page': False}, 'junk']}))
            env = {k: v for k, v in os.environ.items() if not k.startswith('XDG_')}
            env.update(HOME=str(home), PATH=f'{tools}:/usr/bin:/bin', LANG='C.UTF-8', MAPRISMA_DESKTOP='generic')
            odd_case = {**base, 'now': 2000.0, 'cache': str(odd), 'installer_latest': None}
            python = json.loads(subprocess.run([sys.executable, '-c', PYTHON, str(ROOT)],
                                               input=json.dumps(cases[0] + [odd_case]), capture_output=True,
                                               check=True, text=True, env=env, timeout=120).stdout)
            lines = [json.dumps({'id': i, 'protocol': 1, 'method': 'dev.agentupdates', 'params': c})
                     for i, c in enumerate(cases[1] + [odd_case], 1)]
            out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                  'bin/fixture_probe.dart'], input=('\n'.join(lines) + '\n').encode(),
                                 capture_output=True, cwd=ROOT / 'packages/maprisma_core', timeout=300, env=env)
            dart = [json.loads(line)['result'] for line in out.stdout.splitlines() if line.startswith(b'{')]
        self.maxDiff = None
        self.assertEqual(len(dart), len(python), out.stderr.decode()[-2000:])
        self.assertEqual(python, dart)
        first = {u['key']: u for u in python[0]['updates']}
        self.assertEqual(first['codex']['command'], ['mise', 'upgrade', 'npm:@openai/codex'])
        self.assertEqual(first['claude']['available'], '2.1.5')          # its stable channel
        self.assertEqual(first['claude']['command'], ['claude', 'update'])
        self.assertTrue(first['llamacpp']['page'])
        self.assertNotIn('claude', {u['key'] for u in python[1]['updates']})   # installed since
        self.assertEqual([u['command'] for u in python[4]['updates']], [['mise', 'upgrade', 'codex']])


if __name__ == '__main__':
    unittest.main()
