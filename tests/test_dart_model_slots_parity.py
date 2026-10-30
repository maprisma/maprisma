"""Development parity: how many models a local LLM keeps loaded for its agents (model_slots:
models_in_use, plan, hints, and the engines' slots / slots_fixed_by / slot_changes) in the Python
reference and the Dart core: llama.cpp with the app's own service (an older --models-max on its command
line) and with the user's own start script, Ollama with and without the app's env file, LM Studio's
one-or-many setting, models too big together for the card. Skipped without a native Dart SDK."""
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

GIB = 1024 ** 3

PYTHON = r'''
import json, sys
from types import SimpleNamespace as NS
sys.path.insert(0, sys.argv[1])
import inventory, llm_engine, model_slots
case = json.loads(sys.stdin.read())
graph = None if case['graph'] is None else NS(nodes=[NS(**n) for n in case['graph']['nodes']],
                                               edges=[NS(**e) for e in case['graph']['edges']])
rts = [inventory.Runtime(r['key'], r['name'], installed=True, running=r['running'], service=r['service'],
                         models_dir=r['models_dir'], models=r['models']) for r in case['runtimes']]
in_use = model_slots.models_in_use(graph)
out = {'in_use': in_use, 'needs': []}
for need in model_slots.plan(rts, in_use):
    rt = next(r for r in rts if r.key == need.key)
    changes = llm_engine.of(rt).slot_changes(rt, need.count)
    out['needs'].append({'key': need.key, 'name': need.name, 'models': need.models, 'kind': need.kind,
                         'slots': need.slots, 'fixed_by': need.fixed_by, 'sizes': need.sizes,
                         'change': need.change, 'swaps': need.swaps,
                         'hints': model_slots.hints(need, case['vram']),
                         'changes': [[str(c.path), c.new] for c in changes]})
print(json.dumps(out))
'''


def node(ident, kind, label):
    return {'id': ident, 'kind': kind, 'label': label, 'column': 1}


def edge(source, target, kind):
    return {'source': source, 'target': target, 'kind': kind}


