"""Bounded map-only activity and failure metadata; no configuration or transcripts."""
from dataclasses import asdict
import ai_core
import link_hints


def failures(settings_path):
    path = (settings_path or ai_core.settings_file()).parent / 'failed-links.json'
    return {} if path.is_symlink() else link_hints.load(path)


def edges(graph, activity, failures, inventory, animate):
    working = {f'agent:{c}' for c, row in activity.items() if row.get('working')}
    models = {e.target for e in graph.edges if e.source in working and e.kind == 'default'}
    external = set()
    if animate == 'all':
        import gpu_usage
        running = [r for r in inventory.runtimes if r.running]
        if running:
            use = gpu_usage.snapshot(running)
            if use.generating:
                external = {f'runtime:{r.key}' for r in running if use.runtimes.get(r.key) and use.runtimes[r.key].running}
    result = []
    for edge in graph.edges:
        row = asdict(edge)
        agent_active = edge.source in working and edge.kind in ('uses', 'mcp', 'skills', 'default')
        model_active = edge.kind == 'serves' and edge.target in models
        runtime_active = edge.kind == 'serves' and edge.source in external
        row.update(active=animate != 'off' and bool(agent_active or model_active or runtime_active),
                   activity='agent' if agent_active or model_active else 'runtime' if runtime_active else '')
        entry = failures.get(link_hints.key(edge.source, edge.target))
        if entry:
            row['hints'] = entry['hints'][:12]
            row['applied'] = entry['applied']
        elif edge.kind == 'failed' and not edge.fixed:
            # A broken local line of the map's own (no recorded failure).
            row['hints'] = [{'level':'error', 'text':'The configured model has no provider connection. Repair or remove this connection.'
                             if edge.dangling else 'This local LLM now listens on another port. Repair or remove this connection.'}]
        result.append(row)
    return result
