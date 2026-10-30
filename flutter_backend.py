"""Private stdio service for Flutter; no socket or frontend-supplied shell command.

One JSON object per line, versioned and bounded. Only named operations are
accepted. Application state stays in the existing settings and adapter modules.
Importing this module does not start agents or load GTK.
"""

from __future__ import annotations

import contextlib
import base64
import binascii
import json
import os
import re
import shutil
import signal
import sys
import time
from dataclasses import asdict
from pathlib import Path
from typing import TextIO, cast

import agent_projects
import agents
import ai_core
import harnesses
import settings_schema
import i18n
from terminal_sessions import Sessions
from flutter_tasks import Tasks
from flutter_connections import Connections
from flutter_removals import Removals
from flutter_addon_catalog import Catalog
from flutter_agent_actions import Actions
from flutter_existing import Existing
from flutter_system_map import SystemMap
from flutter_installers import Plans as InstallerPlans

MAP_SCAN_SETTINGS = (
    'addons_enabled', 'map_layers', 'map_scan_interval', 'map_scan_pause_unfocused',
    'map_scan_targets', 'subagents_minutes', 'subagents_kept', 'language',
    'models_root', 'model_folders', 'mcp_folders', 'skill_folders',
)

PROTOCOL = 1
MAX_REQUEST = 64 * 1024
MAP_REUSE = 5.0                 # seconds a self-built map serves previews and task focus
UI_SETTINGS = frozenset(("flutter_theme_mode", "map_light_fps", "flutter_map_layout", "map_animations", "language", "look", "agent_folder", "map_layers", "subagents_minutes", "subagents_kept", "addons_online", "map_scan_interval", "map_scan_pause_unfocused", "map_scan_targets", "providers_with_agents", "ai_checks_agent", "warn_notify",
                         "cost_currency", "cost_limit", "warn_yellow", "warn_red", "terminal_tabs",
                         "usage_box", "usage_box_items", "usage_box_size",
                         "ai_local_helper", "ai_checks", "window_mode"))


