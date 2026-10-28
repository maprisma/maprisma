"""First installs from registered, checksummed releases; fixed backend destinations."""
from __future__ import annotations

from dataclasses import asdict
import json
from pathlib import Path
import os
import time
import uuid

import agents
import first_agent
import install_ctl
import inventory
import providers
from flutter_addon_catalog import install_lock
from flutter_addons import AdapterRegistry
import ai_core
import settings_schema

MAX_PLAN = 128 * 1024
TTL = 600


def installer(selection: dict):
    if (set(selection) - {'kind','key','build'} or not {'kind','key'} <= set(selection)
            or not all(isinstance(value,str) for value in selection.values())):
        raise ValueError('Invalid installer selection')
    kind, key = selection['kind'], selection['key']
    tables = {'runtime':install_ctl.INSTALLERS, 'agent':install_ctl.AGENT_INSTALLERS,
              'tool':install_ctl.TOOL_INSTALLERS}
    if kind not in tables or key not in tables[kind] or not install_ctl.NAME_RE.fullmatch(key):
        raise ValueError('Unknown registered installer')
    inst = tables[kind][key]
    if not inst.can_install or inst.installed_folder() is not None:
        raise ValueError('This action requires a missing, installable program')
    if kind == 'runtime':
        provider = providers.get(key)
        if provider is None or provider.kind != 'local' or not provider.detect:
            raise ValueError('Unavailable provider')
        if provider.detect(inventory.own_processes()).installed:
            raise ValueError('Provider is already installed by another method')
    elif kind == 'agent':
        if any(agent.command == key and agent.installed for agent in agents.list_agents()):
            raise ValueError('Agent is already installed by another method')
    elif first_agent.has_tool(inst.command):
        raise ValueError('Prerequisite is already installed')
    if os.path.lexists(install_ctl.BIN_DIR/inst.command):
        raise ValueError('Existing program link or file must not be replaced')
    protected = [inst.env_file] if inst.env_file != install_ctl.HOME else []
    if inst.has_service:
        protected.append(install_ctl.UNIT_DIR/f'{inst.service}.service')
    if any(os.path.lexists(path) for path in protected):
        raise ValueError('Existing configuration must not be replaced by a first install')
    return inst


def prepare(selection: dict, settings_path: Path | None = None) -> dict:
    inst = installer(selection)
    gpu = install_ctl.detect_gpu() if inst.uses_models else install_ctl.Gpu()
    build = selection.get('build', inst.default_build(gpu))
    if build not in {key for key,_label in inst.builds} | {inst.default_build(gpu)}:
        raise ValueError('Unavailable hardware build')
    release = inst.latest(gpu, build)
    # The npm-only/internal special cases need their own contract; this flow is
    # deliberately limited to declared archive checksums from the existing policy.
    checked = install_ctl.Release.from_json(release.to_json())
    if (not checked.assets or checked.to_json() != release.to_json()
            or any(size <= 0 or name not in checked.digests for name,_url,size in checked.assets)):
        raise ValueError('No complete checksummed release')
    folder = inst.default_folder
    models = folder/'models' if inst.uses_models else None
    source = {'type':type(inst).__module__+'.'+type(inst).__qualname__, 'key':inst.key,
              'command':inst.command,'binary':inst.bin_rel,'service':inst.service,
              'has_service':inst.has_service,'uses_models':inst.uses_models,
              'spec':asdict(inst.spec) if hasattr(inst,'spec') else None}
    record = {'version':1,'settings_path':str(settings_path) if settings_path else None,'selection':{**selection,'build':build},'name':inst.name,
              'release':checked.to_json(),'gpu':asdict(gpu),'folder':str(folder),
              'models':str(models) if models else None,'source':source}
    body = json.dumps(record,ensure_ascii=True,allow_nan=False).encode()
    if len(body) > MAX_PLAN:
        raise ValueError('Installer preview too large')
    return json.loads(body)


class Plans:
    def __init__(self):
        self.items: dict[str,tuple[float,dict]] = {}

    def register(self, record: dict) -> dict:
        if record.get('version') != 1 or len(json.dumps(record).encode()) > MAX_PLAN:
            raise ValueError('Invalid installer preview')
        now = time.monotonic()
        self.items = {key:value for key,value in self.items.items() if now-value[0]<TTL}
        while len(self.items)>=16:
            del self.items[next(iter(self.items))]
        token = uuid.uuid4().hex
        self.items[token] = (now,record)
        release = install_ctl.Release.from_json(record['release'])
        return {'installer':token,'kind':record['selection']['kind'],'key':record['selection']['key'],
                'name':record['name'],'version':release.version,'size':release.size,
                'files':[{'name':name,'size':size} for name,_url,size in release.assets],
                'folder':record['folder'],'models':record['models'],'gpu':record['gpu'],
                'build':record['selection']['build'],'has_service':record['source']['has_service']}

    def apply(self, params: dict, queue) -> dict:
        if (set(params) != {'installer','start_now','start_at_login'} or not isinstance(params['installer'],str)
                or type(params['start_now']) is not bool or type(params['start_at_login']) is not bool):
            raise ValueError('Invalid installer confirmation')
        token = params['installer']
        if token not in self.items or time.monotonic()-self.items[token][0]>=TTL:
            raise ValueError('Unknown or expired installer preview')
        record = self.items[token][1]
        if not record['source']['has_service'] and (params['start_now'] or params['start_at_login']):
            raise ValueError('This program has no managed service')
        result = queue({'record':record,'start_now':params['start_now'],'start_at_login':params['start_at_login']})
        del self.items[token]
        return result


def execute(body: bytes, progress) -> dict:
    if len(body)>MAX_PLAN:
        raise ValueError('Installer plan too large')
    plan = json.loads(body)
    if (not isinstance(plan,dict) or set(plan) != {'record','start_now','start_at_login'}
            or type(plan['start_now']) is not bool or type(plan['start_at_login']) is not bool):
        raise ValueError('Invalid private installer plan')
    record = plan['record']
    # Share the application installation lock with add-on installers. A detached
    # worker from the previous UI must finish before a second installation begins.
    with install_lock():
        chosen = record['settings_path']
        path = Path(chosen) if chosen else None
        registry = AdapterRegistry()
        registry.reload(set(settings_schema.value(ai_core.load_settings(path),'addons_enabled')))
        current = prepare(record['selection'],path)
        if current != record:
            raise ValueError('Release, hardware or installer changed; preview again')
        inst = installer(record['selection'])
        if not inst.has_service and (plan['start_now'] or plan['start_at_login']):
            raise ValueError('No managed service')
        inst.install(Path(record['folder']),Path(record['models']) if record['models'] else None,
                     plan['start_at_login'],plan['start_now'],install_ctl.Gpu(**record['gpu']),
                     install_ctl.Release.from_json(record['release']),progress,lambda:False)
        return {'ok':True,'kind':record['selection']['kind'],'key':record['selection']['key'],
                'version':record['release']['version']}
