"""Development parity: the Python and Dart workers run the same provider operations against a fake
llama.cpp router (own socket on 127.0.0.1) and a fake systemctl, and send the same requests.
Skipped without a native Dart SDK."""
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
try:
    from dart_sdk import resolve_dart
    DART = resolve_dart()
except (OSError, ValueError, RuntimeError):
    DART = None

SERVER = '''#!/usr/bin/python3
import http.server, json, os, sys
port = int(sys.argv[sys.argv.index("--port") + 1])
log = os.path.expanduser("~/requests.log")
class Handler(http.server.BaseHTTPRequestHandler):
    def _answer(self):
        size = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(size).decode() if size else ""
        with open(log, "a") as handle:
            handle.write(json.dumps([self.command, self.path, json.loads(body) if body else None]) + "\\n")
        reply = b'{"success": true}' if "fail" not in body else b'{"error": "no"}'
        self.send_response(200 if "fail" not in body else 500)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)
    do_GET = do_POST = _answer
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
'''

SYSTEMCTL = '#!/bin/sh\necho "$@" >> "$HOME/systemctl.log"\n'


def free_port() -> int:
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartProviderOpsParityTest(unittest.TestCase):
    def test_same_requests_and_results(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            bin_dir = home / '.local/bin'
            bin_dir.mkdir(parents=True)
            for name, text in (('llama-server', SERVER), ('systemctl', SYSTEMCTL)):
                (bin_dir / name).write_text(text)
                os.chmod(bin_dir / name, 0o700)
            port = free_port()
            (home / '.config/systemd/user').mkdir(parents=True)
            (home / '.config/systemd/user/llama.service').write_text(
                f'[Service]\nExecStart={bin_dir}/llama-server --port {port}\n')
            (home / '.cache/llama.cpp').mkdir(parents=True)
            (home / '.cache/llama.cpp/fixture-chat-Q4_K_M.gguf').write_text('GGUF')
            env = {'HOME': str(home), 'PATH': f'{bin_dir}:/usr/bin:/bin', 'LANG': 'C.UTF-8',
                   'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_CACHE_HOME': str(home / '.cache'),
                   'XDG_DATA_HOME': str(home / '.local/share'), 'MAPRISMA_DESKTOP': 'generic'}
            server = subprocess.Popen([str(bin_dir / 'llama-server'), '--port', str(port)], env=env)
            try:
                for _ in range(100):
                    with socket.socket() as s:
                        if s.connect_ex(('127.0.0.1', port)) == 0:
                            break
                    time.sleep(0.05)
                operations = [
                    ('model.load', {'key': 'llamacpp', 'model': 'fixture-chat-Q4_K_M'}),
                    ('model.unload', {'key': 'llamacpp', 'model': 'fixture-chat-Q4_K_M'}),
                    ('model.load', {'key': 'llamacpp', 'model': 'not-there'}),
                    ('model.load', {'key': 'llamacpp', 'model': 'bad name!'}),
                    ('runtime.stop', {'key': 'llamacpp'}),
                    ('runtime.start', {'key': 'llamacpp'}),
                    ('runtime.start', {'key': 'ollama'}),
                    ('runtime.start', {'key': 'llamacpp', 'extra': 'x'}),
                ]
                sides = {}
                for side, command, cwd in (
                        ('python', [sys.executable, '-u', str(ROOT / 'flutter_worker.py')], ROOT),
                        ('dart', [DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                  'bin/maprisma-core.dart', 'worker'], ROOT / 'packages/maprisma_core')):
                    results = []
                    for operation, params in operations:
                        out = subprocess.run(command, input=json.dumps({'operation': operation, 'params': params}).encode() + b'\n',
                                             capture_output=True, env=env, cwd=cwd, timeout=120)
                        lines = [json.loads(line) for line in out.stdout.splitlines() if line.startswith(b'{')]
                        results.append(lines[-1] if lines else {'stderr': out.stderr.decode()[-300:]})
                    logs = {}
                    for name in ('requests.log', 'systemctl.log'):
                        path = home / name
                        logs[name] = path.read_text().splitlines() if path.exists() else []
                        path.unlink(missing_ok=True)
                    sides[side] = (results, logs)
                self.assertEqual(sides['python'], sides['dart'])
                results, logs = sides['dart']
                self.assertEqual([r.get('type') for r in results],
                                 ['result', 'result', 'error', 'error', 'result', 'result', 'error', 'error'])
                self.assertEqual(logs['requests.log'], [
                    '["POST", "/models/load", {"model": "fixture-chat-Q4_K_M"}]',
                    '["POST", "/models/unload", {"model": "fixture-chat-Q4_K_M"}]'])
                self.assertEqual(logs['systemctl.log'], ['--user stop llama.service', '--user start llama.service'])
            finally:
                server.kill()
                server.wait()

    def test_same_model_actions_after_the_files(self):
        import connect
        import flutter_plan_wire
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            bin_dir = home / '.local/bin'
            bin_dir.mkdir(parents=True)
            (bin_dir / 'llama-server').write_text(SERVER)
            os.chmod(bin_dir / 'llama-server', 0o700)
            port = free_port()
            (home / '.config/systemd/user').mkdir(parents=True)
            (home / '.config/systemd/user/llama.service').write_text(
                f'[Service]\nExecStart={bin_dir}/llama-server --port {port}\n')
            (home / '.cache/llama.cpp').mkdir(parents=True)
            for name in ('fixture-chat-Q4_K_M', 'fixture-next-Q4_K_M'):
                (home / f'.cache/llama.cpp/{name}.gguf').write_text('GGUF')
            env = {'HOME': str(home), 'PATH': f'{bin_dir}:/usr/bin:/bin', 'LANG': 'C.UTF-8',
                   'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_CACHE_HOME': str(home / '.cache'),
                   'XDG_DATA_HOME': str(home / '.local/share'), 'MAPRISMA_DESKTOP': 'generic'}
            server = subprocess.Popen([str(bin_dir / 'llama-server'), '--port', str(port)], env=env)
            try:
                for _ in range(100):
                    with socket.socket() as s:
                        if s.connect_ex(('127.0.0.1', port)) == 0:
                            break
                    time.sleep(0.05)
                sides = {}
                for side, command, cwd in (
                        ('python', [sys.executable, '-u', str(ROOT / 'flutter_worker.py')], ROOT),
                        ('dart', [DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                  'bin/maprisma-core.dart', 'worker'], ROOT / 'packages/maprisma_core')):
                    target = home / f'{side}/settings.json'
                    plan = connect.Plan('pi', 'llamacpp', 'llama-local', changes=[
                        connect.Change(target, '', '{"model": "next"}\n')])
                    plan.model_actions = [
                        {'operation': 'model.unload', 'key': 'llamacpp', 'model': 'fixture-chat-Q4_K_M', 'agents': []},
                        {'operation': 'model.load', 'key': 'llamacpp', 'model': 'fixture-next-Q4_K_M', 'agents': []}]
                    results = []
                    for actions in (plan.model_actions, [dict(plan.model_actions[1], model='not-there')]):
                        plan.model_actions = actions
                        with tempfile.TemporaryFile() as private:
                            private.write(flutter_plan_wire.encode(plan, home / f'{side}/backups'))
                            private.seek(0)
                            os.fchmod(private.fileno(), 0o600)
                            out = subprocess.run(command + ['--plan-fd', str(private.fileno())],
                                                 input=b'{"operation": "connections.apply", "params": {}}\n',
                                                 capture_output=True, pass_fds=(private.fileno(),), env=env,
                                                 cwd=cwd, timeout=120)
                        lines = [json.loads(line) for line in out.stdout.splitlines() if line.startswith(b'{')]
                        result = lines[-1] if lines else {'stderr': out.stderr.decode()[-300:]}
                        results.append(result.get('type'))
                        if result.get('type') == 'result':
                            results.append(result['result']['context_failures'])
                        target.unlink(missing_ok=True)
                    log = home / 'requests.log'
                    sides[side] = (results, log.read_text().splitlines() if log.exists() else [])
                    log.unlink(missing_ok=True)
                self.assertEqual(sides['python'], sides['dart'])
                # The first plan unloads and loads after its file (the guard asks the running
                # runtime for its models before writing and again before the unload); the second
                # names a model the runtime does not have and is refused before anything is written.
                self.assertEqual(sides['dart'], (['result', 0, 'error'], [
                    '["GET", "/models", null]',
                    '["GET", "/models", null]',
                    '["POST", "/models/unload", {"model": "fixture-chat-Q4_K_M"}]',
                    '["POST", "/models/load", {"model": "fixture-next-Q4_K_M"}]']))
            finally:
                server.kill()
                server.wait()

    def test_same_ollama_context_requests_after_the_files(self):
        import connect
        import flutter_plan_wire
        import inventory
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            bin_dir = home / '.local/bin'
            bin_dir.mkdir(parents=True)
            (bin_dir / 'ollama').write_text(SERVER)
            os.chmod(bin_dir / 'ollama', 0o700)
            port = free_port()
            env = {'HOME': str(home), 'PATH': f'{bin_dir}:/usr/bin:/bin', 'LANG': 'C.UTF-8',
                   'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_CACHE_HOME': str(home / '.cache'),
                   'XDG_DATA_HOME': str(home / '.local/share'), 'MAPRISMA_DESKTOP': 'generic'}
            server = subprocess.Popen([str(bin_dir / 'ollama'), '--port', str(port)], env=env)
            try:
                for _ in range(100):
                    with socket.socket() as s:
                        if s.connect_ex(('127.0.0.1', port)) == 0:
                            break
                    time.sleep(0.05)
                rt = inventory.Runtime('ollama', 'Ollama', installed=True, address=f'127.0.0.1:{port}')
                closed = inventory.Runtime('ollama', 'Ollama', installed=True, address=f'127.0.0.1:{free_port()}')
                sides = {}
                for side, command, cwd in (
                        ('python', [sys.executable, '-u', str(ROOT / 'flutter_worker.py')], ROOT),
                        ('dart', [DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                  'bin/maprisma-core.dart', 'worker'], ROOT / 'packages/maprisma_core')):
                    target = home / f'{side}/settings.json'
                    plan = connect.Plan('pi', 'ollama', 'ollama-local', changes=[
                        connect.Change(target, '', '{"model": "m"}\n')],
                        contexts=[(rt, 'gemma:latest', 16384), (rt, 'fail:latest', 8192),
                                  (closed, 'gemma:latest', 4096)])
                    with tempfile.TemporaryFile() as private:
                        private.write(flutter_plan_wire.encode(plan, home / f'{side}/backups'))
                        private.seek(0)
                        os.fchmod(private.fileno(), 0o600)
                        out = subprocess.run(command + ['--plan-fd', str(private.fileno())],
                                             input=b'{"operation": "connections.apply", "params": {}}\n',
                                             capture_output=True, pass_fds=(private.fileno(),), env=env,
                                             cwd=cwd, timeout=120)
                    lines = [json.loads(line) for line in out.stdout.splitlines() if line.startswith(b'{')]
                    result = lines[-1] if lines else {'stderr': out.stderr.decode()[-300:]}
                    self.assertEqual(result.get('type'), 'result', result)
                    self.assertEqual(target.read_text(), '{"model": "m"}\n')
                    log = home / 'requests.log'
                    sides[side] = (result['result']['context_failures'], log.read_text().splitlines())
                    log.unlink()
                self.assertEqual(sides['python'], sides['dart'])
                self.assertEqual(sides['dart'], (2, [
                    '["POST", "/api/create", {"model": "gemma:latest", "from": "gemma:latest", '
                    '"parameters": {"num_ctx": 16384}, "stream": false}]',
                    '["POST", "/api/create", {"model": "fail:latest", "from": "fail:latest", '
                    '"parameters": {"num_ctx": 8192}, "stream": false}]']))
            finally:
                server.kill()
                server.wait()


if __name__ == '__main__':
    unittest.main()
