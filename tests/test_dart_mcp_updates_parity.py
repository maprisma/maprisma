"""Development parity: the daily AI checks' MCP server updates (mcp_updates.installed_servers, prompt_for,
_answer_json, validate, cached, still_open, on_pc, due and task_prompt) in the Python reference and the Dart
core: an app unpacked in ~/Applications or as an unpacked AppImage in another folder (direct, through a link), pinned and unpinned npm and PyPI
packages, pipx run, a remote server; answers with prose around the JSON, an unknown server, an older or
unparsable version, an http or spaced link, long notes, no JSON; the cache fresh, failed and old; an update
moved by the map's Update, one already downloaded as AppImage. Skipped without a native Dart SDK."""
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
sys.path.insert(0, sys.argv[1])
import mcp_scan, mcp_updates
case = json.loads(sys.stdin.read())
servers = mcp_updates.installed_servers(case['library'])
cache = Path(case['cache'])
def answer(text):
    try:
        return [dataclasses.asdict(f) for f in mcp_updates.validate(mcp_updates._answer_json(text), servers)]
    except ValueError:
        return None
found = [mcp_updates.Found(**f) for f in case['found']]
print(json.dumps({
    'servers': [dataclasses.asdict(s) for s in servers],
    'prompt': mcp_updates.prompt_for(servers),
    'answers': [answer(t) for t in case['answers']],
    'cached': [dataclasses.asdict(f) for f in mcp_updates.cached(cache)],
    'open': [dataclasses.asdict(f) for f in mcp_updates.still_open(found, servers)],
    'on_pc': [mcp_updates.on_pc(f) for f in found],
    'due': [mcp_updates.due(n, cache) for n in case['now']],
    'tasks': [mcp_updates.task_prompt(f) for f in found],
    'images': [str(p) for p in mcp_scan.appimages()]}))
