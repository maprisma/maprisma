"""Development parity: Strata (provider_strata) through the Python reference and the Dart core. A fake
Strata terminal (its `strata` logs what it is asked), launch presets (one with an API key that must
never be read out), run configs, a /usr/bin/strata stand-in that is another program, and a fake Strata
server whose process looks like Strata's own (its terminal's Python running `-m serve.server --config
<run config>`). Both sides must find, start, stop and unload it the same way. Nothing leaves the
temporary HOME; the PC's own processes stay out (a /proc of the fake server only). Skipped without a
native Dart SDK."""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tests'))
try:
    from dart_sdk import resolve_dart
    DART = resolve_dart()
except (OSError, ValueError, RuntimeError):
    DART = None

from test_dart_agent_start_parity import PYTHON_SERVICE, Side  # noqa: E402
from test_dart_provider_ops_parity import own_proc, free_port  # noqa: E402

SERVER = '''import http.server, json, os, sys
config = sys.argv[sys.argv.index("--config") + 1]
port = json.load(open(config))["port"]
log = os.path.expanduser("~/requests.log")
class Handler(http.server.BaseHTTPRequestHandler):
    def _answer(self):
        size = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(size).decode() if size else ""
        with open(log, "a") as handle:
            handle.write(json.dumps([self.command, self.path, json.loads(body) if body else None]) + "\\n")
        reply = json.dumps({"object": "list", "data": [{"id": "qwen-q2_0", "object": "model"}]}
                           if self.path == "/v1/models" else {"unloaded": True}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)
    do_GET = do_POST = _answer
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
'''

STRATA = '#!/bin/sh\necho "$@" >> "$HOME/strata.log"\necho "Strata is serving."\n'
OTHER = '#!/bin/sh\necho "the file manager" >> "$HOME/other.log"\n'


