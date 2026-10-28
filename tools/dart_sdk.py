#!/usr/bin/env python3
"""Locate native SDK Dart without executing PATH wrappers (which may mount FUSE)."""
from pathlib import Path
import os
import shutil


def native_dart(path):
    binary = Path(path).resolve(strict=True)
    with binary.open('rb') as handle:
        magic = handle.read(4)
    if magic != b'\x7fELF' or not os.access(binary, os.X_OK):
        raise ValueError(f'Dart must be a native SDK executable, not a wrapper: {path}')
    return str(binary)


def resolve_dart(explicit=None):
    if explicit:
        return native_dart(explicit)
    candidates = []
    root = os.environ.get('FLUTTER_ROOT')
    if root:
        candidates.append(Path(root) / 'bin/cache/dart-sdk/bin/dart')
    for name in ('flutter', 'dart'):
        located = shutil.which(name)
        if located:
            resolved = Path(located).resolve()
            candidates.extend(parent / 'bin/cache/dart-sdk/bin/dart'
                              for parent in resolved.parents)
            if name == 'dart':
                candidates.append(resolved)
    for candidate in candidates:
        try:
            return native_dart(candidate)
        except (OSError, ValueError, RuntimeError):
            continue
    raise ValueError('Native Dart SDK not found; set FLUTTER_ROOT or pass --dart /path/to/dart-sdk/bin/dart')


if __name__ == '__main__':
    try:
        print(resolve_dart())
    except (OSError, ValueError, RuntimeError) as error:
        raise SystemExit(str(error)) from error
