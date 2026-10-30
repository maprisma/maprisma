#!/usr/bin/env python3
"""Release regression: the app's Backend is the Dart core alone; an unknown route is refused (unported_route),
and the compiled release has no Python fallback in it."""
from pathlib import Path
import os
import argparse
from dart_sdk import resolve_dart
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart')
    args = parser.parse_args()
    try:
        dart = resolve_dart(args.dart)
    except (OSError, ValueError, RuntimeError) as error:
        parser.error(str(error))
    with tempfile.TemporaryDirectory(prefix='asterism-core-release-') as temp:
        folder = Path(temp)
        source = folder / 'probe.dart'
        source.write_text("""import 'dart:io';
import 'package:asterism/backend.dart';
Future<void> main() async {
  final backend = await Backend.start();
  try {
    final settings = await backend.call('settings.get');
    if (settings['map_light_fps'] != 20) throw StateError('Wrong defaults');
    try { await backend.call('nothing.unported', {}); throw StateError('Fallback allowed'); }
    on BackendError catch(e) { if(e.code != 'unported_route') rethrow; }
    stdout.writeln('Dart-only router refuses unported routes');
  } finally { await backend.shutdown(); }
}
""")
        binary = folder / 'probe'
        subprocess.run([dart, 'compile', 'exe', '-DASTERISM_DEVEL=false',
                        f'--packages={ROOT / "flutter_app/.dart_tool/package_config.json"}',
                        str(source), '-o', str(binary)], check=True)
        data = binary.read_bytes()
        for marker in (b'/usr/bin/python3', b'flutter_backend.py', b'Asterism service was not found'):
            if marker in data:
                raise SystemExit('Python fallback marker survived AOT tree shaking')
        home = folder / 'home'
        home.mkdir()
        env = {**os.environ, 'HOME': str(home), 'XDG_CONFIG_HOME': str(home / '.config'),
               'XDG_CACHE_HOME': str(home / '.cache'), 'ASTERISM_DESKTOP': 'generic'}
        subprocess.run([str(binary)], env=env, check=True, timeout=15)
        print('AOT release transport check passed: no Python fallback code markers')


if __name__ == '__main__':
    main()
