#!/usr/bin/env python3
"""Release gate (phase 7): the shipped Maprisma has no Python in it.

Checks a built Linux bundle (default: the newest development preview) and the app's Dart sources:
- no .py/.pyc file, no python executable and no Python environment folder in the bundle;
- no marker of a Python service in its binaries: the interpreter path it would start, the old
  service script, the old transport class;
- none of these in the code of the app's and the core's Dart sources (lib/, bin/; comments naming
  the Python reference a port follows are allowed), outside tests and tools.

Task 073: every ELF file of the bundle needs at most glibc GLIBC_BASELINE (the oldest system the release
supports); `--glibc` prints the highest version the bundle needs (tools/build-release.py writes it into the
archive for install.sh).

Names like "python3" in the core's data (programs it recognises, folders it looks into) are not a
service and are allowed. Exit 1 with every finding listed.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MARKERS = (b'/usr/bin/python3', b'flutter_backend', b'PythonTransport', b'MAPRISMA_SOURCE')
GLIBC_BASELINE = '2.34'
SOURCES = (ROOT / 'flutter_app/lib', ROOT / 'packages/maprisma_core/lib', ROOT / 'packages/maprisma_core/bin')


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


def _version(text: str) -> tuple[int, ...]:
    return tuple(int(part) for part in text.split('.'))


def glibc_needs(bundle: Path) -> dict[str, str]:
    """The highest GLIBC_ symbol version each ELF file of the bundle needs (objdump -T)."""
    needs = {}
    for path in sorted(bundle.rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as f:
            if f.read(4) != b'\x7fELF':
                continue
        out = subprocess.run(['objdump', '-T', str(path)], capture_output=True, text=True).stdout
        found = sorted(set(re.findall(r'\bGLIBC_([0-9]+(?:\.[0-9]+)+)\b', out)), key=_version)
        if found:
            needs[str(path.relative_to(bundle))] = found[-1]
    return needs


def check_glibc(bundle: Path, baseline: str = GLIBC_BASELINE) -> list[str]:
    return [f'{rel}: needs glibc {need}, more than {baseline}'
            for rel, need in glibc_needs(bundle).items() if _version(need) > _version(baseline)]


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
    parser.add_argument('--glibc', action='store_true', help='print the highest glibc version the bundle needs')
    args = parser.parse_args()
    bundle = args.bundle or newest_bundle()
    if bundle is None or not bundle.is_dir():
        parser.error('no bundle found: build one first (tools/flutter-dev build)')
    if args.glibc:
        needs = glibc_needs(bundle).values()
        print(max(needs, key=_version) if needs else '0')
        return
    glibc = check_glibc(bundle)
    if glibc:
        print(f'The bundle needs a newer glibc than {GLIBC_BASELINE}, the oldest supported:', file=sys.stderr)
        for problem in glibc:
            print(f'  {problem}', file=sys.stderr)
        sys.exit(1)
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