'''


def found(name, app, current, latest, source='app', program=''):
    return {'name': name, 'app': app, 'current': current, 'latest': latest, 'url': f'https://{app}.org/r',
            'notes': 'Faster.', 'source': source, 'program': program}


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartMcpUpdatesParityTest(unittest.TestCase):
    def test_same_updates(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            apps = home / 'Applications'
            for folder in ('photocraft-0.11.1', 'gridcraft-0.7.0', 'wordcraft-0.6.1', 'figcraft-1.2.0'):
                (apps / folder / 'usr/bin').mkdir(parents=True)
                (apps / folder / 'usr/bin/cli').write_text('#!/bin/sh\n')
            image = apps / 'wordcraft-0.7.0-linux-x86_64.AppImage'
            image.write_text('')
            image.chmod(0o755)
            bin_dir = home / '.local/bin'
            bin_dir.mkdir(parents=True)
            (bin_dir / 'gridcraft-cli').symlink_to(apps / 'gridcraft-0.7.0/usr/bin/cli')
            servers = home / 'Ai/McpServers'                     # unpacked AppImages outside ~/Applications
            for folder in ('cadcraft-0.13.0', 'cadcraft-0.14.0', 'deckcraft-0.11.1'):
                (servers / folder / 'usr/bin').mkdir(parents=True)
                (servers / folder / 'usr/bin/cli').write_text('#!/bin/sh\n')
            (bin_dir / 'deck-cli').symlink_to(servers / 'deckcraft-0.11.1/usr/bin/cli')
            (home / 'tools/bin').mkdir(parents=True)
            (home / 'tools/bin/tool').write_text('')
            library = {
                'photocraft': {'command': str(apps / 'photocraft-0.11.1/usr/bin/cli'), 'args': ['mcp']},
                'gridcraft': {'command': '~/.local/bin/gridcraft-cli', 'args': []},
                'wordcraft': {'command': str(apps / 'wordcraft-0.6.1/usr/bin/cli'), 'args': []},
                'figcraft': {'command': str(apps / 'figcraft-1.2.0/usr/bin/cli'), 'args': []},
                'fetch': {'command': 'npx', 'args': ['-y', '@acme/fetch-mcp@1.4.2']},
                'latest': {'command': 'npx', 'args': ['-y', 'thing@latest']},
                'time': {'command': '/usr/bin/uvx', 'args': ['mcp-server-time==2025.9.1']},
                'git': {'command': 'pipx', 'args': ['run', 'mcp-git@0.6.2']},
                'plain': {'command': 'uvx', 'args': ['mcp-plain']},
                'remote': {'url': 'https://mcp.example.org/sse'},
                'other': {'command': '/opt/tool/bin/tool', 'args': []},
                'cadcraft': {'command': str(servers / 'cadcraft-0.13.0/usr/bin/cli'), 'args': []},
                'deckcraft': {'command': '~/.local/bin/deck-cli', 'args': []},
                'tools': {'command': str(home / 'tools/bin/tool'), 'args': []},
                'bad': 'not a server',
            }
            good = {'servers': [
                {'name': 'photocraft', 'latest': 'v0.12.0', 'release_url': 'https://github.com/x/photocraft/releases',
                 'notes': 'New\nfilters   and ' + 'x' * 300},
                {'name': 'gridcraft', 'latest': '0.6.9', 'release_url': 'https://x.org', 'notes': 'older'},
                {'name': 'wordcraft', 'latest': '0.7.0', 'release_url': 'https://word.org/r', 'notes': ''},
                {'name': 'figcraft', 'latest': '1.3', 'release_url': 'http://fig.org', 'notes': 'http'},
                {'name': 'fetch', 'latest': '1.5.0', 'release_url': 'https://npm js.com', 'notes': 'space'},
                {'name': 'time', 'latest': '2026.1.2', 'release_url': 'https://pypi.org/p/time', 'notes': 'ok'},
                {'name': 'git', 'latest': '0.7.0-beta', 'release_url': 'https://pypi.org/p/git', 'notes': 'beta'},
                {'name': 'nobody', 'latest': '9.9', 'release_url': 'https://n.org', 'notes': 'unknown'},
                {'name': 'time', 'latest': '2027.1.1', 'release_url': 'https://pypi.org/p/t2', 'notes': 'again'},
                {'name': 'fetch', 'latest': None, 'release_url': None, 'notes': 'not found'},
            ]}
            answers = ['Here it is:\n```json\n' + json.dumps(good) + '\n```\nDone.',
                       '{"note": {"servers": "no"}} then {"servers": [{"name": "git", "latest": "1.0.0", '
                       '"release_url": "https://g.org/r", "notes": "list"}]}',
                       'no JSON at all', '{"servers": 3}']
            cache = home / 'cache.json'
            cache.write_text(json.dumps({'checked': 1000.0, 'ok': True, 'agent': 'claude', 'found': [
                found('photocraft', 'photocraft', '0.11.1', '0.12.0'), {'name': 'broken'},
                found('time', 'mcp-server-time', '2025.9.1', '2026.1.2', 'pypi')]}))
            case = {
                'library': library, 'answers': answers, 'cache': str(cache),
                'found': [found('photocraft', 'photocraft', '0.11.1', '0.12.0', program='p'),
                          found('wordcraft', 'wordcraft', '0.6.1', '0.7.0'),
                          found('gridcraft', 'gridcraft', '0.6.0', '0.7.0'),
                          found('fetch', '@acme/fetch-mcp', '1.4.2', '1.5.0', 'npm'),
                          found('time', 'mcp-server-time', '2025.9.1', '2025.9.1', 'pypi'),
                          found('cadcraft', 'cadcraft', '0.13.0', '0.14.0',
                                program=str(servers / 'cadcraft-0.13.0/usr/bin/cli')),
                          found('deckcraft', 'deckcraft', '0.11.1', '0.12.0', program='~/.local/bin/deck-cli')],
                'now': [1000.0, 1000.0 + 86399, 1000.0 + 86400, 999.0],
                'appimages': [str(image)],
            }
            env = {k: v for k, v in os.environ.items() if not k.startswith('XDG_')}
            env.update(HOME=str(home), LANG='C.UTF-8', MAPRISMA_DESKTOP='generic')
            python = json.loads(subprocess.run([sys.executable, '-c', PYTHON, str(ROOT)], input=json.dumps(case),
                                               capture_output=True, check=True, text=True, env=env,
                                               timeout=60).stdout)
            self.assertEqual(python.pop('images'), [str(image)])
            line = json.dumps({'id': 1, 'protocol': 1, 'method': 'dev.mcpupdates', 'params': case})
            out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                  'bin/fixture_probe.dart'], input=(line + '\n').encode(), capture_output=True,
                                 cwd=ROOT / 'packages/maprisma_core', timeout=300, env=env)
            dart = [json.loads(x) for x in out.stdout.splitlines() if x.startswith(b'{')]
            cache.write_text(json.dumps({'checked': 1000.0, 'ok': False, 'error': 'x'}))
            failed = json.loads(subprocess.run([sys.executable, '-c', PYTHON, str(ROOT)],
                                               input=json.dumps({**case, 'now': [1000.0 + 21599, 1000.0 + 21600]}),
                                               capture_output=True, check=True, text=True, env=env,
                                               timeout=60).stdout)['due']
        self.assertEqual(len(dart), 1, out.stderr.decode()[-2000:])
        self.assertIn('result', dart[0], dart[0])
        self.maxDiff = None
        self.assertEqual(python, dart[0]['result'])
        self.assertEqual([s['name'] for s in python['servers']],
                         ['photocraft', 'gridcraft', 'wordcraft', 'figcraft', 'fetch', 'time', 'git',
                          'cadcraft', 'deckcraft'])
        self.assertEqual([f['name'] for f in python['answers'][0]], ['photocraft', 'wordcraft', 'time'])
        self.assertTrue(python['answers'][0][0]['notes'].endswith('…'))
        self.assertEqual([f['name'] for f in python['answers'][1]], ['git'])
        self.assertIsNone(python['answers'][2])
        self.assertEqual(python['on_pc'], [False, True, True, False, False, True, False])
        self.assertIn('/Ai/McpServers/deckcraft-0.11.1).', python['tasks'][6])     # its real folder
        self.assertEqual(python['due'], [False, False, True, True])
        self.assertEqual(failed, [False, True])


if __name__ == '__main__':
    unittest.main()
