"""Development parity: the System Map's AI help (system.help_preview, system.fix_preview,
system.help_apply: a guarded task tab, and the Smart Check web look-up) through the Python backend and
the Dart core, in a temporary HOME with a fake Claude Code: its look-up answers with a fixed JSON in
Claude's own output format, its task tab prints how it was started. The shared run log is compared
too. Skipped without a native Dart SDK."""
import json
import os
import re
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tests'))
try:
    from dart_sdk import resolve_dart
    DART = resolve_dart()
except (OSError, ValueError, RuntimeError):
    DART = None

from test_dart_agent_start_parity import Side  # noqa: E402
from test_dart_existing_ai_parity import SERVICE  # noqa: E402

ANSWER = {'summary': 'A small setup.\x07 Works.', 'findings': [
    {'level': 'tip', 'title': 'Add a model', 'detail': 'llama.cpp has none.', 'node': 'runtime:llamacpp'},
    {'level': 'problem', 'title': 'Old agent', 'detail': 'Update it.', 'node': 'nothing'},
    {'level': 'good', 'title': 'Add a model', 'detail': 'duplicate title'},
    {'level': 'bogus', 'title': 'x'}]}
CLAUDE = r'''#!/bin/sh
if [ "$1" = --version ]; then echo "2.1.0 (Claude Code)"; exit 0; fi
printf '%s\n' "$@" > "$HOME/claude-args-$$.txt"
case " $* " in
  *" -p "*) cat > "$HOME/claude-stdin.txt"
            cat "$HOME/answer.json" ;;
  *) echo "task tab started with $# arguments"; exit 0 ;;
esac
'''


