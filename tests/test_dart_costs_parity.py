"""Development parity: the pieces of an agent's cost card (plugin_costs.cost_text, reference_texts.short_number,
plugin_costs.parse_ecb and usd_per_eur, agent_status.pays_per_token) in the Python reference and the Dart
core: dollars and euros at the edges (<0.01, thousands, rounding), the ECB's daily file and odd ones, the
kept rate fresh, stale with a fetch, stale with the fetch failing, none at all; an agent with limits, a
key in the environment, an API-key-only agent signed in, a usage record with and without a plan, a
sign-in that ran out. Skipped without a native Dart SDK."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace as NS

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
try:
    from dart_sdk import resolve_dart
    DART = resolve_dart()
except (OSError, ValueError, RuntimeError):
    DART = None

PYTHON = r'''
import json, sys
from pathlib import Path
from types import SimpleNamespace as NS
sys.path.insert(0, sys.argv[1])
import agent_status, plugin_costs, reference_texts
case = json.loads(sys.stdin.read())
rates = []
for r in case['rates']:
    def fetch(url, max_bytes=0, timeout=0, r=r):
        if r['fetch'] == 'fail':
            raise OSError('offline')
        return r['fetch'].encode()
    found = plugin_costs.usd_per_eur(fetch=None if r['fetch'] is None else fetch, path=Path(r['path']), now=r['now'])
    rates.append(list(found) if found else None)
pays = []
for c in case['pays']:
    record = c['record']
    details = NS(limits=c['limits'], plan=c['plan'], usage_note=str(record.get('usageStatusText', '')).strip(),
                 has_usage=bool(record.get('ready')) or bool(record.get('hasLocalStats')))
    pays.append(agent_status.pays_per_token(c['command'], details, environ=c['env']))
print(json.dumps({'texts': [plugin_costs.cost_text(*t) for t in case['texts']],
                  'numbers': [reference_texts.short_number(n) for n in case['numbers']],
                  'ecb': [list(x) if x else None for x in map(lambda b: plugin_costs.parse_ecb(b.encode()), case['ecb'])],
                  'rates': rates, 'pays': pays}))
'''

ECB = ("<gesmes:Envelope><Cube><Cube time='2026-10-29'><Cube currency='USD' rate='1.0842'/>"
       "<Cube currency='JPY' rate='160.1'/></Cube></Cube></gesmes:Envelope>")


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartCostsParityTest(unittest.TestCase):
    def test_same_cost_pieces(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            (home / '.dsh').mkdir()
            (home / '.dsh/.credentials.yaml').write_text('x')      # only whether it is there
            texts = [[u, c, r] for u in (0, 0.004, 0.01, 0.125, 3.4, 3.405, 99.999, 100, 123.5, 1234.5, 98765.4)
                     for c, r in (('usd', None), ('eur', 1.0842), ('eur', None))]
            numbers = [0, 999, 1000, 1050, 36835328, 1_000_000_000, 2_450_000_000]
            ecb = [ECB, ECB.replace("time='2026-10-29'", ''), ECB.replace('1.0842', '9.5'), 'nothing', '']
            rates = []
            for side in ('py', 'dart'):
                base = home / side
                base.mkdir()
                fresh = base / 'fresh/exchange-rate.json'
                fresh.parent.mkdir()
                fresh.write_text(json.dumps({'usd_per_eur': 1.07, 'day': '2026-10-28', 'fetched': 1000}))
                stale = base / 'stale/exchange-rate.json'
                stale.parent.mkdir()
                stale.write_text(json.dumps({'usd_per_eur': 1.05, 'day': '2026-10-20', 'fetched': 1000}))
                failing = base / 'failing/exchange-rate.json'
                failing.parent.mkdir()
                failing.write_text(json.dumps({'usd_per_eur': 1.05, 'day': '2026-10-20', 'fetched': 1000}))
                rates.append([{'path': str(fresh), 'fetch': ECB, 'now': 2000},
                              {'path': str(stale), 'fetch': ECB, 'now': 1000 + 90000},
                              {'path': str(stale), 'fetch': None, 'now': 1000 + 90001},       # kept since
                              {'path': str(failing), 'fetch': 'fail', 'now': 1000 + 90000},
                              {'path': str(base / 'none/exchange-rate.json'), 'fetch': None, 'now': 5},
                              {'path': str(base / 'bad/exchange-rate.json'), 'fetch': 'nothing', 'now': 5}])
            pays = [
                {'command': 'claude', 'limits': [{'percent': 0.2}], 'plan': 'Max', 'record': {}, 'env': {}},
                {'command': 'claude', 'limits': [], 'plan': '', 'record': {}, 'env': {'ANTHROPIC_API_KEY': 'x'}},
                {'command': 'claude', 'limits': [], 'plan': '', 'record': {}, 'env': {}},
                {'command': 'dsh', 'limits': [], 'plan': '', 'record': {}, 'env': {}},
                {'command': 'codex', 'limits': [], 'plan': '', 'record': {'ready': True}, 'env': {}},
                {'command': 'codex', 'limits': [], 'plan': 'Plus', 'record': {'ready': True}, 'env': {}},
                {'command': 'claude', 'limits': [], 'plan': '', 'record': {'usageStatusText': 'Sign-in expired'},
                 'env': {'ANTHROPIC_API_KEY': 'x'}},
            ]
            env = {k: v for k, v in os.environ.items() if not k.startswith('XDG_') and not k.endswith('_API_KEY')}
            env.update(HOME=str(home), LANG='C.UTF-8', MAPRISMA_DESKTOP='generic')
            common = {'texts': texts, 'numbers': numbers, 'ecb': ecb, 'pays': pays}
            python = json.loads(subprocess.run([sys.executable, '-c', PYTHON, str(ROOT)],
                                               input=json.dumps({**common, 'rates': rates[0]}), capture_output=True,
                                               check=True, text=True, env=env, timeout=120).stdout)
            line = json.dumps({'id': 1, 'protocol': 2, 'method': 'dev.costs', 'params': {**common, 'rates': rates[1]}})
            out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                  'bin/fixture_probe.dart'], input=(line + '\n').encode(), capture_output=True,
                                 cwd=ROOT / 'packages/maprisma_core', timeout=300, env=env)
            dart = [json.loads(x) for x in out.stdout.splitlines() if x.startswith(b'{')]
            self.assertEqual(len(dart), 1, out.stderr.decode()[-2000:])
            self.assertIn('result', dart[0], dart[0])
            kept = [json.loads((home / side / 'stale/exchange-rate.json').read_text()) for side in ('py', 'dart')]
        self.maxDiff = None
        self.assertEqual(python, dart[0]['result'])
        self.assertEqual(kept[0], kept[1])                               # the fetched rate kept the same way
        self.assertIn('<0.01 €', python['texts'])
        self.assertIn('$1,234', python['texts'])
        self.assertEqual(python['rates'][0], [1.07, '2026-10-28'])       # fresh: kept, not fetched
        self.assertEqual(python['rates'][1], [1.0842, '2026-10-29'])
        self.assertEqual(python['rates'][3], [1.05, '2026-10-20'])       # offline: the last one
        self.assertEqual(python['pays'], [False, True, False, True, True, False, False])


if __name__ == '__main__':
    unittest.main()
