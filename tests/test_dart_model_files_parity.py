"""Development parity: model.import (links into llama.cpp's folder, LM Studio's local/<name>/ with its
vision projector, split files, `ollama create`) and models.pull (Ollama's progress stream from a fake
server on its own port) through the Python and the Dart worker, on two identical homes: the same
answer and progress lines, the same trees, the same requests. Skipped without a native Dart SDK."""
import json
import os
import re
import socket
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

OLLAMA_SERVER = '''#!/usr/bin/python3
import http.server, json, os, sys
port = int(sys.argv[1]); log = sys.argv[2]
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_POST(self):
        size = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(size) or b"null")
        with open(log, "a") as handle:
            handle.write(json.dumps([self.command, self.path, body]) + "\\n")
        lines = ([{"error": "pull model manifest: file does not exist"}] if "fail" in body.get("model", "") else
                 [{"status": "pulling manifest"}, {"status": "downloading", "total": 200, "completed": 50},
                  {"status": "downloading", "total": 200, "completed": 200}, {"status": None},
                  "not an object", {"status": "success"}])
        data = b"".join(json.dumps(l).encode() + b"\\n" for l in lines) + b"garbage\\n"
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
'''

# `ollama create NAME -f MODELFILE`: what it was asked, the Modelfile and its OLLAMA_HOST.
OLLAMA_CLI = '''#!/bin/sh
printf '%s|' "$@" >> "$HOME/ollama.log"
printf '\\n%s\\n' "$OLLAMA_HOST" >> "$HOME/ollama.log"
cat "$4" >> "$HOME/ollama.log"
echo success
'''


def free_port() -> int:
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def seed(home: Path, port: int):
    bin_dir = home / '.local/bin'
    bin_dir.mkdir(parents=True)
    for name, text in (('llama-server', '#!/bin/sh\nexit 0\n'), ('lms', '#!/bin/sh\nexit 0\n'), ('ollama', OLLAMA_CLI)):
        (bin_dir / name).write_text(text)
        os.chmod(bin_dir / name, 0o700)
    units = home / '.config/systemd/user'
    units.mkdir(parents=True)
    (units / 'llama.service').write_text(
        f'[Service]\nEnvironment=LLAMA_ARG_MODELS_DIR={home}/models\nExecStart={bin_dir}/llama-server\n')
    (units / 'ollama.service').write_text(
        f'[Service]\nEnvironment=OLLAMA_HOST=127.0.0.1:{port}\nExecStart={bin_dir}/ollama serve\n')
    (home / 'models').mkdir()
    (home / '.lmstudio').mkdir()
    (home / '.lmstudio/settings.json').write_text(json.dumps({'downloadsFolder': str(home / 'lms')}))
    (home / 'lms/pub/repo').mkdir(parents=True)
    (home / 'lms/pub/repo/existing-Q4_K_M.gguf').write_text('GGUF existing')   # a folder with models counts
    src = home / 'src'
    src.mkdir()
    for name in ('a.gguf', 'Split-Q4-00001-of-00002.gguf', 'Split-Q4-00002-of-00002.gguf', 'mmproj-x.gguf',
                 'Weird name (1).gguf', 'notes.txt'):
        (src / name).write_text(f'GGUF {name}')


