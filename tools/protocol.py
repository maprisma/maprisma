#!/usr/bin/env python3
"""The contract between the GUI (flutter_app) and the core (packages/maprisma_core):
packages/maprisma_core/protocol/routes.json, docs/protocol.md and flutter_app/lib/core_client.g.dart made from it.

    tools/protocol.py update [--record FILE]   find the routes (the core's names, probed without a
                                               network), keep what is written by hand, add result
                                               shapes from a recording (MAPRISMA_RECORD_PROTOCOL)
    tools/protocol.py doc                      write docs/protocol.md
    tools/protocol.py client                   write flutter_app/lib/core_client.g.dart
    tools/protocol.py check                    the contract still holds (tests/test_protocol.py)

routes.json, per route: area, kind (read · preview · change · handle), handle (the field that holds
the handle), params ({name: type}), optional (the params that may be left out), result (its shape,
or null while not described), source
(observed · manual · null) and note. "other" lists the core's dotted names that are not routes
(worker operations, file names): every name the core holds is one or the other, so a new route
cannot go unnoticed. Parameters come from routes.json (and recordings); hand-written params,
result and note are kept by update.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORE = ROOT / 'packages/maprisma_core'
ROUTES = CORE / 'protocol/routes.json'
DOC = ROOT / 'docs/protocol.md'
CLIENT = ROOT / 'flutter_app/lib/core_client.g.dart'
VERSION = 1
NAME = re.compile(r"""['"]([a-z][a-z0-9]*\.[a-z_]+)['"]""")
FILE_ENDINGS = {'json', 'toml', 'yaml', 'md', 'pdf', 'py', 'sh', 'service', 'desktop', 'txt', 'log', 'lock',
                'db', 'svg', 'png', 'zip', 'gz', 'sig', 'sha256', 'jsonl', 'dart', 'g', 'ini', 'conf', 'env',
                'html', 'js', 'css', 'gguf', 'bin', 'exe', 'part', 'tmp', 'bak', 'xml', 'so', 'ico', 'jpg',
                'old', 'new', 'ok', 'bat'}
CHANGE = re.compile(r'(^|_)(apply|install|install_file|file_install|undo|continue|discard|pin|forget|update|'
                    r'set_enabled|run|unpack|later|choose|start|stop|write|resize|cancel|release|reload|'
                    r'refresh|forget_disk|notify|popup|open_manual|seen|settings_changed|usage_refresh)$')
DART_TYPES = {'string': 'String', 'int': 'int', 'bool': 'bool', 'number': 'num'}
DART_WORDS = {'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', 'default', 'do', 'else', 'enum',
              'extends', 'false', 'final', 'finally', 'for', 'if', 'in', 'is', 'new', 'null', 'rethrow', 'return',
              'super', 'switch', 'this', 'throw', 'true', 'try', 'var', 'void', 'while', 'with'}
# Dotted names in flutter_app/lib whose area is a route area, but that name worker task
# operations passed to providers.run / TaskProgress rather than RPC routes (in "other").
GUI_NON_ROUTES = {
    'agents.halt',
    'agents.key',
    'models.download',
    'models.files',
    'models.pull',
    'models.remove',
    'models.search',
}


def _names(files) -> set[str]:
    out = set()
    for f in files:
        out |= set(NAME.findall(Path(f).read_text(errors='ignore')))
    return out


def core_names() -> set[str]:
    """The core's dotted names in the areas the GUI and the tests use (routes and others)."""
    core = _names(sorted((CORE / 'lib/src').glob('*.dart')))
    used = _names(sorted((ROOT / 'flutter_app/lib').glob('*.dart'))) | \
        _names(sorted((ROOT / 'flutter_app/test').rglob('*.dart'))) | _names(sorted((CORE / 'test').glob('*.dart')))
    areas = {n.split('.')[0] for n in used & core if n.split('.')[1] not in FILE_ENDINGS} | {'i18n'}
    return {n for n in core if n.split('.')[0] in areas and n.split('.')[1] not in FILE_ENDINGS
            and not n.endswith('_')}


def handle_routes() -> dict[str, str]:
    text = (CORE / 'lib/src/core_tasks.dart').read_text()
    block = text[text.index('const handleRoutes = {'):]
    block = block[:block.index('};')]
    return dict(re.findall(r"'([a-z.]+)': '([a-z]+)'", block))


