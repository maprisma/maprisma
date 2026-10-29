"""Development parity: Claude Code's sessions as numbers (claude_sessions.collect_by_id) in the Python
reference and the Dart core, read twice with each side's own cache: a session file over 64 MiB, a line
over 8 MiB (skipped), a last line still being written (read on the next run), a session with only a
cost summary (no replies: left out), subagent runs in <session>/subagents/ and an older agent-*.jsonl
next to the sessions, a link (never followed), a file that grew between the runs. Skipped without a
native Dart SDK."""
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
import dataclasses, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import claude_sessions
found = claude_sessions.collect_by_id(Path(sys.argv[2]), cache=Path(sys.argv[3]))
print(json.dumps({k: dataclasses.asdict(v) for k, v in found.items()}))
'''


def reply(sid, stamp, model='claude-opus-5-5', tokens=(10, 20, 30, 40), cwd='/work/a'):
    return json.dumps({'type': 'assistant', 'sessionId': sid, 'timestamp': stamp, 'cwd': cwd,
                       'message': {'model': model, 'usage': dict(zip(
                           ('input_tokens', 'output_tokens', 'cache_read_input_tokens',
                            'cache_creation_input_tokens'), tokens)), 'content': 'never read'}})


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartClaudeSessionsParityTest(unittest.TestCase):
    def test_same_sessions_twice(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            projects = home / '.claude/projects'
            project = projects / '-work-a'
            project.mkdir(parents=True)
            big = project / 'big-session.jsonl'
            with open(big, 'w') as f:
                f.write(reply('big-session', '2026-10-29T10:00:00Z') + '\n')
                filler = json.dumps({'type': 'user', 'text': 'x' * 1_000_000}) + '\n'
                for _ in range(66):
                    f.write(filler)                                          # over 64 MiB in all
                f.write(json.dumps({'type': 'assistant', 'pad': 'y' * (9 * 1024 * 1024)}) + '\n')   # > 8 MiB
                f.write(reply('big-session', '2026-10-29T10:03:00Z', tokens=(1, 2, 3, 4)) + '\n')
                f.write(json.dumps({'type': 'cost-state', 'sessionId': 'big-session', 'totalLinesAdded': 7,
                                    'totalLinesRemoved': 2, 'totalCostUSD': 1.25, 'totalAPIDuration': 900}) + '\n')
                f.write(reply('big-session', '2026-10-29T10:04:00Z')[:-5])  # still being written
            (project / 'only-cost.jsonl').write_text(json.dumps(
                {'type': 'cost-state', 'sessionId': 'only-cost', 'totalCostUSD': 3}) + '\n')
            (project / 'agent-old1.jsonl').write_text(reply('big-session', '2026-10-29T10:01:00Z',
                                                            model='claude-haiku-5-5') + '\n')
            runs = project / 'small/subagents/deep'
            runs.mkdir(parents=True)
            (project / 'small.jsonl').write_text(reply('small', '2026-10-28T08:00:00Z', cwd='/work/b') + '\n')
            (runs / 'agent-x.jsonl').write_text(reply('small', '2026-10-28T08:01:00Z') + '\n' +
                                                reply('small', '2026-10-28T08:02:00Z') + '\n')
            (runs / 'agent-x.meta.json').write_text(json.dumps({'agentType': 'Explore', 'description': 'secret'}))
            outside = home / 'outside.jsonl'
            outside.write_text(reply('linked', '2026-10-28T08:00:00Z') + '\n')
            (project / 'linked.jsonl').symlink_to(outside)
            env = {k: v for k, v in os.environ.items() if not k.startswith('XDG_') and k != 'CLAUDE_CONFIG_DIR'}
            env.update(HOME=str(home), LANG='C.UTF-8', ASTERISM_DESKTOP='generic', TZ='Europe/Berlin',
                       XDG_CACHE_HOME=str(home / 'dart-cache'))
            line = json.dumps({'id': 1, 'protocol': 1, 'method': 'scan.sessions', 'params': {'command': 'claude'}})
            results = []
            for run in range(2):
                python = json.loads(subprocess.run(
                    [sys.executable, '-c', PYTHON, str(ROOT), str(projects), str(home / 'py-cache.json')],
                    capture_output=True, check=True, text=True, env=env, timeout=120).stdout)
                out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                      'bin/fixture_probe.dart'], input=(line + '\n').encode(), capture_output=True,
                                     cwd=ROOT / 'packages/asterism_core', timeout=300, env=env)
                dart = [json.loads(x) for x in out.stdout.splitlines() if x.startswith(b'{')]
                self.assertEqual(len(dart), 1, out.stderr.decode()[-2000:])
                self.assertIn('result', dart[0], dart[0])
                results.append((python, dart[0]['result']['sessions']))
                if run == 0:
                    # The half line is finished now, and one more reply came.
                    text = big.read_bytes()
                    with open(big, 'wb') as f:
                        f.write(text + reply('big-session', '2026-10-29T10:04:00Z')[-5:].encode() + b'\n' +
                                reply('big-session', '2026-10-29T10:06:00Z').encode() + b'\n')
        self.maxDiff = None
        for python, dart in results:
            self.assertEqual(python, dart)
        first, second = results[0][0], results[1][0]
        self.assertEqual(set(first), {'big-session', 'small'})               # no replies, a link: left out
        self.assertEqual(first['big-session']['replies'], 2)
        self.assertEqual(second['big-session']['replies'], 4)                # read on from where it stopped
        self.assertEqual(first['big-session']['subagents'], {'?': [1, 70, 0.0]})
        self.assertEqual(first['small']['subagents'], {'Explore': [1, 140, 60.0]})
        self.assertEqual(first['big-session']['lines_added'], 7)


if __name__ == '__main__':
    unittest.main()
