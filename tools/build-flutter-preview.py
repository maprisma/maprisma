#!/usr/bin/env python3
"""Build an isolated preview without replacing a possibly running app bundle."""
from pathlib import Path
import shutil
import subprocess
import tempfile


def preview_identity(stage: Path):
    cmake = stage / 'linux/CMakeLists.txt'
    text = cmake.read_text()
    expected = 'set(APPLICATION_ID "io.github.ubruckhaus.Asterism")'
    if expected not in text:
        raise SystemExit('Unexpected production application id')
    cmake.write_text(text.replace(expected, 'set(APPLICATION_ID "io.github.ubruckhaus.Asterism.Devel")'))

def main():
    root = Path(__file__).resolve().parent.parent
    previews = root / '.flutter-previews'
    previews.mkdir(exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='preview-', dir=previews)) / 'flutter_app'
    shutil.copytree(root / 'flutter_app', stage,
                    ignore=shutil.ignore_patterns('build', '.dart_tool', 'ephemeral', '.flutter-plugins*'))
    preview_identity(stage)
    command = ['flutter', '--suppress-analytics', '--no-version-check']
    subprocess.run([*command, 'pub', 'get', '--offline'], cwd=stage, check=True)
    subprocess.run([*command, 'build', 'linux', '--no-pub',
                    f'--dart-define=ASTERISM_SOURCE={root}'], cwd=stage, check=True)
    print(f'\nDevelopment preview: {stage / "build/linux/x64/release/bundle/asterism"}', flush=True)


if __name__ == '__main__':
    main()