def dispatch_names() -> set[str]:
    """The names the dispatcher itself knows: its route sets and the names its branches compare."""
    core = (CORE / 'lib/src/core.dart').read_text()
    body = core[core.index('Map<String, dynamic> _dispatch('):core.index('String handle(String frame)')]
    sets = ''
    for name, path in (('portedRoutes', 'core.dart'), ('readOnlyRoutes', 'read_service.dart')):
        text = (CORE / 'lib/src' / path).read_text()
        start = text.index(f'const {name} = ')
        sets += text[start:text.index('};', start)]
    return set(NAME.findall(body + sets)) | set(handle_routes())


def probe(names: list[str]) -> list[str]:
    """The names the core serves (tool/route_probe.dart), run without a network."""
    unshare = shutil.which('unshare')
    if unshare is None:
        sys.exit('unshare is needed: the probe must not reach the network')
    sys.path.insert(0, str(ROOT / 'tools'))
    from dart_sdk import resolve_dart
    done = subprocess.run([unshare, '-rn', resolve_dart(), 'run', 'tool/route_probe.dart'], cwd=CORE,
                          input=json.dumps(names) + '\n', capture_output=True, text=True, timeout=300)
    if done.returncode != 0:
        sys.exit(f'route probe failed: {done.stderr[-500:]}')
    return json.loads(done.stdout.strip().splitlines()[-1])


def gui_names() -> set[str]:
    """Every quoted dotted name in flutter_app/lib (core_client.g.dart excluded)."""
    return _names(f for f in sorted((ROOT / 'flutter_app/lib').glob('*.dart')) if f != CLIENT)


def gui_calls() -> dict[str, dict[str, str]]:
    """{route: {param: '?'}} from the GUI's literal calls (its parameter names, when written there)."""
    out: dict[str, dict[str, str]] = {}
    call = re.compile(r"\.call\(\s*'([a-z][a-z0-9]*\.[a-z_]+)'(?:\s*,\s*\{(.*?)\}\s*[,)])?", re.S)
    for f in sorted((ROOT / 'flutter_app/lib').glob('*.dart')):
        if f == CLIENT:
            continue
        for method, body in call.findall(f.read_text()):
            params = out.setdefault(method, {})
            for key in re.findall(r"'([a-z_]+)'\s*:", body or ''):
                params.setdefault(key, '?')
    return out


def kind(method: str, handles: dict) -> str:
    if method in handles:
        return 'handle'
    leaf = method.split('.', 1)[1]
    if leaf == 'preview' or leaf.endswith('_preview'):
        return 'preview'
    return 'change' if CHANGE.search(leaf) else 'read'


def shape(value):
    if isinstance(value, dict):
        return {k: shape(v) for k, v in sorted(value.items())}
    if isinstance(value, list):
        merged = None
        for item in value[:50]:
            merged = merge(merged, shape(item))
        return [merged] if merged is not None else []
    return {bool: 'bool', int: 'int', float: 'number', str: 'string', type(None): 'null'}.get(type(value), '?')


def merge(a, b):
    """Two observed shapes as one: keys of both, differing scalars as 'a|b'."""
    if a is None:
        return b
    if b is None or a == b:
        return a
    if isinstance(a, dict) and isinstance(b, dict):
        return {k: merge(a.get(k), b.get(k)) for k in sorted(set(a) | set(b))}
    if isinstance(a, list) and isinstance(b, list):
        return [merge(a[0] if a else None, b[0] if b else None)] if a or b else []
    if isinstance(a, str) and isinstance(b, str):
        return '|'.join(sorted(set(a.split('|')) | set(b.split('|'))))
    return '?'


def load() -> dict:
    return json.loads(ROUTES.read_text()) if ROUTES.exists() else {'protocol': VERSION, 'routes': {}, 'other': []}


def save(data: dict) -> None:
    ROUTES.parent.mkdir(exist_ok=True)
    ROUTES.write_text(json.dumps(data, indent=1, ensure_ascii=False, sort_keys=True) + '\n')


