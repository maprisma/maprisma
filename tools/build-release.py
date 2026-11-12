#!/usr/bin/env python3
"""Build a Maprisma release: dist/maprisma-<version>-x86_64.tar.gz and its SHA-256.

The app with its own id (com.maprisma.Maprisma, MAPRISMA_RELEASE=true), the core's helper
(lib/maprisma-core), the manuals and the AI helpers of the other Maprisma apps (data/; helpers.json from
tools/export-helpers.py, installed as /usr/lib/maprisma/data/helpers.json), the signed add-ons from Uwe's
maprisma-addons checkout (addons/, unpacked from dist/adapters-<version>.zip: the version must be this one, signed with
tools/release-adapters.sh there), then the bundle gate (tools/check-bundle.py). The archive holds one
folder maprisma-<version>/ with:
    app/                      the bundle (maprisma, lib/, data/, addons/)
    share/applications/       com.maprisma.Maprisma.desktop
    share/metainfo/           com.maprisma.Maprisma.metainfo.xml
    share/icons/hicolor/scalable/apps/com.maprisma.Maprisma.svg
    LICENSE
The AUR package maprisma-bin and the AppImage are made from it (packaging/).

    tools/build-release.py [--addons <maprisma-addons checkout>]
"""
import argparse
import hashlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_ID = 'com.maprisma.Maprisma'


def version() -> str:
    found = re.search(r'^MAPRISMA_VERSION = "([0-9.]+)"', (ROOT / 'addons.py').read_text(), re.M)
    if not found:
        sys.exit('no MAPRISMA_VERSION in addons.py')
    return found.group(1)


def release_identity(stage: Path):
    cmake = stage / 'linux/CMakeLists.txt'
    text = cmake.read_text()
    if f'set(APPLICATION_ID "{APP_ID}")' not in text:
        sys.exit('Unexpected application id in linux/CMakeLists.txt')


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--addons', type=Path, default=ROOT.parent / 'maprisma-addons')
    args = parser.parse_args()
    ver = version()
    adapters = args.addons / 'dist' / f'adapters-{ver}.zip'
    if not adapters.is_file():
        sys.exit(f'{adapters} is missing: sign the {ver} add-ons first '
                 f'(cd {args.addons} && MAPRISMA={ROOT} tools/release-adapters.sh)')
    if subprocess.run([sys.executable, '-I', str(ROOT / 'tools/export-helpers.py'), '--check']).returncode:
        sys.exit('data/helpers.json is out of date: run tools/export-helpers.py and commit it')
    sys.path.insert(0, str(ROOT / 'tools'))
    from dart_sdk import resolve_dart
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='release-', dir=dist) as temp:
        stage = Path(temp) / 'flutter_app'
        shutil.copytree(ROOT / 'flutter_app', stage,
                        ignore=shutil.ignore_patterns('build', '.dart_tool', 'ephemeral', '.flutter-plugins*'))
        shutil.copytree(ROOT / 'packages', stage.parent / 'packages',
                        ignore=shutil.ignore_patterns('build', '.dart_tool'))
        release_identity(stage)
        command = ['flutter', '--suppress-analytics', '--no-version-check']
        subprocess.run([*command, 'pub', 'get', '--offline'], cwd=stage, check=True)
        subprocess.run([*command, 'build', 'linux', '--release', '--no-pub',
                        '--dart-define=MAPRISMA_RELEASE=true'], cwd=stage, check=True)
        bundle = stage / 'build/linux/x64/release/bundle'
        core = stage.parent / 'packages/maprisma_core'
        subprocess.run([resolve_dart(), 'pub', 'get', '--offline'], cwd=core, check=True)
        subprocess.run([resolve_dart(), 'compile', 'exe', 'bin/maprisma-core.dart', '-o',
                        str(bundle / 'lib/maprisma-core')], cwd=core, check=True)
        (bundle / 'data').mkdir(exist_ok=True)
        for manual in sorted((ROOT / 'data').glob('user-manual*.pdf')):
            shutil.copy2(manual, bundle / 'data' / manual.name)
        shutil.copy2(ROOT / 'data/helpers.json', bundle / 'data/helpers.json')   # the AI helpers (JSON)
        subprocess.run([sys.executable, str(ROOT / 'packaging/unpack-adapters.py'), str(adapters),
                        str(bundle / 'addons')], check=True)
        subprocess.run([sys.executable, str(ROOT / 'tools/check-bundle.py'), str(bundle)], check=True)
        top = Path(temp) / f'maprisma-{ver}'
        shutil.copytree(bundle, top / 'app', symlinks=True)
        for source, target in ((f'data/{APP_ID}.desktop', 'share/applications'),
                               (f'data/{APP_ID}.metainfo.xml', 'share/metainfo'),
                               (f'data/icons/{APP_ID}.svg', 'share/icons/hicolor/scalable/apps'),
                               ('LICENSE', '.')):
            (top / target).mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / source, top / target / Path(source).name)
        archive = dist / f'maprisma-{ver}-x86_64.tar.gz'

        def owned(info):          # root-owned in any package made from it, no build user's names
            info.uid = info.gid = 0
            info.uname = info.gname = 'root'
            return info
        with tarfile.open(archive, 'w:gz') as tar:
            tar.add(top, arcname=top.name, filter=owned)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (dist / f'{archive.name}.sha256').write_text(f'{digest}  {archive.name}\n')
    print(f'\n{archive}\nsha256 {digest}')


if __name__ == '__main__':
    main()
