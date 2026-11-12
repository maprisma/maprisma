#!/usr/bin/env python3
"""Export the AI helpers of the adapters for the other Maprisma apps: data/helpers.json.

Every adapter (adapters/<command>.toml) with an [ask] or a [task] is one helper, in preference
order (PREFERRED first, then the rest alphabetically). The file is installed with the app as
/usr/lib/maprisma/data/helpers.json (tools/build-release.py); its format is in docs/adapter-format.md
(The helpers export):

    {"version": 3, "helpers": [{"id": "claude", "name": "Claude Code", "command": "claude",
      "ask": {"argv": [...], "stdin": false} | null, "task": {"argv": [...]} | null,
      "verified": true}, ...]}

"{prompt}" stays a placeholder that a caller replaces as ONE argv element, never through a shell.
An [ask]'s "{effort}" (Maprisma's Thinking time) is left out: the agent's default. "verified" is
false when an entry is marked verified = false in the adapter (taken from the agent's documentation
only). An [ask] with helper = false (its tools cannot be switched off) is not exported. "version" goes up by one whenever the helpers change.

    python3 -I tools/export-helpers.py           write data/helpers.json (when it changed)
    python3 -I tools/export-helpers.py --check   exit 1 when data/helpers.json is out of date

Standard library only; it reads the TOML files and runs nothing of them.
"""
import argparse
import json
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ADAPTERS = ROOT / 'adapters'
OUTPUT = ROOT / 'data' / 'helpers.json'
PREFERRED = ('claude', 'codex', 'gemini', 'agy', 'opencode', 'cursor-agent', 'copilot')


class ExportError(ValueError):
    pass


def _argv(table: dict, where: str, command: str, drop: tuple = ()) -> list[str]:
    argv = [a for a in table.get('argv', []) if a not in drop]
    if not argv or not all(isinstance(a, str) for a in argv) or argv[0] != command:
        raise ExportError(f'{where}: argv must be texts starting with “{command}”')
    if argv.count('{prompt}') > 1 or any('{prompt}' in a and a != '{prompt}' for a in argv):
        raise ExportError(f'{where}: “{{prompt}}” at most once, as an argument of its own')
    return argv


def helper(stem: str, data: dict) -> dict | None:
    """One adapter's helper entry; None when it has neither an [ask] nor a [task]."""
    command = data.get('command')
    if command != stem:
        raise ExportError(f'{stem}.toml: command “{command}” is not its file name')
    ask = task = None
    verified = True
    if 'ask' in data and data['ask'].get('helper', True) is not False:     # helper = false: not safe for them
        argv = _argv(data['ask'], f'{stem}: ask', command, drop=('{effort}',))
        ask = {'argv': argv, 'stdin': '{prompt}' not in argv}
        verified = verified and data['ask'].get('verified', True) is not False
    if 'task' in data:
        argv = _argv(data['task'], f'{stem}: task', command)
        if '{prompt}' not in argv:
            raise ExportError(f'{stem}: task.argv needs “{{prompt}}”')
        task = {'argv': argv}
        verified = verified and data['task'].get('verified', True) is not False
    if ask is None and task is None:
        return None
    return {'id': stem, 'name': data.get('name', stem), 'command': command, 'ask': ask, 'task': task,
            'verified': verified}


def order(stem: str) -> tuple:
    return (PREFERRED.index(stem), '') if stem in PREFERRED else (len(PREFERRED), stem)


def helpers(adapters: Path = ADAPTERS) -> list[dict]:
    found = []
    for path in sorted(adapters.glob('*.toml'), key=lambda p: order(p.stem)):
        entry = helper(path.stem, tomllib.loads(path.read_text(encoding='utf-8')))
        if entry is not None:
            found.append(entry)
    return found


def export(current: dict | None, found: list[dict]) -> dict:
    """The file's content: the version kept while the helpers are the same, else one more."""
    version = current.get('version', 0) if isinstance(current, dict) else 0
    if not (isinstance(current, dict) and current.get('helpers') == found):
        version += 1
    return {'version': version, 'helpers': found}


def text(content: dict) -> str:
    return json.dumps(content, ensure_ascii=False, indent=2) + '\n'


def read(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return None


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--check', action='store_true', help='only say whether the file is up to date')
    args = parser.parse_args(argv)
    try:
        found = helpers()
    except (ExportError, tomllib.TOMLDecodeError) as error:
        print(f'export-helpers: {error}', file=sys.stderr)
        return 2
    current = read(OUTPUT)
    content = export(current, found)
    up_to_date = OUTPUT.is_file() and OUTPUT.read_text(encoding='utf-8') == text(content)
    if args.check:
        if not up_to_date:
            print(f'{OUTPUT.relative_to(ROOT)} is out of date: run tools/export-helpers.py', file=sys.stderr)
        return 0 if up_to_date else 1
    if not up_to_date:
        OUTPUT.write_text(text(content), encoding='utf-8')
        print(f'{OUTPUT.relative_to(ROOT)}: version {content["version"]}, {len(found)} helpers')
    return 0


if __name__ == '__main__':
    sys.exit(main())
