"""Development parity: Hugging Face search and file lists (models_ctl.search/files) parsed by
Python and by the Dart core from the same API answers (a live answer saved in tests/data with
hand-made edge cases), including the URL each side asks. Skipped without a native Dart SDK."""
import json
import subprocess
import sys
import unittest
from dataclasses import asdict
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'tools'))

import models_ctl  # noqa: E402

try:
    from dart_sdk import resolve_dart
    DART = resolve_dart()
except (OSError, ValueError, RuntimeError):
    DART = None

ANSWERS = json.loads((ROOT / 'tests/data/hf_answers.json').read_text())


def python_side(request):
    urls = []
    def answer(url):
        urls.append(url)
        return request['items']
    with mock.patch.object(models_ctl, '_json_list', answer):
        try:
            found = (models_ctl.search(request['query'], limit=request['limit']) if request['kind'] == 'search'
                     else models_ctl.files(request['repo']))
        except ValueError as error:
            return {'error': 'FormatException', 'message': str(error)}
    return {'found': [asdict(f) for f in found], 'urls': urls}


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartModelHubParityTest(unittest.TestCase):
    def test_same_repos_and_files(self):
        requests = [
            {'kind': 'search', 'query': q, 'limit': limit, 'items': ANSWERS['search']}
            for q, limit in (('qwen3 coder', 25), ('', 20), ('  ünï/c0de & x=1?  ', 3), ('x' * 130, 25))
        ] + [
            {'kind': 'files', 'repo': 'unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF', 'items': ANSWERS['tree']},
            {'kind': 'files', 'repo': 'not a repo', 'items': []},
        ]
        lines = [json.dumps({'id': i, 'protocol': 2, 'method': 'dev.hfparse', 'params': r})
                 for i, r in enumerate(requests, 1)]
        out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                              'bin/fixture_probe.dart'], input=('\n'.join(lines) + '\n').encode(),
                             capture_output=True, cwd=ROOT / 'packages/maprisma_core', timeout=300, check=True)
        replies = [json.loads(line)['result'] for line in out.stdout.splitlines() if line.startswith(b'{')]
        self.assertEqual(len(replies), len(requests))
        for request, reply in zip(requests, replies):
            expected = python_side(request)
            if 'error' in expected:
                self.assertEqual(reply.get('error'), 'FormatException')
            else:
                self.assertEqual(json.loads(json.dumps(expected)), reply, request['kind'])
        self.assertGreater(len(replies[0]['found']), 5)
        self.assertGreater(len(replies[4]['found']), 5)


if __name__ == '__main__':
    unittest.main()
