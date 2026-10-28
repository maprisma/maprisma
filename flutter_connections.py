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
            'mcp': [{'id': s.name, 'name': s.name, 'kind': s.kind, 'target': s.target,
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
            fields |= {'model', 'use_now'}
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
            plan = connect.plan(command, rt, '' if params['remove'] else model,
                                False if params['remove'] else params['use_now'], remove=params['remove'])
        elif params['kind'] == 'mcp':
            server = next((item for item in inv.mcp if item.name == params['item']), None)
            if server is None or not mcp_ctl.supported(command):
                raise ValueError('MCP server unavailable')
            plan = mcp_ctl.plan(command, server.name, sources=server.agents, remove=params['remove'])
        else:
            folder = next((item for item in inv.skill_sets if item.path == params['item']), None)
            if folder is None or not skills_ctl.own_dir(command):
                raise ValueError('Skill folder unavailable')
            plan = skills_ctl.plan(command, folder.path, remove=params['remove'])
        result = self.keep(plan)
        result.update({'kind': params['kind'], 'command': command, 'item': params['item'], 'remove': params['remove']})
        return result

    def keep(self, plan: connect.Plan) -> dict:
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
        if plan.empty() and not plan.contexts:
            del self.plans[ident]
            return {'ok': True, 'undo': None}
        if queue is not None or plan.runtime or plan.contexts:
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
        return {'ok': True, 'undo': token, 'context_failures': failures}

    def undo(self, ident: str) -> dict:
        if ident not in self.undos:
            raise ValueError('Unknown Undo handle')
        folder = self.undos[ident]
        restored = connect.undo(folder)
        if restored:
            del self.undos[ident]
        return {'ok': True, 'restored': [connect.tilde(path) for path in restored]}
