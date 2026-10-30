"""Development parity: removing a local LLM's model (models.remove_preview / models.remove_apply)
through the Python backend and the Dart core: llama.cpp's files to the desktop's trash (gio, inside the
temporary HOME), a model LM Studio links to (shared), only a link, a split model, a file changed after
the preview, and Ollama's own delete on a fake Ollama server. Skipped without a native Dart SDK or gio."""
import json
import os
import shutil
import socket
import subprocess
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

from test_dart_agent_start_parity import PYTHON_SERVICE, Side  # noqa: E402

OLLAMA_SERVER = '''
import http.server, json, sys
port = int(sys.argv[1]); log = sys.argv[2]
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_DELETE(self):
        size = int(self.headers.get("Content-Length") or 0)
        with open(log, "a") as handle:
            handle.write(json.dumps([self.command, self.path, json.loads(self.rfile.read(size) or b"null")]) + "\\n")
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
'''


def free_port() -> int:
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def seed(home: Path, port: int):
    bin_dir = home / '.local/bin'
    bin_dir.mkdir(parents=True)
    for name in ('llama-server', 'lms', 'ollama'):
        (bin_dir / name).write_text('#!/bin/sh\nexit 0\n')
        os.chmod(bin_dir / name, 0o700)
    units = home / '.config/systemd/user'
    units.mkdir(parents=True)
    (units / 'llama.service').write_text(
        f'[Service]\nEnvironment=LLAMA_ARG_MODELS_DIR={home}/models\nExecStart={bin_dir}/llama-server\n')
    (units / 'ollama.service').write_text(
        f'[Service]\nEnvironment=OLLAMA_HOST=127.0.0.1:{port}\nEnvironment=OLLAMA_MODELS={home}/ollama\n'
        f'ExecStart={bin_dir}/ollama serve\n')
    models = home / 'models'
    models.mkdir()
    for name in ('shared-Q4.gguf', 'Split-Q4-00001-of-00002.gguf', 'Split-Q4-00002-of-00002.gguf',
                 'Other-Q4-00001-of-00002.gguf', 'Other-Q4-00002-of-00002.gguf', 'mmproj-x.gguf'):
        (models / name).write_text(f'GGUF {name}')
    (home / 'elsewhere').mkdir()
    (home / 'elsewhere/real.gguf').write_text('GGUF real')
    (models / 'linked.gguf').symlink_to(home / 'elsewhere/real.gguf')
    # LM Studio reads shared-Q4.gguf through a link: removing it there takes it from LM Studio too.
    (home / '.lmstudio').mkdir()
    (home / '.lmstudio/settings.json').write_text(json.dumps({'downloadsFolder': str(home / 'lms')}))
    (home / 'lms/pub/repo').mkdir(parents=True)
    (home / 'lms/pub/repo/shared-Q4.gguf').symlink_to(models / 'shared-Q4.gguf')
    manifest = home / 'ollama/manifests/registry.ollama.ai/library/qwen3'
    manifest.mkdir(parents=True)
    (manifest / '8b').write_text('{}')
    (home / '.config/maprisma').mkdir(parents=True)
    (home / '.config/maprisma/settings.json').write_text(json.dumps({'setup_done': True}))


def tree(home: Path) -> dict:
    found = {}
    for path in sorted(home.rglob('*')):
        rel = str(path.relative_to(home))
        if rel.startswith(('.local/bin', '.config', '.cache', '.local/state')) or rel.endswith('.trashinfo') \
                or '/Trash/expunged' in rel:
            continue
        if path.is_symlink():
            found[rel] = ('link', os.readlink(path).replace(str(home), '$HOME'))
        elif path.is_dir():
            found[rel] = ('dir',)
        else:
            found[rel] = ('file', path.read_text(errors='replace'))
    return found


