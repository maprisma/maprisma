"""Backend-to-worker plans on an inherited private FD, never frontend JSON."""
from __future__ import annotations

from dataclasses import asdict
import json
from pathlib import Path

import connect
import inventory

MAX_BYTES = 24 * 1024 * 1024


def encode(plan: connect.Plan, backup_root: Path) -> bytes:
    if plan.commands or plan.undo_commands or plan.files_add or plan.retire or plan.links_add or plan.links_remove:
        raise ValueError('Unsupported private plan')
    body = json.dumps({'version': 1, 'backup_root': str(backup_root), 'agent': plan.agent,
                       'runtime': plan.runtime, 'provider': plan.provider,
                       'changes': [{'path': str(c.path), 'old': c.old, 'new': c.new} for c in plan.changes],
                       'contexts': [{'runtime': asdict(rt), 'model': model, 'tokens': tokens}
                                    for rt, model, tokens in plan.contexts]}, ensure_ascii=False, allow_nan=False).encode()
    if len(body) > MAX_BYTES:
        raise ValueError('Private plan too large')
    return body


def decode(body: bytes) -> tuple[connect.Plan, Path]:
    if len(body) > MAX_BYTES:
        raise ValueError('Private plan too large')
    data = json.loads(body)
    if data.get('version') != 1 or set(data) != {'version', 'backup_root', 'agent', 'runtime', 'provider', 'changes', 'contexts'}:
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
    return connect.Plan(data['agent'], data['runtime'], data['provider'], changes=changes, contexts=contexts), root
