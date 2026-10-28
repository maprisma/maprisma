"""Private, bounded metadata cache. Loading never detects or executes anything."""
from __future__ import annotations
import json
import os
from pathlib import Path
import stat
import math
import fcntl
import ai_core
import identity

VERSION = 1
MAX_BYTES = 900 * 1024


def location(settings_path: Path | None = None) -> Path:
    # Explicit profiles are self-contained; the default rebuildable map uses XDG cache.
    return (settings_path.parent if settings_path else identity.cache_dir()) / 'system-map.json'


def valid_view(view):
    if not isinstance(view,dict) or (view.get('selected') is not None and not isinstance(view['selected'],str)):return False
    m=view.get('transform')
    if not isinstance(m,list) or len(m)!=16 or any(type(x) not in (int,float) or not math.isfinite(x) or abs(x)>1e6 for x in m):return False
    return 0.05<=m[0]<=20 and abs(m[0]-m[5])<1e-6 and m[10]==m[15]==1 and all(m[i]==0 for i in (1,2,3,4,6,7,8,9,11,14))


def load(path: Path) -> dict:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as handle:
            info = os.fstat(handle.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                return {}
            raw = handle.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            return {}
        data = json.loads(raw,parse_constant=lambda value: (_ for _ in ()).throw(ValueError('Non-finite metadata')))
        if not isinstance(data, dict) or data.get('version') != VERSION:
            return {}
        if not isinstance(data.get('nodes'), list) or not isinstance(data.get('edges'), list) or len(data['nodes']) > 256:
            return {}
        for row in data['nodes']:
            if not isinstance(row, dict) or not all(isinstance(row.get(k), str) for k in ('id','path','kind','label','status','detail','info')) \
                    or type(row.get('column')) is not int or not 0 <= row['column'] <= 4:
                return {}
        if type(data.get('checked_at')) not in (int,float) or not math.isfinite(data['checked_at']) or not 0<=data['checked_at']<1e11:return {}
        if type(data.get('search_done')) is not bool:return {}
        if any(not isinstance(e,dict) or not all(isinstance(e.get(k),str) for k in ('source','target')) for e in data['edges']):return {}
        if not isinstance(data.get('mounts'),list) or any(not isinstance(m,dict) or not all(isinstance(m.get(k),str) for k in ('path','filesystem','identity')) for m in data['mounts']):return {}
        if not isinstance(data.get('records'),list) or len(data['records'])>128:return {}
        for r in data['records']:
            if not isinstance(r,dict) or not all(isinstance(r.get(k),str) for k in ('path','provider','kind','name')) or r['kind'] not in ('runtime','models','store'):return {}
            if not isinstance(r.get('mount'),dict) or not all(isinstance(r['mount'].get(k),str) for k in ('path','filesystem','identity')):return {}
            if type(r.get('count')) is not int or not isinstance(r.get('stamps'),dict) or not isinstance(r.get('dependencies'),list) or not isinstance(r.get('environment'),dict):return {}
        if not isinstance(data.get('notes'),list) or any(not isinstance(n,str) for n in data['notes']):return {}
        for optional in ('health','scan_limits'):
            if not isinstance(data.get(optional,[]),list):data[optional]=[]
        data['health']=[f for f in data.get('health',[]) if isinstance(f,dict) and all(isinstance(f.get(k),str) for k in ('node','level','title','text'))]
        data['scan_limits']=[s for s in data.get('scan_limits',[]) if isinstance(s,dict) and isinstance(s.get('path'),str) and all(isinstance(s.get(k,[]),list) for k in ('limits','notices','foreign'))]
        for n in data['nodes']:
            if 'size' in n and (type(n['size']) not in (int,float) or n['size']<0):n.pop('size',None)
            stack=n.get('stack')
            if stack is not None and (not isinstance(stack,dict) or not isinstance(stack.get('torch'),list) or not isinstance(stack.get('missing'),list)):
                n.pop('stack',None)
        if data.get('view') is not None and not valid_view(data['view']):data['view']=None
        analysis=data.get('analysis')
        if analysis is not None:
            if not isinstance(analysis,dict) or not all(isinstance(analysis.get(k),str) for k in ('summary','when','agent')) or not isinstance(analysis.get('findings'),list):
                data['analysis']=None
            elif any(not isinstance(f,dict) or not all(isinstance(f.get(k),str) for k in ('id','node','level','title','detail')) or f.get('level') not in ('problem','tip','good') for f in analysis['findings']):data['analysis']=None
        if not isinstance(data.get('helpers',[]),list) or any(not isinstance(h,dict) or not all(isinstance(h.get(k),str) for k in ('command','name')) for h in data.get('helpers',[])):return {}
        return data
    except (OSError, ValueError, TypeError):
        return {}


def transact(path: Path, transform):
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    fd=os.open(path.with_suffix('.lock'),os.O_WRONLY|os.O_CREAT|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as lock:
        info=os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077:
            raise ValueError('Invalid System Map lock')
        fcntl.flock(lock.fileno(),fcntl.LOCK_EX)
        data=transform(load(path))
        if not data:return {}
        body=json.dumps(data,ensure_ascii=True,allow_nan=False)
        if len(body.encode())>MAX_BYTES:raise ValueError('System Map cache too large')
        ai_core.atomic_write(path,body,mode=0o600)
        return data


def save(path: Path, data: dict, *, preserve_actions=True):
    def merge(previous):
        old_analysis=previous.get('analysis') or {}
        new_analysis=data.get('analysis') or {}
        if old_analysis.get('when','')>new_analysis.get('when',''):
            data['analysis']=previous['analysis']
        if preserve_actions:
            for key in ('move_undo','view'):
                if key in previous:data[key]=previous[key]
        return data
    transact(path,merge)


def update(path: Path, values: dict) -> dict:
    def merge(previous):
        if not previous:return {}
        if 'analysis' in values and (previous.get('analysis') or {}).get('when','')>(values['analysis'] or {}).get('when',''):
            return previous
        return {**previous,**values}
    return transact(path,merge)
