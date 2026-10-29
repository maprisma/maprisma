"""Provider/model operations for the Flutter service and isolated workers."""
from __future__ import annotations

from dataclasses import asdict
from pathlib import Path

import inventory
import install_ctl
import llm_engine
import models_ctl
import providers
import runtime_ctl

OPERATIONS = frozenset(('runtime.start', 'runtime.stop', 'model.load', 'model.unload',
                        'model.import', 'models.search', 'models.files', 'models.download', 'models.pull'))


def runtime(key: str):
    provider = providers.get(key) if isinstance(key, str) else None
    if provider is None or provider.kind != 'local' or provider.detect is None:
        raise ValueError('Unknown local provider')
    result = provider.detect(inventory.own_processes())
    if result.key != key:
        raise ValueError('Provider identity mismatch')
    return result


def snapshot(settings_path: Path | None = None) -> dict:
    processes = inventory.own_processes()
    local = []
    for provider in providers.local():
        if provider.detect is None:
            continue
        rt = provider.detect(processes)
        engine = llm_engine.of(rt)
        local.append({'key': rt.key, 'name': rt.name, 'installed': rt.installed,
                      'installable':bool(not rt.installed and (inst := install_ctl.INSTALLERS.get(rt.key)) and inst.can_install),
                      'running': rt.running, 'server_off': rt.server_off, 'address': rt.address,
                      'models_dir': rt.models_dir, 'models': [m for m in rt.models if isinstance(m, str)],
                      'can_control': runtime_ctl.can_control(rt), 'can_load': bool(engine.can_load),
                      'removable': engine.removable if rt.installed and engine.removable in ('file', 'api') else '',
                      'download': engine.download if rt.installed else '',
                      'can_import': bool(rt.installed and engine.download in ('file', 'pull')),
                      'tunable': bool(rt.installed and engine.tuning)})
    import ai_core
    folders = ai_core.load_settings(settings_path).get('model_folders', [])
    folders = folders if isinstance(folders, list) else []
    return {'folders': [{'path': p, 'available': Path(p).is_dir()} for p in folders if isinstance(p, str)],
            'local': local, 'online': [{'key': p.key, 'name': p.name} for p in providers.online()]}


def validate(operation: str, params: dict) -> None:
    if operation not in OPERATIONS or not isinstance(params, dict):
        raise ValueError('Unknown provider operation')
    shapes = {
        'runtime.start': {'key'}, 'runtime.stop': {'key'},
        'model.load': {'key', 'model'}, 'model.unload': {'key', 'model'},
        'model.import': {'key', 'path'}, 'models.search': {'query'},
        'models.files': {'repo'}, 'models.download': {'key', 'repo', 'file', 'size'},
        'models.pull': {'key', 'name'},
    }
    if set(params) != shapes[operation] or any(not isinstance(v, str) or len(v) > 4096
                                             for key, v in params.items() if key != 'size'):
        raise ValueError('Invalid provider operation')
    if operation == 'models.download' and (type(params['size']) is not int or params['size'] < 0):
        raise ValueError('Invalid model size')
    if 'repo' in params and not models_ctl.REPO_RE.fullmatch(params['repo']):
        raise ValueError('Invalid model repository')
    if 'model' in params and not llm_engine.MODEL_KEY.fullmatch(params['model']):
        raise ValueError('Invalid model name')
    if operation == 'models.search' and not 1 <= len(params['query'].strip()) <= 120:
        raise ValueError('Invalid search')
    if operation == 'models.pull' and not models_ctl.OLLAMA_NAME_RE.fullmatch(params['name']):
        raise ValueError('Invalid pull name')
    # The entry's shown name, as models_ctl.files gives it (no folder, no .gguf); its paths are
    # looked up again from the model host.
    if operation == 'models.download' and (not models_ctl.ENTRY_NAME_RE.fullmatch(params['file']) or
            params['file'] in ('.', '..')):
        raise ValueError('Invalid model filename')


def execute(operation: str, params: dict, progress=lambda _fraction, _text='': None) -> dict:
    validate(operation, params)
    if operation == 'models.search':
        return {'repos': [asdict(repo) for repo in models_ctl.search(params['query'].strip(), limit=25)]}
    if operation == 'models.files':
        return {'repo': params['repo'], 'files': [asdict(entry) for entry in models_ctl.files(params['repo'])[:100]]}
    rt = runtime(params['key'])
    if not rt.installed:
        raise ValueError('Provider is not installed')
    engine = llm_engine.of(rt)
    if operation.startswith('runtime.'):
        if not runtime_ctl.can_control(rt):
            raise ValueError('Provider cannot be controlled')
        ok, _message = runtime_ctl.start(rt) if operation == 'runtime.start' else runtime_ctl.stop(rt)
        if not ok:
            raise RuntimeError('Provider operation failed')
    elif operation in ('model.load', 'model.unload'):
        if params['model'] not in rt.models or not engine.can_load:
            raise ValueError('Model unavailable')
        ok, _message = (runtime_ctl.load(rt, params['model']) if operation == 'model.load'
                        else runtime_ctl.unload_model(rt, params['model']))
        if not ok:
            raise RuntimeError('Model operation failed')
    elif operation == 'model.import':
        path = Path(params['path']).expanduser()
        if not path.is_absolute():
            raise ValueError('Expected an absolute model path')
        path = path.resolve(strict=True)
        if not path.is_file() or path.suffix.lower() != '.gguf' or engine.download not in ('file', 'pull'):
            raise ValueError('Expected a GGUF model file')
        engine.add_file(rt, path)
        engine.refresh(rt)
    elif operation == 'models.pull':
        if engine.download != 'pull':
            raise ValueError('Provider does not support pulls')
        engine.pull(rt, params['name'], progress, lambda: False)
    elif operation == 'models.download':
        # Resolve file metadata again from the fixed model host. No client URLs,
        # destination paths, sizes or split-part paths enter the downloader.
        entries = models_ctl.files(params['repo'])
        entry = next((item for item in entries if item.name == params['file']), None)
        if entry is None:
            raise ValueError('Model file unavailable')
        if entry.size != params['size']:
            raise ValueError('Model metadata changed; select the file again')
        if engine.download == 'pull':
            if models_ctl.ollama_pull_problem(entry, entries):
                raise ValueError('This model cannot be pulled by this provider')
            name = engine.pull_name(rt, params['repo'], entry, models_ctl.HF)
            engine.pull(rt, name, progress, lambda: False)
        elif engine.download == 'file' and rt.models_dir:
            models_ctl.download_gguf(rt.key, Path(rt.models_dir).expanduser(), params['repo'], entry,
                                     progress, lambda: False)
            engine.refresh(rt)
        else:
            raise ValueError('Provider has no model destination')
    return {'ok': True}
