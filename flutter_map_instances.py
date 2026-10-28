"""Short-lived reviewed handles for stopping a registered external agent instance."""
from __future__ import annotations

import json
import time
import uuid

import agent_terminals
import agents
import provider_watch


class Instances:
    def __init__(self):
        self.plans = {}

    def preview(self, params, sessions):
        if set(params) != {'command'} or not isinstance(params['command'], str):
            raise ValueError('Expected an agent')
        command = params['command']
        if not any(a.command == command and a.installed for a in agents.list_agents()):
            raise ValueError('Agent unavailable')
        now = time.monotonic()
        self.plans = {k:v for k,v in self.plans.items() if now-v[0] < 300}
        pids = {}
        provider_watch.agent_instances([command], pids=pids)
        embedded = [s.process.pid for s in sessions.items.values() if s.process.poll() is None]
        outside = [pid for pid in pids.get(command, [])
                   if not any(pid == own or own in agent_terminals.ancestors(pid) for own in embedded)]
        rows = []
        for instance in agent_terminals.instances(outside, {}):
            if not instance.started: continue
            if len(self.plans) >= 64: self.plans.pop(next(iter(self.plans)))
            token = uuid.uuid4().hex
            self.plans[token] = (now, command, instance)
            rows.append({'preview':token,'label':f'{command} · {instance.pid} · {instance.cwd[:500]}'})
        return {'instances':rows}

    def apply(self, params, queue):
        if set(params) != {'preview'} or not isinstance(params['preview'], str):
            raise ValueError('Expected a preview')
        plan = self.plans.get(params['preview'])
        if plan is None or time.monotonic()-plan[0] >= 300:
            raise ValueError('Preview expired')
        _, command, instance = plan
        body = json.dumps({'command':command,'pid':instance.pid,'started':instance.started}).encode()
        task = queue('agents.halt', body)
        self.plans.pop(params['preview'])
        return task


def execute(body):
    record = json.loads(body)
    if (not isinstance(record, dict) or set(record) != {'command', 'pid', 'started'}
            or not isinstance(record['command'], str) or type(record['pid']) is not int
            or type(record['started']) not in (int, float)):
        raise ValueError('Invalid instance')
    pids = {}
    provider_watch.agent_instances([record['command']], pids=pids)
    if record['pid'] not in pids.get(record['command'], []):
        raise ValueError('Instance changed')
    if not agent_terminals.stop(record['pid'], record['started']):
        raise ValueError('Instance could not be stopped')
    return {'ok':True}
