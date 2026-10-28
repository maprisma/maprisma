"""Development-only scan differentials against an isolated reference HOME."""
from dataclasses import asdict
import datetime as dt
import json
import os
from pathlib import Path
from types import SimpleNamespace


def service():
    import agents
    import inventory
    import provider_watch
    import agent_activity
    import flutter_backend
    import time
    home = Path.home()
    proc = os.environ['ASTERISM_SCAN_PROC']
    system = Path(os.environ['ASTERISM_SCAN_SYSTEM_ROOT'])
    real_list = agents.list_agents
    agents.list_agents = lambda **kw: real_list(db=system / 'var/lib/pacman/local', **kw)
    # The Dart core gains the MCP library write with the write phase; compare reads only.
    import mcp_library
    mcp_library.remember = lambda used: None
    def own_processes():
        found = []
        for path in list(Path(proc).iterdir())[:4000] if Path(proc).is_dir() else []:
            if not path.name.isdigit() or path.stat().st_uid != os.getuid():
                continue
            try:
                import ai_core
                comm=ai_core.read_head(path/'comm',65536,False).decode('utf-8','replace').strip()
                argv=[a.decode('utf-8','replace') for a in ai_core.read_head(path/'cmdline',65536,False).split(b'\0') if a]
                found.append((int(path.name),comm,argv))
            except OSError:
                continue
        return found
    inventory.own_processes = own_processes
    original_scan=provider_watch._scan_agents
    # Callers pass /proc positionally: always scan the fixture's own process tree.
    provider_watch._scan_agents=lambda names,_proc=None,pids_out=None:original_scan(names,proc,pids_out)
    import subagents
    real_projects=subagents.claude_projects
    subagents.claude_projects=lambda agent,pids,now=None,root=subagents.CLAUDE_PROJECTS,proc_=None,recent=subagents.RECENT:real_projects(
        agent,pids,now,root,proc,recent)
    original_working=agent_activity.Activity.working
    agent_activity.Activity.working=lambda self,pids,**kw: original_working(self,pids,proc=proc,**kw)
    if os.environ.get('ASTERISM_SCAN_NOW'):
        now=float(os.environ['ASTERISM_SCAN_NOW'])
        time.time=lambda:now
        import smart_check
        real_categories=smart_check.categories
        smart_check.categories=lambda runs,days=30,now=None:real_categories(
            runs,days,now or __import__('datetime').datetime.fromtimestamp(float(os.environ['ASTERISM_SCAN_NOW'])))
    import ai_core
    result=flutter_backend.Service(ai_core.settings_file())
    result.adapters=SimpleNamespace(items=[])
    import flutter_tasks
    class MapTasks(flutter_tasks.Tasks):
        # Map scans finish at once in fixtures; commits run the real private worker.
        def start_snapshot(self,settings_path,owned,force=False):
            self.maps={'fixture':result.build_map()}
            self.items['fixture']=SimpleNamespace(state='done',operation='map.snapshot',process=SimpleNamespace(poll=lambda:0))
            return {'task':'fixture'}
        def status(self,handle):
            maps=getattr(self,'maps',{})
            return {'state':'done','result':maps[handle]} if handle in maps else super().status(handle)
    result.tasks=MapTasks()
    result._fixture_proc=proc
    return result


def dispatch(current,method,params):
    import agents,agent_details,harnesses,inventory,agent_security,agent_status
    if method=='scan.catalog':
        if params:raise ValueError('Unexpected fields')
        return {'agents':[asdict(a) for a in agents.list_agents()]}
    if method=='scan.inventory':
        if params:raise ValueError('Unexpected fields')
        return asdict(inventory.collect(agents.list_agents(),remember=False))
    if method in ('scan.sessions','scan.security','scan.costs','scan.usage'):
        if set(params)!={'command'} or not isinstance(params['command'],str):raise ValueError('Expected command')
        h=harnesses.get(params['command'])
        if h is None:raise ValueError('Unknown command')
        if method=='scan.security':
            report=agent_security.report_for(h.command)
            return json.loads(json.dumps(asdict(report),default=str)) | {'level':report.level()}
        now=float(os.environ['ASTERISM_SCAN_NOW'])
        today=dt.datetime.fromtimestamp(now).date()
        # Claude's generic API writes a rebuildable on-disk cache. Disable it in
        # this read-only fixture via an explicit, supported memory-only option.
        if h.session_files=='claude-files':
            import claude_sessions
            found=claude_sessions.collect_by_id(cache=None)
        else:
            found=h.sessions.collect() if h.sessions else {}
        if method=='scan.sessions':return {'sessions':{str(key):asdict(s) for key,s in found.items()}}
        if method=='scan.costs':
            value=agent_status.costs(h.command,today,sessions=found)
        else:
            value=agent_status.from_sessions(list(found.values()),'fixture',today)
        return {'value':json.loads(json.dumps(asdict(value),default=lambda v:v.isoformat() if isinstance(v,(dt.datetime,dt.date)) else str(v))) if value is not None else None}
    return current.dispatch(method,params)
