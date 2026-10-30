"""Reviewed agent lifecycle actions; no command, argv or URL accepted from UI data."""
from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import tempfile
import time
import uuid

import agents
import ai_core
import first_agent
import harnesses
import install_recipes
import settings_schema

TTL = 300


@dataclass
class Plan:
    public: dict
    argv: list[str]
    step: install_recipes.Step | None = None

    def signature(self):
        return json.dumps([self.public, self.argv, self.step.run if self.step else None], sort_keys=True)


def resolve(params: dict) -> Plan:
    if (set(params) - {'command', 'action', 'login', 'kind'} or not {'command', 'action'} <= set(params)
            or not isinstance(params['command'], str) or not isinstance(params['action'], str)):
        raise ValueError('Invalid agent action')
    kind = params.get('kind','agent')
    if kind != 'agent':
        if kind != 'tool' or params['command'] != 'node' or params['action'] != 'install' or 'login' in params:
            raise ValueError('Unknown prerequisite action')
        ai_core.add_user_program_dirs()
        if not first_agent.has_tool('mise'):
            raise ValueError('Install the prerequisite manager first')
        argv = first_agent.node_step()
        step = install_recipes.Step('command',[shlex.join(argv)],[argv])
        public = {'command':'node','name':'Node.js','action':'install','commands':step.commands,
                  'note':'','url':'','data':[],'installed':first_agent.node_ready(),'version':'','source':'',
                  'runnable':True,'external':True,'logins':[]}
        return Plan(public,[],step)
    command, action = params['command'], params['action']
    if action not in ('install', 'update', 'uninstall', 'login', 'logout', 'verify'):
        raise ValueError('Unknown agent action')
    ai_core.add_user_program_dirs()
    agent = next((item for item in agents.list_agents() if item.command == command), None)
    harness = harnesses.get(command)
    if agent is None or harness is None:
        raise ValueError('Unavailable agent')
    public = {'command':command, 'name':agent.name, 'action':action, 'commands':[],
              'note':'', 'url':'', 'data':[], 'installed':bool(agent.installed), 'version':agent.version, 'source':agent.source, 'runnable':False, 'external':False, 'logins':[]}
    if action in ('install','update','uninstall'):
        if 'login' in params or (action != 'install' and not agent.installed):
            raise ValueError('Invalid lifecycle action')
        step = install_recipes.choose(harness.install, action, agent.source)
        if step is None:
            raise ValueError('No installation recipe')
        public.update(commands=step.commands, note=step.note, url=step.url,
                      data=list(harness.data) if action == 'uninstall' else [],
                      runnable=bool(step.run and not step.installer), external=True)
        return Plan(public, [], step)
    if not agent.installed:
        raise ValueError('Agent is not installed')
    if action == 'logout':
        if 'login' in params or not harness.logout:
            raise ValueError('No registered sign-out command')
        argv = list(harness.logout)
    elif action == 'verify':
        if 'login' in params:
            raise ValueError('Invalid test request')
        argv = first_agent.verify_argv(command)
        if not argv:
            raise ValueError('No fixed test command')
        argv = list(argv)
        public['note'] = first_agent.TEST_PROMPT
    else:
        access = harness.access() if harness.access else None
        logins = list(access.logins) if access else []
        index = params.get('login', 0)
        if type(index) is not int or not 0 <= index < len(logins):
            raise ValueError('No registered sign-in command')
        argv = list(logins[index].argv)
        public['logins'] = [item.label for item in logins]
        public['note'] = logins[index].note
    binary = shutil.which(argv[0]) if argv else None
    if not binary:
        raise ValueError('Program unavailable')
    argv[0] = binary
    public.update(commands=[shlex.join(argv)], runnable=True)
    return Plan(public, argv)


class Actions:
    def __init__(self, settings_path: Path | None):
        self.settings_path = settings_path
        self.previews: dict[str, tuple[float, dict, Plan]] = {}
        self.verifications: dict[str, tuple[str, tempfile.TemporaryDirectory, str]] = {}

    def preview(self, params: dict) -> dict:
        plan = resolve(params)
        now = time.monotonic()
        self.previews = {key:value for key,value in self.previews.items() if now-value[0] < TTL}
        while len(self.previews) >= 16:
            del self.previews[next(iter(self.previews))]
        token = uuid.uuid4().hex if plan.public['runnable'] else None
        if token:
            self.previews[token] = (now, dict(params), plan)
        return {**plan.public, 'preview':token}

    def apply(self, token: str, sessions) -> dict:
        if token not in self.previews:
            raise ValueError('Unknown agent action preview')
        created, params, previous = self.previews[token]
        if time.monotonic()-created >= TTL:
            raise ValueError('Agent action preview expired')
        plan = resolve(params)
        if not plan.public['runnable'] or plan.signature() != previous.signature():
            raise ValueError('Agent action changed; preview again')
        if params['action'] in ('update','uninstall') and any(
                session.command == params['command'] and sessions.poll(session) is None
                for session in sessions.items.values()):
            raise ValueError('Finish the owned agent before updating or removing it')
        if plan.public['external']:
            assert plan.step is not None
            if not install_recipes.run(plan.step):
                raise ValueError('No terminal available')
            result = {'external':True}
        else:
            env = dict(os.environ)
            ai_core.drop_agent_session_vars(env)
            ai_core.add_user_program_dirs(env)
            env.update(TERM='xterm-256color', COLORTERM='truecolor', MAPRISMA_NO_PROVIDERS='1')
            env.pop('MAPRISMA_PAGE', None)
            env.pop('MAPRISMA_VIEW', None)
            temporary = tempfile.TemporaryDirectory(prefix='asterism-agent-test-') if params['action'] == 'verify' else None
            cwd = temporary.name if temporary else str(Path.home())
            try:
                ident = sessions.start(params['command'], plan.argv, cwd, env)
            except BaseException:
                if temporary:
                    temporary.cleanup()
                raise
            if temporary:
                self.verifications[ident] = (params['command'], temporary, '')
            result = {'session':ident, 'command':plan.public['name'], 'path':cwd}
        del self.previews[token]
        return result

    def observe(self, ident: str, result: dict) -> None:
        if ident not in self.verifications:
            return
        command, temporary, tail = self.verifications[ident]
        tail = (tail + result['text'])[-4096:]
        self.verifications[ident] = (command, temporary, tail)
        if not result['ended']:
            return
        try:
            cleaned = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', tail)
            answer = first_agent.answer_ok(cleaned.encode(), result['exit_code'] == 0)
            if answer:
                state = dict(settings_schema.value(ai_core.load_settings(self.settings_path), 'first_agent'))
                verified = state.get('verified', [])
                verified = [item for item in verified if isinstance(item,str) and item != command] if isinstance(verified,list) else []
                ai_core.update_settings(self.settings_path,
                    first_agent={**state, 'verified':verified+[command]})
        except (OSError, ValueError):
            result['verification_failed'] = True
        finally:
            self.forget(ident)

    def forget(self, ident: str):
        item = self.verifications.pop(ident, None)
        if item:
            item[1].cleanup()

    def close(self):
        for ident in list(self.verifications):
            self.forget(ident)
