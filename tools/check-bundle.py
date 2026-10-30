#!/usr/bin/env python3
"""Release gate (phase 7): the shipped Asterism has no Python in it.

Checks a built Linux bundle (default: the newest development preview) and the app's Dart sources:
- no .py/.pyc file, no python executable and no Python environment folder in the bundle;
- no marker of a Python service in its binaries: the interpreter path it would start, the old
  service script, the old transport class;
- none of these in the code of the app's and the core's Dart sources (lib/, bin/; comments naming
  the Python reference a port follows are allowed), outside tests and tools.

Names like "python3" in the core's data (programs it recognises, folders it looks into) are not a
service and are allowed. Exit 1 with every finding listed.
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MARKERS = (b'/usr/bin/python3', b'flutter_backend', b'PythonTransport', b'ASTERISM_SOURCE')
SOURCES = (ROOT / 'flutter_app/lib', ROOT / 'packages/asterism_core/lib', ROOT / 'packages/asterism_core/bin')


def newest_bundle() -> Path | None:
    found = sorted((ROOT / '.flutter-previews').glob('preview-*/flutter_app/build/linux/x64/release/bundle'),
                   key=lambda p: p.stat().st_mtime)
    return found[-1] if found else None


def check_bundle(bundle: Path) -> list[str]:
    problems = []
    for path in sorted(bundle.rglob('*')):
        rel = path.relative_to(bundle)
        name = path.name.lower()
        if path.is_symlink():
            continue
        if path.is_dir():
            if name in ('site-packages', '__pycache__', 'venv', '.venv'):
                problems.append(f'{rel}/: a Python folder')
            continue
        if name.endswith(('.py', '.pyc', '.pyo')):
            problems.append(f'{rel}: a Python file')
        elif name.startswith('python'):
            problems.append(f'{rel}: a Python executable')
        else:
            data = path.read_bytes()
            for marker in MARKERS:
                if marker in data:
                    problems.append(f'{rel}: contains {marker.decode()}')
    return problems


def check_sources() -> list[str]:
    problems = []
    for folder in SOURCES:
        for path in sorted(folder.rglob('*.dart')):
            # Comments may name the Python reference a port follows; code may not.
            data = b'\n'.join(re.sub(rb'(^|\s)//.*$', b'', line) for line in path.read_bytes().splitlines())
            for marker in MARKERS:
                if marker in data:
                    problems.append(f'{path.relative_to(ROOT)}: contains {marker.decode()}')
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('bundle', nargs='?', type=Path, help='a built bundle (default: the newest preview)')
    args = parser.parse_args()
    bundle = args.bundle or newest_bundle()
    if bundle is None or not bundle.is_dir():
        parser.error('no bundle found: build one first (tools/flutter-dev build)')
    problems = check_sources() + check_bundle(bundle)
    if problems:
        print('Python found where the app must have none:', file=sys.stderr)
        for problem in problems:
            print(f'  {problem}', file=sys.stderr)
        sys.exit(1)
    print(f'Bundle check passed: no Python in {bundle.relative_to(ROOT) if bundle.is_relative_to(ROOT) else bundle} '
          f'or the app sources')


if __name__ == '__main__':
    main()