def seed(home: Path):
    bin_dir = home / '.local/bin'
    bin_dir.mkdir(parents=True)
    (bin_dir / 'claude').write_text(CLAUDE)
    os.chmod(bin_dir / 'claude', 0o700)
    (bin_dir / 'llama-server').write_text('#!/bin/sh\nexit 0\n')
    os.chmod(bin_dir / 'llama-server', 0o700)
    units = home / '.config/systemd/user'
    units.mkdir(parents=True)
    (units / 'llama-server.service').write_text(
        f'[Service]\nEnvironment=LLAMA_ARG_MODELS_DIR={home}/models\nExecStart={bin_dir}/llama-server\n')
    (home / 'models').mkdir()
    # Claude's own output format: the answer (prose around the JSON) and its token use.
    (home / 'answer.json').write_text(json.dumps({
        'type': 'result', 'is_error': False, 'result': 'Here: ' + json.dumps(ANSWER) + ' Done.',
        'usage': {'input_tokens': 10, 'cache_read_input_tokens': 5, 'output_tokens': 7},
        'total_cost_usd': 0.01234}) + '\n')
    (home / '.claude').mkdir()
    (home / '.config/maprisma').mkdir(parents=True)
    (home / '.config/maprisma/settings.json').write_text(json.dumps({'setup_done': True}))


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartSystemHelpParityTest(unittest.TestCase):
    def test_same_ai_help(self):
        sides = {}
        with tempfile.TemporaryDirectory() as temp:
            for side in ('python', 'dart'):
                home = Path(temp) / side
                seed(home)
                env = {'HOME': str(home), 'PATH': f'{home}/.local/bin:/usr/bin:/bin', 'LANG': 'C.UTF-8',
                       'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_CACHE_HOME': str(home / '.cache'),
                       'XDG_DATA_HOME': str(home / '.local/share'), 'XDG_STATE_HOME': str(home / '.local/state'),
                       'ASTERISM_DESKTOP': 'generic', 'ASTERISM_FLUTTER_DEVEL': '1'}
                runner = (Side([sys.executable, '-c', SERVICE, str(ROOT)], ROOT, env) if side == 'python' else
                          Side([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                'bin/asterism-core.dart'], ROOT / 'packages/asterism_core', env))
                answers = []

                def wait(reply):
                    if 'task' not in reply:
                        return reply
                    for _ in range(300):
                        status = runner.call('tasks.status', {'task': reply['task']})
                        if status.get('state') != 'running':
                            break
                        time.sleep(0.1)
                    return [status.get('state'), status.get('result')]

                def read_all(session):
                    text = ''
                    for _ in range(100):
                        read = runner.call('sessions.read', {'session': session})
                        text += read.get('text', '')
                        if read.get('ended') or 'error' in read:
                            break
                        time.sleep(0.05)
                    return text

                def call(label, method, params=None):
                    reply = wait(runner.call(method, params or {}))
                    answers.append([label, reply])
                    return reply

                try:
                    call('before refresh', 'system.help_preview', {'command': 'claude', 'topic': 'overview'})
                    wait(runner.call('system.refresh', {}))
                    overview = call('overview', 'system.help_preview', {'command': 'claude', 'topic': 'overview'})
                    check = call('check', 'system.help_preview', {'command': 'claude', 'topic': 'check'})
                    call('not installed', 'system.help_preview', {'command': 'codex', 'topic': 'overview'})
                    call('bad topic', 'system.help_preview', {'command': 'claude', 'topic': 'delete'})
                    started = call('run overview', 'system.help_apply', {'preview': overview['preview']})
                    answers.append(['tab', read_all(started['session'])])
                    runner.call('sessions.stop', {'session': started['session']})
                    call('used preview', 'system.help_apply', {'preview': overview['preview']})
                    call('run check', 'system.help_apply', {'preview': check['preview']})
                    cached = runner.call('system.cached', {})
                    analysis = cached.get('analysis') or {}
                    answers.append(['cached analysis', analysis])
                    finding = next((f['id'] for f in analysis.get('findings', []) if f['title'] == 'Old agent'), 'x')
                    fix = call('fix', 'system.fix_preview', {'command': 'claude', 'finding': finding})
                    call('fix unknown', 'system.fix_preview', {'command': 'claude', 'finding': 'nothing'})
                    if 'preview' in fix:
                        started = call('run fix', 'system.help_apply', {'preview': fix['preview']})
                        answers.append(['fix tab', read_all(started['session'])])
                        runner.call('sessions.stop', {'session': started['session']})
                finally:
                    runner.close()
                runs = json.loads((home / '.local/state/omarchy-plugin-ai/runs.json').read_text())
                args = sorted(path.read_text() for path in home.glob('claude-args-*.txt'))
                stdin = (home / 'claude-stdin.txt').read_text() if (home / 'claude-stdin.txt').exists() else ''
                text = json.dumps([answers, runs, args, stdin]).replace(str(home), '$HOME')
                text = re.sub(r'"(core-)?[0-9a-f]{32}"', '"<handle>"', text)
                text = re.sub(r'"(when|checked_at)": "?[0-9T:.e+-]+"?', r'"\1": 0', text)
                sides[side] = json.loads(text)
        self.maxDiff = None
        self.assertEqual(sides['python'], sides['dart'])
        answers, runs, args, stdin = sides['dart']
        results = dict((a[0], a[1]) for a in answers)
        self.assertEqual(results['before refresh'], {'error': 'refused'})
        self.assertEqual(results['run check'][0], 'done')
        analysis = results['cached analysis']
        self.assertEqual([f['title'] for f in analysis['findings']], ['Old agent', 'Add a model'])
        # 'nothing' is no node of the map; 'Add a model' is named twice, the last one (no node) wins.
        self.assertEqual([f['node'] for f in analysis['findings']], ['', ''])
        self.assertIn('--permission-mode', '\n'.join(args))
        self.assertIn('PC_FACTS_JSON', results['overview']['prompt'])
        self.assertEqual([r['task'] for r in runs['runs']], ['setup-help', 'setup-analysis', 'smart-fix'])


if __name__ == '__main__':
    unittest.main()
