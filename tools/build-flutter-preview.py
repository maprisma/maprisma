#!/usr/bin/env python3
"""Build an isolated preview without replacing a possibly running app bundle."""
from pathlib import Path
import shutil
import subprocess
import tempfile


def preview_identity(stage: Path):
    cmake = stage / 'linux/CMakeLists.txt'
    text = cmake.read_text()
    expected = 'set(APPLICATION_ID "com.maprisma.Maprisma")'
    if expected not in text:
        raise SystemExit('Unexpected production application id')
    cmake.write_text(text.replace(expected, 'set(APPLICATION_ID "com.maprisma.Maprisma.Devel")'))

def main():
    root = Path(__file__).resolve().parent.parent
    previews = root / '.flutter-previews'
    previews.mkdir(exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='preview-', dir=previews)) / 'flutter_app'
    shutil.copytree(root / 'flutter_app', stage,
                    ignore=shutil.ignore_patterns('build', '.dart_tool', 'ephemeral', '.flutter-plugins*'))
    shutil.copytree(root / 'packages', stage.parent / 'packages',
                    ignore=shutil.ignore_patterns('build', '.dart_tool'))
    preview_identity(stage)
    command = ['flutter', '--suppress-analytics', '--no-version-check']
    subprocess.run([*command, 'pub', 'get', '--offline'], cwd=stage, check=True)
    subprocess.run([*command, 'build', 'linux', '--no-pub',
                    '--dart-define=MAPRISMA_DEVEL=true'], cwd=stage, check=True)
    # The core's plan worker sits next to the app (CoreTasks looks in bundle/lib).
    import sys
    sys.path.insert(0, str(root / 'tools'))
    from dart_sdk import resolve_dart
    core = stage.parent / 'packages/maprisma_core'
    subprocess.run([resolve_dart(), 'pub', 'get', '--offline'], cwd=core, check=True)
    subprocess.run([resolve_dart(), 'compile', 'exe', 'bin/maprisma-core.dart', '-o',
                    str(stage / 'build/linux/x64/release/bundle/lib/maprisma-core')], cwd=core, check=True)
    # The user manuals beside the app (Help opens the one in the interface language).
    data = stage / 'build/linux/x64/release/bundle/data'
    data.mkdir(exist_ok=True)
    for manual in sorted((root / 'data').glob('user-manual*.pdf')):
        shutil.copy2(manual, data / manual.name)
    print(f'\nDevelopment preview: {stage / "build/linux/x64/release/bundle/maprisma"}', flush=True)


if __name__ == '__main__':
    main()
