"""Development parity: programs on this PC that offer an MCP server and skill sets apps brought along
(mcp_scan.scan with fold_versions, new_versions_found, not_looked_into, skills_scan.scan) in the Python
reference and the Dart core: a usage text with root options and --headless, a marker across the 8 MiB
read seam, a program named for MCP that only says "MCP server", clients left out, two unpacked versions
of an app (the older one used by an agent), an AppImage looked into before (from the cache) and a newer
one not yet, PATH and /opt programs, Setup's added folders, skill sets (known, skipped, nested, added).
Skipped without a native Dart SDK."""
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
import extra_folders, mcp_scan, skills_scan
case = json.loads(sys.stdin.read())
mcp_scan.OPT = Path(case['opt'])
mcp_scan.SCAN_CACHE = Path(case['cache'])
mcp_scan.clients = lambda: set(case['skip'])
skills_scan.ROOTS = [(Path(r), d) for r, d in case['skill_roots']]
extra_folders.saved = lambda kind: case['mcp_folders'] if kind == 'mcp' else case['skill_folders']
found = mcp_scan.scan(case['configured'], [])
print(json.dumps({'mcp': [dataclasses.asdict(c) for c in found],
                  'versions': [str(p) for p in mcp_scan.new_versions_found()],
                  'not_looked': [str(p) for p in mcp_scan.not_looked_into()],
                  'skills': [dataclasses.asdict(s) for s in skills_scan.scan(case['known'])]}))
'''

ELF = b'\x7fELF\x02\x01\x01\x00'
MARKS = b'\x00tools/list\x00protocolVersion\x00notifications/initialized\x00'


def program(path: Path, body: bytes, elf: bool = True):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes((ELF if elf else b'#!/bin/sh\n') + body)
    path.chmod(0o755)


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartFoundScanParityTest(unittest.TestCase):
    def test_same_finds(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            apps = home / 'Applications'
            program(home / '.local/bin/wordcraft-cli', MARKS + b'Usage: wordcraft-cli mcp [--automation-read-root DIR]'
                    b' [--headless]\n     --automation-write-root DIR  where it writes\n   sub thing\n\x00rest')
            # A marker across the first 8 MiB read: found from the overlap.
            seam = 8 * 1024 * 1024 - len(ELF) - 5
            program(home / 'bin/bigtool', b'\x00' * seam + b'tools/list\x00' + b' ' * 100 + b'protocolVersion')
            program(home / 'bin/foo-mcp', b'This is an MCP server for foo', elf=False)
            program(home / 'bin/claude', MARKS)                                 # a client: never offered
            program(home / 'bin/plain', b'nothing here')
            for version in ('0.7.0', '0.8.0'):
                program(apps / f'gridcraft-{version}/usr/bin/gridcraft-cli',
                        MARKS + b'gridcraft-cli mcp [--root DIR] [--automation-write-root DIR]\n')
            (home / '.local/bin/gridcraft').symlink_to(apps / 'gridcraft-0.7.0/usr/bin/gridcraft-cli')
            image = apps / 'vectorcraft-1.2.0-x86_64.AppImage'
            program(image, b'squashfs')
            program(apps / 'vectorcraft-1.3.0-x86_64.AppImage', b'squashfs newer')
            program(apps / 'other.AppImage', b'squashfs other')
            opt = home / 'opt'
            program(opt / 'photo/bin/photocraft', MARKS + b'photocraft mcp [--read-root DIR]\n')
            path_dir = home / 'path'
            program(path_dir / 'mcp-server-notes', MARKS)
            program(path_dir / 'unrelated', MARKS)
            added = home / 'shared'
            program(added / 'filmcraft-2.0/usr/bin/filmcraft', MARKS + b'filmcraft mcp [--headless]\n')
            st = image.stat()
            seed = {f'appimage:{image}|{st.st_size}|{int(st.st_mtime)}':
                    [['vectorcraft-cli', 3, 'vectorcraft-cli mcp [--connect PORT | --headless]']]}
            # Skill sets.
            share = home / 'share'
            for folder in ('omaraw/skills/edit', 'omaraw/skills/export', 'known/skills/a', 'icons/x/skills/b',
                           'deep/one/two/skills/c'):
                (share / folder).mkdir(parents=True)
                (share / folder / 'SKILL.md').write_text('---\nname: x\n---\n')
            (home / 'mine/s1').mkdir(parents=True)
            (home / 'mine/s1/SKILL.md').write_text('x')
            real = str(apps / 'gridcraft-0.7.0/usr/bin/gridcraft-cli')
            cases = []
            for side in ('py', 'dart'):
                cache = home / f'{side}-cache.json'
                cache.write_text(json.dumps(seed))
                cases.append({'opt': str(opt), 'cache': str(cache), 'skip': ['claude', 'node'],
                              'skill_roots': [[str(share), 4]], 'mcp_folders': ['~/shared', '~/missing'],
                              'skill_folders': ['~/mine'], 'configured': {real: ['codex']},
                              'known': [str(share / 'known/skills')]})
            env = {k: v for k, v in os.environ.items() if not k.startswith('XDG_')}
            env.update(HOME=str(home), PATH=f'{path_dir}:/usr/bin:/bin', LANG='C.UTF-8', MAPRISMA_DESKTOP='generic')
            python = json.loads(subprocess.run([sys.executable, '-c', PYTHON, str(ROOT)], input=json.dumps(cases[0]),
                                               capture_output=True, check=True, text=True, env=env,
                                               timeout=120).stdout)
            line = json.dumps({'id': 1, 'protocol': 1, 'method': 'dev.foundscan', 'params': cases[1]})
            out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                  'bin/fixture_probe.dart'], input=(line + '\n').encode(), capture_output=True,
                                 cwd=ROOT / 'packages/maprisma_core', timeout=300, env=env)
            dart = [json.loads(x)['result'] for x in out.stdout.splitlines() if x.startswith(b'{')]
            self.assertEqual(len(dart), 1, out.stderr.decode()[-2000:])
            self.maxDiff = None
            self.assertEqual(python, dart[0])
            # The second look comes from the cache: the same again.
            again = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                    'bin/fixture_probe.dart'], input=(line + '\n').encode(), capture_output=True,
                                   cwd=ROOT / 'packages/maprisma_core', timeout=300, env=env)
            self.assertEqual([json.loads(x)['result'] for x in again.stdout.splitlines() if x.startswith(b'{')],
                             dart)
            names = {c['name']: c for c in python['mcp']}
            self.assertEqual(names['wordcraft']['command'],
                             [str(home / '.local/bin/wordcraft-cli'), 'mcp', '--headless', '--automation-read-root',
                              str(home / 'Documents'), '--automation-write-root', str(home / 'Documents')])
            self.assertIn('bigtool', names)
            self.assertIn('foo', names)
            self.assertNotIn('claude', names)
            self.assertEqual(names['gridcraft']['version'], '0.8.0')
            self.assertEqual(names['gridcraft']['update_from'], '0.7.0')
            self.assertEqual(names['gridcraft']['users'], ['codex'])
            self.assertEqual(names['vectorcraft']['appimage'], str(image))
            self.assertIn('notes', names)
            self.assertIn('filmcraft', names)
            self.assertEqual(python['versions'], [str(apps / 'vectorcraft-1.3.0-x86_64.AppImage')])
            self.assertEqual({s['origin'] for s in python['skills']}, {'omaraw', 'two', 'mine'})


if __name__ == '__main__':
    unittest.main()
