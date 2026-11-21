#!/usr/bin/env python3
"""Build independently replaceable first-party feature backends, never sign them."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

from dart_sdk import resolve_dart

FEATURES = ('reports', 'ask-ai', 'ai-project-center')


def build_features(core: Path, destination: Path, features=FEATURES):
    for feature in features:
        target = destination / feature
        target.mkdir(parents=True, exist_ok=True)
        executable = target / 'plugin'
        subprocess.run([
            resolve_dart(), 'compile', 'exe', f'-DMAPRISMA_FEATURE_ID={feature}',
            'bin/maprisma-feature.dart', '-o', str(executable),
        ], cwd=core, check=True)
        metadata = {'id': feature, 'api': 1,
                    'sha256': hashlib.sha256(executable.read_bytes()).hexdigest()}
        (target / 'feature.json').write_text(json.dumps(metadata, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--feature', choices=FEATURES, action='append')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    build_features(root / 'packages/maprisma_core', args.output.resolve(),
                   args.feature or FEATURES)


if __name__ == '__main__':
    main()
