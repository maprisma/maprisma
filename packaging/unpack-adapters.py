"""Unpack adapters-<version>.zip (maprisma-addons tools/zip_bundle.py) into the app's addons folder
for the AppImage and the AUR package: only <add-on id>/<file> entries, no links, files 0644 and
folders 0755. Maprisma checks every add-on's signature again when it starts.
    unpack-adapters.py <adapters.zip> <target folder>"""
import re
import sys
import zipfile
from pathlib import Path

# The files an add-on may have (addons.verify allows the same, and checks each against the signed list).
NAME = re.compile(r"[a-z][a-z0-9-]{1,40}/(addon\.json|addon\.py|agent\.toml|hooks\.py|icon\.svg|MANIFEST\.sha256|"
                  r"SIGNATURE|translations/[a-z]{2}\.json)")
archive, target = Path(sys.argv[1]), Path(sys.argv[2])
with zipfile.ZipFile(archive) as zf:
    infos = [i for i in zf.infolist() if not i.is_dir()]
    bad = [i.filename for i in infos if not NAME.fullmatch(i.filename) or (i.external_attr >> 16) & 0o170000 == 0o120000]
    if bad:
        sys.exit(f"unexpected entry in {archive.name}: {bad[0]}")
    for info in infos:
        path = target / info.filename
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
        path.write_bytes(zf.read(info))
        path.chmod(0o644)
for folder in [target, *target.rglob("*")]:
    if folder.is_dir():
        folder.chmod(0o755)
print(len({i.filename.split('/')[0] for i in infos}), "add-ons in", target)
