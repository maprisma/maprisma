"""Development parity: the MCP servers to start with and the MCP registry (mcp_catalog, mcp_registry)
in the Python reference and the Dart core: registry answers turned into ways to run a server (odd and
hostile entries included), the user's values filled in, the saved list searched and downloaded page by
page (fresh, resumed, up to date, offline), the picks pinned to their versions. No network: answers
are fixtures. Skipped without a native Dart SDK."""
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


def _server(name, **extra):
    return {'server': {'name': name, **extra}}


REGISTRY = {'servers': [
    _server('io.github.someone/files-mcp-server', title='  Files\n  server ', description='Reads\tfiles　here' * 40,
            version='1.2.0', repository={'url': 'https://github.com/someone/files'}, websiteUrl='http://plain.example',
            packages=[{'registryType': 'npm', 'identifier': '@someone/files', 'version': '1.2.0',
                       'transport': {'type': 'stdio'},
                       'environmentVariables': [
                           {'name': 'API_KEY', 'isRequired': True, 'isSecret': True, 'description': 'The key'},
                           {'name': 'BASE', 'default': 'https://x/{region}', 'variables': {
                               'region': {'description': 'Region', 'default': 'eu'}}},
                           {'name': 'BAD\n'}, {'name': None}, {'name': '9bad'}, 'junk'],
                       'packageArguments': [
                           {'type': 'positional', 'isRequired': True, 'valueHint': 'folder', 'description': 'Folder'},
                           {'type': 'named', 'name': '--token', 'value': '{token}', 'isSecret': True},
                           {'type': 'named', 'name': '--mode=', 'value': 'fast'},
                           {'type': 'positional', 'value': ''}, 7]}],
            _meta=None),
    {'server': {'name': 'com.example/py-mcp', 'description': True,
                'packages': [{'registryType': 'pypi', 'identifier': 'mcp-py', 'version': 'latest'},
                             {'registryType': 'npm', 'identifier': '-evil'},
                             {'registryType': 'npm', 'identifier': 'has space'},
                             {'registryType': 'npm', 'identifier': 'sse-pkg', 'transport': {'type': 'sse'}},
                             {'registryType': 'npm', 'identifier': 'str-transport', 'transport': 'stdio'},
                             {'registryType': 'cargo', 'identifier': 'rusty'}]},
     '_meta': {'io.modelcontextprotocol.registry/official': {'updatedAt': '2026-01-02T03:04:05Z',
                                                              'status': 'deprecated'}}},
    _server('io.docker/thing_server', packages=[
        {'registryType': 'oci', 'identifier': 'docker.io/acme/thing', 'version': '2',
         'environmentVariables': [{'name': 'TOKEN', 'isSecret': True}],
         'runtimeArguments': [{'type': 'named', 'name': '-e', 'value': 'PASS_ME'},
                              {'type': 'named', 'name': '--env', 'value': 'SET=on {flag}'},
                              {'type': 'named', 'name': '-v', 'value': '/:/host'},
                              {'type': 'named', 'name': '-e', 'value': 'TOKEN=dup'},
                              {'type': 'named', 'name': '-e', 'value': 'PASS_ME'}]},
        {'registryType': 'oci', 'identifier': 'ghcr.io/a/b:tag', 'version': '9'}]),
    _server('remote-only', remotes=[
        {'type': 'streamable-http', 'url': 'https://API.Example.com:8443/mcp', 'headers': [
            {'name': 'Authorization', 'value': 'Bearer {key}', 'isRequired': True,
             'variables': {'key': {'isSecret': True, 'description': 'Key'}}}]},
        {'type': 'sse', 'url': 'https://sse.example/events'},
        {'type': 'streamable-http', 'url': 'http://insecure.example'},
        {'type': 'websocket', 'url': 'https://ws.example'}]),
    _server('io.github.x/too-many', packages=[
        {'registryType': 'npm', 'identifier': 'many', 'packageArguments': [{'value': str(i)} for i in range(41)]}]),
    _server('Ünïcödé/Prefix-MCP-Server-Ärger-mcp', packages=[{'registryType': 'npm', 'identifier': 'paket-ü'}]),
    _server('mcp-server-plain', packages=[{'registryType': 'npm', 'identifier': 'plain', 'version': 3}]),
    _server('nothing-runs', packages=[{'registryType': 'npm', 'identifier': ''}]),
    {'server': 'not a dict'}, {'server': {'name': 5}}, 'junk',
]}

