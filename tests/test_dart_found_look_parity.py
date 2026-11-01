"""Development parity: looking inside an AppImage and unpacking it for a server in it (mcp_scan.look_inside
and unpack) in the Python reference and the Dart core, with a real bubblewrap run: a stand-in AppImage
(a script that unpacks itself on --appimage-extract) is looked into, its program offered from the
cache, then the whole AppImage unpacked into ~/Applications/<app>-<version>/ and its program found
there. Nothing of the look stays in the temporary folder. Skipped without a native Dart SDK or bwrap."""
import json
import os
import shutil
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
import mcp_scan
case = json.loads(sys.stdin.read())
mcp_scan.OPT = Path(case['opt'])
mcp_scan.SCAN_CACHE = Path(case['cache'])
mcp_scan.TEMP = Path(case['temp'])
mcp_scan.clients = lambda: set()
image = Path(case['image'])
looked = mcp_scan.look_inside([image])
before = [dataclasses.asdict(c) for c in mcp_scan.scan({}, [])]
folder = mcp_scan.unpack(image)
after = [dataclasses.asdict(c) for c in mcp_scan.scan({}, [])]
temp = Path(case['temp'])
print(json.dumps({'looked': {k: [list(x) for x in v] for k, v in looked.items()}, 'before': before,
                  'folder': str(folder), 'after': after,
                  'not_looked': [str(p) for p in mcp_scan.not_looked_into()],
                  'temp_left': len(list(temp.iterdir())) if temp.is_dir() else 0}))
'''

APPIMAGE = '''#!/bin/sh
# A stand-in AppImage: unpacks itself (usr/bin only when asked) where it runs.
[ "$1" = "--appimage-extract" ] || exit 2
/usr/bin/mkdir -p squashfs-root/usr/bin
/usr/bin/printf '#!/bin/sh\\ntools/list protocolVersion\\nUsage: toolx-cli mcp [--headless] [--read-root DIR]\\n' \\
    > squashfs-root/usr/bin/toolx-cli
/usr/bin/chmod 755 squashfs-root/usr/bin/toolx-cli
if [ -z "$2" ]; then
  /usr/bin/mkdir -p squashfs-root/usr/share/toolx
  /usr/bin/printf 'data' > squashfs-root/usr/share/toolx/data.txt
fi
'''


def fixture(home: Path) -> dict:
    apps = home / 'Applications'
    apps.mkdir(parents=True)
    image = apps / 'toolx-1.4.0-x86_64.AppImage'
    image.write_text(APPIMAGE)
    image.chmod(0o755)
    return {'opt': str(home / 'opt'), 'cache': str(home / '.cache/maprisma/mcp-scan-3.json'),
            'temp': str(home / '.cache/maprisma/tmp'), 'image': str(image)}


@unittest.skipIf(DART is None or shutil.which('bwrap') is None, 'native Dart SDK or bwrap not available')
class DartFoundLookParityTest(unittest.TestCase):
    def run_side(self, home: Path, dart: bool) -> dict:
        case = fixture(home)
        env = {k: v for k, v in os.environ.items() if not k.startswith('XDG_')}
        env.update(HOME=str(home), PATH='/usr/bin:/bin', LANG='C.UTF-8', MAPRISMA_DESKTOP='generic')
        if not dart:
            out = subprocess.run([sys.executable, '-c', PYTHON, str(ROOT)], input=json.dumps(case),
                                 capture_output=True, text=True, env=env, timeout=180)
            self.assertEqual(out.returncode, 0, out.stderr[-2000:])
            text = out.stdout
        else:
            line = json.dumps({'id': 1, 'protocol': 2, 'method': 'dev.foundlook', 'params': case})
            out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                  'bin/fixture_probe.dart'], input=(line + '\n').encode(), capture_output=True,
                                 cwd=ROOT / 'packages/maprisma_core', timeout=300, env=env)
            results = [json.loads(x)['result'] for x in out.stdout.splitlines() if x.startswith(b'{')]
            self.assertEqual(len(results), 1, out.stderr.decode()[-2000:])
            text = json.dumps(results[0])
        return json.loads(text.replace(str(home), '/HOME'))

    def test_same_look_and_unpack(self):
        with tempfile.TemporaryDirectory() as one, tempfile.TemporaryDirectory() as two:
            python = self.run_side(Path(one), dart=False)
            dart = self.run_side(Path(two), dart=True)
            self.assertTrue((Path(two) / 'Applications/toolx-1.4.0/usr/share/toolx/data.txt').is_file())
        self.maxDiff = None
        self.assertEqual(python, dart)
        image = '/HOME/Applications/toolx-1.4.0-x86_64.AppImage'
        self.assertEqual(python['looked'][image][0][:2], ['toolx-cli', 2])
        self.assertEqual(python['before'][0]['appimage'], image)
        self.assertEqual(python['before'][0]['command'],
                         ['/HOME/Applications/toolx-1.4.0/usr/bin/toolx-cli', 'mcp', '--headless',
                          '--read-root', '/HOME/Documents'])
        self.assertEqual(python['folder'], '/HOME/Applications/toolx-1.4.0')
        self.assertEqual(python['after'][0]['appimage'], '')       # now a program in the unpacked folder
        self.assertEqual(python['after'][0]['version'], '1.4.0')
        self.assertEqual(python['not_looked'], [])
        self.assertEqual(python['temp_left'], 0)


if __name__ == '__main__':
    unittest.main()
