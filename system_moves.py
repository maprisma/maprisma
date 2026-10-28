"""Reviewed model-folder moves with existing file primitives, config backups and private Undo journals."""
from __future__ import annotations
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import time
import uuid

import ai_core
import connect
import existing_ai
import inventory
import model_folders
import model_move
import providers
import system_map_cache

MAX_BYTES=700*1024
JOURNAL_MAX=4*1024*1024


def journal_root(settings_path=None):
    """Undo is durable even when the default System Map cache is cleared."""
    return (settings_path or ai_core.settings_file()).parent / 'model-moves'


def _json(value):
    return json.dumps(value,default=str,ensure_ascii=True,sort_keys=True)


def prepare(selection: dict) -> dict:
    source=Path(selection['source']).resolve(strict=True)
    disk=Path(selection['disk'])
    mount=existing_ai.root_for(str(disk),existing_ai.mounts())
    if mount!=selection['mount']:raise ValueError('Destination mount changed')
    target=disk/source.name
    if target.resolve()!=target or (target.exists() and target.stat().st_dev!=disk.stat().st_dev):raise ValueError('Use a real destination on this mount')
    if model_folders.MODELS_INI.is_symlink():raise ValueError('Model preset is a symbolic link')
    local={p.key:p for p in providers.built_in_local()}
    local.update({p.key:p for p in providers.local()})
    processes=inventory.own_processes()
    runtimes=[p.detect(processes) for p in local.values() if p.detect]
    folders=model_folders.discover(runtimes,[str(source)])
    folder=next((f for f in folders if f.path==source),None)
    if folder is None:raise ValueError('No movable model files')
    if any(rt.running and rt.key in folder.readers for rt in runtimes):
        raise ValueError('Stop runtimes reading this folder before moving it')
    # Unknown provider settings are never rewritten; lost readers are explicitly disclosed.
    change=model_folders.plan(folder,target,runtimes,ini=model_folders.MODELS_INI)
    settings=Path(selection['settings_path']) if selection.get('settings_path') else ai_core.settings_file()
    if settings.is_symlink():raise ValueError('Settings path is a symbolic link')
    before=connect._read(settings)
    saved=json.loads(before) if before.strip() else {}
    if not isinstance(saved,dict):raise ValueError('Invalid application settings')
    added=saved.get('model_folders',[])
    if not isinstance(added,list) or any(not isinstance(x,str) for x in added):raise ValueError('Invalid model folders')
    updated=[p for p in added if os.path.realpath(p)!=str(source)]
    if str(target) not in updated:updated.append(str(target))
    config=connect.Plan('system-map','','')
    if updated!=added:
        saved['model_folders']=updated
        config.changes.append(connect.Change(settings,before,json.dumps(saved,ensure_ascii=False,indent=2)+'\n'))
    ini=model_folders.MODELS_INI
    old=connect._read(ini)
    new=old
    replacements={str(src):str(dst) for src,dst in change.move.steps}
    for src,dst in replacements.items():new=new.replace(src,dst)
    # A preset may spell a model through a same-disk directory alias.
    for line in old.splitlines():
        _key,sep,value=line.partition('=')
        value=value.strip()
        if sep and value.startswith('/') and str(model_folders.real(value)) in replacements:
            new=new.replace(value,replacements[str(model_folders.real(value))])
    if new!=old:config.changes.append(connect.Change(ini,old,new))
    lost=[]
    for key in change.lost:
        rt=next(r for r in runtimes if r.key==key)
        provider=local.get(key)
        if provider is not None and not provider.model_folder_changes:
            provider=next((p for p in providers.built_in_local() if p.key==key),provider)
        if provider is None or not provider.model_folder_changes or model_folders.real(rt.models_dir)!=source:
            lost.append(key);continue
        try:config.changes.extend(provider.model_folder_changes(rt,target))
        except (OSError,ValueError):lost.append(key)
    for link,_old,new in change.links:
        if link.lstat().st_uid!=os.getuid():raise ValueError('A model link belongs to another user')
        config.links_remove.append((link,Path(os.readlink(link))))
        config.links_add.append((link,new))
    facts={'move':asdict(change.move),'config':asdict(config),'lost':lost}
    signature=hashlib.sha256(_json(facts).encode()).hexdigest()
    record={**selection,'signature':signature,'facts':json.loads(_json(facts))}
    if len(_json(record).encode())>MAX_BYTES:raise ValueError('Move preview too large')
    return record


def _move(record):
    m=record['facts']['move']
    return model_move.Move(m['name'],[(Path(a),Path(b)) for a,b in m['steps']],m['size'],m['copy'],
                          Path(m['root']),Path(m['back']), {p:tuple(i) for p,i in m['idents'].items()},
                          {p:(Path(a),tuple(i)) for p,(a,i) in m['anchors'].items()})


def _config(record):
    p=record['facts']['config']
    return connect.Plan('system-map','','',changes=[connect.Change(Path(c['path']),c['old'],c['new']) for c in p['changes']],
        links_add=[(Path(a),Path(b)) for a,b in p['links_add']],links_remove=[(Path(a),Path(b)) for a,b in p['links_remove']])


def _journal(path,data):
    ai_core.atomic_write(path,_json(data),mode=0o600)