PYTHON = r'''
import dataclasses, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import mcp_catalog, mcp_registry
task = json.loads(sys.stdin.read())
out = {}
data = task['registry']
out['parse'] = {'servers': [dataclasses.asdict(s) for s in mcp_registry.parse(data)],
                'kept': [mcp_registry._kept(item) for item in data['servers']]}
out['fill'] = []
for case in task['fill']:
    filled = mcp_registry.fill(case['entry'], case['values'])
    dropped = mcp_registry.drop_unfilled(filled, case['optional'])
    out['fill'].append({'filled': filled, 'dropped': dropped, 'unfilled': mcp_registry.unfilled(dropped),
                        'secret': mcp_registry.secret_in_args(case['entry'], case['secrets'])})
out['search'] = []
for case in task['search']:
    found = mcp_registry.search_list(case['query'], case['offset'], path=Path(case['list']), with_total=True)
    out['search'].append({'found': None if found is None else
                          [[dataclasses.asdict(s) for s in found[0]], found[1], found[2]]})
versions = task['versions']
out['picks'] = {'servers': [dataclasses.asdict(mcp_catalog.resolve(
    p, ask=lambda kind, name: versions.get(f'{kind}:{name}', ''))) for p in mcp_catalog.PICKS]}
out['picks_data'] = [dataclasses.asdict(p) for p in mcp_catalog.PICKS]
out['refresh'] = []
for case in task['refresh']:
    asked = []
    def fetch(url, **_kw):
        asked.append(url)
        if url not in case['pages']:
            raise RuntimeError('offline')
        return case['pages'][url]
    ok = mcp_registry.refresh_list(Path(case['list']), now=case['now'], fetch=fetch)
    out['refresh'].append({'ok': ok, 'asked': asked, 'file': Path(case['list']).read_text() if Path(case['list']).exists() else None})
print(json.dumps(out))
'''