class Service:
    def __init__(self, settings_path: Path | None = None):
        self.settings_path = settings_path
        self.sessions = Sessions()
        self.adapters = None
        self.tasks = Tasks()
        self.connections = Connections(settings_path.parent / 'connection-backups' if settings_path else None)
        self.existing = Existing(settings_path, self.connections.backup_root)
        self.system_map = SystemMap(settings_path)
        import system_tools
        self.stack_actions = system_tools.StackActions()
        import system_moves
        self.system_moves = system_moves.Moves()
        self.removals = Removals()
        self.addon_catalog = Catalog()
        from flutter_addon_actions import Actions as AddonActions
        self.addon_actions = AddonActions()
        self.agent_actions = Actions(settings_path)
        self.installer_plans = InstallerPlans()
        self.migration_error = None
        self._map_task = None
        self._map_force_pending = False
        self._map_forced = False
        self._map_started = float("-inf")
        self._map_inputs = None
        self._map_result = {'activity': {}, 'nodes': [], 'edges': []}
        self._map_built = float('-inf')

    def system_public(self, result: dict) -> dict:
        if not result:
            return {'version':1, 'nodes':[], 'edges':[], 'notes':[], 'helpers':[], 'limited':False, 'checked_at':None}
        # Cached discoveries remain private; only fresh opaque handles reach Flutter.
        public = self.existing.register({'records':result.get('records', []), 'limited':False, 'visited':0})
        found = {r['path']:r for r in public['items']}
        root_keys={'version','checked_at','searched_at','edges','notes','helpers','limited','mounts','scan_limits','analysis','health','move_undo','view','search_done','mount_signature'}
        node_keys={'id','path','kind','label','detail','info','status','column','mount_path','size','size_partial','stack','fstab','install_source','launch_path'}
        visible = {k:v for k,v in result.items() if k in root_keys}
        visible['nodes']=[{k:v for k,v in n.items() if k in node_keys} for n in result['nodes']]
        if isinstance(visible.get('analysis'),dict):
            analysis=visible['analysis']
            visible['analysis']={k:analysis[k] for k in ('agent','when','summary','findings') if k in analysis}
        for node in visible['nodes']:
            path = os.path.realpath(node['path']) if node['path'] else ''
            if node['kind'] in ('runtime','folder','models','store') and path in found and node['status'] != 'missing':
                node['found'] = found[path]['found']
                node['provider'] = found[path]['provider']
                if node['kind'] == 'folder' and found[path]['kind'] in ('models','store'):
                    node['kind'] = found[path]['kind']
        return visible

    def finish_system_search(self, path: str, result: dict) -> dict:
        import system_map_cache
        saved = system_map_cache.load(self.system_map.cache_path)
        if saved:
            before = [r for r in saved.get('records',[]) if not Path(r['path']).is_relative_to(path)]
            merged = {(r['kind'],r['path']):r for r in [*before,*result['records']]}
            saved['records'] = list(merged.values())[:128]
            saved['search_done'] = True
            saved['scan_limits']=[r for r in saved.get('scan_limits',[]) if r['path']!=path]+[{'path':path,**{k:result.get(k,[]) for k in ('limits','notices','foreign')},'depth':result.get('depth',5)}]
            self.system_map.register(saved, result['records'])
        return self.existing.register(result)

    def finish_system_move(self,result):
        import system_map_cache
        saved=system_map_cache.load(self.system_map.cache_path)
        if saved and 'move_undo' in result:
            system_map_cache.update(self.system_map.cache_path,{'move_undo':result['move_undo']})
        return result

    def enabled_addons(self) -> set[str]:
        return set(settings_schema.value(ai_core.load_settings(self.settings_path), "addons_enabled"))

    def initialize(self) -> None:
        import config_migration
        from flutter_addons import AdapterRegistry
        # Migration precedes all writes and uses the same backup/rollback policy.
        try:
            config_migration.migrate(target=self.settings_path.parent if self.settings_path else None)
        except (OSError, ValueError) as error:
            self.migration_error = str(error)
            print(f"Asterism settings import failed: {error}", file=sys.stderr)
        ai_core.migrate_settings(self.settings_path)
        self.adapters = AdapterRegistry()
        self.adapters.reload(self.enabled_addons())
        self.finish_plugin_migration()

    def finish_plugin_migration(self) -> None:
        if self.adapters is None:
            return
        state = settings_schema.value(ai_core.load_settings(self.settings_path), "plugin_migration")
        if not isinstance(state, dict):
            return
        supported = [item for item in self.adapters.items if item.kind in ("agent", "provider")
                     and item.state in ("verified", "loaded")]
        if not state.get("addons_pending") or not supported:
            return
        enabled = self.enabled_addons()
        try:
            found = self.adapters.installed(enabled)
        except Exception:
            return  # retain the migration marker and retry next start
        enabled |= found
        ai_core.update_settings(self.settings_path, addons_enabled=sorted(enabled), setup_done=True,
                                plugin_migration={**state, "addons_pending": False})
        self.adapters.reload(enabled)

    def snapshot(self) -> dict:
        settings = ai_core.load_settings(self.settings_path)
        catalog = agents.list_agents()
        return {
            "protocol": PROTOCOL,
            "migration_error": self.migration_error,
            "language": settings_schema.value(settings, "language"),
            "settings": self.settings(settings),
            "theme": self.theme(settings),
            "setup_needed": self.adapters is not None and not settings_schema.value(settings, "setup_done"),
            "agents": [asdict(agent) for agent in catalog],
            "projects": {
                agent.command: self.projects(agent.command, settings)
                for agent in catalog
            },
        }

    def theme(self, settings: dict) -> dict:
        import desktop
        if desktop.NAME != "omarchy" or settings_schema.value(settings, "look") != "omarchy":
            return {}
        return {key: value for key, value in desktop.theme_colors().items()
                if isinstance(key, str) and isinstance(value, str) and re.fullmatch(r"#[0-9a-fA-F]{6}", value)}

    def settings(self, saved: dict | None = None) -> dict:
        saved = ai_core.load_settings(self.settings_path) if saved is None else saved
        return {key: settings_schema.value(saved, key) for key in UI_SETTINGS}

    def agent(self, command):
        if not isinstance(command, str):
            raise ValueError("Invalid agent")
        found = next((a for a in agents.list_agents() if a.command == command), None)
        if found is None:
            raise ValueError("Unknown agent")
        return found

    def projects(self, command: str, settings: dict | None = None) -> dict:
        settings = ai_core.load_settings(self.settings_path) if settings is None else settings
        pinned = settings.get("agent_projects", {})
        pin = pinned.get(command) if isinstance(pinned, dict) else None
        return {
            "default": agent_projects.selected(command, pinned, settings.get("agent_folder", str(Path.home()))),
            "pinned": pin if isinstance(pin, str) else None,
            "history": [{"path": path, "available": agent_projects.folder(path) is not None}
                        for path in agent_projects.history(command, settings.get("agent_project_history", {}))],
        }

    def task_focus(self, params: dict) -> list[str]:
        """Resolve public anchors against the last bounded map, without a new scan."""
        import flutter_task_focus
        addon = None
        ident = params.get('id')
        if self.adapters is not None and isinstance(ident, str):
            addon = next((item for item in self.adapters.items if item.id == ident), None)
        return flutter_task_focus.resolve(self._map_result, params, addon)   # never scans

    def current_map(self) -> dict:
        """The map the map editor's previews resolve against. In the Flutter Devel app the Dart core
        answers map.snapshot, so this reference builds its own (reused for MAP_REUSE seconds); task
        focus keeps using the last known map and never scans."""
        now = time.monotonic()
        if self._map_result.get('nodes') and now - getattr(self, '_map_built', float('-inf')) < MAP_REUSE:
            return self._map_result
        if self._map_task is None:
            self._map_result = self.build_map()
        self._map_built = now
        return self._map_result

    def catalog_focus(self, result: dict) -> dict:
        result = self.addon_catalog.register(result)
        for entry in result['entries']:
            entry['focus'] = self.task_focus(entry)
        return result

    def dispatch(self, method: str, params: dict) -> dict:
        result = self._dispatch(method, params)
        if method == 'providers.snapshot':
            for runtime in result.get('local', []):
                runtime['focus'] = self.task_focus({'key': runtime['key']})
        if method in ('connections.preview', 'agents.action_preview', 'models.remove_preview',
                      'addons.remove_preview', 'providers.run', 'connections.snapshot',
                      'system.folder_preview'):
            context = params.get('params', {}) if method == 'providers.run' else params
            result = {**result, 'focus': self.task_focus(context)}
        return result

    def _dispatch(self, method: str, params: dict) -> dict:
        self.tasks.poll()
        if method == 'system.mount_signature':
            import existing_ai
            if params:raise ValueError('Unexpected mount signature parameters')
            return {'signature':json.dumps(sorted((m['path'],m['identity']) for m in existing_ai.mounts()))}
        if method == 'system.view':
            import math, system_map_cache
            if set(params)!={'selected','transform'} or not system_map_cache.valid_view(params):raise ValueError('Invalid System Map view')
            saved=system_map_cache.load(self.system_map.cache_path)
            if not saved:return {'ok':False}
            if params['selected'] is not None and params['selected'] not in {n['id'] for n in saved['nodes']}:raise ValueError('Unknown node')
            system_map_cache.update(self.system_map.cache_path,{'view':{'selected':params['selected'],'transform':params['transform']}})
            return {'ok':True}
        if method == 'system.folder_preview':
            import existing_ai, providers, flutter_providers, flutter_existing, connect
            if set(params)!={'found','runtime'}:raise ValueError('Invalid folder connection')
            record=self.existing.get(params['found'])
            if record['kind'] not in ('models','store'):raise ValueError('Choose a model folder/store')
            existing_ai.validate(record)
            rt=flutter_providers.runtime(params['runtime'])
            provider=providers.get(rt.key)
            if provider is None or provider.model_folder_changes is None:
                provider=next((p for p in providers.built_in_local() if p.key==rt.key),None)
            if provider is None or provider.model_folder_changes is None:raise ValueError('No safe model-folder configuration')
            changes=provider.model_folder_changes(rt,Path(record['path']))
            if any(c.path.is_symlink() for c in changes):raise ValueError('Configuration is a symbolic link')
            plan=connect.Plan('system-map','','',changes=changes)
            if record['kind']=='models':plan.changes+=flutter_existing.build_plan(record,None,self.settings_path).changes
            result=self.connections.keep(plan)
            return {**result,'item':record['path'],'command':rt.name,'notes':['Changes apply when the runtime next starts. Running services are not restarted.']}
        if method == 'system.move_preview':
            if set(params)!={'source','target'}:raise ValueError('Invalid folder move')
            if self.system_map.last is None:raise ValueError('Refresh the System Map')
            nodes=self.system_map.last[1]['nodes']
            source=next((n for n in nodes if n['id']==params['source'] and n['kind'] in ('models','folder')),None)
            target=next((n for n in nodes if n['id']==params['target'] and n['kind']=='disk'),None)
            if not source or not target or source['status']=='missing' or target['status']=='missing':raise ValueError('Folder/disk unavailable')
            import existing_ai
            mount=existing_ai.root_for(target['path'],existing_ai.mounts())
            record={'source':source['path'],'disk':target['path'],'mount':mount,
                    'settings_path':str(self.settings_path) if self.settings_path else None}
            return self.tasks._private('system.move_preview',json.dumps(record).encode(),self.system_moves.register)
        if method == 'system.move_apply':
            if set(params)!={'preview'} or self.installation_running() or any(t.operation=='system.refresh' and t.state=='running' for t in self.tasks.items.values()):raise ValueError('Invalid/busy move request')
            return self.system_moves.apply(params['preview'],lambda record:self.tasks._private('system.move_apply',json.dumps(record).encode(),self.finish_system_move))
        if method == 'system.move_undo':
            if set(params)!={'undo'} or not isinstance(params['undo'],str) or not re.fullmatch('[0-9a-f]{32}',params['undo']) or self.installation_running():raise ValueError('Invalid/busy move Undo')
            return self.tasks._private('system.move_undo',json.dumps({'undo':params['undo'],'settings_path':str(self.settings_path) if self.settings_path else None}).encode(),lambda result:self.finish_system_move({**result,'move_undo':None} if result.get('ok') else result))
        if method == 'system.tool_check':
            import system_tools
            if set(params)!={'node'}:raise ValueError('Invalid supporting tool selection')
            return self.tasks._private('system.tool_check',json.dumps(system_tools.check_record(params['node'])).encode())
        if method in ('system.stack_preview','system.stack_apply'):
            field='part' if method.endswith('_preview') else 'preview'
            if set(params)!={field}:raise ValueError('Invalid GPU stack action')
            if field=='part':return self.stack_actions.preview(params[field])
            if self.installation_running():raise ValueError('An installation is already running')
            return self.stack_actions.apply(params[field])
        if method == 'usage.snapshot':
            import ai_helper, smart_check, plugin_ai
            if params:raise ValueError('Unexpected Usage parameters')
            return {'categories':[{'plugin':c.plugin,'task':smart_check.TASKS.get(c.task,c.task),'runs':len(c.runs),'entries':[{'when':str(r.get('when','')),'agent':str(r.get('agent','')),'ok':r.get('ok') is True,'tokens':plugin_ai.tokens_of(r)} for r in c.runs[:100]],'totals':{key:getattr(c.totals,key) for key in ('runs','ok','tokens_today','tokens','cost','unknown')}}
                                  for c in smart_check.categories(ai_helper.runs())]}
        if method == 'system.forget_disk':
            if set(params) != {'node'} or not isinstance(params['node'], str):
                raise ValueError('Choose a missing disk')
            if self.installation_running() or any(item.operation == 'system.refresh' and item.state == 'running' for item in self.tasks.items.values()):
                raise ValueError('Finish System Map work before forgetting a disk')
            result = self.system_map.forget_disk(params['node'])
            return {'ok': True, **self.system_public(result)}
        if method == 'system.cached':
            if params:
                raise ValueError('Unexpected System Map parameters')
            import system_map_cache
            return self.system_public(system_map_cache.load(self.system_map.cache_path))
        if method == 'system.refresh':
            if self.installation_running():raise ValueError('Finish committed changes before refreshing')
            if set(params) not in (set(), {'search'}) or type(params.get('search', False)) is not bool:
                raise ValueError('Invalid System Map refresh')
            return self.tasks.start_system(self.settings_path, params.get('search', False),
                lambda result: self.system_public(self.system_map.register(result)))
        if method == 'system.fix_preview':
            return self.system_map.fix_preview(params)
        if method == 'system.help_preview':
            return self.system_map.preview(params)
        if method == 'system.help_apply':
            if set(params) != {'preview'}:
                raise ValueError('Invalid AI-help handle')
            if self.installation_running():
                raise ValueError('An installation is already running')
            return self.system_map.apply(params['preview'], self.sessions, self.tasks.start_system_analysis)
        if method == 'existing.mounts':
            import existing_ai
            if params:
                raise ValueError('Unexpected mount parameters')
            return {'mounts': existing_ai.mounts()}
        if method == 'existing.scan':
            import existing_ai
            if set(params) != {'path'} or not isinstance(params['path'], str):
                raise ValueError('Choose a mounted folder')
            existing_ai.root_for(params['path'], existing_ai.mounts())
            if any(t.operation == 'existing.scan' and t.state == 'running' for t in self.tasks.items.values()):
                raise ValueError('A disk scan is already running')
            return self.tasks.start_existing_scan(params['path'], lambda result: self.finish_system_search(params['path'],result))
        if method == 'existing.preview':
            return self.existing.preview(params)
        if method == 'existing.check':
            if set(params) != {'found'}:
                raise ValueError('Invalid program check')
            return self.tasks.start_existing_check(self.existing.get(params['found']))
        if method == 'existing.apply':
            if set(params) != {'plan'}:
                raise ValueError('Invalid reconnect preview')
            if self.installation_running():
                raise ValueError('An installation is already running')
            return self.existing.apply(params['plan'], self.tasks.start_existing_apply,
                                       self.connections.register_backup)
        if method == 'installers.preview':
            import flutter_installers
            if self.installation_running():
                raise ValueError('An installation is already running')
            # Pure shape/registry check; release lookup belongs in the worker.
            if set(params)-{'kind','key','build'} or not {'kind','key'}<=set(params):
                raise ValueError('Invalid installer selection')
            if not all(isinstance(value,str) for value in params.values()):
                raise ValueError('Invalid installer selection')
            return self.tasks.start_installer_preview(params,self.settings_path,self.installer_plans.register)
        if method == 'installers.install':
            if self.installation_running() or any(self.sessions.poll(session) is None for session in self.sessions.items.values()):
                raise ValueError('Finish running operations before installing')
            return self.installer_plans.apply(params,self.tasks.start_installer)
        if method == 'guide.snapshot':
            if params:
                raise ValueError('Unexpected guide parameters')
            return self.tasks.start_guide(self.settings_path)
        if method == 'guide.choose':
            if set(params) != {'route'}:
                raise ValueError('Invalid route selection')
            import flutter_first_agent
            return flutter_first_agent.choose(params['route'], self.adapters, self.settings_path)
        if method == 'agents.action_preview':
            return self.agent_actions.preview(params)
        if method == 'agents.action_apply':
            if set(params) != {'preview'} or not isinstance(params['preview'],str):
                raise ValueError('Invalid agent action preview')
            if self.addon_installing():
                raise ValueError('Add-on installation in progress')
            return self.agent_actions.apply(params['preview'], self.sessions)
        if method == "agents.activity":
            if set(params) != {"command"}:
                raise ValueError("Expected an agent")
            agent = self.agent(params['command'])
            _, activity = self.activity([agent])
            return activity.get(agent.command, {'instances': 0, 'subagents_supported': False, 'children': []})
        if method == "models.remove_preview":
            return self.removals.preview(params)
        if method == "models.remove_apply":
            if set(params) != {"removal"} or not isinstance(params["removal"], str):
                raise ValueError("Invalid removal handle")
            return self.removals.apply(params["removal"], self.tasks.start_removal)
        if method == "connections.snapshot":
            if set(params) - {'command'} or ('command' in params and not isinstance(params['command'], str)):
                raise ValueError("Unexpected connection parameters")
            return self.connections.snapshot()
        if method == 'connections.author_preview':
            result = self.connections.author_preview(params)
            anchors = []
            for command in result.pop('agent_commands'):
                anchors.extend(self.task_focus({'command': command, 'kind': result['kind'], 'item': result['item']}))
            return {**result, 'focus': list(dict.fromkeys(anchors))}
        if method in ('agents.halt_preview', 'agents.halt_apply'):
            import flutter_map_instances
            if not hasattr(self, '_map_instances'):
                self._map_instances = flutter_map_instances.Instances()
            if method == 'agents.halt_preview':
                return self._map_instances.preview(params, self.sessions)
            return self._map_instances.apply(params, self.tasks.start_halt)
        if method == 'connections.repair_preview':
            import flutter_map_editor
            return flutter_map_editor.repair_preview(params, self.current_map(), self.connections, self.settings_path)
        if method in ('connections.move_preview', 'models.switch_preview', 'models.attach_preview'):
            import flutter_map_editor
            return flutter_map_editor.preview(method, params, self.current_map(), self.connections, self.settings_path)
        if method == "connections.preview":
            return self.connections.preview(params)
        if method in ("connections.apply", "connections.undo"):
            field = "plan" if method == "connections.apply" else "undo"
            if set(params) != {field} or not isinstance(params[field], str):
                raise ValueError("Invalid connection handle")
            return self.connections.apply(params[field], queue=self.tasks.start_plan) if field == "plan" else self.connections.undo(params[field])
        if method == "providers.snapshot":
            if params:
                raise ValueError("Unexpected provider parameters")
            import flutter_providers
            return flutter_providers.snapshot(self.settings_path)
        if method == "providers.run":
            if self.installation_running():raise ValueError('Finish committed changes first')
            if set(params) != {"operation", "params"} or not isinstance(params["operation"], str):
                raise ValueError("Invalid provider operation")
            return self.tasks.start(params["operation"], params["params"])
        if method in ("tasks.status", "tasks.cancel"):
            if set(params) != {"task"} or not isinstance(params["task"], str) or params["task"] not in self.tasks.items:
                raise ValueError("Unknown operation handle")
            return self.tasks.status(params["task"]) if method == "tasks.status" else self.tasks.cancel(params["task"])
        if method in ('addons.remove_preview','addons.remove_apply','addons.remove_undo'):
            self.guard_addon_changes()
            field = 'id' if method.endswith('_preview') else 'preview' if method.endswith('_apply') else 'undo'
            if set(params)!={field} or not isinstance(params[field],str) or self.adapters is None:
                raise ValueError('Invalid add-on removal')
            if field=='id':return self.addon_actions.preview(self.adapters, params[field])
            if field=='preview':return self.addon_actions.apply(params[field],self.adapters,self.settings_path)
            return self.addon_actions.undo(params[field],self.adapters,self.settings_path)
        if method == 'addons.catalog':
            if params or self.adapters is None:
                raise ValueError('Add-on service unavailable')
            return self.tasks.start_catalog(self.settings_path, self.catalog_focus)
        if method == 'addons.install':
            self.guard_addon_changes()
            if (set(params) != {'preview'} or not isinstance(params['preview'], str)
                    or self.adapters is None):
                raise ValueError('Invalid add-on preview')
            if any(self.sessions.poll(session) is None for session in self.sessions.items.values()):
                raise ValueError('Finish running agents before changing add-ons')
            if self.addon_installing():
                raise ValueError('An add-on installation is already running')
            if not settings_schema.value(ai_core.load_settings(self.settings_path), 'addons_online'):
                raise ValueError('Online add-on access disabled')
            return self.addon_catalog.apply(params['preview'], lambda record:
                self.tasks.start_addon_install(record, self.settings_path, self.finish_addon_install))
        if method in ('setup.detect', 'setup.apply', 'setup.later'):
            if self.adapters is None:
                raise ValueError('Add-on service unavailable')
            if method == 'setup.apply':
                self.guard_addon_changes()
                if self.addon_installing():
                    raise ValueError('Add-on installation in progress')
                if set(params) != {'enabled'}:
                    raise ValueError('Invalid setup request')
                import flutter_setup
                return flutter_setup.apply(self.adapters, self.settings_path, params['enabled'])
            if params:
                raise ValueError('Unexpected setup parameters')
            if method == 'setup.detect':
                return self.tasks.start_setup(self.settings_path)
            ai_core.update_settings(self.settings_path, setup_done=True)
            return {'ok': True}
        if method == "addons.list":
            if params or self.adapters is None:
                raise ValueError("Add-on service unavailable")
            return self.adapters.snapshot(self.enabled_addons())
        if method == "addons.set_enabled":
            self.guard_addon_changes()
            if self.addon_installing():
                raise ValueError('Add-on installation in progress')
            if set(params) != {"id", "enabled"} or not isinstance(params["id"], str) or type(params["enabled"]) is not bool:
                raise ValueError("Invalid add-on request")
            if self.adapters is None:
                raise ValueError("Add-on service unavailable")
            item = next((a for a in self.adapters.items if a.id == params["id"]), None)
            if item is None or item.kind not in ("agent", "provider") or (
                    params["enabled"] and item.state not in ("verified", "loaded")):
                raise ValueError("Add-on unavailable")
            enabled = self.enabled_addons()
            if params["enabled"]:
                enabled.add(item.id)
            else:
                enabled.discard(item.id)
            before = self.enabled_addons()
            try:
                self.adapters.reload(enabled)
                if params['enabled'] and not any(a.id == item.id and a.state == 'loaded' for a in self.adapters.items):
                    raise ValueError('An adapter could not be loaded')
                ai_core.update_settings(self.settings_path, addons_enabled=sorted(enabled))
            except Exception:
                self.adapters.reload(before)
                raise
            return self.adapters.snapshot(enabled)
        if method == 'app.settings_changed':
            if params:
                raise ValueError('Unexpected parameters')
            # Devel router writes ported settings in Dart; drop only cached
            # translations here, never replay the settings write.
            i18n._lang = None
            return {}
        if method in ('settings.get', 'app.identity', 'desktop.snapshot'):
            if params:
                raise ValueError('Unexpected parameters')
            if method == 'settings.get':
                return self.settings()
            import identity
            import desktop
            if method == 'app.identity':
                return {'name': identity.name(), 'app_id': identity.app_id(),
                        'short_name': identity.short_name(), 'config_dir': str(identity.config_dir()),
                        'cache_dir': str(identity.cache_dir())}
            theme_dir = desktop.theme_dir()
            return {'name': desktop.NAME, 'theme_dir': str(theme_dir) if theme_dir else None}
        if method == 'i18n.lookup':
            if (set(params) not in ({'text'}, {'text', 'other', 'n'})
                    or not isinstance(params.get('text'), str)
                    or ('other' in params and (not isinstance(params['other'], str) or type(params['n']) is not int))):
                raise ValueError('Invalid translation')
            text = i18n._(params['text']) if 'other' not in params else i18n.ngettext(params['text'], params['other'], params['n'])
            return {'language': i18n.current(), 'text': text}
        if method == "settings.update":
            if set(params) != {"values"} or not isinstance(params["values"], dict):
                raise ValueError("Invalid settings request")
            values = dict(params["values"])
            if not values or set(values) - UI_SETTINGS:
                raise ValueError("Unknown setting")
            for key, value in values.items():
                if (value is not None or key in ("flutter_theme_mode", "map_light_fps", "flutter_map_layout", "map_animations")) and not settings_schema.SCHEMA[key].valid(value):
                    raise ValueError("Invalid setting value")
            if "language" in values and values["language"] not in {"auto", *i18n.CODES}:
                raise ValueError("Unknown language")
            if values.get("agent_folder") is not None:
                folder = agent_projects.folder(values["agent_folder"])
                if folder is None:
                    raise ValueError("Project folder unavailable")
                values["agent_folder"] = folder
            if "map_layers" in values and (values["map_layers"] is None or
                    set(values["map_layers"]) - set(settings_schema.MAP_LAYERS)):
                raise ValueError("Unknown map layer")
            ai_core.update_settings(self.settings_path, **values)
            if "language" in values:
                i18n._lang = None  # invalidate the existing translation module's settings cache
            return self.settings()
        if method == "agents.details":
            if set(params) != {"command"}:
                raise ValueError("Expected an agent")
            agent = self.agent(params["command"])
            import agent_details
            info = agent_details.details_for(agent.command)
            # Explicit DTO: do not serialize an adapter object or arbitrary hook data.
            return {
                "command": agent.command, "plan": info.plan, "model": info.model,
                "actions": self.action_choices(agent),
                "providers": [{"name": p.name, "local": p.local, "active": p.active}
                              for p in info.providers],
                "limits": [{"label": limit.label, "percent": limit.percent,
                            "resets_at": limit.resets_at.isoformat() if limit.resets_at else None}
                           for limit in info.limits],
                "today_prompts": info.today_prompts, "today_sessions": info.today_sessions,
                "today_tokens": info.today_tokens, "total_sessions": info.total_sessions,
                "active_days": info.active_days,
                "last_used": info.last_used.isoformat() if info.last_used else None,
            }
        if method == "map.snapshot":
            if (set(params) - {'force', 'poll'} or any(type(value) is not bool for value in params.values())
                    or (params.get('force') and params.get('poll'))):
                raise ValueError("Invalid map scan request")
            reply = lambda: {**self._map_result, 'pending': self._map_task is not None or self._map_force_pending}
            if self._map_task is not None and self._map_task not in self.tasks.items:
                self._map_task = None
            if self._map_task is not None:
                status = self.tasks.status(self._map_task)
                if status['state'] == 'running':
                    if params.get('force') and not self._map_forced:
                        self._map_force_pending = True
                    return reply()
                if status['state'] == 'done':
                    self._map_result = status['result']
                    self._map_built = time.monotonic()
                self._map_task = None
            if params.get('poll') and not self._map_force_pending:
                return reply()
            saved = ai_core.load_settings(self.settings_path)
            interval = cast(int, settings_schema.value(saved, 'map_scan_interval'))
            targets = settings_schema.value(saved, 'map_scan_targets')
            force = params.get('force', False) or self._map_force_pending
            if not force and (interval == 0 or not targets):
                return reply()
            owned = [{'command': session.command, 'pid': session.process.pid}
                     for session in self.sessions.items.values() if self.sessions.poll(session) is None]
            scan_settings = json.dumps({key: settings_schema.value(saved, key) for key in MAP_SCAN_SETTINGS},
                                       sort_keys=True, ensure_ascii=True)
            inputs = (scan_settings, tuple((row['command'], row['pid']) for row in owned))
            if not force and inputs == self._map_inputs and time.monotonic() - self._map_started < interval:
                return reply()
            try:
                self._map_task = self.tasks.start_snapshot(self.settings_path, owned, force=force)['task']
            except ValueError:
                return reply()
            self._map_forced = force
            self._map_force_pending = False
            self._map_started, self._map_inputs = time.monotonic(), inputs
            return reply()
        if method == 'app.theme':
            if params:
                raise ValueError('Unexpected theme parameters')
            return {'theme': self.theme(ai_core.load_settings(self.settings_path))}
        if method == "app.snapshot":
            if params:
                raise ValueError("Unexpected parameters")
            return self.snapshot()
        if method in ("sessions.read", "sessions.write", "sessions.resize", "sessions.stop"):
            expected = {"sessions.read": {"session"}, "sessions.write": {"session", "data"},
                        "sessions.resize": {"session", "cols", "rows"}, "sessions.stop": {"session"}}[method]
            if set(params) != expected or not isinstance(params.get("session"), str):
                raise ValueError("Invalid session request")
            ident = params["session"]
            if ident not in self.sessions.items:
                raise ValueError("Unknown session")
            if method == "sessions.read":
                result = self.sessions.read(ident)
                self.agent_actions.observe(ident, result)
                return result
            if method == "sessions.stop":
                result = self.sessions.stop(ident)
                self.agent_actions.forget(ident)
                return result
            if method == "sessions.resize":
                return self.sessions.resize(ident, params["cols"], params["rows"])
            if not isinstance(params["data"], str) or len(params["data"]) > 24 * 1024:
                raise ValueError("Invalid terminal input")
            try:
                data = base64.b64decode(params["data"], validate=True)
            except binascii.Error as error:
                raise ValueError("Invalid terminal input") from error
            return self.sessions.write(ident, data)
        if method == "sessions.start":
            return self.start(params)
        if method not in ("projects.pin", "projects.forget"):
            raise ValueError("Unknown operation")
        if set(params) != {"command", "path"}:
            raise ValueError("Expected command and path")
        command, path = params["command"], params["path"]
        if not isinstance(command, str) or not any(a.command == command for a in agents.list_agents()):
            raise ValueError("Unknown agent")
        if path is not None and (not isinstance(path, str) or len(path) > 4096):
            raise ValueError("Invalid path")
        settings = ai_core.load_settings(self.settings_path)
        pinned = settings.get("agent_projects", {})
        if method == "projects.pin":
            ai_core.update_settings(self.settings_path, agent_projects=agent_projects.pin(command, path, pinned))
        else:
            if not isinstance(path, str):
                raise ValueError("Expected a history path")
            history, pinned = agent_projects.forget(command, path, settings.get("agent_project_history", {}), pinned)
            ai_core.update_settings(self.settings_path, agent_project_history=history, agent_projects=pinned)
        return self.projects(command)

    def activity(self, catalog) -> tuple[dict, dict]:
        import flutter_activity
        saved = ai_core.load_settings(self.settings_path)
        if not hasattr(self, "_activity_tracker"):
            import agent_activity
            self._activity_tracker = agent_activity.Activity()
        return flutter_activity.snapshot(catalog, self.sessions,
            recent=cast(int, settings_schema.value(saved, 'subagents_minutes')) * 60,
            kept=cast(int, settings_schema.value(saved, 'subagents_kept')), tracker=self._activity_tracker)

    def action_choices(self, agent) -> dict:
        import install_recipes
        harness = harnesses.get(agent.command)
        access = harness.access() if harness and harness.access else None
        choices = {}
        for action in ('install','update','uninstall'):
            step = install_recipes.choose(harness.install, action, agent.source) if harness else None
            choices[action] = bool(step and (step.commands or step.url) and
                                   (action == 'install' or agent.installed))
        return {**choices, 'managed_install':bool(not agent.installed and agent.command in __import__('install_ctl').AGENT_INSTALLERS), 'login':bool(agent.installed and access and access.logins),
                'verify':bool(agent.installed and harness and harness.ask),
                # An API key the agent reads: handed to its own command, or written to its .env file.
                'key':bool(agent.installed and access and access.key and (access.key.stdin or access.key.env_file))}

    def installation_running(self) -> bool:
        return any(item.operation in ('addons.install','installers.install','existing.apply','system.move_apply','system.move_undo') and item.state == 'running'
                   for item in self.tasks.items.values())

    def guard_addon_changes(self):
        if self.addon_installing():raise ValueError('An installation is already running')
        if any(self.sessions.poll(session) is None for session in self.sessions.items.values()):
            raise ValueError('Finish running agents before changing add-ons')

    def addon_installing(self) -> bool:
        return self.installation_running()

    def finish_addon_install(self, result: dict) -> dict:
        if set(result) != {'ok', 'id', 'version'} or result['ok'] is not True:
            raise ValueError('Invalid add-on installation result')
        if self.adapters is None:
            raise ValueError('Add-on service unavailable')
        enabled = self.enabled_addons()
        self.adapters.reload(enabled)
        item = next((item for item in self.adapters.items if item.id == result['id']), None)
        return {**result, 'enabled': result['id'] in enabled,
                'loaded': bool(item and item.state == 'loaded')}

    def start(self, params: dict) -> dict:
        if self.addon_installing():
            raise ValueError('Add-on installation in progress')
        if set(params) != {"command", "path", "outside"} or type(params["outside"]) is not bool:
            raise ValueError("Invalid start request")
        command = params["command"]
        if not isinstance(command, str):
            raise ValueError("Invalid agent")
        agent = next((a for a in agents.list_agents() if a.command == command and a.installed), None)
        harness = harnesses.get(command)
        if agent is None or harness is None or harness.chat_app:
            raise ValueError("No terminal program for this agent")
        chosen = self.projects(command)["default"] if params["path"] is None else params["path"]
        folder = agent_projects.folder(chosen)
        if folder is None:
            raise ValueError("Project folder unavailable")
        env = dict(os.environ)
        ai_core.drop_agent_session_vars(env)
        ai_core.add_user_program_dirs(env)
        env.update(TERM="xterm-256color", COLORTERM="truecolor")
        env.pop("AI_AGENTS_MAP_PAGE", None)
        env.pop("AI_AGENTS_MAP_VIEW", None)
        program = shutil.which(command, path=env.get("PATH"))
        if program is None:
            raise ValueError("Program unavailable")
        argv = [program, *harness.start]
        ident = None
        if params["outside"]:
            import desktop
            # env removes inherited session markers without interpolating a shell command.
            unset = [part for name in os.environ if ai_core.is_agent_session_var(name)
                     or name in ("AI_AGENTS_MAP_PAGE", "AI_AGENTS_MAP_VIEW") for part in ("-u", name)]
            launcher = shutil.which("env")
            if launcher is None or not desktop.open_terminal(
                    [launcher, *unset, f"PATH={env['PATH']}", "TERM=xterm-256color", "COLORTERM=truecolor", *argv], folder):
                raise OSError("Terminal could not be opened")
        else:
            ident = self.sessions.start(command, argv, folder, env)
        try:
            settings = ai_core.load_settings(self.settings_path)
            ai_core.update_settings(self.settings_path, agent_project_history=agent_projects.used(
                command, folder, settings.get("agent_project_history", {})))
        except Exception:
            if ident is not None:
                self.sessions.stop(ident)
            raise
        return {"session": ident, "command": command, "path": folder}

    def build_map(self, cache: dict | None = None, targets=None) -> dict:
        import agent_details
        import graph
        import inventory
        cache = {} if cache is None else cache
        targets = set(settings_schema.MAP_SCAN_TARGETS if targets is None else targets)
        if 'catalog' not in cache or 'agents' in targets:
            cache['catalog'] = agents.list_agents()
            cache['details'] = {agent.command: agent_details.details_for(agent.command)
                                for agent in cache['catalog'] if agent.installed}
        catalog, details = cache['catalog'], cache['details']
        if 'inventory' not in cache or 'inventory' in targets:
            cache['inventory'] = inventory.collect(catalog)
            # The provider watcher's config after each scan, as the Dart core writes it (the core,
            # not this reference, manages the watcher's user service).
            import provider_watch
            try:
                provider_watch.write_config(cache['inventory'], (self.settings_path.parent if self.settings_path
                                                                 else provider_watch.CONFIG.parent) / 'providers-with-agents.json')
            except OSError:
                pass
        if 'activity' not in cache or 'activity' in targets:
            cache['activity'] = self.activity(catalog)
        running, activity = cache['activity']
        labels = {"skills": lambda n: i18n.ngettext("1 skill", "{0} skills", n).format(n),
                  "more": lambda n: i18n._("+{0} more").format(n),
                  "running": lambda n: i18n._("running") if n == 1 else i18n._("{0} running").format(n),
                  "in_use": lambda names: i18n._("in use · {0}").format(names),
                  "server_off": i18n._("server off")}
        import flutter_map_payload
        failures = flutter_map_payload.failures(self.settings_path)
        built = graph.build(catalog, details, cache['inventory'], labels=labels, running=running, failures=failures)
        payload_edges = flutter_map_payload.edges(built, activity, failures, cache['inventory'],
            self.settings().get('map_animations', 'all'))
        hidden = graph.hidden_by_layers(built, self.settings()["map_layers"])
        return {"activity": activity, "nodes": [asdict(node) for node in built.nodes if node.id not in hidden],
                "edges": [edge for edge in payload_edges
                          if edge["source"] not in hidden and edge["target"] not in hidden]}