def update_records(record,source,destination):
    path=system_map_cache.location(Path(record['settings_path']) if record['settings_path'] else None)
    saved=system_map_cache.load(path)
    if not saved:return
    saved['records']=[r for r in saved['records'] if r['path'] not in (str(source),str(destination))]
    try:
        mounted=existing_ai.root_for(str(destination),existing_ai.mounts())
        files=[destination/Path(a).name for a,b in record['facts']['move']['steps'] if (destination/Path(a).name).is_file()]
        if files:
            tracked=[destination,*files]
            saved['records'].append({'kind':'models','provider':'','name':'GGUF','path':str(destination),
                'count':len(files),'models':'','environment':{},'dependencies':[str(p) for p in files],
                'mount':mounted,'stamps':{str(p):existing_ai.stamp(p) for p in tracked}})
    except (OSError,ValueError):pass
    system_map_cache.save(path,saved)


def execute(body: bytes,progress=lambda f,t='':None) -> dict:
    if len(body)>MAX_BYTES:raise ValueError('Move plan too large')
    record=json.loads(body)
    from flutter_addon_catalog import install_lock
    with install_lock():
        current=prepare({k:record[k] for k in ('source','disk','mount','settings_path')})
        if current['signature']!=record['signature']:raise ValueError('Move preview changed')
        move=_move(current)
        token=uuid.uuid4().hex
        root=journal_root(Path(record['settings_path']) if record['settings_path'] else None)/token
        path=root/'journal.json'
        journal={'record':record,'done':[],'backup':None,'complete':False}
        _journal(path,journal)
        try:
            for step in move.steps:
                one=model_move.Move(move.name,[step],move.size,move.copy,move.root,move.back,move.idents,move.anchors)
                done=model_move.apply(one,progress=progress)
                journal['done'] += [[str(a),str(b),list(i)] for a,b,i in done]
                _journal(path,journal)
            backup=connect.apply(_config(current),backup_root=root/'config')
            journal['backup']=str(backup)
            journal['complete']=True
            _journal(path,journal)
            update_records(record,move.back,move.root)
        except Exception:
            journal['complete']=False
            # A partial config transaction already wrote its private manifest before changes.
            for backup in (root/'config').glob('*'):
                if (backup/'manifest.json').is_file():connect.undo(backup)
            remaining=[]
            for a,b,i in reversed(journal['done']):
                if model_move.undo(move,[(Path(a),Path(b),tuple(i))]):remaining.append([a,b,i])
            journal['done']=remaining
            _journal(path,journal)
            return {'ok':False,'move_undo':token if remaining else None}
        return {'ok':True,'move_undo':token}


def undo(token: str,settings_path=None,progress=lambda f,t='':None) -> dict:
    if not isinstance(token,str) or not re.fullmatch('[0-9a-f]{32}',token):raise ValueError('Invalid move Undo')
    root=journal_root(settings_path)/token
    # Existing default-profile journals were written next to the map cache.
    if not (root/'journal.json').exists():
        legacy=system_map_cache.location(settings_path).parent/'model-moves'/token
        if (legacy/'journal.json').exists():root=legacy
    path=root/'journal.json'
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(fd,'rb') as f:
        st=os.fstat(f.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.getuid() or st.st_mode&0o077:raise ValueError('Invalid move journal')
        raw=f.read(JOURNAL_MAX+1)
    if len(raw)>JOURNAL_MAX:raise ValueError('Move journal too large')
    journal=json.loads(raw)
    move=_move(journal['record'])
    from flutter_addon_catalog import install_lock
    with install_lock():
        problems=[]
        for step in list(reversed(journal['done'])):
            a,b,i=step
            errors=model_move.undo(move,[(Path(a),Path(b),tuple(i))],progress=progress)
            if errors:problems+=errors
            else:
                journal['done'].remove(step)
                _journal(path,journal)
        if not problems and journal['backup']:
            backup=Path(journal['backup'])
            if backup.parent!=root/'config':raise ValueError('Invalid configuration backup')
            connect.undo(backup)
            journal['backup']=None
            _journal(path,journal)
        if not problems:update_records(journal['record'],move.root,move.back)
        return {'ok':not problems,'remaining':len(journal['done'])}


class Moves:
    def __init__(self):self.plans={}
    def register(self,record):
        token=uuid.uuid4().hex
        self.plans={k:v for k,v in self.plans.items() if time.monotonic()-v[0]<600}
        while len(self.plans)>=8:self.plans.pop(next(iter(self.plans)))
        self.plans[token]=(time.monotonic(),record)
        facts=record['facts']
        notes=['The new folder is on another disk: copied first, then removed here.'] if facts['move']['copy'] else []
        if facts['config']['links_add']:notes.append('Links and model references will be updated.')
        if facts['lost']:notes.append('Some runtimes will need their model folder updated after this move.')
        return {'preview':token,'source':record['source'],'destination':facts['move']['root'],'size':facts['move']['size'],
                'count':len(facts['move']['steps']),'model_files':[Path(a).name for a,b in facts['move']['steps']], 'files':[{'path':c['path']} for c in facts['config']['changes']],
                'notes':notes,'empty':False}
    def apply(self,token,queue):
        if not isinstance(token,str) or token not in self.plans:raise ValueError('Unknown move preview')
        created,record=self.plans[token]
        if time.monotonic()-created>=600:raise ValueError('Move preview expired')
        result=queue(record)
        del self.plans[token]
        return result
