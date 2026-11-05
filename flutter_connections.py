"""Private plans for discovered MCP/skill connections; configuration stays in Python.

Even a diff's context lines can contain unrelated API keys. Flutter receives a
structured file/change summary, never raw configuration, env/header values or
the plan object. Apply and Undo accept opaque handles only.
"""
from __future__ import annotations

import difflib
from pathlib import Path
import time
import uuid

import agents
import connect
import inventory
import mcp_ctl
import skills_ctl
import llm_engine


class Connections:
    def __init__(self, backup_root: Path | None = None):
        self.plans: dict[str, tuple[float, connect.Plan]] = {}
        self.undos: dict[str, Path] = {}
        self.backup_root = backup_root or connect.BACKUP_ROOT

    def snapshot(self) -> dict:
        catalog = agents.list_agents()
        inv = inventory.collect(catalog)
        return {
            'agents': [{'command': a.command, 'name': a.name, 'provider': a.command in connect.SUPPORTED,
                        'mcp': mcp_ctl.supported(a.command),
                        'skills': bool(skills_ctl.own_dir(a.command))} for a in catalog if a.installed],
            'mcp': [{'id': s.id, 'name': s.name, 'kind': s.kind, 'target': s.target,
                     'agents': s.agents} for s in inv.mcp],
            'skills': [{'id': s.path, 'name': s.path, 'skills': s.skills, 'agents': s.agents}
                       for s in inv.skill_sets],
            'providers': [{'id': rt.key, 'name': rt.name, 'address': rt.address, 'models': connect.chat_models(rt.models),
                           'agents': [a.command for a in catalog if a.installed and a.command in connect.SUPPORTED
                                      and connect.is_connected(a.command, rt.key)]}
                          for rt in inv.runtimes if rt.installed and rt.key in connect.KEYS],
        }

    def preview(self, params: dict) -> dict:
        fields = {'kind', 'command', 'item', 'remove'}
        if params.get('kind') == 'provider':
            fields |= {'model', 'use_now'} | ({'name'} if 'name' in params else set())
        if set(params) != fields or params['kind'] not in ('mcp', 'skills', 'provider') \
                or type(params['remove']) is not bool or not isinstance(params['command'], str) \
                or not isinstance(params['item'], str):
            raise ValueError('Invalid connection request')
        catalog = agents.list_agents()
        command = params['command']
        if not any(a.command == command and a.installed for a in catalog):
            raise ValueError('Agent unavailable')
        inv = inventory.collect(catalog)
        if params['kind'] == 'provider':
            if command not in connect.SUPPORTED or type(params['use_now']) is not bool or not isinstance(params['model'], str):
                raise ValueError('Agent provider configuration unavailable')
            rt = next((rt for rt in inv.runtimes if rt.key == params['item'] and rt.installed and rt.key in connect.KEYS), None)
            if rt is None:
                raise ValueError('Provider unavailable')
            model = params['model']
            if not params['remove'] and ((model and (not llm_engine.MODEL_KEY.fullmatch(model) or model not in connect.chat_models(rt.models)))
                                        or (params['use_now'] and not model)):
                raise ValueError('Choose an available chat model')
            name = params.get('name')
            if name is not None:      # the agent's own entry for this LLM, by its own name (Repair of a moved one)
                import agent_details
                known = agent_details.details_for(command).providers
                if not isinstance(name, str) or not any(p.name == name and p.local for p in known):
                    raise ValueError('Provider unavailable')
            plan = connect.plan(command, rt, '' if params['remove'] else model,
                                False if params['remove'] else params['use_now'], remove=params['remove'],
                                **({'name': name} if name is not None else {}))
        elif params['kind'] == 'mcp':
            # The map's id: the name, or name~2 for another server of that name.
            server = next((item for item in inv.mcp if item.id == params['item']), None)
            if server is None or not mcp_ctl.supported(command):
                raise ValueError('MCP server unavailable')
            plan = mcp_ctl.plan(command, server.name, sources=server.agents, remove=params['remove'],
                                library_key=server.library or None)
        else:
            folder = next((item for item in inv.skill_sets if item.path == params['item']), None)
            if folder is None or not skills_ctl.own_dir(command):
                raise ValueError('Skill folder unavailable')
            plan = skills_ctl.plan(command, folder.path, remove=params['remove'])
        result = self.keep(plan)
        result.update({'kind': params['kind'], 'command': command, 'item': params['item'], 'remove': params['remove']})
        return result

    def forget_preview(self, params: dict) -> dict:
        """A known server no agent uses leaves the list, with a preview and Undo."""
        import mcp_library
        if set(params) != {'name'} or not isinstance(params['name'], str):
            raise ValueError('Invalid request')
        name = params['name']          # the map's id (name, or name~2): the one known server it is
        inv = inventory.collect(agents.list_agents())
        server = next((s for s in inv.mcp if s.id == name), None)
        if server is None or not server.library or server.library not in mcp_library.load() or server.agents:
            raise ValueError('MCP server unavailable')
        change = mcp_library.change(server.library, None)
        result = self.keep(connect.Plan('', '', server.library, changes=[change]))
        result.update({'kind': 'mcp', 'item': name, 'remove': True, 'focus': []})
        return result

    def author_preview(self, params: dict) -> dict:
        """New definitions are data saved to adapter-owned files, never executed."""
        import os, re
        if not isinstance(params, dict) or params.get('kind') not in ('mcp', 'skills'):
            raise ValueError('Invalid authoring request')
        kind = params['kind']
        fields = {'kind', 'agents', 'name', 'entry'} if kind == 'mcp' else {'kind', 'agents', 'folder'}
        if set(params) != fields:
            raise ValueError('Unexpected authoring fields')
        selected = params['agents']
        if (not isinstance(selected, list) or not 1 <= len(selected) <= 32
                or any(not isinstance(c, str) or not c or len(c) > 128 for c in selected)
                or len(set(selected)) != len(selected)):
            raise ValueError('Choose installed agents')
        catalog = {a.command: a for a in agents.list_agents() if a.installed}
        if any(c not in catalog for c in selected):
            raise ValueError('Agent unavailable')
        plans, notes = [], []
        if kind == 'mcp':
            name, entry = params['name'], params['entry']
            if (not isinstance(name, str) or not mcp_ctl.NAME_RE.fullmatch(name)
                    or not isinstance(entry, dict)
                    or set(entry) != {'transport', 'command', 'args', 'url', 'env', 'headers'}):
                raise ValueError('Invalid server definition')
            if (any(not isinstance(entry[k], str) or len(entry[k]) > 4096 or '\0' in entry[k]
                    for k in ('transport', 'command', 'url'))
                    or not isinstance(entry['args'], list) or len(entry['args']) > 128
                    or any(not isinstance(a, str) or len(a) > 4096 or '\0' in a for a in entry['args'])):
                raise ValueError('Invalid server arguments')
            for field in ('env', 'headers'):
                values = entry[field]
                if (not isinstance(values, dict) or len(values) > 64
                        or any(not isinstance(k, str) or not isinstance(v, str) or len(v) > 8192
                               or any(char in v for char in ('\0', '\n', '\r'))
                               or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_-]{0,127}', k) for k, v in values.items())):
                    raise ValueError('Invalid server fields')
            if any(char in entry['url'] for char in ('\n', '\r')):
                raise ValueError('Invalid server address')
            clean = mcp_ctl.check_entry(entry)
            if clean['transport'] == 'stdio' and (not clean['command'].strip() or '\r' in clean['command']):
                raise ValueError('Invalid executable name')
            if any(not mcp_ctl.supported(c) for c in selected):
                raise ValueError('MCP configuration unavailable')
            if any(mcp_ctl.is_connected(c, name) for c in selected):
                notes.append('Existing definitions with this name will be replaced for the selected agents.')
            plans = [mcp_ctl.plan(c, name, entry=clean) for c in selected]
            notes.append('Maprisma saves configuration only. Agents may start this server when they read it.')
            item = name
        else:
            folder = params['folder']
            if not isinstance(folder, str) or not folder or len(folder) > 4096 or '\0' in folder:
                raise ValueError('Choose a skill-set folder')
            source = skills_ctl.expand(folder)
            if not source.is_absolute():
                raise ValueError('Choose an absolute skill folder')
            source = source.resolve(strict=True)
            if not source.is_dir():
                raise ValueError('Choose a skill-set folder')
            # Bound the existing one-category-level discovery before its sorted reads.
            count = 0
            def bounded(directory):
                nonlocal count
                with os.scandir(directory) as entries:
                    result = []
                    for entry in entries:
                        count += 1
                        if len(result) >= 200 or count > 1000:
                            raise ValueError('Choose a smaller skill-set folder')
                        result.append(entry)
                    return result
            for entry in bounded(source):
                if not entry.name.startswith('.') and entry.is_dir() and not (Path(entry.path) / 'SKILL.md').is_file():
                    bounded(entry.path)
            if not skills_ctl.skills_of(source):
                raise ValueError('No skill folders found')
            if any(not skills_ctl.own_dir(c) for c in selected):
                raise ValueError('Skill configuration unavailable')
            plans = [skills_ctl.plan(c, str(source)) for c in selected]
            item = skills_ctl.tilde(source)
            notes.append('Skills may include scripts that agents can run.')
            notes.append('The original skill files stay in place. Agents read linked skills; later edits take effect there too.')
            if any(skills_ctl.reach(c, source).native for c in selected):
                notes.append('Some agents already read this folder automatically; their native access is unchanged.')
        result = self.keep(connect.merge(plans))
        result.update({'kind': kind, 'item': item, 'agents': [catalog[c].name for c in selected],
                       'notes': notes, 'agent_commands': list(selected)})
        return result

    def keep(self, plan: connect.Plan) -> dict:
        for field in ('links_add', 'links_remove'):
            unique = {}
            for link, target in getattr(plan, field):
                if link in unique and unique[link] != target:
                    raise ValueError('Conflicting skill names')
                unique[link] = target
            if len(unique) > 200:
                raise ValueError('Too many skill links; select fewer agents or skills')
            setattr(plan, field, list(unique.items()))
        if plan.commands or plan.undo_commands or plan.files_add or plan.retire:
            raise ValueError('This connection needs a background operation')
        if sum(len(c.old.encode()) + len(c.new.encode()) for c in plan.changes) > 8 * 1024 * 1024:
            raise ValueError('Connection preview too large')
        now = time.monotonic()
        self.plans = {key: value for key, value in self.plans.items() if now - value[0] < 600}
        while len(self.plans) >= 8:
            self.plans.pop(next(iter(self.plans)))
        ident = uuid.uuid4().hex
        self.plans[ident] = (now, plan)
        files = []
        for change in plan.changes:
            added = removed = 0
            for tag, i, j, a, b in difflib.SequenceMatcher(None, change.old.splitlines(), change.new.splitlines()).get_opcodes():
                if tag in ('replace', 'delete'):
                    removed += j - i
                if tag in ('replace', 'insert'):
                    added += b - a
            files.append({'path': connect.tilde(change.path), 'added': added, 'removed': removed})
        return {'plan': ident, 'empty': plan.empty() and not plan.contexts, 'files': files,
                'contexts': [{'provider': rt.name, 'model': model, 'tokens': tokens} for rt, model, tokens in plan.contexts],
                'links_add': [[connect.tilde(p), connect.tilde(t)] for p, t in plan.links_add],
                'links_remove': [[connect.tilde(p), connect.tilde(t)] for p, t in plan.links_remove]}

    def apply(self, ident: str, queue=None) -> dict:
        if ident not in self.plans:
            raise ValueError('Unknown connection preview')
        created, plan = self.plans[ident]
        if time.monotonic() - created >= 600:
            raise ValueError('Connection preview expired')
        if plan.empty() and not plan.contexts and not getattr(plan, 'model_actions', []):
            del self.plans[ident]
            return {'ok': True, 'undo': None}
        if queue is not None or plan.runtime or plan.contexts or plan.model_actions:
            if queue is None:
                raise ValueError('This connection requires a worker')
            result = queue(plan, self.backup_root, self.register_backup)
            del self.plans[ident]
            return result
        backup = connect.apply(plan, backup_root=self.backup_root)
        result = self.register_backup({'backup': str(backup)})
        del self.plans[ident]
        return result

    def register_backup(self, result: dict) -> dict:
        if set(result) not in ({'backup'}, {'backup', 'context_failures'}) or not isinstance(result['backup'], str):
            raise ValueError('Invalid private result')
        failures = result.get('context_failures', 0)
        if type(failures) is not int or failures < 0:
            raise ValueError('Invalid context result')
        backup = Path(result['backup'])
        if backup.is_symlink() or not backup.is_dir() or backup.parent.resolve() != self.backup_root.resolve():
            raise ValueError('Backup outside connection storage')
        token = uuid.uuid4().hex
        while len(self.undos) >= 16:
            self.undos.pop(next(iter(self.undos)))
        self.undos[token] = backup
        # choice_failures: the Dart core's provider choices (Plan.choices) that could not follow the
        # files; this reference has none, so always 0 (review 063 round 3 #2).
        return {'ok': True, 'undo': token, 'context_failures': failures, 'choice_failures': 0}

    def undo(self, ident: str) -> dict:
        if ident not in self.undos:
            raise ValueError('Unknown Undo handle')
        folder = self.undos[ident]
        restored = connect.undo(folder)
        if restored:
            del self.undos[ident]
        return {'ok': True, 'restored': [connect.tilde(path) for path in restored], 'choice_failures': 0}
