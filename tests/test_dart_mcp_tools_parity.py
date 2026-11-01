"""Development parity: asking an MCP server for its tools (mcp_tools.ask) in the Python reference and
the Dart core, against fixture servers: stdio ones (pages, prompts, noise on stdout, errors, a server
that dies, a huge cursor, endless pages, its environment and folder) and a local streamable-HTTP one
(a session id, an event-stream answer, the entry's headers). Skipped without a native Dart SDK."""
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
try:
    from dart_sdk import resolve_dart
    DART = resolve_dart()
except (OSError, ValueError, RuntimeError):
    DART = None

SERVER = r'''
import json, os, sys
mode = sys.argv[1]
print("starting up, not JSON", flush=True)
def say(message):
    print(json.dumps(message), flush=True)
for line in sys.stdin:
    q = json.loads(line)
    m, i = q.get("method"), q.get("id")
    if m == "initialize":
        if mode == "init-error":
            say({"jsonrpc": "2.0", "id": i, "error": {"code": -1, "message": "nope " * 80}}); continue
        if mode == "dies":
            sys.exit(3)
        caps = {"tools": {}, **({"prompts": {}} if mode in ("ok", "prompt-error") else {})}
        say({"jsonrpc": "2.0", "id": 7, "result": {"wrong": "id"}})
        say({"jsonrpc": "2.0", "id": i, "result": {"capabilities": caps, "serverInfo": {
            "name": os.environ.get("FIXTURE_NAME", "fake") + " " + "x" * 70, "version": 1.5 if mode == "ok" else os.getcwd()}}})
    elif m == "tools/list":
        cursor = (q.get("params") or {}).get("cursor")
        tools = [{"name": f"t{i}-{cursor}", "description": "  spaced\n\tout  text " * 30,
                  "inputSchema": {"properties": {"path": {}, "bad name": {}, "ok\n": {}, "x" * 70: {}}}},
                 {"name": 5}, "junk", {"name": "no-desc", "description": 3}]
        nxt = {"ok": "p2" if not cursor else None, "huge": "c" * 2000, "endless": f"c{i}"}.get(mode)
        say({"jsonrpc": "2.0", "id": i, "result": {"tools": tools, **({"nextCursor": nxt} if nxt else {})}})
    elif m == "prompts/list":
        if mode == "prompt-error":
            say({"jsonrpc": "2.0", "id": i, "error": "plain"}); continue
        say({"jsonrpc": "2.0", "id": i, "result": {"prompts": [
            {"name": "review", "description": "Review it", "arguments": [{"name": "file"}, {"name": "bad arg"}, 4]}]}})
'''


class _Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        q = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if self.headers.get('Authorization') != 'Bearer k':
            self.send_response(401); self.end_headers(); return
        if 'id' not in q:
            self.send_response(202); self.end_headers(); return
        if q['method'] == 'initialize':
            body = json.dumps({'jsonrpc': '2.0', 'id': q['id'], 'result': {
                'capabilities': {'prompts': {}}, 'serverInfo': {'name': 'web', 'version': '2'}}}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Mcp-Session-Id', 'sess-1')
        else:
            if self.headers.get('Mcp-Session-Id') != 'sess-1':
                self.send_response(400); self.end_headers(); return
            result = {'tools': [{'name': 'search', 'description': 'Finds'}]} if q['method'] == 'tools/list' \
                else {'prompts': []}
            body = ('event: message\ndata: {"jsonrpc":"2.0","id":0}\n\n'
                    f'data: {json.dumps({"jsonrpc": "2.0", "id": q["id"], "result": result})}\n\n').encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


PYTHON = r'''
import json, sys
sys.path.insert(0, sys.argv[1])
import mcp_tools
out = []
for entry in json.loads(sys.stdin.read()):
    try:
        out.append(mcp_tools.ask(entry))
    except Exception as error:
        out.append({'error': str(error)})
print(json.dumps(out))
'''


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartMcpToolsParityTest(unittest.TestCase):
    def test_same_tools_from_the_same_servers(self):
        web = http.server.ThreadingHTTPServer(('127.0.0.1', 0), _Handler)
        threading.Thread(target=web.serve_forever, daemon=True).start()
        self.addCleanup(web.server_close)
        self.addCleanup(web.shutdown)
        url = f'http://127.0.0.1:{web.server_address[1]}/mcp'
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            script = home / 'server.py'
            script.write_text(SERVER)

            def stdio(mode, **env):
                return {'transport': 'stdio', 'command': sys.executable, 'args': [str(script), mode],
                        'env': env, 'url': '', 'headers': {}}

            entries = [stdio('ok', FIXTURE_NAME='from-env'), stdio('prompt-error'), stdio('init-error'),
                       stdio('dies'), stdio('huge'), stdio('endless'),
                       {'transport': 'http', 'command': '', 'args': [], 'env': {}, 'url': url,
                        'headers': {'Authorization': 'Bearer k'}},
                       {'transport': 'http', 'command': '', 'args': [], 'env': {}, 'url': url,
                        'headers': {'Authorization': 'Bearer wrong'}},
                       {'transport': 'sse', 'command': '', 'args': [], 'env': {}, 'url': url, 'headers': {}}]
            env = {k: v for k, v in os.environ.items() if 'proxy' not in k.lower()}
            env.update(HOME=str(home), LANG='C.UTF-8')
            python = json.loads(subprocess.run([sys.executable, '-c', PYTHON, str(ROOT)], input=json.dumps(entries),
                                               capture_output=True, check=True, text=True, env=env,
                                               timeout=300).stdout)
            lines = [json.dumps({'id': i, 'protocol': 2, 'method': 'dev.mcptools', 'params': {'entry': e}})
                     for i, e in enumerate(entries, 1)]
            out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                  'bin/fixture_probe.dart'], input=('\n'.join(lines) + '\n').encode(),
                                 capture_output=True, cwd=ROOT / 'packages/maprisma_core', timeout=300, env=env)
            dart = [json.loads(line)['result'] for line in out.stdout.splitlines() if line.startswith(b'{')]
        self.maxDiff = None
        self.assertEqual(len(dart), len(entries), out.stderr.decode()[-2000:])
        # A program that dies: Python reads EOF ("the server stopped"); so does Dart.
        self.assertEqual(python, dart)
        ok = python[0]
        self.assertEqual(ok['server'][:9], 'from-env ')
        self.assertEqual(len(ok['tools']), 4)
        self.assertEqual(ok['prompts'][0]['params'], ['file'])
        self.assertEqual(python[1]['prompts'], [])
        self.assertTrue(python[2]['error'].startswith('nope'))
        self.assertEqual(python[6]['tools'][0]['name'], 'search')
        self.assertIn('error', python[7])
        self.assertEqual(python[8], {'error': 'an SSE server: not asked'})
        self.assertEqual(len(python[5]['tools']), 19 * 2)


if __name__ == '__main__':
    unittest.main()
