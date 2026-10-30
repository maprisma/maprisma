"""Development parity: the badge in an agent's map box (agent_details.battery and battery_tip, and the cost
label of ai_popup.update_costs with plugin_costs.cost_colour) in the Python reference and the Dart core:
limits past their reset left out, exactly a tenth left being red, a tie in the percentage, the reset
time in the local clock; a cost in dollars and in euros, at and above the levels, with the red one's
notification text. Skipped without a native Dart SDK."""
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
sys.path.insert(0, sys.argv[1])
import agent_details, plugin_costs
from i18n import _
case = json.loads(sys.stdin.read())
now = dt.datetime.fromisoformat(case['now'])
out = {'batteries': [], 'costs': []}
for c in case['batteries']:
    limits = [agent_details.Limit(label=l.get('label', ''), percent=l['percent'],
                                  resets_at=dt.datetime.fromisoformat(l['resets_at']) if l.get('resets_at') else None)
              for l in c['limits']]
    b = agent_details.battery(limits, now, tuple(c['levels']))
    out['batteries'].append([list(b) if b else None, agent_details.battery_tip(limits, now)])
for usd, limit, currency, rate, (yellow, red) in case['costs']:
    text = plugin_costs.cost_text(usd, currency, rate)
    limit_text = plugin_costs.cost_text(limit * (rate or 1) if currency == "eur" and rate else limit, currency, rate)
    colour = plugin_costs.cost_colour(usd, limit, currency, rate, yellow, red)
    badge = {'kind': 'cost', 'label': _("{0} today").format(text),
             'tip': _("Paid per token, with no plan limits: about {0} today at API prices "
                      "(estimated from the tokens of its sessions active today).").format(text) + "\n"
                    + _("A day's limit: {0} (Settings › Costs).").format(limit_text),
             'colour': colour}
    if colour == 'red':
        badge['red_body'] = _("About {0} today, {1} % of the day's limit ({2}).").format(
            text, round(100 * plugin_costs.in_currency(usd, currency, rate)[0] / limit), limit_text)
    out['costs'].append(badge)
print(json.dumps(out))
'''


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartBadgesParityTest(unittest.TestCase):
    def test_same_badges(self):
        now = '2026-10-30T09:00:00+00:00'
        levels = [0.75, 0.9]
        batteries = [
            {'limits': [], 'levels': levels},
            {'limits': [{'label': '5 h', 'percent': 0.4, 'resets_at': '2026-10-30T12:30:00+00:00'},
                        {'label': 'Week', 'percent': 0.8, 'resets_at': '2026-11-02T15:00:00+00:00'}],
             'levels': levels},
            {'limits': [{'label': '', 'percent': 0.9}], 'levels': levels},                    # a tenth left: red
            {'limits': [{'label': 'Old', 'percent': 1.0, 'resets_at': '2026-10-29T09:00:00+00:00'}],
             'levels': levels},                                                               # past its reset
            {'limits': [{'label': 'Tie', 'percent': 0.125}, {'label': 'Over', 'percent': 1.7}], 'levels': [0.5, 0.6]},
        ]
        costs = [[1.5, 100, 'usd', None, levels], [80, 100, 'usd', None, levels], [95, 100, 'usd', None, levels],
                 [130, 100, 'eur', 1.08, levels], [0.004, 10, 'eur', None, levels], [9.25, 10, 'usd', None, [0.5, 0.925]]]
        case = {'now': now, 'batteries': batteries, 'costs': costs}
        env = {k: v for k, v in os.environ.items() if not k.startswith('XDG_')}
        env.update(LANG='C.UTF-8', LC_ALL='C.UTF-8', TZ='Europe/Berlin', MAPRISMA_DESKTOP='generic')
        python = json.loads(subprocess.run([sys.executable, '-c', PYTHON, str(ROOT)], input=json.dumps(case),
                                           capture_output=True, check=True, text=True, env=env, timeout=60).stdout)
        line = json.dumps({'id': 1, 'protocol': 1, 'method': 'dev.badges', 'params': case})
        out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                              'bin/fixture_probe.dart'], input=(line + '\n').encode(), capture_output=True,
                             cwd=ROOT / 'packages/maprisma_core', timeout=300, env=env)
        dart = [json.loads(x) for x in out.stdout.splitlines() if x.startswith(b'{')]
        self.assertEqual(len(dart), 1, out.stderr.decode()[-2000:])
        self.assertIn('result', dart[0], dart[0])
        self.maxDiff = None
        self.assertEqual(python, dart[0]['result'])
        self.assertEqual(python['batteries'][1][0], [0.2, 'yellow'])
        self.assertEqual(python['batteries'][1][1], '5 h: 60 % left, resets Fri 13:30\nWeek: 20 % left, resets Mon 16:00')
        self.assertEqual(python['batteries'][2][0], [0.1, 'red'])
        self.assertIsNone(python['batteries'][3][0])
        self.assertEqual([c['colour'] for c in python['costs']], ['green', 'yellow', 'red', 'red', 'green', 'red'])


if __name__ == '__main__':
    unittest.main()