def update(record: Path | None) -> None:
    data = load()
    names = sorted(core_names())
    handles = handle_routes()
    # Served (the probe) and named by the dispatcher: a prefix branch (addons.*) also answers for
    # its worker operations' names, which are not routes.
    served = (set(probe(names)) & dispatch_names()) | set(handles)
    observed: dict[str, dict] = {}
    if record is not None:
        for line in record.read_text().splitlines():
            entry = json.loads(line)
            if 'result' not in entry:     # a refused request says nothing about the route's parameters
                continue
            seen = observed.setdefault(entry['method'], {'params': None, 'result': None})
            seen['params'] = merge(seen['params'], shape(entry['params']))
            seen['result'] = merge(seen['result'], shape(entry['result']))
    routes = {}
    for method in sorted(served):
        old = data['routes'].get(method, {})
        params = dict(old.get('params') or {})
        seen = observed.get(method, {})
        for key, value in (seen.get('params') or {}).items():
            if key != '__contract_probe__' and params.get(key, '?') == '?':
                params[key] = value
        result, source = old.get('result'), old.get('source')
        if source != 'manual' and seen.get('result') is not None:
            result, source = merge(result if source == 'observed' else None, seen['result']), 'observed'
        routes[method] = {'area': method.split('.')[0], 'kind': kind(method, handles),
                          **({'handle': handles[method]} if method in handles else {}),
                          'params': params, **({'optional': old['optional']} if old.get('optional') else {}),
                          'result': result, 'source': source, 'note': old.get('note', '')}
    data = {'protocol': data.get('protocol', VERSION), 'routes': routes,
            'other': sorted(set(names) - served)}
    save(data)
    described = sum(1 for r in routes.values() if r['result'] is not None)
    print(f'{len(routes)} routes ({described} with a result shape), {len(data["other"])} other names')


def doc_text(data: dict) -> str:
    out = ['# Maprisma protocol', '',
           'The contract between the GUI (`flutter_app`) and the core (`packages/maprisma_core`). Generated by',
           '`tools/protocol.py doc` from `packages/maprisma_core/protocol/routes.json`; edit that file, not this one.',
           '',
           f'Protocol version **{data["protocol"]}**. A request is `{{"id", "protocol", "method", "params"}}`, the answer',
           '`{"id", "result"}` or `{"id", "error": {"code"}}`. Kinds: **read** changes nothing; **preview** returns a plan',
           'and changes nothing; **change** changes files or state (after a preview where there is one); **handle**',
           'takes the handle a preview or start returned (`plan`, `undo`, `task`, `session`).',
           '', '`?` marks a parameter type or a result shape not described yet: describe it when you touch the route.',
           'A parameter written `name?` may be left out.', '']
    routes = data['routes']
    for area in sorted({r['area'] for r in routes.values()}):
        out += [f'## {area}', '', '| Route | Kind | Params | Result |', '|---|---|---|---|']
        for method in sorted(m for m, r in routes.items() if r['area'] == area):
            r = routes[method]
            params = ', '.join(f'`{k}{"?" if k in r.get("optional", ()) else ""}`: '
                               f'{v if isinstance(v, str) else json.dumps(v)}'
                               for k, v in sorted(r['params'].items())) or '—'
            if r['result'] is None:
                result = '?'
            elif isinstance(r['result'], dict):
                result = ', '.join(f'`{k}`' for k in sorted(r['result'])) or '{}'
            else:
                result = f'`{json.dumps(r["result"])}`'
            note = f' {r["note"]}' if r.get('note') else ''
            out.append(f'| `{method}` | {r["kind"]}{" (" + r["handle"] + ")" if "handle" in r else ""} | '
                       f'{params} | {result}{note} |')
        out.append('')
    return '\n'.join(out)


def _camel(name: str) -> str:
    parts = re.split(r'[._]+', name)
    word = parts[0] + ''.join(p.capitalize() for p in parts[1:])
    return f'{word}Value' if word in DART_WORDS else word


def _dart_type(spec, optional: bool) -> str:
    base = DART_TYPES.get(spec, 'Object?') if isinstance(spec, str) else 'Object?'
    if base == 'Object?':
        return base
    return f'{base}?' if optional else base