@unittest.skipIf(DART is None or shutil.which('gio') is None, 'native Dart SDK or gio not available')
class DartModelRemovalsParityTest(unittest.TestCase):
    def test_same_removals(self):
        sides = {}
        with tempfile.TemporaryDirectory() as temp:
            port = free_port()
            log = Path(temp) / 'ollama.log'
            server = subprocess.Popen([sys.executable, '-c', OLLAMA_SERVER, str(port), str(log)])
            try:
                for _ in range(100):
                    with socket.socket() as s:
                        if s.connect_ex(('127.0.0.1', port)) == 0:
                            break
                    time.sleep(0.05)
                for side in ('python', 'dart'):
                    home = Path(temp) / side
                    home.mkdir()
                    seed(home, port)
                    env = {'HOME': str(home), 'PATH': f'{home}/.local/bin:/usr/bin:/bin', 'LANG': 'C.UTF-8',
                           'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_CACHE_HOME': str(home / '.cache'),
                           'XDG_DATA_HOME': str(home / '.local/share'), 'MAPRISMA_DESKTOP': 'generic',
                           'MAPRISMA_FLUTTER_DEVEL': '1'}
                    runner = (Side([sys.executable, '-c', PYTHON_SERVICE, str(ROOT)], ROOT, env) if side == 'python'
                              else Side([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                         'bin/maprisma-core.dart'], ROOT / 'packages/maprisma_core', env))
                    answers, tokens = [], {}

                    def wait(reply):
                        if 'task' not in reply:
                            return reply
                        for _ in range(300):
                            status = runner.call('tasks.status', {'task': reply['task']})
                            if status.get('state') != 'running':
                                break
                            time.sleep(0.1)
                        return [status.get('state'), status.get('result')]

                    try:
                        answers.append(runner.call('providers.snapshot', {}).get('local'))
                        for label, params in (('shared', {'key': 'llamacpp', 'model': 'shared-Q4'}),
                                              ('split', {'key': 'llamacpp', 'model': 'Split-Q4-00001-of-00002'}),
                                              ('other', {'key': 'llamacpp', 'model': 'Other-Q4-00002-of-00002'}),
                                              ('link', {'key': 'llamacpp', 'model': 'linked'}),
                                              ('ollama', {'key': 'ollama', 'model': 'qwen3:8b'}),
                                              ('missing', {'key': 'llamacpp', 'model': 'nothing'}),
                                              ('unknown', {'key': 'nobody', 'model': 'x'}),
                                              ('shape', {'key': 'llamacpp'})):
                            reply = runner.call('models.remove_preview', params)
                            if 'removal' in reply:
                                tokens[label] = reply['removal']
                                reply = {**reply, 'removal': '<token>'}
                            reply.pop('focus', None)
                            answers.append([label, reply])
                        # A part changed after the preview: nothing goes.
                        (home / 'models/Other-Q4-00002-of-00002.gguf').write_text('GGUF changed, longer')
                        for label in ('shared', 'shared', 'split', 'other', 'link', 'ollama'):
                            answers.append([label, wait(runner.call('models.remove_apply', {'removal': tokens[label]}))])
                        answers.append(runner.call('models.remove_apply', {'removal': 'nope'}))
                        answers.append(runner.call('models.remove_apply', {'removal': 1}))
                    finally:
                        runner.close()
                    sides[side] = json.loads(json.dumps([answers, tree(home)]).replace(str(home), '$HOME'))
                deletes = log.read_text().splitlines() if log.exists() else []
            finally:
                server.kill()
                server.wait()
        self.maxDiff = None
        self.assertEqual(sides['python'], sides['dart'])
        answers, files = sides['dart']
        results = {a[0]: a[1] for a in answers[9:15]}
        self.assertEqual(results['split'], ['done', {'ok': True, 'recoverable': True}])
        self.assertEqual(results['other'][0], 'failed')
        self.assertEqual(results['ollama'], ['done', {'ok': True, 'recoverable': False}])
        self.assertEqual(answers[1][1]['shared'], ['LM Studio'])
        self.assertTrue(answers[4][1]['links_only'])
        self.assertIn('.local/share/Trash/files/Split-Q4-00001-of-00002.gguf', files)
        self.assertIn('elsewhere/real.gguf', files)                  # only the link went
        self.assertEqual(len(deletes), 2)                              # one Ollama delete per side
        self.assertEqual(json.loads(deletes[0]), ['DELETE', '/api/delete', {'model': 'qwen3:8b'}])


if __name__ == '__main__':
    unittest.main()