def seed(home: Path, port: int) -> tuple[Path, Path]:
    """The Strata terminal, its link, presets, run configs and another program called strata."""
    data = home / '.local/share/strata'
    terminal = data / 'terminal/0.1.57'
    (terminal / 'bin').mkdir(parents=True)
    (terminal / 'bin/strata').write_text(STRATA)
    os.chmod(terminal / 'bin/strata', 0o755)
    (terminal / 'VERSION').write_text('0.1.57\n')
    (data / 'terminal/current').symlink_to(terminal)
    (home / '.local/bin').mkdir(parents=True)
    (home / '.local/bin/strata').symlink_to(data / 'terminal/current/bin/strata')
    # Another program of that name earlier on PATH: not Strata.
    other = home / 'usr/bin'
    other.mkdir(parents=True)
    (other / 'strata').write_text(OTHER)
    os.chmod(other / 'strata', 0o755)
    presets = home / '.config/strata/launch-presets'
    presets.mkdir(parents=True)
    (presets / 'office.json').write_text(json.dumps(
        {'name': 'Office', 'port': port, 'last_used': '2026-11-05 10:00:00.000000', 'api_key': 'secret-key'}))
    (presets / 'older.json').write_text(json.dumps(
        {'name': 'Older', 'port': 1234, 'last_used': '2026-10-01 10:00:00.000000'}))
    (presets / 'nobody.json').write_text(json.dumps({'name': 'Nobody', 'port': 'x', 'last_used': 5,
                                                     'created': '2026-01-01'}))
    (presets / 'Bad Name.json').write_text(json.dumps({'last_used': '2099-01-01', 'port': 9}))
    (presets / '.hidden.json').write_text(json.dumps({'last_used': '2099-01-01', 'port': 9}))
    install = data / 'install'
    install.mkdir(parents=True)
    run_config = install / 'strata-qwen-q2_0.json'
    run_config.write_text(json.dumps({'port': port, 'model_name': 'Qwen3.8 Flash Next', 'args': []}))
    (install / 'strata-Upper.json').write_text('{}')
    (install / 'strata-x.shared-settings.json').write_text('{}')
    (install / 'notes.json').write_text('{}')
    (install / 'strata-linked.json').symlink_to(run_config)
    return run_config, other


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartStrataParityTest(unittest.TestCase):
    maxDiff = None

    def test_same_scan_and_operations(self):
        sides = {}
        with tempfile.TemporaryDirectory() as temp:
            for side in ('python', 'dart'):
                home = Path(temp) / side
                home.mkdir()
                port = free_port()
                run_config, other = seed(home, port)
                env = {'HOME': str(home), 'PATH': f'{other}:{home}/.local/bin:/usr/bin:/bin', 'LANG': 'C.UTF-8',
                       'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_CACHE_HOME': str(home / '.cache'),
                       'XDG_DATA_HOME': str(home / '.local/share'), 'MAPRISMA_DESKTOP': 'generic',
                       'MAPRISMA_FLUTTER_DEVEL': '1', 'MAPRISMA_SCAN_GPU': str(home / 'drm')}
                # The server as Strata starts it: argv[0] is its terminal's Python.
                module = home / 'srv/serve'
                module.mkdir(parents=True)
                (module / '__init__.py').write_text('')
                (module / 'server.py').write_text(SERVER)
                python = home / '.local/share/strata/terminal/0.1.57/python/bin/python3.12'
                server = subprocess.Popen([str(python), '-m', 'serve.server', '--config', str(run_config),
                                           '--ready-file', str(home / 'ready.json')],
                                          executable=sys.executable, cwd=home / 'srv', env=env)
                try:
                    for _ in range(100):
                        with socket.socket() as s:
                            if s.connect_ex(('127.0.0.1', port)) == 0:
                                break
                        time.sleep(0.05)
                    env['MAPRISMA_SCAN_PROC'] = own_proc(home, server.pid)
                    runner = (Side([sys.executable, '-c', PYTHON_SERVICE, str(ROOT)], ROOT, env) if side == 'python'
                              else Side([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                         'bin/maprisma-core.dart'], ROOT / 'packages/maprisma_core', env))
                    try:
                        local = runner.call('providers.snapshot', {}).get('local') or []
                        strata = [r for r in local if isinstance(r, dict) and r.get('key') == 'strata']
                    finally:
                        runner.close()
                    results = []
                    for side_command, cwd in ((([sys.executable, '-u', str(ROOT / 'flutter_worker.py')], ROOT)
                                               if side == 'python' else
                                               ([DART, '--disable-dart-dev',
                                                 '--packages=.dart_tool/package_config.json',
                                                 'bin/maprisma-core.dart', 'worker'],
                                                ROOT / 'packages/maprisma_core')),):
                        for operation, params in (('model.unload', {'key': 'strata', 'model': 'qwen-q2_0'}),
                                                  ('runtime.stop', {'key': 'strata'}),
                                                  ('runtime.start', {'key': 'strata'})):
                            out = subprocess.run(side_command, input=json.dumps(
                                {'operation': operation, 'params': params}).encode() + b'\n',
                                capture_output=True, env=env, cwd=cwd, timeout=120)
                            lines = [json.loads(line) for line in out.stdout.splitlines() if line.startswith(b'{')]
                            results.append(lines[-1] if lines else {'stderr': out.stderr.decode()[-300:]})
                    logs = {name: (home / name).read_text().splitlines() if (home / name).exists() else []
                            for name in ('requests.log', 'strata.log', 'other.log')}
                    sides[side] = json.loads(json.dumps([strata, results, logs])
                                             .replace(str(home), '$HOME').replace(str(port), '$PORT'))
                finally:
                    server.kill()
                    server.wait()
        self.assertEqual(sides['python'], sides['dart'])
        strata, results, logs = sides['dart']
        self.assertEqual(len(strata), 1, strata)
        found = strata[0]
        self.assertEqual((found['installed'], found['running'], found['address']), (True, True, '127.0.0.1:$PORT'))
        self.assertEqual(found['models'], ['qwen-q2_0'])
        self.assertEqual(found['models_dir'], '~/.local/share/strata/install')
        self.assertTrue(found['can_control'])
        # It cannot load or unload one model on request (can_load False): refused; start and stop work.
        self.assertEqual([r.get('type') for r in results], ['error', 'result', 'result'], results)
        self.assertNotIn('["POST", "/v1/unload", {}]', logs['requests.log'])
        self.assertEqual(logs['strata.log'], ['launch --stop', 'launch --preset office --yes --no-tui'])
        self.assertEqual(logs['other.log'], [])                    # the other strata never ran
        self.assertNotIn('secret-key', json.dumps(sides))


if __name__ == '__main__':
    unittest.main()
