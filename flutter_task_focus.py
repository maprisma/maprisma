"""Public task anchors from existing graph facts; never scan or expose config."""
from __future__ import annotations


def resolve(graph: dict, params: dict, addon=None) -> list[str]:
    nodes = graph.get('nodes', [])
    known = {n['id'] for n in nodes}
    candidates = set()
    command = params.get('command')
    if isinstance(command, str):
        candidates.add(f'agent:{command}')
    key = params.get('key', params.get('runtime'))
    if isinstance(key, str):
        candidates.add(f'runtime:{key}')
    kind, item = params.get('kind'), params.get('item')
    if isinstance(item, str) and kind in ('mcp', 'skills', 'provider'):
        candidates.add(f"{'runtime' if kind == 'provider' else kind}:{item}")
        if kind == 'provider':
            key = item
    model = params.get('model')
    if isinstance(key, str) and isinstance(model, str) and model:
        candidates.add(f'model:runtime:{key}:{model.lower()}')
    if addon is not None:
        for provided in addon.provides:
            if addon.kind == 'agent':
                candidates.add(f'agent:{provided}')
            elif addon.kind == 'provider':
                candidates.update((f'runtime:{provided}', f'cloud:{provided.lower()}'))
    return [node['id'] for node in nodes if node['id'] in candidates & known]