def tree(home: Path) -> dict:
    found = {}
    for path in sorted(home.rglob('*')):
        rel = str(path.relative_to(home))
        if rel.startswith(('.local/bin', '.config', '.cache', '.local/share', '.local/state', 'ollama.log')):
            continue
        st = os.lstat(path)
        if path.is_symlink():
            found[rel] = ('link', os.readlink(path).replace(str(home), '$HOME'))
        elif path.is_dir():
            found[rel] = ('dir',)
        else:
            found[rel] = ('file', path.read_bytes().replace(str(home).encode(), b'$HOME'), st.st_nlink)
    return found


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartModelFilesParityTest(unittest.TestCase):
    def test_same_imports_and_pulls(self):
        with tempfile.TemporaryDirectory() as temp:
            port = free_port()
            log = Path(temp) / 'server.log'
            server = subprocess.Popen([sys.executable, '-c', OLLAMA_SERVER, str(port), str(log)])
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
                    home = Path(temp) / side
                    home.mkdir()
                    seed(home, port)
                    env = {'HOME': str(home), 'PATH': f'{home}/.local/bin:/usr/bin:/bin', 'LANG': 'C.UTF-8',
                           'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_CACHE_HOME': str(home / '.cache'),
                           'XDG_DATA_HOME': str(home / '.local/share'), 'MAPRISMA_DESKTOP': 'generic'}
                    src = home / 'src'
                    operations = [
                        ('model.import', {'key': 'llamacpp', 'path': str(src / 'a.gguf')}),
                        ('model.import', {'key': 'llamacpp', 'path': str(src / 'Split-Q4-00002-of-00002.gguf')}),
                        ('model.import', {'key': 'lmstudio', 'path': str(src / 'a.gguf')}),
                        ('model.import', {'key': 'lmstudio', 'path': str(src / 'Weird name (1).gguf')}),
                        ('model.import', {'key': 'llamacpp', 'path': 'src/a.gguf'}),
                        ('model.import', {'key': 'llamacpp', 'path': str(src / 'notes.txt')}),
                        ('model.import', {'key': 'llamacpp', 'path': str(src / 'missing.gguf')}),
                        ('model.import', {'key': 'ollama', 'path': str(src / 'Split-Q4-00001-of-00002.gguf')}),
                        ('models.pull', {'key': 'ollama', 'name': 'qwen3:8b'}),
                        ('models.pull', {'key': 'ollama', 'name': 'fail:1b'}),
                        ('models.pull', {'key': 'llamacpp', 'name': 'qwen3:8b'}),
                        ('models.pull', {'key': 'ollama', 'name': 'Bad Name'}),
                    ]
                    answers = []
                    for operation, params in operations:
                        out = subprocess.run(command, input=json.dumps({'operation': operation, 'params': params}).encode() + b'\n',
                                             capture_output=True, env=env, cwd=cwd, timeout=120)
                        answers.append([json.loads(line) for line in out.stdout.splitlines() if line.startswith(b'{')]
                                       or out.stderr.decode()[-300:])
                    requests = log.read_text().splitlines() if log.exists() else []
                    log.unlink(missing_ok=True)
                    cli = (home / 'ollama.log').read_text().replace(str(home), '$HOME') if (home / 'ollama.log').exists() else ''
                    cli = re.sub(r'maprisma-[^/]+/', 'maprisma-<tmp>/', cli)
                    sides[side] = (json.loads(json.dumps(answers).replace(str(home), '$HOME')), tree(home), requests, cli)
                self.assertEqual(sides['python'][0], sides['dart'][0])
                self.assertEqual(sides['python'][1], sides['dart'][1])
                self.assertEqual(sides['python'][2:], sides['dart'][2:])
                answers, files, requests, cli = sides['dart']
                self.assertEqual([a[-1]['type'] for a in answers],
                                 ['result'] * 4 + ['error'] * 3 + ['result', 'result', 'error', 'error', 'error'])
                self.assertEqual(files['models/a.gguf'][2], 3)            # hard links: src, llama.cpp, LM Studio
                self.assertIn('lms/local/a/mmproj-x.gguf', files)
                self.assertIn('models/Split-Q4-00002-of-00002.gguf', files)
                self.assertIn('split-q4|-f|', cli)
                self.assertEqual(requests, [
                    '["POST", "/api/pull", {"model": "qwen3:8b", "stream": true}]',
                    '["POST", "/api/pull", {"model": "fail:1b", "stream": true}]'])
                self.assertEqual([m.get('fraction') for m in answers[8] if m['type'] == 'progress'],
                                 [0.0, 0.25, 1.0, 0.0, 0.0])
            finally:
                server.kill()
                server.wait()


if __name__ == '__main__':
    unittest.main()
