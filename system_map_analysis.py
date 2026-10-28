"""Confirmed Smart Check against an allowlisted System Map summary, in a worker."""
from __future__ import annotations
from dataclasses import asdict
import copy
import json
from pathlib import Path
import tempfile
import uuid
import signal
import threading

import agents
import ai_helper
import plugin_ai
import smart_check
import system_map_cache


def analyze(body: bytes) -> dict:
    if len(body) > 128 * 1024:
        raise ValueError('System analysis request too large')
    data = json.loads(body)
    import ai_core
    from flutter_addons import AdapterRegistry
    settings_path = Path(data['settings_path']) if data.get('settings_path') else None
    registry = AdapterRegistry()
    registry.reload(set(ai_core.load_settings(settings_path).get('addons_enabled', [])))
    command = data['command']
    if command not in ai_helper.helpers({a.command for a in agents.list_agents() if a.installed}):
        raise ValueError('AI checker unavailable')
    cancel=threading.Event()
    previous=signal.getsignal(signal.SIGTERM)
    signal.signal(signal.SIGTERM,lambda _signal,_frame:cancel.set())
    raw_answer = {}
    def lookup(agent, task, prompt, schema, **kwargs):
        nonlocal raw_answer
        richer = copy.deepcopy(schema)
        richer['properties']['findings']['items']['properties']['node'] = {'type':'string'}
        def bounded(argv,**options):
            if cancel.is_set():return b'',False
            return ai_helper._bounded(argv,**options)
        text = ai_helper.look_up(agent, task, data['prompt'], richer, run=bounded, **kwargs)
        raw_answer = plugin_ai.first_json(text, 'findings')
        return text
    # Reuse existing validation/logging, but keep this UI's analysis separate from GTK's cache.
    try:
        with ai_helper.watched(cancel), tempfile.TemporaryDirectory(prefix='asterism-analysis-') as tmp:
            result = asdict(smart_check.analyze(command, '', look_up=lookup, cache=Path(tmp)/'analysis.json'))
    finally:
        signal.signal(signal.SIGTERM,previous)
    if cancel.is_set():raise InterruptedError('System analysis stopped')
    mapping = {smart_check._one_line(f.get('title'),100): f.get('node','')
               for f in raw_answer.get('findings',[]) if isinstance(f,dict)}
    for finding in result['findings']:
        finding['id'] = uuid.uuid4().hex
        node = mapping.get(finding['title'], '')
        finding['node'] = node if node in data['nodes'] else ''
    path = Path(data['cache_path'])
    saved = system_map_cache.load(path)
    if not saved:
        raise ValueError('System Map unavailable')
    system_map_cache.update(path, {'analysis':result})
    return {'analysis':result}
