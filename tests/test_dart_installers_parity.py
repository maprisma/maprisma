"""Development parity: program installers (installers.preview / installers.install, install_ctl's
check_archive and kobold_ctl.sync) through the Python backend and the Dart core. GitHub is a fake
`curl` serving release lists and assets from a folder, systemctl a fake that only logs; nothing
leaves the machine and nothing outside the temporary HOME is written. Skipped without a native
Dart SDK."""
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
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

FAKE_CURL = r'''#!/bin/sh
exec python3 -I -c '
import json, os, re, sys
args = sys.argv[1:]
if "--config" in args:
    text = sys.stdin.read()
    url = re.search(r"^url = \"((?:[^\"\\]|\\.)*)\"", text, re.M).group(1).replace("\\\"", "\"").replace("\\\\", "\\")
else:
    url = args[args.index("--") + 1]
web = json.load(open(os.environ["FAKE_WEB"] + "/map.json"))
if url not in web:
    sys.stderr.write("404 " + url + "\n")
    sys.exit(22)
with open(web[url], "rb") as handle:
    sys.stdout.buffer.write(handle.read())
' "$@"
'''
TOOLS = ('sh', 'bash', 'python3', 'tar', 'gzip', 'zstd', 'lspci', 'setsid', 'kill', 'chmod', 'cat', 'env',
         'uname', 'bwrap', 'dart')
FAKE_SYSTEMCTL = '#!/bin/sh\necho "$*" >> "$HOME/systemctl.log"\nexit 0\n'


def tar_bytes(members, mode='w:gz', fmt=tarfile.GNU_FORMAT) -> bytes:
    """members: (name, kind, data-or-target) with kind file | dir | sym | lnk | fifo | chr."""
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode=mode, format=fmt) as tar:
        for name, kind, value in members:
            info = tarfile.TarInfo(name)
            info.mtime = 1_700_000_000
            if kind == 'file':
                info.size, info.mode = len(value), 0o755
                tar.addfile(info, io.BytesIO(value))
                continue
            info.type = {'dir': tarfile.DIRTYPE, 'sym': tarfile.SYMTYPE, 'lnk': tarfile.LNKTYPE,
                         'fifo': tarfile.FIFOTYPE, 'chr': tarfile.CHRTYPE}[kind]
            if kind == 'dir':
                info.mode = 0o755
            if kind in ('sym', 'lnk'):
                info.linkname = value
            tar.addfile(info)
    return out.getvalue()


def asset(web: Path, urls: dict, name: str, data: bytes) -> dict:
    (web / name).write_bytes(data)
    url = f'https://github.com/fake/releases/download/{name}'
    urls[url] = str(web / name)
    return {'name': name, 'browser_download_url': url, 'size': len(data),
            'digest': 'sha256:' + hashlib.sha256(data).hexdigest()}


def fake_web(web: Path) -> None:
    urls = {}
    def page(url, value):
        name = f'page{len(urls)}.json'
        (web / name).write_text(json.dumps(value))
        urls[url] = str(web / name)
    mise = tar_bytes([('mise', 'dir', None), ('mise/bin', 'dir', None),
                      ('mise/bin/mise', 'file', b'#!/bin/sh\necho mise 2026.10.3\n')])
    page('https://api.github.com/repos/jdx/mise/releases/latest', {
        'tag_name': 'v2026.10.3', 'assets': [asset(web, urls, 'mise-v2026.10.3-linux-x64-musl.tar.gz', mise),
                                             asset(web, urls, 'mise-v2026.10.3-linux-arm64-musl.tar.gz', mise)]})
    llama = lambda build: tar_bytes([('llama-b9000', 'dir', None),
                                     ('llama-b9000/llama-server', 'file', f'#!/bin/sh\n# {build}\n'.encode()),
                                     ('llama-b9000/libggml.so.1', 'file', b'lib'),
                                     ('llama-b9000/libggml.so', 'sym', 'libggml.so.1')])
    page('https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=5', [
        {'tag_name': 'b9000', 'assets': [
            asset(web, urls, 'llama-b9000-bin-ubuntu-vulkan-x64.tar.gz', llama('vulkan')),
            asset(web, urls, 'llama-b9000-bin-ubuntu-rocm-7.0-x64.tar.gz', llama('rocm')),
            asset(web, urls, 'llama-b9000-bin-ubuntu-cuda-12.4-x64.tar.gz', llama('cuda')),
            asset(web, urls, 'cudart-llama-b9000-bin-ubuntu-cuda-12.4-x64.tar.gz', tar_bytes([('cudart.so', 'file', b'c')])),
            asset(web, urls, 'llama-b9000-bin-ubuntu-x64.tar.gz', llama('cpu'))]}])
    page('https://api.github.com/repos/LostRuins/koboldcpp/releases/latest', {
        'tag_name': 'v1.99', 'assets': [asset(web, urls, 'koboldcpp-linux-x64', b'\x7fELF cuda'),
                                        asset(web, urls, 'koboldcpp-linux-x64-nocuda', b'\x7fELF vulkan')]})
    ollama = tar_bytes([('bin', 'dir', None), ('bin/ollama', 'file', b'#!/bin/sh\n')], mode='w')
    zst = subprocess.run(['zstd', '-q', '-c'], input=ollama, capture_output=True, check=True).stdout
    page('https://api.github.com/repos/ollama/ollama/releases/latest', {
        'tag_name': 'v0.40.4', 'assets': [asset(web, urls, 'ollama-linux-amd64.tar.zst', zst),
                                          asset(web, urls, 'ollama-linux-amd64-rocm.tar.zst', zst)]})
    page('https://api.github.com/repos/janhq/jan/releases/latest', {
        'tag_name': 'v0.7.0', 'assets': [asset(web, urls, 'Jan_0.7.0_amd64.AppImage', b'not run here')]})
    (web / 'map.json').write_text(json.dumps(urls))