def serve(service: Service, source, output: TextIO) -> None:
    while True:
        raw = source.readline(MAX_REQUEST + 1)
        if not raw:
            return
        request_id = None
        try:
            if len(raw) > MAX_REQUEST:
                # An oversized record cannot leave its tail as another request.
                raise OverflowError("Request too large")
            request = json.loads(raw)
            if not isinstance(request, dict):
                raise ValueError("Expected an object")
            request_id = request.get("id")
            if type(request_id) is not int or request_id < 0:
                request_id = None
                raise ValueError("Expected a request id")
            if type(request.get("protocol")) is not int or request.get("protocol") != PROTOCOL:
                raise ValueError("Unsupported protocol")
            method, params = request.get("method"), request.get("params", {})
            if not isinstance(method, str) or not isinstance(params, dict):
                raise ValueError("Invalid request")
            # Adapter diagnostics must not corrupt the framed stdout stream.
            with contextlib.redirect_stdout(sys.stderr):
                result = service.dispatch(method, params)
            response = {"id": request_id, "result": result}
        except OverflowError:
            response = {"id": request_id, "error": {"code": "request_too_large"}}
            output.write(json.dumps(response) + "\n")
            output.flush()
            while raw and not raw.endswith(b"\n"):
                raw = source.readline(MAX_REQUEST + 1)
            continue
        except (ValueError, TypeError, UnicodeError):
            response = {"id": request_id, "error": {"code": "invalid_request"}}
        except Exception:
            # Do not ship exception messages (which can contain local private data).
            response = {"id": request_id, "error": {"code": "operation_failed"}}
        output.write(json.dumps(response, ensure_ascii=True) + "\n")
        output.flush()


def main() -> None:
    # Also protect direct reference-service launches, before initialization.
    os.environ["ASTERISM_FLUTTER_DEVEL"] = "1"
    def interrupted(_signum, _frame):
        raise SystemExit(0)

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, interrupted)
    service = Service()
    try:
        with contextlib.redirect_stdout(sys.stderr):
            service.initialize()
        serve(service, sys.stdin.buffer, sys.stdout)
    finally:
        # A fallback TERM must not interrupt EOF cleanup of owned processes.
        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(signum, signal.SIG_IGN)
        try:
            service.tasks.close()
        finally:
            try:
                service.sessions.close()
            finally:
                service.agent_actions.close()


if __name__ == "__main__":
    main()
