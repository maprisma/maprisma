"""Development parity: the map's usage statistics box (usage_box.read, head_model, newest_file, parts,
size_text, rate_text) in the Python reference and the Dart core: Claude Code's, Codex's and Pi's session
lines, a reply over several lines, a tool result between replies, a line over 64 KiB, a file read from its
last 256 KiB (cut in the middle), the context size from the file, from the adapter's contexts and not
known, the newest session file at a depth, a link (never followed). Skipped without a native Dart SDK."""
import json
import os
import subprocess
import sys
import tempfile
import time
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
import usage_box
case = json.loads(sys.stdin.read())
reads = []
for form, path, contexts in case['reads']:
    r = usage_box.read(form, Path(path), contexts)
    reads.append(None if r is None else [dataclasses.asdict(r[0]), r[1],
                                        [list(x) for x in usage_box.parts(r[0], usage_box.ITEMS)],
                                        [list(x) for x in usage_box.parts(r[0], ('used',))]])
print(json.dumps({
    'reads': reads,
    'heads': [usage_box.head_model(form, Path(path)) for form, path in case['heads']],
    'newest': [(lambda p: None if p is None else str(p))(usage_box.newest_file(Path(r), d, s))
               for r, d, s in case['newest']],
    'sizes': [usage_box.size_text(n) for n in case['sizes']],
    'rates': [usage_box.rate_text(r) for r in case['rates']]}))
'''


def iso(t):
    return time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(t)) + f'.{int(t * 1000) % 1000:03d}Z'


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartUsageBoxParityTest(unittest.TestCase):
    def test_same_readings(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            t0 = 1_793_300_000.0
            claude = home / 'claude/-p/session.jsonl'
            claude.parent.mkdir(parents=True)
            lines = [{'type': 'user', 'timestamp': iso(t0)}]
            for i in range(3):                                         # one reply over three lines
                lines.append({'type': 'assistant', 'timestamp': iso(t0 + 2 + i),
                              'message': {'id': 'msg_1', 'model': 'claude-opus-5-5',
                                          'usage': {'output_tokens': 40 * (i + 1), 'input_tokens': 10,
                                                    'cache_read_input_tokens': 150000,
                                                    'cache_creation_input_tokens': 2000}}})
            lines.append({'type': 'assistant', 'timestamp': iso(t0 + 6), 'pad': 'x' * 70000})   # skipped
            claude.write_text('\n'.join(json.dumps(x) for x in lines) + '\n')
            big = home / 'claude/-p/big.jsonl'
            with open(big, 'w') as f:
                f.write(json.dumps({'type': 'assistant', 'timestamp': iso(t0), 'message': {
                    'id': 'early', 'model': 'claude-haiku-5-5', 'usage': {'output_tokens': 5}}}) + '\n')
                for _ in range(400):
                    f.write(json.dumps({'type': 'progress', 'data': 'y' * 1000}) + '\n')
                f.write(json.dumps({'type': 'user', 'timestamp': iso(t0 + 10)}) + '\n')
                f.write(json.dumps({'type': 'assistant', 'timestamp': iso(t0 + 13.5), 'message': {
                    'id': 'late', 'usage': {'output_tokens': 70, 'input_tokens': 900}}}) + '\n')
            codex = home / 'codex/2026/10/30/rollout-x.jsonl'
            codex.parent.mkdir(parents=True)
            codex.write_text('\n'.join(json.dumps(x) for x in [
                {'type': 'turn_context', 'timestamp': iso(t0), 'payload': {'model': 'gpt-6-sol'}},
                {'timestamp': iso(t0 + 1), 'payload': {'type': 'user_message'}},
                {'timestamp': iso(t0 + 9), 'payload': {'type': 'token_count', 'info': {
                    'last_token_usage': {'output_tokens': 300, 'total_tokens': 240000},
                    'model_context_window': 272000}}},
                {'timestamp': iso(t0 + 10), 'payload': {'type': 'function_call_output'}},
                {'timestamp': iso(t0 + 10.1), 'payload': {'type': 'token_count', 'info': {
                    'last_token_usage': {'output_tokens': 50, 'total_tokens': 241000},
                    'model_context_window': 272000}}}]) + '\n')
            pi = home / 'pi/s/session.jsonl'
            pi.parent.mkdir(parents=True)
            pi.write_text('\n'.join(json.dumps(x) for x in [
                {'type': 'model_change', 'timestamp': iso(t0), 'modelId': 'qwen3-8b'},
                {'type': 'message', 'timestamp': iso(t0 + 1), 'message': {'role': 'user'}},
                {'type': 'message', 'id': 'a1', 'timestamp': iso(t0 + 4),
                 'message': {'role': 'assistant', 'usage': {'output': 120, 'totalTokens': 9000}}}]) + '\n')
            (home / 'claude/-p/linked.jsonl').symlink_to(claude)
            for path, mtime in ((claude, t0 + 100), (big, t0 + 50)):
                os.utime(path, (mtime, mtime))
            contexts = {'claude-opus-5': 1000000, '': 200000}
            case = {
                'reads': [['claude-jsonl', str(claude), contexts], ['claude-jsonl', str(big), contexts],
                          ['codex-jsonl', str(codex), {}], ['pi-jsonl', str(pi), {}],
                          ['pi-jsonl', str(pi), {'qwen3': 32768}], ['claude-jsonl', str(home / 'none.jsonl'), {}],
                          ['claude-jsonl', str(home / 'claude/-p/linked.jsonl'), contexts]],
                'heads': [['claude-jsonl', str(big)], ['codex-jsonl', str(codex)], ['pi-jsonl', str(pi)]],
                'newest': [[str(home / 'claude'), 1, t0], [str(home / 'claude'), 1, t0 + 200],
                           [str(home / 'codex'), 3, 0], [str(home / 'codex'), 2, 0]],
                'sizes': [0, 999, 1000, 1499, 1500, 2500, 272000, 1000000, 1050000, 2500000],
                'rates': [0.04, 9.95, 9.96, 10, 42.5, 43.5, 1234.6],
            }
            env = {k: v for k, v in os.environ.items() if not k.startswith('XDG_')}
            env.update(HOME=str(home), LANG='C.UTF-8', TZ='Europe/Berlin', MAPRISMA_DESKTOP='generic')
            python = json.loads(subprocess.run([sys.executable, '-c', PYTHON, str(ROOT)], input=json.dumps(case),
                                               capture_output=True, check=True, text=True, env=env,
                                               timeout=60).stdout)
            line = json.dumps({'id': 1, 'protocol': 1, 'method': 'dev.usagebox', 'params': case})
            out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                  'bin/fixture_probe.dart'], input=(line + '\n').encode(), capture_output=True,
                                 cwd=ROOT / 'packages/maprisma_core', timeout=300, env=env)
            dart = [json.loads(x) for x in out.stdout.splitlines() if x.startswith(b'{')]
        self.assertEqual(len(dart), 1, out.stderr.decode()[-2000:])
        self.assertIn('result', dart[0], dart[0])
        self.maxDiff = None
        self.assertEqual(python, dart[0]['result'])
        first = python['reads'][0]
        self.assertEqual(first[0]['window'], 1000000)                       # the adapter's contexts
        self.assertEqual(first[2], [['30 t/s', 'line'], ['1M', 'line'], ['15%', 'line']])
        self.assertEqual(python['reads'][2][0]['window'], 272000)          # from the file
        self.assertIsNone(python['reads'][5])
        self.assertIsNone(python['reads'][6])                              # a link is not read
        self.assertEqual(python['heads'][0], 'claude-haiku-5-5')


if __name__ == '__main__':
    unittest.main()