def client_text(data: dict) -> str:
    out = [
        '// Generated from packages/maprisma_core/protocol/routes.json by tools/protocol.py client.',
        '// Do not edit by hand.',
        '',
        "import 'service_transport.dart';",
        '',
        'class _CallTransport implements ServiceTransport {',
        '  const _CallTransport(this._call);',
        '',
        '  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)',
        '  _call;',
        '',
        '  @override',
        '  bool get isConnected => true;',
        '',
        '  @override',
        '  Future<Map<String, dynamic>> call(',
        '    String method, [',
        '    Map<String, dynamic> params = const {},',
        '  ]) => _call(method, params);',
        '',
        '  @override',
        '  void dispose() {}',
        '',
        '  @override',
        '  Future<void> shutdown() async {}',
        '}',
        '',
        'class CoreClient {',
        '  const CoreClient(this.transport);',
        '',
        '  CoreClient.fromCall(',
        '    Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) call,',
        '  ) : transport = _CallTransport(call);',
        '',
        '  final ServiceTransport transport;',
    ]
    routes = data['routes']
    for method in sorted(routes):
        r = routes[method]
        name = _camel(method)
        params = dict(r['params'])
        if r['kind'] == 'handle' and 'handle' in r:
            params[r['handle']] = 'string'
        out.append('')
        if not params:
            sig = f'  Future<Map<String, dynamic>> {name}(['
            one = f'  Future<Map<String, dynamic>> {name}([Map<String, dynamic> params = const {{}}]) =>'
            call_line = f"      transport.call('{method}', params);"
            if len(one) <= 80:
                out.append(one)
                out.append(call_line)
            else:
                out.extend([
                    sig,
                    '    Map<String, dynamic> params = const {},',
                    f"  ]) => transport.call('{method}', params);",
                ])
            continue
        opt = set(r.get('optional', ()))
        arg_parts = []
        map_parts = []
        for k in sorted(params):
            arg_name = _camel(k)
            is_opt = k in opt and k != r.get('handle')
            dtype = _dart_type(params[k], is_opt)
            if is_opt:
                arg_parts.append(f'{dtype} {arg_name}')
                map_parts.append(f"'{k}': ?{arg_name}")
            else:
                arg_parts.append(f'required {dtype} {arg_name}')
                map_parts.append(f"'{k}': {arg_name}")
        args_inline = '{' + ', '.join(arg_parts) + '}'
        map_inline = '{' + ', '.join(map_parts) + '}'
        single = f"  Future<Map<String, dynamic>> {name}({args_inline}) => transport.call('{method}', {map_inline});"
        sig_single = f'  Future<Map<String, dynamic>> {name}({args_inline}) =>'
        call_single = f"      transport.call('{method}', {map_inline});"
        if len(single) <= 80:
            out.append(single)
        elif len(sig_single) <= 80 and len(call_single) <= 80:
            out.append(sig_single)
            out.append(call_single)
        elif len(sig_single) <= 80:
            out.append(sig_single)
            out.append(f"      transport.call('{method}', {{")
            for mp in map_parts:
                out.append(f'        {mp},')
            out.append('      });')
        else:
            out.append(f'  Future<Map<String, dynamic>> {name}({{')
            for ap in arg_parts:
                out.append(f'    {ap},')
            tail_inline = f"  }}) => transport.call('{method}', {map_inline});"
            if len(tail_inline) <= 80:
                out.append(tail_inline)
            else:
                out.append(f"  }}) => transport.call('{method}', {{")
                for mp in map_parts:
                    out.append(f'    {mp},')
                out.append('  });')
    out.append('}')
    return '\n'.join(out)


def check() -> list[str]:
    """What breaks the contract (static, fast)."""
    data = load()
    routes, other = set(data['routes']), set(data['other'])
    areas = {r['area'] for r in data['routes'].values()}
    problems = []
    unknown = core_names() - routes - other
    if unknown:
        problems.append(f'new dotted names in the core, neither route nor other (tools/protocol.py update): '
                        f'{sorted(unknown)}')
    gone = routes - dispatch_names()
    if gone:
        problems.append(f'routes no longer in the core: {sorted(gone)}')
    called = {n for n in gui_names() if n.split('.')[0] in areas} - routes - GUI_NON_ROUTES
    if called:
        problems.append(f'the GUI calls routes the contract does not have: {sorted(called)}')
    calls = gui_calls()
    if calls:
        problems.append(f'the GUI calls routes directly instead of CoreClient: {sorted(calls)}')
    if not DOC.exists() or DOC.read_text() != doc_text(data) + '\n':
        problems.append('docs/protocol.md is not up to date (tools/protocol.py doc)')
    if not CLIENT.exists() or CLIENT.read_text() != client_text(data) + '\n':
        problems.append('flutter_app/lib/core_client.g.dart is not up to date (tools/protocol.py client)')
    return problems


def main(argv) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest='command', required=True)
    up = sub.add_parser('update')
    up.add_argument('--record', type=Path)
    sub.add_parser('doc')
    sub.add_parser('client')
    sub.add_parser('check')
    args = parser.parse_args(argv)
    if args.command == 'update':
        update(args.record)
        data = load()
        DOC.write_text(doc_text(data) + '\n')
        CLIENT.write_text(client_text(data) + '\n')
    elif args.command == 'doc':
        DOC.write_text(doc_text(load()) + '\n')
    elif args.command == 'client':
        CLIENT.write_text(client_text(load()) + '\n')
    else:
        problems = check()
        for p in problems:
            print(p)
        return 1 if problems else 0
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
