"""Backend-to-worker plans on an inherited private FD, never frontend JSON."""
from __future__ import annotations

from dataclasses import asdict
import json
from pathlib import Path

import connect
import inventory

MAX_BYTES = 24 * 1024 * 1024


def encode(plan: connect.Plan, backup_root: Path) -> bytes:
    if plan.commands or plan.undo_commands or plan.files_add or plan.retire:
        raise ValueError('Unsupported private plan')
    body = json.dumps({'version': 3, 'model_actions': getattr(plan, 'model_actions', []), 'backup_root': str(backup_root), 'agent': plan.agent,
                       'runtime': plan.runtime, 'provider': plan.provider,
                       'links_add': [[str(p), str(t)] for p, t in plan.links_add],
                       'links_remove': [[str(p), str(t)] for p, t in plan.links_remove],
                       'changes': [{'path': str(c.path), 'old': c.old, 'new': c.new} for c in plan.changes],
                       'contexts': [{'runtime': asdict(rt), 'model': model, 'tokens': tokens}
                                    for rt, model, tokens in plan.contexts]}, ensure_ascii=False, allow_nan=False).encode()
    if len(body) > MAX_BYTES:
        raise ValueError('Private plan too large')
    decode(body)
    return body


def decode(body: bytes) -> tuple[connect.Plan, Path]:
    if len(body) > MAX_BYTES:
        raise ValueError('Private plan too large')
    data = json.loads(body)
    if not isinstance(data, dict) or type(data.get('version')) is not int:
        raise ValueError('Invalid private plan')
    fields = {'version', 'backup_root', 'agent', 'runtime', 'provider', 'changes', 'contexts'}
    if data.get('version') in (2, 3):
        fields |= {'links_add', 'links_remove'}
    if data.get('version') == 3:
        fields.add('model_actions')
    if data.get('version') not in (1, 2, 3) or set(data) != fields:
        raise ValueError('Invalid private plan')
    root = Path(data['backup_root'])
    if not root.is_absolute():
        raise ValueError('Expected an absolute backup root')
    changes = []
    for change in data['changes']:
        path = Path(change['path'])
        if not path.is_absolute() or not isinstance(change['old'], str) or not isinstance(change['new'], str):
            raise ValueError('Invalid configuration change')
        changes.append(connect.Change(path, change['old'], change['new']))
    contexts = []
    for entry in data['contexts']:
        if type(entry['tokens']) is not int or entry['tokens'] <= 0 or not isinstance(entry['model'], str):
            raise ValueError('Invalid model context')
        contexts.append((inventory.Runtime(**entry['runtime']), entry['model'], entry['tokens']))
    def links(key):
        entries = data.get(key, [])
        if not isinstance(entries, list) or len(entries) > 200:
            raise ValueError('Too many skill links')
        result = []
        for entry in entries:
            if (not isinstance(entry, list) or len(entry) != 2
                    or any(not isinstance(value, str) or not value or len(value) > 4096 or '\0' in value for value in entry)):
                raise ValueError('Invalid skill link')
            link, target = map(Path, entry)
            if not link.is_absolute() or (key == 'links_add' and not target.is_absolute()):
                raise ValueError('Expected absolute skill paths')
            result.append((link, target))
        return result
    plan = connect.Plan(data['agent'], data['runtime'], data['provider'], changes=changes,
                        contexts=contexts, links_add=links('links_add'), links_remove=links('links_remove'))
    actions = data.get('model_actions', [])
    if not isinstance(actions, list) or len(actions) > 2:
        raise ValueError('Invalid model actions')
    for action in actions:
        if (not isinstance(action, dict) or set(action) != {'operation', 'key', 'model', 'agents'}
                or action['operation'] not in ('model.load', 'model.unload')
                or any(not isinstance(action[k], str) or not action[k] or len(action[k]) > 4096 for k in ('key', 'model'))
                or not isinstance(action['agents'], list) or len(action['agents']) > 32
                or any(not isinstance(c, str) or not c or len(c) > 128 for c in action['agents'])
                or len(set(action['agents'])) != len(action['agents'])):
            raise ValueError('Invalid model action')
    plan.model_actions = actions
    return plan, root
