"""Reviewed, reversible removal of user add-ons; bundled add-ons stay with their package."""
from __future__ import annotations
import os
import itertools
import re
import shutil
import stat
from pathlib import Path
import time
import uuid
import addons
import ai_core


BACKUP_RETENTION = 30 * 24 * 60 * 60
REMOVAL_NOTES = [
    'After a removal, backups older than 30 days may be deleted. Active Undo backups are kept.',
]


def prune_backups(root: Path, keep=(), *, now=None):
    """Bounded, best-effort retention cleanup, only after an accepted removal."""
    cutoff = (time.time() if now is None else now) - BACKUP_RETENTION
    protected = set(keep)
    try:
        root_info = root.lstat()
        if not stat.S_ISDIR(root_info.st_mode) or root_info.st_uid != os.getuid() or root_info.st_mode & 0o077:
            return
        with os.scandir(root) as entries:
            for entry in itertools.islice(entries, 200):
                path = root / entry.name
                if path in protected or not re.fullmatch('[0-9a-f]{32}', entry.name):
                    continue
                try:
                    info = entry.stat(follow_symlinks=False)
                    # ctime protects old-format backups whose original directory mtime
                    # predates their removal; use the newest metadata change conservatively.
                    if stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and max(info.st_mtime, info.st_ctime) < cutoff:
                        shutil.rmtree(path)
                except OSError:
                    continue
    except OSError:
        pass  # Cleanup must not turn a committed removal into a reported failure.


class Actions:
    def __init__(self):
        self.previews = {}
        self.undos = {}

    def preview(self, registry, ident):
        item = next((i for i in registry.items if i.id == ident), None)
        if item is None or item.folder.parent != addons.USER_DIR or item.folder.is_symlink() or not item.folder.is_dir():
            raise ValueError('Only user add-ons can be removed')
        st = item.folder.stat()
        self.previews = {k:v for k,v in self.previews.items() if time.monotonic()-v[0]<600}
        while len(self.previews)>=8:self.previews.pop(next(iter(self.previews)))
        token = uuid.uuid4().hex
        self.previews[token] = (time.monotonic(), ident, item.folder, (st.st_dev, st.st_ino))
        return {'preview': token, 'name': item.name, 'version': item.version, 'notes': list(REMOVAL_NOTES)}

    def apply(self, token, registry, settings_path):
        if token not in self.previews:raise ValueError('Unknown add-on removal')
        created, ident, source, stamp = self.previews[token]
        if time.monotonic()-created>=600:raise ValueError('Removal preview expired')
        st = source.stat()
        if source.is_symlink() or source.parent!=addons.USER_DIR or (st.st_dev,st.st_ino)!=stamp:
            raise ValueError('Add-on changed; review again')
        settings = ai_core.load_settings(settings_path)
        enabled = set(settings.get('addons_enabled', []))
        root = addons.USER_DIR.parent/'addon-backups'
        root.mkdir(mode=0o700,parents=True,exist_ok=True)
        if root.is_symlink() or root.stat().st_uid!=os.getuid() or root.stat().st_mode&0o077:
            raise ValueError('Unsafe backup folder')
        undo = uuid.uuid4().hex
        backup = root/undo
        os.rename(source, backup)
        try:
            registry.reload(enabled-{ident})
            ai_core.update_settings(settings_path, addons_enabled=sorted(enabled-{ident}))
        except Exception:
            os.rename(backup,source);registry.reload(enabled);raise
        self.undos[undo] = (ident, source, backup, ident in enabled)
        del self.previews[token]
        prune_backups(root, keep=[entry[2] for entry in self.undos.values()])
        return {'ok':True,'undo':undo}

    def undo(self, token, registry, settings_path):
        if token not in self.undos:raise ValueError('Unknown add-on Undo')
        ident, source, backup, was_on = self.undos[token]
        if source.exists() or source.is_symlink() or backup.is_symlink():raise ValueError('Add-on path is occupied')
        enabled = set(ai_core.load_settings(settings_path).get('addons_enabled', []))
        restored = enabled|{ident} if was_on else enabled-{ident}
        os.rename(backup,source)
        try:
            registry.reload(restored)
            if was_on and not any(i.id==ident and i.state=='loaded' for i in registry.items):
                raise ValueError('Restored add-on could not be verified')
            ai_core.update_settings(settings_path,addons_enabled=sorted(restored))
        except Exception:
            os.rename(source,backup);registry.reload(enabled);raise
        del self.undos[token]
        return {'ok':True}
