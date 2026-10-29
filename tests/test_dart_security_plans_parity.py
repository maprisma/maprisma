"""Development parity: changing one security setting of an agent (agent_security.plan: JSON, TOML
and YAML settings files edited in place) in the Python reference and the Dart core. Every setting and
every choice of every built-in agent with security facts, in a temporary HOME whose settings files
hold other content that must stay as written. Skipped without a native Dart SDK."""
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

FILES = {
    '.claude/settings.json': json.dumps({'model': 'opus', 'permissions': {'allow': ['Bash(ls:*)'], 'defaultMode': 'default'},
                                         'env': {'X': '1'}}, indent=2) + '\n',
    '.codex/config.toml': 'model = "gpt-5"\n# a comment that stays\nsandbox_mode = "read-only"\n\n[projects."/home/u"]\n'
                          'trust_level = "trusted"\n\n[tui]\nnotifications = true\n',
    '.copilot/settings.json': '{}\n',
    '.config/cursor/cli-config.json': json.dumps({'permissions': {'allow': [], 'deny': []}, 'version': 1}, indent=2) + '\n',
    '.hermes/config.yaml': 'model: hermes\nterminal:\n  backend: local\n  # keep me\nsecurity: {}\nother:\n  x: 1\n',
    '.config/opencode/opencode.json': json.dumps({'$schema': 'https://opencode.ai/config.json', 'permission': 'ask'}) + '\n',
    '.pi/agent/settings.json': json.dumps({'theme': 'dark'}) + '\n',
}
COMMANDS = ('claude', 'codex', 'copilot', 'cursor-agent', 'hermes', 'opencode', 'pi')

PYTHON = r'''
import json, sys
sys.path.insert(0, sys.argv[1])
import agent_security
out = []
for command in json.loads(sys.argv[2]):
    report = agent_security.report_for(command)
    for setting in report.settings:
        for choice in [c.value for c in setting.choices] + ['not-a-choice']:
            try:
                plan = agent_security.plan(command, setting.key, choice)
                out.append([command, setting.key, choice, [[str(c.path), c.new] for c in plan.changes]])
            except ValueError as error:
                out.append([command, setting.key, choice, 'refused'])
print(json.dumps(out))
'''


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartSecurityPlansParityTest(unittest.TestCase):
    def test_same_security_changes(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            for rel, text in FILES.items():
                (home / rel).parent.mkdir(parents=True, exist_ok=True)
                (home / rel).write_text(text)
            env = {**os.environ, 'HOME': str(home), 'XDG_CONFIG_HOME': str(home / '.config'),
                   'XDG_DATA_HOME': str(home / '.local/share'), 'XDG_CACHE_HOME': str(home / '.cache'),
                   'ASTERISM_DESKTOP': 'generic', 'LANG': 'C.UTF-8'}
            python = json.loads(subprocess.run([sys.executable, '-c', PYTHON, str(ROOT), json.dumps(COMMANDS)],
                                               capture_output=True, check=True, env=env, timeout=120).stdout)
            lines = [json.dumps({'id': i, 'protocol': 1, 'method': 'dev.securityplan',
                                 'params': {'command': c, 'key': k, 'value': v}})
                     for i, (c, k, v, _r) in enumerate(python, 1)]
            out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                  'bin/fixture_probe.dart'], input=('\n'.join(lines) + '\n').encode(),
                                 capture_output=True, cwd=ROOT / 'packages/asterism_core', timeout=300, env=env)
            replies = [json.loads(line)['result'] for line in out.stdout.splitlines() if line.startswith(b'{')]
        dart = [[c, k, v, 'refused' if 'error' in r else r['changes']] for (c, k, v, _p), r in zip(python, replies)]
        self.maxDiff = None
        self.assertEqual(len(python), len(dart))
        self.assertEqual(python, dart)
        self.assertGreater(len(python), 30)
        changed = [r for r in python if isinstance(r[3], list) and r[3]]
        self.assertTrue(any('# a comment that stays' in r[3][0][1] for r in changed if r[0] == 'codex'))
        self.assertTrue(any('# keep me' in r[3][0][1] for r in changed if r[0] == 'hermes'))
        self.assertTrue(all(r[3] == 'refused' for r in python if r[2] == 'not-a-choice'))


if __name__ == '__main__':
    unittest.main()
