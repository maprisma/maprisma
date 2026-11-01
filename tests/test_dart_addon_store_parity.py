"""Development parity: the signed add-on catalog (addon_store.parse_catalog) and installing add-on
zips (install_bytes: unpack, the add-on's own signature, replacing an installed copy) in Python and
in the Dart core, with Uwe's real signed catalog and zips from maprisma-addons and tampered zips.
Skipped without a native Dart SDK or the maprisma-addons checkout."""
import base64
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile
from dataclasses import asdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ADDONS = ROOT.parent / 'maprisma-addons'
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'tools'))

import addon_store  # noqa: E402

try:
    from dart_sdk import resolve_dart
    DART = resolve_dart()
except (OSError, ValueError, RuntimeError):
    DART = None


def rezip(source: bytes, change) -> bytes:
    """A copy of a zip with change(name, data) -> [(name, data, mode)] applied to each member."""
    out = io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(source)) as old, zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as new:
        for info in old.infolist():
            for name, data, mode in change(info.filename, old.read(info)):
                item = zipfile.ZipInfo(name)
                item.external_attr = mode << 16
                item.compress_type = zipfile.ZIP_DEFLATED
                new.writestr(item, data)
    return out.getvalue()


def tree(root: Path) -> dict:
    found = {}
    for path in sorted(root.rglob('*')):
        rel = str(path.relative_to(root))
        if rel.startswith('.'):
            continue
        found[rel] = ('dir', oct(path.stat().st_mode & 0o777)) if path.is_dir() else \
            (path.read_bytes(), oct(path.stat().st_mode & 0o777))
    return found


@unittest.skipIf(DART is None or not ADDONS.is_dir(), 'native Dart SDK or maprisma-addons not available')
class DartAddonStoreParityTest(unittest.TestCase):
    def probe(self, requests):
        lines = [json.dumps({'id': i, 'protocol': 2, 'method': 'dev.addonstore', 'params': r})
                 for i, r in enumerate(requests, 1)]
        out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                              'bin/fixture_probe.dart'], input=('\n'.join(lines) + '\n').encode(),
                             capture_output=True, cwd=ROOT / 'packages/maprisma_core', timeout=300, check=True)
        return [json.loads(line)['result'] for line in out.stdout.splitlines() if line.startswith(b'{')]

    def test_same_catalog(self):
        text, sig = (ADDONS / 'catalog.json').read_bytes(), (ADDONS / 'catalog.sig').read_bytes()
        cases = [(text, sig), (text + b' ', sig), (text.replace(b'"agent-goose"', b'"agent-gooze"'), sig)]
        with tempfile.TemporaryDirectory() as temp:
            requests = []
            for index, (t, s) in enumerate(cases):
                (Path(temp) / f'{index}.json').write_bytes(t)
                (Path(temp) / f'{index}.sig').write_bytes(s)
                requests.append({'op': 'parse', 'text': f'{temp}/{index}.json', 'sig': f'{temp}/{index}.sig'})
            replies = self.probe(requests)
        for (t, s), reply in zip(cases, replies):
            entries = addon_store.parse_catalog(t, s)
            expected = None if entries is None else [asdict(e) for e in entries]
            self.assertEqual(expected, reply['entries'])
        self.assertGreater(len(replies[0]['entries']), 20)
        self.assertIsNone(replies[1]['entries'])

    def test_same_installs(self):
        dist = ADDONS / 'dist'
        # One signed version so far: a first install, then the same version again.
        version = json.loads((ADDONS / 'agent-goose/addon.json').read_text())['version']   # as signed
        goose = (dist / f'agent-goose-{version}.zip').read_bytes()
        jan = (dist / f'llm-jan-{version}.zip').read_bytes()
        cases = [
            ('first', goose, 'agent-goose'),
            ('again', goose, 'agent-goose'),
            ('code', jan, 'llm-jan'),
            ('wrong id', goose, 'agent-other'),
            ('changed file', rezip(goose, lambda n, d: [(n, d + b'\n' if n.endswith('agent.toml') else d, 0o644)]), None),
            ('extra file', rezip(goose, lambda n, d: [(n, d, 0o644)] + ([('agent-goose/x.txt', b'x', 0o644)]
                                                                        if n.endswith('addon.json') else [])), None),
            ('link', rezip(goose, lambda n, d: [(n, d, 0o120777 if n.endswith('agent.toml') else 0o644)]), None),
            ('bad name', rezip(goose, lambda n, d: [(n.replace('agent-goose/', 'agent-goose/../'), d, 0o644)]), None),
            ('two ids', rezip(goose, lambda n, d: [(n.replace('agent-goose/addon.json', 'other/addon.json'), d, 0o644)]),
             None),
            ('garbage', b'not a zip', None),
        ]
        sides = {}
        with tempfile.TemporaryDirectory() as temp:
            for side in ('python', 'dart'):
                user = Path(temp) / side / 'addons'
                user.mkdir(parents=True)
                results = []
                if side == 'python':
                    for _label, data, expect in cases:
                        try:
                            item = addon_store.install_bytes(data, user_dir=user, expect=expect,
                                                             trash=lambda path: __import__('shutil').rmtree(path))
                            results.append({'id': item.id, 'version': item.version, 'state': item.state})
                        except addon_store.InstallError:
                            results.append('refused')
                else:
                    replies = self.probe([{'op': 'install', 'zip': base64.b64encode(data).decode(),
                                           'user_dir': str(user), 'expect': expect} for _l, data, expect in cases])
                    results = ['refused' if 'error' in r else r for r in replies]
                sides[side] = (results, tree(user))
        self.assertEqual(sides['python'], sides['dart'])
        results, files = sides['dart']
        version = json.loads((ADDONS / 'agent-goose/addon.json').read_text())['version']
        self.assertEqual(results[0]['version'], version)
        self.assertEqual(results[1]['version'], version)
        self.assertEqual(results[2]['id'], 'llm-jan')
        self.assertEqual(results[3:], ['refused'] * 7)
        self.assertEqual(files['agent-goose'], ('dir', '0o755'))


if __name__ == '__main__':
    unittest.main()
