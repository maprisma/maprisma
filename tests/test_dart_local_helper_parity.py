"""Development parity: the local helper (local_helper.suggest, chosen, NOT_CHAT and advise_argv) in the
Python reference and the Dart core: the largest chat model that fits the card with room for its context,
too small ones, no card, no sizes known; the confirmed one while it is there and gone; speech, embedding
and vision names; Pi's advise argv with the model and provider filled in. Skipped without a native Dart
SDK."""
import json
import os
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
import json, sys
sys.path.insert(0, sys.argv[1])
import local_helper
case = json.loads(sys.stdin.read())
C = lambda raw: [local_helper.Candidate(*c) for c in raw]
out = lambda c: None if c is None else [c.agent, c.provider, c.runtime, c.model, c.size]
argv, output = local_helper.advise_argv(local_helper.Candidate(*case['advise']))
print(json.dumps({
    'suggested': [out(local_helper.suggest(C(found), vram)) for found, vram in case['suggest']],
    'chosen': [out(local_helper.chosen(C(found), setting)) for found, setting in case['chosen']],
    'not_chat': [bool(local_helper.NOT_CHAT.search(n)) for n in case['names']],
    'advise': [argv, output]}))
'''

GB = 1024 ** 3


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartLocalHelperParityTest(unittest.TestCase):
    def test_same_helper(self):
        found = [['pi', 'llama-local', 'llamacpp', 'small', 1 * GB],
                 ['pi', 'llama-local', 'llamacpp', 'mid', 9 * GB],
                 ['pi', 'llama-local', 'llamacpp', 'big', 19 * GB],
                 ['pi', 'llama-local', 'llamacpp', 'huge', 40 * GB]]
        unsized = [['pi', 'ollama', 'ollama', 'gemma3', 0], ['pi', 'ollama', 'ollama', 'qwen3', 0]]
        case = {
            'suggest': [[found, 24 * GB], [found, 8 * GB], [found, 0], [unsized, 24 * GB],
                        [[found[0]], 24 * GB], [[], 24 * GB], [found[3:], 24 * GB]],
            'chosen': [[found, {'agent': 'pi', 'provider': 'llama-local', 'model': 'mid'}],
                       [found, {'agent': 'pi', 'provider': 'llama-local', 'model': 'gone'}],
                       [found, {}], [found, None], [found, 'mid']],
            'names': ['gemma-4-26B', 'whisper-large-v3', 'nomic-embed-text', 'bge-reranker', 'mmproj-f16',
                      'kokoro-tts', 'flux-schnell', 'Qwen3-Coder-30B', 'sd-vae', 'parakeet-asr'],
            'advise': ['pi', 'llama-local', 'llamacpp', 'gemma-4-26B', 17 * GB],
        }
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            tools = home / '.local/bin'
            tools.mkdir(parents=True)
            (tools / 'pi').write_text('#!/bin/sh\n')
            (tools / 'pi').chmod(0o755)
            env = {k: v for k, v in os.environ.items() if not k.startswith('XDG_')}
            env.update(HOME=str(home), PATH=f'{tools}:/usr/bin:/bin', LANG='C.UTF-8', ASTERISM_DESKTOP='generic')
            python = json.loads(subprocess.run([sys.executable, '-c', PYTHON, str(ROOT)], input=json.dumps(case),
                                               capture_output=True, check=True, text=True, env=env,
                                               timeout=60).stdout)
            line = json.dumps({'id': 1, 'protocol': 1, 'method': 'dev.helper', 'params': case})
            out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                  'bin/fixture_probe.dart'], input=(line + '\n').encode(), capture_output=True,
                                 cwd=ROOT / 'packages/asterism_core', timeout=300, env=env)
            dart = [json.loads(x) for x in out.stdout.splitlines() if x.startswith(b'{')]
        self.assertEqual(len(dart), 1, out.stderr.decode()[-2000:])
        self.assertIn('result', dart[0], dart[0])
        self.maxDiff = None
        self.assertEqual(python, dart[0]['result'])
        self.assertEqual(python['suggested'][0][3], 'big')               # 19 GB fits 85 % of 24 GB
        self.assertIsNone(python['suggested'][4])                         # under 2 GB: too poor
        self.assertEqual(python['suggested'][3][3], 'gemma3')             # no sizes: the first
        self.assertEqual(python['chosen'][0][3], 'mid')
        self.assertIn('--offline', python['advise'][0])
        self.assertIn('gemma-4-26B', python['advise'][0])


if __name__ == '__main__':
    unittest.main()
