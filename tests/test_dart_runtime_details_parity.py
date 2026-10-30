"""Development parity: a local LLM's details (agent_status.runtime_usage, agent_security.runtime_report and
agent_details.gpu_battery) in the Python reference and the Dart core: sessions of two agents whose models
match the LLM's by name (tags, file endings, a provider prefix of this LLM and of another), the last 7
days, an LLM with no models; listening on loopback, on the network, without an address, not installed;
the GPU memory free and held. Skipped without a native Dart SDK."""
import datetime as dt
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

PYTHON = r'''
import datetime as dt, json, sys
from types import SimpleNamespace as NS
sys.path.insert(0, sys.argv[1])
import agent_details, agent_security, agent_status, claude_sessions
case = json.loads(sys.stdin.read())
today = dt.date.fromisoformat(case['today'])
sessions = {name: [claude_sessions.Session(**d) for d in items] for name, items in case['sessions'].items()}
usage = agent_status.runtime_usage(case['models'], sessions, case['connect_key'], today)
out = {'usage': None if usage is None else {
    'days': [[d.isoformat(), n] for d, n in usage.days], 'by_model': usage.by_model,
    'sessions_total': usage.sessions_total, 'sessions_week': usage.sessions_week,
    'sessions_today': usage.sessions_today}}
out['risks'] = []
for installed, address in case['risks']:
    report = agent_security.runtime_report(NS(key='x', installed=installed, address=address))
    out['risks'].append([{'level': r.level, 'title': r.title, 'text': r.why, 'step': r.lower} for r in report.risks])
out['gpu'] = []
for free, total, own in case['gpu']:
    b = agent_details.gpu_battery(free, total, own)
    out['gpu'].append(None if b is None else {'kind': 'battery', 'left': b[0], 'colour': b[1], 'tip': b[2]})
print(json.dumps(out))
'''

GIB = 1024 ** 3


def session(last, tokens):
    return {'cwd': '/w', 'first': last, 'last': last, 'active': 0.0, 'replies': 1, 'tokens': tokens,
            'hours': {}, 'lines_added': 0, 'lines_removed': 0, 'cost': 0.0, 'api_ms': 0}


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartRuntimeDetailsParityTest(unittest.TestCase):
    def test_same_runtime_details(self):
        today = dt.date(2026, 10, 30)
        noon = dt.datetime(2026, 10, 30, 12).timestamp()
        sessions = {
            'Pi': [session(noon, {'llama-local/Qwen3-8B-Q4_K_M.gguf': [100, 20, 5, 7]}),
                   session(noon - 3 * 86400, {'qwen3-8b-q4_k_m': [1, 2, 3, 4], 'claude-opus-5-5': [9, 9, 9, 9]}),
                   session(noon - 20 * 86400, {'gemma3:latest': [50, 0, 0, 0]})],
            'Hermes': [session(noon - 86400, {'ollama/gemma3:12b': [10, 10, 10, 10]}),
                       session(noon, {'other-llm/qwen3-8b-q4_k_m': [7, 7, 7, 7]})],
        }
        case = {'today': today.isoformat(), 'sessions': sessions,
                'models': ['Qwen3-8B-Q4_K_M.gguf', 'gemma3:latest'], 'connect_key': 'llama-local',
                'risks': [[True, '127.0.0.1:8080'], [True, '0.0.0.0:11434'], [True, ''], [False, '127.0.0.1:1']],
                'gpu': [[20 * GIB, 24 * GIB, 0], [2 * GIB, 24 * GIB, 13 * GIB], [0, 0, 0], [-5, 24 * GIB, 0]]}
        env = {k: v for k, v in os.environ.items() if not k.startswith('XDG_')}
        env.update(LANG='C.UTF-8', TZ='Europe/Berlin', ASTERISM_DESKTOP='generic')
        python = json.loads(subprocess.run([sys.executable, '-c', PYTHON, str(ROOT)], input=json.dumps(case),
                                           capture_output=True, check=True, text=True, env=env, timeout=60)
                            .stdout)
        line = json.dumps({'id': 1, 'protocol': 1, 'method': 'dev.runtime', 'params': case})
        out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                              'bin/fixture_probe.dart'], input=(line + '\n').encode(), capture_output=True,
                             cwd=ROOT / 'packages/asterism_core', timeout=300, env=env)
        dart = [json.loads(x) for x in out.stdout.splitlines() if x.startswith(b'{')]
        self.assertEqual(len(dart), 1, out.stderr.decode()[-2000:])
        self.assertIn('result', dart[0], dart[0])
        self.maxDiff = None
        self.assertEqual(python, dart[0]['result'])
        usage = python['usage']
        self.assertEqual(usage['sessions_total'], 3)                   # other LLMs' prefixes left out
        self.assertEqual(usage['sessions_today'], 1)
        self.assertEqual(usage['days'][-1], ['2026-10-30', 127])
        self.assertEqual(python['risks'][1][0]['level'], 'high')
        self.assertEqual(python['gpu'][1]['colour'], 'red')


if __name__ == '__main__':
    unittest.main()
