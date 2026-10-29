"""Development parity: tips from an agent on a local LLM's performance (llm_tuning.facts_text, prompt and
validate) in the Python reference and the Dart core: the facts an agent sees, and which of its
suggestions the app stands behind (settings with allowed values per model or for every model, contexts
that fit, builds it knows, notes; odd and hostile answers dropped). Skipped without a native Dart SDK."""
import json
import os
import subprocess
import sys
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
LLAMA = {'runtime': 'llama.cpp', 'key': 'llamacpp', 'gpu': 'AMD Radeon RX 7900 XTX', 'vram': 24 * GIB,
         'stacks': ['ROCm', 'Vulkan'], 'build': 'vulkan', 'builds': ['rocm', 'vulkan', 'cuda', 'cpu'],
         'devices': 'Vulkan0: AMD Radeon\nVulkan1: llvmpipe',
         'settings': {'*': {'flash-attn': 'on', 'gpu-layers': 'all'}, 'big': {'cache-type-k': 'q8_0'}, 'empty': {}},
         'tuning': {'flash-attn': ['on|off|auto', 'flash attention'], 'cache-type-k': ['f16|q8_0|q4_0', 'key cache'],
                    'threads': [r'[1-9]|[1-9]\d|1\d\d|2[0-5]\d', 'CPU threads']},
         'per_model': True,
         'models': [{'name': 'big', 'size': 16_810_714_336, 'context': 98304, 'best': 94208, 'trained': 262144,
                     'per_token': 74880},
                    {'name': 'small', 'size': 0, 'context': 0, 'best': 0, 'trained': 0, 'per_token': 0}],
         'loaded': ['big'], 'vram_used': 18 * GIB}
OLLAMA = {**LLAMA, 'runtime': 'Ollama', 'key': 'ollama', 'stacks': [], 'build': '', 'builds': [], 'devices': '',
          'settings': {'*': {'OLLAMA_FLASH_ATTENTION': '1'}}, 'per_model': False, 'loaded': [],
          'tuning': {'OLLAMA_FLASH_ATTENTION': ['0|1', 'flash attention'],
                     'OLLAMA_NUM_PARALLEL': ['[1-8]', 'requests at once']}}


def s(kind, title='T', **kw):
    return {'kind': kind, 'title': title, **kw}


ANSWERS = [
    {'summary': '  Two   things\nto do. ', 'suggestions': [
        s('setting', key='flash-attn', value='auto', why='  faster\n\tand smaller  '),
        s('setting', key='flash-attn', value='on'),                       # set already
        s('setting', key='flash-attn', value='on', model='big'),          # per model: not set there
        s('setting', key='cache-type-k', value='q8_0', model='big'),     # set already there
        s('setting', key='threads', value='300'), s('setting', key='threads', value='16'),
        s('setting', key='nope', value='1'), s('setting', key='flash-attn', value='on\n'),
        s('context', value='65536', model='big'), s('context', value='99999', model='big'),
        s('context', value='512', model='big'), s('context', value='4k', model='big'),
        s('context', value='8192', model='small'), s('context', value='8192'),
        s('build', value='rocm', model='big', key='x'), s('build', value='vulkan'), s('build', value='metal'),
        s('note', value='x', key='y', model='big', title='A note'), s('note', title=''), s('note', title='   '),
        s('setting', key='flash-attn', value='off', model='ghost'), s('wrong'), 'junk', None,
        s('note', title='T' * 300, why=5), s('note', title=True, model=0), s('note', title=['a']),
        s('note', title='overflow')]},
    {'summary': None, 'suggestions': {'kind': 'note'}},
    {'suggestions': 'text'},
    'not an object',
    {'summary': 5, 'suggestions': None},
    {'summary': ['x'], 'suggestions': [
        s('note', title=["it's", 'a"b', None, 1.5, {'k': True}, 'tab\there'], why={'x': [1, 'y']})]},
]


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartTuningTipsParityTest(unittest.TestCase):
    def test_same_facts_text_prompt_and_checked_tips(self):
        cases = [(facts, answer) for facts in (LLAMA, OLLAMA) for answer in ANSWERS]
        cases.append((OLLAMA, {'suggestions': [s('setting', key='OLLAMA_NUM_PARALLEL', value='2'),
                                               s('setting', key='OLLAMA_NUM_PARALLEL', value='2', model='big'),
                                               s('setting', key='OLLAMA_FLASH_ATTENTION', value='1')]}))
        python_code = r'''
import dataclasses, json, sys
sys.path.insert(0, sys.argv[1])
import llm_tuning
out = []
for facts, answer in json.loads(sys.stdin.read()):
    f = dict(facts)
    f['models'] = [llm_tuning.ModelFacts(**m) for m in f['models']]
    f['tuning'] = {k: tuple(v) for k, v in f['tuning'].items()}
    facts = llm_tuning.Facts(**f)
    try:
        summary, found = llm_tuning.validate(answer, facts)
        validated = [summary, [dataclasses.asdict(x) for x in found]]
    except ValueError as error:
        validated = {'error': str(error)}
    out.append({'text': llm_tuning.facts_text(facts), 'prompt': llm_tuning.prompt(facts), 'validated': validated})
print(json.dumps(out))
'''
        env = {**os.environ, 'LANG': 'C.UTF-8'}
        python = json.loads(subprocess.run([sys.executable, '-c', python_code, str(ROOT)], input=json.dumps(cases),
                                           capture_output=True, check=True, text=True, env=env, timeout=120).stdout)
        lines = [json.dumps({'id': i, 'protocol': 1, 'method': 'dev.tuningtips',
                             'params': {'facts': f, 'answer': a}}) for i, (f, a) in enumerate(cases, 1)]
        out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                              'bin/fixture_probe.dart'], input=('\n'.join(lines) + '\n').encode(),
                             capture_output=True, cwd=ROOT / 'packages/asterism_core', timeout=300, env=env)
        dart = [json.loads(line)['result'] for line in out.stdout.splitlines() if line.startswith(b'{')]
        self.maxDiff = None
        self.assertEqual(len(dart), len(cases), out.stderr.decode()[-2000:])
        self.assertEqual(python, dart)
        summary, found = python[0]['validated']
        self.assertEqual(summary, 'Two things to do.')
        self.assertEqual(len(found), 8)
        self.assertEqual([(f['kind'], f['model'], f['key'], f['value']) for f in found][:5], [
            ('setting', '*', 'flash-attn', 'auto'), ('setting', 'big', 'flash-attn', 'on'),
            ('setting', '*', 'threads', '16'), ('context', 'big', 'ctx-size', '65536'),
            ('build', '*', '', 'rocm')])
        self.assertEqual(python[5]['validated'][1][0]['title'], "[\"it's\", 'a\"b', None, 1.5, {'k': True}, 'tab\\there']")
        self.assertIn('Its devices: Vulkan0: AMD Radeon; Vulkan1: llvmpipe', python[0]['text'])
        self.assertEqual(python[3]['validated'], {'error': 'the answer is not JSON'})
        self.assertEqual([(f['model'], f['value']) for f in python[-1]['validated'][1]], [('*', '2')])


if __name__ == '__main__':
    unittest.main()
