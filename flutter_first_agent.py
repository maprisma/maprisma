"""Worker-built first-agent checklist, reusing catalog/adapters and existing pages."""
from pathlib import Path
from typing import cast

import agents
import agent_status
import ai_core
import first_agent
import connect
import harnesses
import inventory
import install_ctl
import providers
import settings_schema
from i18n import _


def catalog(registry):
    return first_agent.load(loaded_addons=registry.items if registry else ())


def choose(route_id, registry, path: Path | None):
    if not isinstance(route_id,str) or route_id not in {route.id for route in catalog(registry).routes}:
        raise ValueError('Unknown first-agent route')
    saved = dict(settings_schema.value(ai_core.load_settings(path), 'first_agent'))
    ai_core.update_settings(path, first_agent={**saved, 'route':route_id, 'later':False})
    return {'ok':True}


def snapshot(registry, path: Path | None) -> dict:
    found = catalog(registry)
    saved = cast(dict, settings_schema.value(ai_core.load_settings(path), 'first_agent'))
    verified_agents = saved.get('verified', [])
    verified_agents = verified_agents if isinstance(verified_agents,list) else []
    agent_list = agents.list_agents()
    installed = {item.command for item in agent_list if item.installed}
    runtimes = inventory.collect(agent_list).runtimes if any(route.kind == 'local' for route in found.routes) else []
    rows = []
    for route in found.routes:
        harness = harnesses.get(route.agent)
        access = harness.access() if harness and harness.access else None
        present = route.agent in installed
        steps = []
        def step(title, done, detail='', action='', **extra):
            steps.append({'title':title,'done':bool(done),'detail':detail,'action':action,**extra})
        if harness is None:
            step(_('Switch on its add-on'), False, action='addons')
        missing = first_agent.missing(route)
        for tool in route.needs:
            action = ''
            if tool in missing:
                if tool in install_ctl.TOOL_INSTALLERS:
                    action = 'install-tool'
                elif tool == 'node' and first_agent.has_tool('mise'):
                    action = 'install-node'
            step(tool, tool not in missing, action=action, target=tool)
        agent_action = 'install-agent' if route.agent in install_ctl.AGENT_INSTALLERS else 'install'
        step(route.name, present, action='' if present else (agent_action if harness else 'addons'))
        if route.kind == 'online':
            step(_('Sign in or set an API key'), present and access is not None and agent_status.credentials_present(access),
                 _(route.access), 'login' if present and access and access.logins else '')
        else:
            runtime = next((rt for rt in runtimes if rt.key == route.runtime), None)
            provider = providers.get(route.runtime)
            if provider is None:
                step(_('Switch on its add-on'), False, route.runtime, 'addons')
            have_runtime = runtime is not None and runtime.installed
            inst = install_ctl.INSTALLERS.get(route.runtime)
            runtime_action = 'install-runtime' if not have_runtime and inst and inst.can_install else 'providers'
            step(provider.name if provider else route.runtime, have_runtime, action=runtime_action, target=route.runtime)
            step(_('A model'), bool(runtime and runtime.models), action='providers')
            # The existing Connections page remains authoritative for previews and Undo.
            connected = bool(present and runtime and connect.is_connected(route.agent, route.runtime)
                             and connect.is_active(route.agent, route.runtime))
            step(_('Connections'), connected,
                 _('A preview shows what changes in its settings; Undo puts it back.'), 'connections')
        verified = present and route.agent in verified_agents
        step(_('A test question'), verified,
             _('{0} answers one short question, so you see that it works.').format(route.name),
             'verify' if present and harness and harness.ask else '')
        rows.append({'id':route.id,'kind':route.kind,'title':_(route.title),'access':_(route.access),
                     'command':route.agent,'name':route.name,'steps':steps,'verified':verified})
    return {'routes':rows, 'selected':saved.get('route')}
