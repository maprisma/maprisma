"""Development parity: the details of an MCP server and of a skill set (mcp_pages.mcp_rows and the texts of
open_mcp_details / open_skills_details) in the Python reference and the Dart core: a stdio server in
Claude Code's and Codex's settings (environment values hidden), a remote server with a token in its query
and a header (hidden), a skill set Claude Code reads through links in its own folder, with folded and
plain descriptions. Skipped without a native Dart SDK."""
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
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import mcp_ctl, mcp_pages, skills_ctl
from i18n import _
case = json.loads(sys.stdin.read())
out = {'mcp': {}, 'skills': {}}
for name, agents in case['mcp'].items():
    out['mcp'][name] = {a: [list(r) for r in mcp_pages.McpPages.mcp_rows(a, mcp_ctl.normal(mcp_ctl.raw_entries(a).get(name)))]
                        for a in agents}
ways = {"native": _("reads the folder by itself"), "listed": _("the folder is in its settings"),
        "links": _("links in its own folder ({0})")}
folder = Path(case['skills']['path'])
rows = []
for a in case['skills']['agents']:
    way = skills_ctl.how(a, folder)
    text = ways.get(way, _("through a folder it reads"))
    if way == "links":
        text = text.format(skills_ctl.own_dir(a) or "")
    rows.append(text)
out['skills']['ways'] = rows
out['skills']['descriptions'] = {p.name: skills_ctl.description(p) or "—" for p in skills_ctl.skills_of(folder)}
print(json.dumps(out))
'''


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartItemDetailsParityTest(unittest.TestCase):
    def test_same_details(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            tools = home / '.local/bin'
            tools.mkdir(parents=True)
            for name in ('claude', 'codex'):
                (tools / name).write_text('#!/bin/sh\n')
                (tools / name).chmod(0o755)
            (home / '.claude.json').write_text(json.dumps({'mcpServers': {
                'notes': {'command': 'npx', 'args': ['-y', 'notes-mcp@1.2', '--root', '/srv/my notes'],
                          'env': {'NOTES_TOKEN': 'secret'}},
                'remote': {'type': 'http', 'url': 'https://mcp.example.test/v1/mcp?key=secret',
                           'headers': {'Authorization': 'Bearer secret'}}}}))
            (home / '.codex').mkdir()
            (home / '.codex/config.toml').write_text(
                '[mcp_servers.notes]\ncommand = "npx"\nargs = ["-y", "notes-mcp@1.2"]\n')
            skills = home / 'shared/skills'
            for name, front in (('pdf', 'description: >\n  Reads PDFs\n  and forms.\n'),
                                ('xlsx', 'description: "Sheets."\n'), ('bare', 'name: bare\n')):
                (skills / name).mkdir(parents=True)
                (skills / name / 'SKILL.md').write_text(f'---\nname: {name}\n{front}---\nbody\n')
            (home / '.claude/skills').mkdir(parents=True)
            for name in ('pdf', 'xlsx', 'bare'):
                (home / '.claude/skills' / name).symlink_to(skills / name)
            env = {k: v for k, v in os.environ.items() if not k.startswith('XDG_')}
            env.update(HOME=str(home), PATH=f'{tools}:/usr/bin:/bin', LANG='C.UTF-8', ASTERISM_DESKTOP='generic')
            case = {'mcp': {'notes': ['claude', 'codex'], 'remote': ['claude']},
                    'skills': {'path': str(skills), 'agents': ['claude']}}
            python = json.loads(subprocess.run([sys.executable, '-c', PYTHON, str(ROOT)], input=json.dumps(case),
                                               capture_output=True, check=True, text=True, env=env, timeout=120)
                                .stdout.replace(str(home), '~'))
            lines = [json.dumps({'id': 1, 'protocol': 1, 'method': 'details.mcp', 'params': {'name': 'notes'}}),
                     json.dumps({'id': 2, 'protocol': 1, 'method': 'details.mcp', 'params': {'name': 'remote'}}),
                     json.dumps({'id': 3, 'protocol': 1, 'method': 'details.skills',
                                 'params': {'path': '~/shared/skills'}})]
            out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                  'bin/fixture_probe.dart'], input=('\n'.join(lines) + '\n').encode(),
                                 capture_output=True, cwd=ROOT / 'packages/asterism_core', timeout=300, env=env)
            dart = [json.loads(x) for x in out.stdout.replace(os.fsencode(home), b'~').splitlines()
                    if x.startswith(b'{')]
        self.assertEqual(len(dart), 3, out.stderr.decode()[-2000:])
        for reply in dart:
            self.assertIn('result', reply, reply)
        self.maxDiff = None
        names = {'claude': 'Claude Code', 'codex': 'Codex'}
        for reply, name in ((dart[0], 'notes'), (dart[1], 'remote')):
            got = {s['heading']: s['rows'] for s in reply['result']['sections']}
            self.assertEqual({names[a]: rows for a, rows in python['mcp'][name].items()}, got)
        skills = dart[2]['result']['sections']
        self.assertEqual([r[1] for r in skills[0]['rows']], python['skills']['ways'])
        self.assertEqual({r[0]: r[1] for r in skills[1]['rows']}, python['skills']['descriptions'])
        notes = python['mcp']['notes']['claude']
        self.assertIn(['Environment', 'NOTES_TOKEN = •••', 'Values are not shown: they may be keys or tokens.'], notes)
        self.assertIn(['Address', 'https://mcp.example.test/v1/mcp ?…',
                       'Query parameters are not shown: they may hold a token.'], python['mcp']['remote']['claude'])
        self.assertNotIn('secret', json.dumps(dart))


if __name__ == '__main__':
    unittest.main()
