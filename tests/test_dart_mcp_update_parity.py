"""Development parity: moving every user of an app's older version to its newer one (mcp_update.plan_all and
links) in the Python reference and the Dart core: Claude Code's and Codex's entries that start the older
program (an arg into the old folder moves along, an entry starting a moved link stays, others untouched),
the list of MCP servers, an absolute and a relative link into the old folder, the old folder retired. The
candidates come from the reference's own scan. Skipped without a native Dart SDK."""
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
import mcp_scan, mcp_update
case = json.loads(sys.stdin.read())
mcp_scan.OPT = Path(case['opt'])
mcp_scan.SCAN_CACHE = Path(case['cache'])
mcp_scan.clients = lambda: set()
found = [c for c in mcp_scan.scan(case['configured'], []) if c.update_from]
plan = mcp_update.plan_all(found, case['agents'])
print(json.dumps({'candidates': [dataclasses.asdict(c) for c in found],
                  'plan': {'changes': [[str(c.path), c.old, c.new] for c in plan.changes],
                           'links_add': [[str(l), str(t)] for l, t in plan.links_add],
                           'links_remove': [[str(l), str(t)] for l, t in plan.links_remove],
                           'retire': [str(p) for p in plan.retire],
                           'links': [[[str(l), t, n] for l, t, n in mcp_update.links(c)] for c in found]}}))
'''

MARKS = b'#!/bin/sh\ntools/list protocolVersion\ngridcraft-cli mcp [--root DIR]\n'


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartMcpUpdateParityTest(unittest.TestCase):
    def test_same_update_plan(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            apps = home / 'Applications'
            for version in ('0.7.0', '0.8.0'):
                program = apps / f'gridcraft-{version}/usr/bin/gridcraft-cli'
                program.parent.mkdir(parents=True)
                program.write_bytes(MARKS)
                program.chmod(0o755)
                (apps / f'gridcraft-{version}/share').mkdir()
            old = apps / 'gridcraft-0.7.0/usr/bin/gridcraft-cli'
            (home / '.local/bin').mkdir(parents=True)
            (home / '.local/bin/gridcraft').symlink_to(old)
            (home / 'bin').mkdir()
            (home / 'bin/gc').symlink_to('../Applications/gridcraft-0.7.0/usr/bin/gridcraft-cli')
            (home / 'bin/unrelated').symlink_to('/usr/bin/env')
            (home / '.claude.json').write_text(json.dumps({'mcpServers': {
                'grid': {'command': str(old), 'args': ['--root', str(apps / 'gridcraft-0.7.0/share'), 'x']},
                'linked': {'command': 'gridcraft', 'args': ['mcp']},
                'other': {'command': 'npx', 'args': ['-y', 'thing']}}}, indent=2))
            (home / '.codex').mkdir()
            (home / '.codex/config.toml').write_text(
                f'model = "x"\n\n[mcp_servers.grid2]\ncommand = "{old}"\nargs = ["mcp"]\n')
            listed = {'servers': {'grid': {'transport': 'stdio', 'command': str(old), 'args': ['mcp'], 'env': {},
                                           'url': '', 'headers': {}}}}
            for app in ('ai-agents-map', 'asterism'):
                (home / f'.config/{app}').mkdir(parents=True)
                (home / f'.config/{app}/mcp-servers.json').write_text(json.dumps(listed, indent=2) + '\n')
            case = {'opt': str(home / 'opt'), 'cache': str(home / 'scan.json'), 'agents': ['claude', 'codex'],
                    'configured': {str(old): ['claude']}}
            tools = home / 'tools'
            for name in ('claude', 'codex'):
                (tools / name).parent.mkdir(exist_ok=True)
                (tools / name).write_text('#!/bin/sh\n')
                (tools / name).chmod(0o755)
            env = {k: v for k, v in os.environ.items() if not k.startswith('XDG_')}
            env.update(HOME=str(home), PATH=f'{home}/.local/bin:{tools}:/usr/bin:/bin', LANG='C.UTF-8',
                       ASTERISM_DESKTOP='generic')
            out = subprocess.run([sys.executable, '-c', PYTHON, str(ROOT)], input=json.dumps(case),
                                 capture_output=True, text=True, env=env, timeout=120)
            self.assertEqual(out.returncode, 0, out.stderr[-3000:])
            python = json.loads(out.stdout)
            line = json.dumps({'id': 1, 'protocol': 1, 'method': 'dev.mcpupdate',
                               'params': {'candidates': python['candidates'], 'agents': case['agents']}})
            run = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                  'bin/fixture_probe.dart'], input=(line + '\n').encode(), capture_output=True,
                                 cwd=ROOT / 'packages/asterism_core', timeout=300, env=env)
            dart = [json.loads(x) for x in run.stdout.splitlines() if x.startswith(b'{')]
            self.assertEqual(len(dart), 1, run.stderr.decode()[-3000:])
            self.assertIn('result', dart[0], dart[0])
            expected = json.loads(json.dumps(python['plan']).replace('.config/ai-agents-map', '.config/asterism'))
        self.maxDiff = None
        self.assertEqual(expected, dart[0]['result'])
        plan = python['plan']
        self.assertEqual(len(plan['changes']), 3)                            # Claude Code, Codex, the list
        claude = next(c for c in plan['changes'] if c[0].endswith('.claude.json'))
        self.assertIn('gridcraft-0.8.0/share', claude[2])
        self.assertIn('"command": "gridcraft"', claude[2])                   # the link's user stays
        self.assertEqual(len(plan['links_add']), 2)
        self.assertEqual(plan['retire'], [str(apps / 'gridcraft-0.7.0')])


if __name__ == '__main__':
    unittest.main()