def files_of(home: Path) -> dict:
    found = {}
    for path in sorted(home.rglob('*')):
        rel = str(path.relative_to(home))
        if rel.startswith(('.cache', '.config/maprisma', 'web', 'tools', '.local/bin/curl', '.local/bin/systemctl')) \
                or rel.endswith('.lock') or '__pycache__' in rel:
            continue
        if path.is_symlink():
            found[rel] = ('link', os.readlink(path))
        elif path.is_dir():
            found[rel] = 'dir'
        else:
            text = path.read_bytes().decode('utf-8', 'replace')
            found[rel] = (text.replace(str(home), '$HOME'), oct(path.stat().st_mode & 0o777))
    return found


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartInstallersParityTest(unittest.TestCase):
    def probe(self, requests):
        lines = [json.dumps({'id': i, 'protocol': 2, 'method': method, 'params': params})
                 for i, (method, params) in enumerate(requests, 1)]
        out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                              'bin/fixture_probe.dart'], input=('\n'.join(lines) + '\n').encode(),
                             capture_output=True, cwd=ROOT / 'packages/maprisma_core', timeout=300, check=True)
        return [json.loads(line)['result'] for line in out.stdout.splitlines() if line.startswith(b'{')]

    def test_same_archive_checks(self):
        import install_ctl
        long = 'deep/' * 30 + 'file.txt'
        cases = [
            ('good', tar_bytes([('a', 'dir', None), ('a/x.so.1', 'file', b'x'), ('a/x.so', 'sym', 'x.so.1'),
                                ('a/hard', 'lnk', 'a/x.so.1')]), 0, 100),
            ('absolute', tar_bytes([('/etc/passwd', 'file', b'x')]), 0, 100),
            ('dotdot', tar_bytes([('a/../../x', 'file', b'x')]), 0, 100),
            ('link out', tar_bytes([('a', 'sym', '/etc')]), 0, 100),
            ('through link', tar_bytes([('a', 'sym', '.'), ('a/b', 'file', b'x')]), 0, 100),
            ('chain out', tar_bytes([('a', 'sym', '.'), ('b', 'sym', 'a/..')]), 0, 100),
            ('climb', tar_bytes([('d', 'dir', None), ('d/l', 'sym', '../../x')]), 0, 100),
            ('hard to link', tar_bytes([('a', 'sym', 'b'), ('b', 'file', b'x'), ('c', 'lnk', 'a')]), 0, 100),
            ('fifo', tar_bytes([('p', 'fifo', None)]), 0, 100),
            ('device', tar_bytes([('c', 'chr', None)]), 0, 100),
            ('too large', tar_bytes([('a', 'file', b'x' * 300)]), 200, 100),
            ('too many', tar_bytes([(f'f{i}', 'file', b'x') for i in range(5)]), 0, 3),
            ('gnu long name', tar_bytes([(long, 'file', b'x')]), 0, 100),
            ('pax long name', tar_bytes([(long, 'file', b'x')], fmt=tarfile.PAX_FORMAT), 0, 100),
            ('ustar prefix', tar_bytes([('p' * 90 + '/' + 'n' * 90, 'file', b'x')], fmt=tarfile.USTAR_FORMAT), 0, 100),
            ('pax long link out', tar_bytes([('l', 'sym', '../' * 40 + 'x')], fmt=tarfile.PAX_FORMAT), 0, 100),
            ('plain', tar_bytes([('a', 'file', b'x')], mode='w'), 0, 100),
            ('zstd', subprocess.run(['zstd', '-q', '-c'], input=tar_bytes([('a', 'file', b'x' * 2000)], mode='w'),
                                    capture_output=True, check=True).stdout, 0, 100),
            ('truncated body', tar_bytes([('a', 'file', b'x' * 5000)], mode='w')[:2048], 0, 100),
            ('garbage after', tar_bytes([('a', 'file', b'x')], mode='w')[:1024] + b'z' * 512, 0, 100),
            ('garbage', b'z' * 1024, 0, 100),
            ('empty', b'', 0, 100),
        ]
        with tempfile.TemporaryDirectory() as temp:
            requests, expected = [], []
            for index, (label, data, limit, most) in enumerate(cases):
                path = Path(temp) / f'{index}.tar'
                path.write_bytes(data)
                try:
                    install_ctl.check_archive(path, limit, most)
                    expected.append((label, 'ok'))
                except RuntimeError as error:
                    text = str(error)
                    expected.append((label, 'not a readable archive' if text.startswith('not a readable') else text))
                requests.append(('dev.tarcheck', {'path': str(path), 'limit': limit or install_ctl.MAX_UNPACKED,
                                                  'max_entries': most}))
            replies = self.probe(requests)
        got = [(label, 'ok' if r.get('ok') else 'not a readable archive' if r['error'].startswith('not a readable')
                else r['error']) for (label, *_rest), r in zip(cases, replies)]
        self.assertEqual(expected, got)
        self.assertEqual(dict(got)['good'], 'ok')
        self.assertNotEqual(dict(got)['chain out'], 'ok')

    def test_same_kobold_sync(self):
        import kobold_ctl
        sides = {}
        with tempfile.TemporaryDirectory() as temp:
            for side in ('python', 'dart'):
                models, configs = Path(temp) / side / 'models', Path(temp) / side / 'configs'
                (models / 'sub').mkdir(parents=True)
                configs.mkdir(parents=True)
                for name in ('a-Q4.gguf', 'sub/b-00001-of-00002.gguf', 'sub/b-00002-of-00002.gguf',
                             'mmproj-a.gguf', 'notes.txt', 'c name!.GGUF'):
                    (models / name).write_bytes(b'not a real gguf')
                (configs / 'gone.kcpps').write_text(json.dumps({'model_param': '/nowhere.gguf', 'ai_agents_map': True}))
                (configs / 'mine.kcpps').write_text(json.dumps({'model_param': '/nowhere.gguf'}))
                if side == 'python':
                    written = kobold_ctl.sync(models, 'vulkan', 8 * 1024 ** 3, configs)
                else:
                    written = self.probe([('dev.koboldsync', {'models': str(models), 'build': 'vulkan',
                                                              'vram': 8 * 1024 ** 3, 'configs': str(configs)})])[0]['written']
                sides[side] = (sorted(written), {p.name: p.read_text().replace(str(Path(temp) / side), '$T')
                                                 for p in sorted(configs.iterdir())})
        self.assertEqual(sides['python'], sides['dart'])
        self.assertIn('b.kcpps', sides['dart'][1])
        self.assertNotIn('gone.kcpps', sides['dart'][1])

    def test_same_previews_and_installs(self):
        sides = {}
        with tempfile.TemporaryDirectory() as temp:
            for side in ('python', 'dart'):
                home = Path(temp) / side
                bin_dir = home / '.local/bin'
                bin_dir.mkdir(parents=True)
                for name, text in (('curl', FAKE_CURL), ('systemctl', FAKE_SYSTEMCTL)):
                    (bin_dir / name).write_text(text)
                    os.chmod(bin_dir / name, 0o700)
                (home / '.config/maprisma').mkdir(parents=True)
                (home / '.config/maprisma/settings.json').write_text(json.dumps({'setup_done': True}))
                # Only the tools the installers use: a mise or llama-server of this PC stays out.
                tools = home / 'tools'
                tools.mkdir()
                for name in TOOLS:
                    found = shutil.which(name)
                    if found:
                        (tools / name).symlink_to(found)
                (home / 'web').mkdir()
                fake_web(home / 'web')
                env = {'HOME': str(home), 'PATH': f'{bin_dir}:{tools}', 'LANG': 'C.UTF-8',
                       'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_CACHE_HOME': str(home / '.cache'),
                       'XDG_DATA_HOME': str(home / '.local/share'), 'MAPRISMA_DESKTOP': 'generic',
                       'MAPRISMA_FLUTTER_DEVEL': '1', 'FAKE_WEB': str(home / 'web')}
                runner = (Side([sys.executable, '-c', PYTHON_SERVICE, str(ROOT)], ROOT, env) if side == 'python' else
                          Side([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                'bin/maprisma-core.dart'], ROOT / 'packages/maprisma_core', env))
                answers = []

                def wait(task):
                    if 'task' not in task:
                        return task
                    for _ in range(600):
                        status = runner.call('tasks.status', {'task': task['task']})
                        if status.get('state') != 'running':
                            break
                        time.sleep(0.1)
                    return [status.get('state'), status.get('result')]

                try:
                    tokens = {}
                    for label, selection in (
                            ('mise', {'kind': 'tool', 'key': 'mise'}),
                            ('llama', {'kind': 'runtime', 'key': 'llamacpp', 'build': 'cpu'}),
                            ('kobold', {'kind': 'runtime', 'key': 'koboldcpp', 'build': 'vulkan'}),
                            ('ollama', {'kind': 'runtime', 'key': 'ollama'}),
                            ('jan', {'kind': 'runtime', 'key': 'jan'}),
                            ('bad build', {'kind': 'runtime', 'key': 'llamacpp', 'build': 'quantum'}),
                            ('lmstudio', {'kind': 'runtime', 'key': 'lmstudio'}),
                            ('vllm', {'kind': 'runtime', 'key': 'vllm'}),
                            ('agent', {'kind': 'agent', 'key': 'dsh'}),
                            ('unknown', {'kind': 'runtime', 'key': 'nobody'}),
                            ('no key', {'kind': 'runtime'}),
                            ('extra', {'kind': 'tool', 'key': 'mise', 'folder': '/tmp'})):
                        reply = runner.call('installers.preview', selection)
                        result = wait(reply)
                        if isinstance(result, list) and isinstance(result[1], dict) and 'installer' in result[1]:
                            tokens[label] = result[1]['installer']
                            result = [result[0], {**result[1], 'installer': '<token>'}]
                        answers.append([label, result])
                    answers.append(runner.call('installers.install', {'installer': tokens['mise'], 'start_now': True,
                                                                      'start_at_login': False}))
                    answers.append(runner.call('installers.install', {'installer': 'nope', 'start_now': False,
                                                                      'start_at_login': False}))
                    for label, now, login in (('mise', False, False), ('llama', True, True), ('kobold', False, True),
                                              ('ollama', False, False)):
                        answers.append([label, wait(runner.call('installers.install', {
                            'installer': tokens[label], 'start_now': now, 'start_at_login': login}))])
                    answers.append(runner.call('installers.install', {'installer': tokens['mise'], 'start_now': False,
                                                                      'start_at_login': False}))
                    answers.append(['again', wait(runner.call('installers.preview', {'kind': 'tool', 'key': 'mise'}))])
                finally:
                    runner.close()
                log = (home / 'systemctl.log').read_text() if (home / 'systemctl.log').exists() else ''
                log = [line for line in log.splitlines() if any(s in line for s in ('llama-server', 'koboldcpp', 'ollama'))]
                sides[side] = json.loads(json.dumps([answers, files_of(home), log]).replace(str(home), '$HOME'))
        self.assertEqual(sides['python'], sides['dart'])
        answers, files, log = sides['dart']
        self.assertEqual(answers[0][1][0], 'done')
        self.assertEqual(answers[0][1][1]['version'], 'v2026.10.3')
        self.assertEqual(files['.local/bin/mise'], ['link', '$HOME/.local/share/maprisma/mise/current/bin/mise'])
        self.assertEqual([a[1][0] for a in answers[14:18]], ['done'] * 4)      # mise, llama.cpp, KoboldCpp, Ollama
        self.assertEqual(answers[18], {'error': 'refused'})                      # a preview is used once
        self.assertIn('.local/share/maprisma/llamacpp/b9000-cpu/llama-server', files)
        self.assertIn('--user enable llama-server.service', log)
        self.assertIn('--user restart llama-server.service', log)


if __name__ == '__main__':
    unittest.main()
