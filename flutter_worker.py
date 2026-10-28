"""One isolated provider/model operation. Not an executable-command endpoint."""
import contextlib
import json
import math
import sys
import os
import stat
from typing import Any, cast

import ai_core
from flutter_addons import AdapterRegistry
import flutter_providers


def execute_private(operation,body,progress):
    from pathlib import Path
    if operation.startswith('system.move_'):
        import system_moves
        record=json.loads(body)
        chosen=Path(record['settings_path']) if record.get('settings_path') else None
        registry=AdapterRegistry()
        registry.reload(set(ai_core.load_settings(chosen).get('addons_enabled',[])))
        if operation=='system.move_preview':return system_moves.prepare(record)
        if operation=='system.move_apply':return system_moves.execute(body,progress)
        if operation=='system.move_undo':return system_moves.undo(record['undo'],chosen,progress)
        raise ValueError('Invalid move operation')
    if operation=='system.tool_check':
        import system_tools
        return system_tools.check(body)
    if operation=='system.analyze':
        import system_map_analysis
        return system_map_analysis.analyze(body)
    if operation in ('existing.apply','existing.check'):
        import flutter_existing
        return flutter_existing.execute(body) if operation=='existing.apply' else flutter_existing.check(json.loads(body))
    if operation=='installers.install':
        import flutter_installers
        return flutter_installers.execute(body,progress)
    if operation=='addons.install':
        import flutter_addon_catalog
        return flutter_addon_catalog.execute(body)
    if operation=='connections.apply':
        import connect,flutter_plan_wire,llm_engine
        plan,root=flutter_plan_wire.decode(body)
        contexts,plan.contexts=plan.contexts,[]
        backup=connect.apply(plan,backup_root=root)
        failures=0
        for runtime,model,tokens in contexts:
            try:llm_engine.of(runtime).set_context(runtime,model,tokens)
            except Exception:failures+=1
        return {'backup':str(backup),'context_failures':failures}
    if operation=='models.remove':
        import flutter_removals
        return flutter_removals.execute(json.loads(body))
    raise ValueError('Invalid private operation')


def main():
    output = sys.stdout
    def send(message):
        try:
            output.write(json.dumps(message, ensure_ascii=True, allow_nan=False) + '\n')
            output.flush()
        except BrokenPipeError:
            pass  # A detached commit still completes after the UI closes.
    def progress(fraction, text=''):
        fraction = float(fraction)
        send({'type': 'progress', 'fraction': min(1.0, max(0.0, fraction)) if math.isfinite(fraction) else 0.0,
              'text': str(text or '')[:300]})
    try:
        raw = sys.stdin.buffer.readline(64 * 1024 + 1)
        if len(raw) > 64 * 1024:
            raise ValueError('Request too large')
        request = json.loads(raw)
        if not isinstance(request, dict) or set(request) != {'operation', 'params'}:
            raise ValueError('Invalid worker request')
        private = len(sys.argv) == 3 and sys.argv[1] == '--plan-fd'
        if not private and request['operation'] not in ('map.snapshot', 'setup.detect', 'addons.catalog', 'guide.snapshot', 'installers.preview', 'existing.scan', 'system.refresh'):
            if len(sys.argv) != 1:
                raise ValueError('Invalid worker arguments')
            flutter_providers.validate(request['operation'], request['params'])
        with contextlib.redirect_stdout(sys.stderr):
            registry = AdapterRegistry()
            if not private and request['operation'] in ('map.snapshot', 'setup.detect', 'guide.snapshot', 'installers.preview', 'system.refresh'):
                from pathlib import Path
                chosen = request['params']['settings_path']
                saved = ai_core.load_settings(Path(chosen) if chosen else None)
                registry.reload(set(saved.get('addons_enabled', [])))
            elif request['operation'] not in ('addons.install', 'addons.catalog', 'installers.install', 'existing.scan', 'existing.apply', 'existing.check', 'system.analyze', 'system.tool_check', 'system.move_preview', 'system.move_apply', 'system.move_undo'):
                registry.reload(set(ai_core.setting('addons_enabled')))
            if request['operation'] == 'system.refresh' and not private:
                import flutter_system_map
                import system_tools
                sys.addaudithook(system_tools.read_only_scan_audit)
                import i18n
                i18n.SETTINGS_FILE=Path(chosen) if chosen else ai_core.settings_file()
                i18n._lang=None
                result = flutter_system_map.refresh(Path(chosen) if chosen else None, request['params']['search'], progress)
            elif request['operation'] == 'existing.scan' and not private:
                import existing_ai
                result = existing_ai.scan(request['params']['path'], progress)
            elif request['operation'] == 'installers.preview' and not private:
                import flutter_installers
                result = flutter_installers.prepare(request['params']['selection'],Path(chosen) if chosen else None)
            elif request['operation'] == 'guide.snapshot' and not private:
                import flutter_first_agent
                import i18n
                from pathlib import Path
                chosen = request['params']['settings_path']
                path = Path(chosen) if chosen else None
                i18n.SETTINGS_FILE = path or ai_core.settings_file()
                i18n._lang = None
                result = flutter_first_agent.snapshot(registry, path)
            elif request['operation'] == 'addons.catalog' and not private:
                import flutter_addon_catalog
                from pathlib import Path
                chosen = request['params']['settings_path']
                result = flutter_addon_catalog.catalog_records(Path(chosen) if chosen else None)
            elif request['operation'] == 'setup.detect' and not private:
                from pathlib import Path
                chosen = request['params']['settings_path']
                saved = ai_core.load_settings(Path(chosen) if chosen else None)
                enabled = set(saved.get('addons_enabled', []))
                result = {'installed': sorted(registry.installed(enabled))}
            elif request['operation'] == 'map.snapshot' and not private:
                from pathlib import Path
                from types import SimpleNamespace
                from flutter_backend import Service
                params = request['params']
                service = Service(Path(params['settings_path']) if params['settings_path'] else None)
                service.adapters = registry
                service.sessions = cast(Any, SimpleNamespace(items={
                    str(i): SimpleNamespace(command=row['command'],
                        process=SimpleNamespace(pid=row['pid'], poll=lambda: None))
                    for i, row in enumerate(params['owned'])}))
                result = service.build_map()
            elif private:
                if request.get('operation') not in ('connections.apply', 'models.remove', 'addons.install', 'installers.install', 'existing.apply', 'existing.check', 'system.analyze', 'system.tool_check', 'system.move_preview', 'system.move_apply', 'system.move_undo') or request['params'] != {}:
                    raise ValueError('Invalid private operation')
                import connect
                import flutter_plan_wire
                with os.fdopen(int(sys.argv[2]), 'rb') as handle:
                    info = os.fstat(handle.fileno())
                    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                        raise ValueError('Expected a private plan file')
                    body = handle.read(flutter_plan_wire.MAX_BYTES + 1)
                result = execute_private(request['operation'], body, progress)
            else:
                result = flutter_providers.execute(request['operation'], request['params'], progress)
        send({'type': 'result', 'result': result})
    except Exception:
        send({'type': 'error', 'code': 'operation_failed'})


if __name__ == '__main__':
    main()