GRAPH = {
    'nodes': [node('agent:pi', 'agent', 'Pi'), node('agent:dsh', 'agent', 'DeepSeek Harness'),
              node('agent:claude', 'agent', 'Claude Code'), node('agent:hermes', 'agent', 'Hermes'),
              node('runtime:llamacpp', 'runtime', 'llama.cpp'), node('runtime:ollama', 'runtime', 'Ollama'),
              node('runtime:lmstudio', 'runtime', 'LM Studio'),
              node('model:l:big', 'model', 'big'), node('model:l:small', 'model', 'small'),
              node('model:o:gemma', 'model', 'gemma'), node('model:o:qwen', 'model', 'qwen'),
              node('model:s:one', 'model', 'one'), node('model:s:two', 'model', 'two')],
    'edges': [edge('runtime:llamacpp', 'model:l:big', 'serves'), edge('runtime:llamacpp', 'model:l:small', 'serves'),
              edge('runtime:ollama', 'model:o:gemma', 'serves'), edge('runtime:ollama', 'model:o:qwen', 'serves'),
              edge('runtime:lmstudio', 'model:s:one', 'serves'), edge('runtime:lmstudio', 'model:s:two', 'serves'),
              edge('agent:pi', 'runtime:llamacpp', 'uses'), edge('agent:pi', 'model:l:big', 'default'),
              edge('agent:dsh', 'runtime:llamacpp', 'uses'), edge('agent:dsh', 'model:l:small', 'default'),
              edge('agent:claude', 'runtime:llamacpp', 'available'), edge('agent:claude', 'model:l:small', 'default'),
              edge('agent:pi', 'runtime:ollama', 'uses'), edge('agent:pi', 'model:o:gemma', 'default'),
              edge('agent:hermes', 'runtime:ollama', 'uses'), edge('agent:hermes', 'model:o:qwen', 'default'),
              edge('agent:hermes', 'runtime:lmstudio', 'uses'), edge('agent:hermes', 'model:s:one', 'default'),
              edge('agent:claude', 'runtime:lmstudio', 'uses'), edge('agent:claude', 'model:s:two', 'default'),
              edge('agent:pi', 'model:x', 'default')]}


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartModelSlotsParityTest(unittest.TestCase):
    def _home(self, home: Path, own_script: bool):
        models = home / 'models'
        models.mkdir()
        with open(models / 'big.gguf', 'wb') as f:
            f.truncate(14 * GIB)
        with open(models / 'small.gguf', 'wb') as f:
            f.truncate(9 * GIB)
        units = home / '.config/systemd/user'
        units.mkdir(parents=True)
        if own_script:
            script = home / '.local/bin/my-llama'
            script.parent.mkdir(parents=True)
            script.write_text('#!/bin/sh\nexec llama-server --models-max 1 "$@"\n')
            script.chmod(0o755)
            (units / 'llama-server.service').write_text(f'[Service]\nExecStart={script} --port 8080\n')
        else:
            (units / 'llama-server.service').write_text(
                '# installed by Maprisma\n[Service]\nExecStart=%h/.local/bin/llama-server --port 8080 --models-max 2\n')
        (home / '.config/llama.cpp').mkdir(parents=True)
        (home / '.config/llama.cpp/server.env').write_text('LLAMA_ARG_HOST=127.0.0.1\n')
        if not own_script:
            (home / '.config/ollama').mkdir(parents=True)
            (home / '.config/ollama/server.env').write_text('OLLAMA_MAX_LOADED_MODELS=1\n')
        (home / '.lmstudio/.internal').mkdir(parents=True)
        (home / '.lmstudio/settings.json').write_text(json.dumps({'developer': {'other': 1}, 'theme': 'ü'}))
        with open(home / 'one.gguf', 'wb') as f:
            f.truncate(3 * GIB)
        (home / '.lmstudio/.internal/model-index-cache.json').write_text(json.dumps({'models': [
            {'defaultIdentifier': 'one', 'entryPoint': {'absPath': str(home / 'one.gguf')}}]}))

    def test_same_slots(self):
        for own_script in (False, True):
            with self.subTest(own_script=own_script), tempfile.TemporaryDirectory() as temp:
                home = Path(temp)
                self._home(home, own_script)
                runtimes = [{'key': 'llamacpp', 'name': 'llama.cpp', 'running': False, 'service': 'llama-server',
                             'models_dir': str(home / 'models'), 'models': ['big', 'small']},
                            {'key': 'ollama', 'name': 'Ollama', 'running': False, 'service': 'ollama',
                             'models_dir': '', 'models': ['gemma', 'qwen']},
                            {'key': 'lmstudio', 'name': 'LM Studio', 'running': False, 'service': '',
                             'models_dir': '', 'models': ['one', 'two']}]
                case = {'graph': GRAPH, 'runtimes': runtimes, 'vram': 16 * GIB}
                env = {k: v for k, v in os.environ.items() if not k.startswith('XDG_')}
                env.update(HOME=str(home), LANG='C.UTF-8', ASTERISM_DESKTOP='generic')
                python = json.loads(subprocess.run([sys.executable, '-c', PYTHON, str(ROOT)], input=json.dumps(case),
                                                   capture_output=True, check=True, text=True, env=env,
                                                   timeout=120).stdout)
                line = json.dumps({'id': 1, 'protocol': 1, 'method': 'dev.modelslots', 'params': case})
                out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                      'bin/fixture_probe.dart'], input=(line + '\n').encode(), capture_output=True,
                                     cwd=ROOT / 'packages/asterism_core', timeout=300, env=env)
                dart = [json.loads(x)['result'] for x in out.stdout.splitlines() if x.startswith(b'{')]
                self.assertEqual(len(dart), 1, out.stderr.decode()[-2000:])
                self.maxDiff = None
                self.assertEqual(python, dart[0])
                needs = {n['key']: n for n in python['needs']}
                self.assertEqual(python['in_use']['runtime:llamacpp'], {'big': ['Pi'], 'small': ['DeepSeek Harness']})
                if own_script:
                    self.assertEqual(needs['llamacpp']['fixed_by'], '~/.local/bin/my-llama')
                    self.assertEqual(needs['llamacpp']['slots'], 1)
                    self.assertTrue(needs['llamacpp']['swaps'])
                    self.assertEqual(needs['llamacpp']['changes'], [])
                    self.assertEqual(len(needs['llamacpp']['hints']), 2)        # swaps, and too big together
                    self.assertEqual(needs['ollama']['fixed_by'], 'OLLAMA_MAX_LOADED_MODELS')
                else:
                    self.assertEqual(needs['llamacpp']['slots'], 2)
                    self.assertFalse(needs['llamacpp']['change'])               # 2 in use, 2 kept
                    self.assertEqual(len(needs['llamacpp']['changes']), 2)      # env file, and the old flag out of the unit
                    self.assertTrue(needs['ollama']['change'])
                    self.assertIn('OLLAMA_MAX_LOADED_MODELS=2', needs['ollama']['changes'][0][1])
                self.assertTrue(needs['lmstudio']['change'])
                self.assertIn('"unloadPreviousJITModelOnLoad": false', needs['lmstudio']['changes'][0][1])


if __name__ == '__main__':
    unittest.main()