def _page(names, cursor=''):
    return {'servers': [_server(n, description=f'about {n}', packages=[{'registryType': 'npm', 'identifier': n}])
                        for n in names], 'metadata': {'nextCursor': cursor} if cursor else {}}


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartMcpCatalogParityTest(unittest.TestCase):
    def test_same_catalog_registry_and_list(self):
        import mcp_registry
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            tools = temp / 'bin'
            tools.mkdir()
            (tools / 'npx').write_text('#!/bin/sh\n')
            (tools / 'npx').chmod(0o755)
            env = {**os.environ, 'PATH': str(tools), 'HOME': str(temp), 'TZ': 'Europe/Berlin', 'LANG': 'C.UTF-8'}
            # Options from the registry answer, as the form fills them.
            sys.path.insert(0, str(ROOT))
            os.environ['PATH'], old_path = str(tools), os.environ['PATH']
            try:
                options = [o for s in mcp_registry.parse(REGISTRY) for o in s.options]
            finally:
                os.environ['PATH'] = old_path
            fill = []
            for option in options:
                names = [n.name for n in option.needs]
                fill.append({'entry': option.entry, 'values': {n: f'v-{n}' for n in names[::2]},
                             'optional': names[1::2], 'secrets': [n.name for n in option.needs if n.secret]})
            fill.append({'entry': {'transport': 'stdio', 'command': 'docker', 'args': ['run', '-e', 'TOKEN', '-e', 'X',
                                                                                        '--flag', '{opt}', 'img'],
                                   'env': {'TOKEN': '{tok}', 'X': '1'}, 'url': '', 'headers': {'H': '{tok}'}},
                         'values': {}, 'optional': ['tok', 'opt'], 'secrets': ['tok', 'nope']})
            # A saved list to search (statuses, odd times, names that hold the query first).
            listed = {f'io.github.s/srv-{i:02d}': {
                'server': {'name': f'io.github.s/srv-{i:02d}', 'title': f'Title {i}',
                           'description': 'git tools' if i % 3 == 0 else 'file system',
                           'packages': [{'registryType': 'npm', 'identifier': f'srv{i}'}]},
                '_meta': {'io.modelcontextprotocol.registry/official': {
                    'updatedAt': ['2026-03-0%dT10:00:00Z' % (1 + i % 9), '2026-1-5T1:2:3', 'garbage', None][i % 4],
                    'status': ['active', '', 'deleted', 'active'][i % 4]}}} for i in range(45)}
            listed['git-first'] = {'server': {'name': 'git-first', 'packages': [{'registryType': 'npm',
                                                                                 'identifier': 'g'}]}}
            saved = temp / 'list.json'
            saved.write_text(json.dumps({'fetched': '2026-10-01T00:00:00Z', 'checked': 1, 'servers': listed}))
            unfetched = temp / 'unfetched.json'
            unfetched.write_text(json.dumps({'fetched': '', 'servers': listed}))
            search = [{'query': q, 'offset': o, 'list': str(saved)} for q, o in
                      [('', 0), ('', 20), ('', 40), ('git', 0), ('FILE  sys', 0), ('zzz', 0), ('srv', 100)]]
            search += [{'query': 'git', 'offset': 0, 'list': str(unfetched)},
                       {'query': 'git', 'offset': 0, 'list': str(temp / 'missing.json')}]
            versions = {'npm:@modelcontextprotocol/server-filesystem': '2026.1.14', 'pypi:mcp-server-git': '0.6.2',
                        'npm:@playwright/mcp': 'bad version!', 'npm:@upstash/context7-mcp': '1.0.0'}
            api = mcp_registry.API
            first = f'{api}?limit=100&version=latest'
            refresh = []
            for side in ('py', 'dart'):
                fresh, resumed, recent, offline = (temp / side / n for n in ('fresh.json', 'resumed.json',
                                                                              'recent.json', 'offline.json'))
                fresh.parent.mkdir()
                resumed.write_text(json.dumps({'fetched': '2026-09-01T00:00:00Z', 'checked': 5, 'servers': {
                    'old': {'server': {'name': 'old', 'extra': 'dropped', 'packages': []}}},
                    'resume': {'since': '2026-09-01T00:00:00Z', 'cursor': 'c1', 'started': '2026-10-01T00:00:00Z'}}))
                recent.write_text(json.dumps({'fetched': 'x', 'checked': 1000.0, 'servers': {}}))
                refresh.append([
                    {'list': str(fresh), 'now': 1800000000.5, 'pages': {
                        first: _page(['a', 'b'], 'c1'), f'{first}&cursor=c1': _page(['c'], 'c1')}},
                    {'list': str(resumed), 'now': 1800000000.0, 'pages': {
                        f'{api}?limit=100&version=latest&updated_since=2026-09-01T00%3A00%3A00Z&cursor=c1':
                            _page(['d', 'old'], '')}},
                    {'list': str(recent), 'now': 2000.0, 'pages': {}},
                    {'list': str(offline), 'now': 5.0, 'pages': {}},
                ])
            task = {'registry': REGISTRY, 'fill': fill, 'search': search, 'versions': versions,
                    'refresh': refresh[0]}
            python = json.loads(subprocess.run([sys.executable, '-c', PYTHON, str(ROOT)], input=json.dumps(task),
                                               capture_output=True, check=True, text=True, env=env,
                                               timeout=120).stdout)
            requests = [('dev.mcpparse', {'data': REGISTRY})]
            requests += [('dev.mcpfill', case) for case in fill]
            requests += [('dev.mcpsearch', case) for case in search]
            requests += [('dev.mcppicks', {'versions': versions})]
            requests += [('dev.mcprefresh', case) for case in refresh[1]]
            lines = [json.dumps({'id': i, 'protocol': 1, 'method': m, 'params': p})
                     for i, (m, p) in enumerate(requests, 1)]
            out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                  'bin/fixture_probe.dart'], input=('\n'.join(lines) + '\n').encode(),
                                 capture_output=True, cwd=ROOT / 'packages/asterism_core', timeout=300, env=env)
            replies = [json.loads(line) for line in out.stdout.splitlines() if line.startswith(b'{')]
            self.assertEqual(len(replies), len(requests), out.stderr.decode()[-2000:])
            dart = [r.get('result', r.get('error')) for r in replies]
            refreshed = []
            for case, reply in zip(refresh[1], dart[-4:]):
                path = Path(case['list'])
                refreshed.append({**reply, 'file': path.read_text() if path.exists() else None})
        self.maxDiff = None
        self.assertEqual(python['parse'], dart[0])
        self.assertEqual(python['fill'], dart[1:1 + len(fill)])
        self.assertEqual(python['search'], dart[1 + len(fill):1 + len(fill) + len(search)])
        self.assertEqual(python['picks'], dart[1 + len(fill) + len(search)])
        for py, da in zip(python['refresh'], refreshed):
            self.assertEqual({**py, 'file': py['file'] and json.loads(py['file'])},
                             {**da, 'file': da['file'] and json.loads(da['file'])})
        # The same English texts as the reference's picks.
        from_dart = {s['short'] for s in dart[1 + len(fill) + len(search)]['servers']}
        self.assertEqual(from_dart, {p['key'] for p in python['picks_data']})
        servers = {s['name']: s for s in python['parse']['servers']}
        self.assertNotIn('nothing-runs', servers)
        self.assertEqual([o['kind'] for o in servers['remote-only']['options']], ['remote', 'remote'])
        docker = servers['io.docker/thing_server']['options'][0]['entry']
        self.assertNotIn('/:/host', docker['args'])
        self.assertTrue(any(r['ok'] for r in python['refresh']))


if __name__ == '__main__':
    unittest.main()
