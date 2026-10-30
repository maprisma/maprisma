"""Development parity: a local LLM's performance facts and tuning changes (llm_tuning.collect and the
engines' tuning_now / tuning_changes) in the Python reference and the Dart core: llama.cpp with
models.ini sections, GGUF headers (a model that fits, one without a KV cache, a broken one, one whose
file differs in case, a missing one) and its devices; Ollama with and without the app's env file.
Skipped without a native Dart SDK."""
import json
import os
import struct
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

GIB = 1024 ** 3


def _str(text):
    data = text.encode()
    return struct.pack('<Q', len(data)) + data


def _u32(key, value):
    return _str(key) + struct.pack('<I', 4) + struct.pack('<I', value)


def gguf(*pairs):
    return b'GGUF' + struct.pack('<IQQ', 3, 0, len(pairs)) + b''.join(pairs)


LLAMA = gguf(_str('general.architecture') + struct.pack('<I', 8) + _str('llama'),
             _u32('llama.context_length', 32768), _u32('llama.block_count', 32),
             _u32('llama.attention.head_count', 32), _u32('llama.attention.head_count_kv', 8),
             _u32('llama.embedding_length', 4096))
NO_KV = gguf(_str('general.architecture') + struct.pack('<I', 8) + _str('whisper'))

PYTHON = r'''
import dataclasses, json, sys
sys.path.insert(0, sys.argv[1])
import install_ctl, inventory, llm_engine, llm_tuning
out = []
for case in json.loads(sys.stdin.read()):
    r = case['rt']
    rt = inventory.Runtime(r['key'], r['name'], installed=True, models_dir=r['models_dir'], models=r['models'])
    engine = llm_engine.of(rt.key)
    g = case['gpu']
    facts = dataclasses.asdict(llm_tuning.collect(rt, engine, install_ctl.Gpu(g['vendor'], g['name'], vram=g['vram'])))
    changes = []
    for section, key, value in case['changes']:
        try:
            changes.append([[str(c.path), c.new] for c in engine.tuning_changes(rt, section, key, value)])
        except ValueError:
            changes.append('refused')
    out.append({'facts': facts, 'changes': changes})
print(json.dumps(out))
'''


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartLlmTuningParityTest(unittest.TestCase):
    def test_same_facts_and_changes(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            models = home / 'models'
            models.mkdir()
            with open(models / 'Big.gguf', 'wb') as f:
                f.write(LLAMA)
                f.truncate(4 * GIB)               # sparse: the size counts, not the disk
            (models / 'small.gguf').write_bytes(LLAMA)
            (models / 'speech.gguf').write_bytes(NO_KV)
            (models / 'broken.gguf').write_bytes(b'GGUF not really')
            ini = home / '.config/llama.cpp/models.ini'
            ini.parent.mkdir(parents=True)
            ini.write_text('[*]\nflash-attn = on\nctx-size = 8192\n\n[big]\nctx-size = 65536\n'
                           'cache-type-k = q8_0\nunknown = 1\n')
            env_dir = home / '.config/ollama'
            env_dir.mkdir(parents=True)
            tools = home / 'bin'
            tools.mkdir()
            (tools / 'llama-server').write_text('#!/bin/sh\necho "available devices:"\n'
                                                'echo "  Vulkan0: AMD Radeon RX (16384 MiB, 15000 MiB free)"\n'
                                                'echo "  Vulkan1: llvmpipe"\n')
            (tools / 'llama-server').chmod(0o755)
            gpu = {'vendor': 'amd', 'name': 'AMD · card1', 'vram': 16 * GIB}
            llama = {'rt': {'key': 'llamacpp', 'name': 'llama.cpp', 'models_dir': '~/models',
                            'models': ['big', 'small', 'speech', 'broken', 'missing']}, 'gpu': gpu,
                     'changes': [['*', 'flash-attn', 'off'], ['big', 'parallel', '4'], ['new', 'gpu-layers', 'all'],
                                 ['*', 'flash-attn', 'maybe'], ['*', 'nope', '1'], ['*', 'threads', '300']]}
            ollama = {'rt': {'key': 'ollama', 'name': 'Ollama', 'models_dir': '~/.ollama/models',
                             'models': ['llama3:8b']}, 'gpu': {**gpu, 'vram': 0},
                      'changes': [['*', 'OLLAMA_NUM_PARALLEL', '2'], ['big', 'OLLAMA_NUM_PARALLEL', '2'],
                                  ['*', 'OLLAMA_FLASH_ATTENTION', '1'], ['*', 'OLLAMA_KV_CACHE_TYPE', 'q2']]}
            env = {k: v for k, v in os.environ.items() if not k.startswith('XDG_')}
            env.update(HOME=str(home), PATH=f'{tools}:/usr/bin:/bin', LANG='C.UTF-8')

            def run_both(cases):
                python = json.loads(subprocess.run([sys.executable, '-c', PYTHON, str(ROOT)],
                                                   input=json.dumps(cases), capture_output=True, check=True,
                                                   text=True, env=env, timeout=120).stdout)
                lines = [json.dumps({'id': i, 'protocol': 1, 'method': 'dev.llmtuning', 'params': c})
                         for i, c in enumerate(cases, 1)]
                out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                      'bin/fixture_probe.dart'], input=('\n'.join(lines) + '\n').encode(),
                                     capture_output=True, cwd=ROOT / 'packages/maprisma_core', timeout=300, env=env)
                dart = [json.loads(line)['result'] for line in out.stdout.splitlines() if line.startswith(b'{')]
                self.assertEqual(len(dart), len(cases), out.stderr.decode()[-2000:])
                return python, dart

            # Ollama without the app's env file first: nothing to tune, nothing to change.
            python, dart = run_both([llama, ollama])
            (env_dir / 'server.env').write_text('OLLAMA_FLASH_ATTENTION=1\nOLLAMA_CONTEXT_LENGTH=8192\n'
                                                'OLLAMA_KV_CACHE_TYPE="q8_0"\n')
            python2, dart2 = run_both([ollama])
        self.maxDiff = None
        self.assertEqual(python, dart)
        self.assertEqual(python2, dart2)
        facts = python[0]['facts']
        self.assertEqual(facts['build'], 'vulkan')
        self.assertIn('Vulkan', facts['stacks'])
        self.assertEqual([m['name'] for m in facts['models']], ['big', 'small', 'broken', 'missing'])
        big = facts['models'][0]
        self.assertEqual(big['size'], 4 * GIB)
        self.assertEqual(big['context'], 65536)
        self.assertEqual(big['best'], 0)                 # its file differs in case: no header read
        self.assertGreater(facts['models'][1]['best'], 0)
        self.assertEqual(facts['settings']['big'], {'cache-type-k': 'q8_0'})   # ctx-size is the context, not a tuning key
        self.assertEqual(python[0]['changes'][3:], ['refused'] * 3)
        self.assertEqual(python[1]['facts']['settings'], {})
        self.assertEqual(python[1]['changes'], ['refused'] * 4)
        ollama_facts = python2[0]
        self.assertEqual(ollama_facts['facts']['settings'], {'*': {'OLLAMA_FLASH_ATTENTION': '1',
                                                                   'OLLAMA_KV_CACHE_TYPE': 'q8_0'}})
        self.assertEqual(ollama_facts['changes'][1:], ['refused', [], 'refused'])


if __name__ == '__main__':
    unittest.main()
