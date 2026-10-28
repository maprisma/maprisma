"""Read-only facts about supporting tools. No imports of detected packages or program runs."""
from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import re
import shutil


@dataclass(frozen=True)
class Tool:
    key: str
    name: str
    commands: tuple[str, ...]
    packages: tuple[str, ...] = ()


TOOLS = (Tool('python', 'Python', ('python3', 'python')), Tool('uv', 'uv', ('uv',)),
         Tool('node', 'Node.js', ('node',), ('nodejs',)), Tool('mise', 'mise', ('mise',)),
         Tool('docker', 'Docker', ('docker',)), Tool('podman', 'Podman', ('podman',)),
         Tool('git', 'Git', ('git',)), Tool('gcc', 'GCC', ('gcc',)),
         Tool('clang', 'Clang', ('clang',)), Tool('cmake', 'CMake', ('cmake',)))


def small(path: Path, limit=16384) -> str:
    import stat
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                return ''
            return f.read(limit).decode('utf-8', 'replace')
    except OSError:
        return ''


def detect(search=False, environ=None) -> list[dict]:
    env = os.environ if environ is None else environ
    result = []
    for tool in TOOLS:
        path = next((p for c in tool.commands if (p := shutil.which(c, path=env.get('PATH', '')))), '')
        if not path:
            continue
        real = Path(path).resolve()
        version = ''
        if search:
            if tool.key == 'python':
                match = re.search(r'python(\d+\.\d+(?:\.\d+)?)$', real.name)
                version = match[1] if match else ''
                cfg = small(real.parent.parent / 'pyvenv.cfg')
                match = re.search(r'^version\s*=\s*([\d.]+)', cfg, re.M)
                version = match[1] if match else version
            # Versioned tool directories are metadata; never infer from arbitrary file contents.
            parts = real.parts
            if 'installs' in parts:
                i = parts.index('installs')
                if len(parts) > i + 2 and re.fullmatch(r'v?\d+(?:\.\d+){1,3}(?:[-+][\w.-]+)?', parts[i+2]):
                    version = parts[i+2]
        if search and not version:
            import agents
            version=next((v for package in tool.packages or (tool.key,) if (v:=agents.package_version(package))), '')
        result.append({'key': tool.key, 'name': tool.name, 'path': path, 'target': str(real), 'version': version})
    virtual = env.get('VIRTUAL_ENV', '')
    if virtual and Path(virtual).is_dir():
        result.append({'key': 'venv', 'name': 'Python virtual environment', 'path': virtual, 'target': virtual, 'version': ''})
    return result


def hardware() -> dict:
    ram = re.search(r'^MemTotal:\s*(\d+)', small(Path('/proc/meminfo')), re.M)
    gpus = []
    for card in sorted(Path('/sys/class/drm').glob('card[0-9]*'))[:16]:
        if '-' in card.name:
            continue
        vendor = small(card / 'device/vendor').strip()
        if vendor not in ('0x1002', '0x10de', '0x8086'):
            continue
        size = small(card / 'device/mem_info_vram_total').strip()
        gpus.append({'name': {'0x1002':'AMD', '0x10de':'NVIDIA', '0x8086':'Intel'}[vendor] + ' · ' + card.name,
                     'vendor': {'0x1002':'amd','0x10de':'nvidia','0x8086':'intel'}[vendor],
                     'vram': int(size) if size.isdigit() else 0})
    return {'cpus': os.cpu_count() or 0, 'ram': int(ram[1])*1024 if ram else 0, 'gpus': gpus}


def check_record(node: str) -> dict:
    import existing_ai
    if not isinstance(node,str) or not node.startswith('tool:'):
        raise ValueError('Unknown supporting tool')
    row = next((r for r in detect() if 'tool:'+r['key']==node and r['key']!='venv'),None)
    if row is None:
        raise ValueError('Supporting tool unavailable')
    return {'kind':'runtime', 'path':row['target'], 'key':row['key'], 'environment':{},
            'stamp':existing_ai.stamp(Path(row['target']))}


def check(body: bytes) -> dict:
    import existing_ai
    import flutter_existing
    import json
    record = json.loads(body)
    def validate(_record):
        fresh=check_record('tool:'+record['key'])
        if fresh!=record:
            raise ValueError('Supporting tool changed; refresh first')
    return flutter_existing.check(record,validator=validate)


class StackActions:
    def __init__(self):
        self.previews={}

    def resolve(self,part):
        import gpu_stack
        import install_recipes
        gpus=hardware()['gpus']
        vendor=next((g['vendor'] for g in gpus if g['vendor']=='amd'), gpus[0]['vendor'] if gpus else '')
        if not isinstance(part,str) or part not in gpu_stack.wanted(gpu_stack.look(vendor,read_only=True)):
            raise ValueError('GPU stack action unavailable')
        step=install_recipes.choose(gpu_stack.ways(part),'install')
        if step is None or not (step.run or step.url):
            raise ValueError('No supported installation action')
        return step

    def preview(self,part):
        import time,uuid
        from dataclasses import asdict
        step=self.resolve(part)
        self.previews={k:v for k,v in self.previews.items() if time.monotonic()-v[0]<600}
        while len(self.previews)>=8:self.previews.pop(next(iter(self.previews)))
        token=uuid.uuid4().hex
        self.previews[token]=(time.monotonic(),part,asdict(step))
        return {'preview':token,'files':[], 'notes':["Follow the vendor's instructions for this distribution."] if step.note else [],
                'commands':step.commands,'url':step.url,'empty':False}

    def apply(self,token):
        import time
        import install_recipes
        from dataclasses import asdict
        if not isinstance(token,str) or token not in self.previews:raise ValueError('Unknown stack preview')
        created,part,old=self.previews[token]
        step=self.resolve(part)
        if time.monotonic()-created>=600 or asdict(step)!=old:raise ValueError('GPU stack preview changed')
        if not install_recipes.run(step):raise ValueError('No terminal available')
        del self.previews[token]
        return {'external':True}


def fstab_hint(path: str, text: str | None = None) -> str:
    """Text to review/copy, only for a simple local whole-filesystem UUID mount."""
    import existing_ai
    text=small(Path('/proc/self/mountinfo'),128*1024) if text is None else text
    for line in text.splitlines():
        fields=line.split()
        try:
            sep=fields.index('-')
            decode=lambda value:re.sub(r'\\([0-7]{3})',lambda m:chr(int(m[1],8)),value)
            if decode(fields[4])!=path or fields[3]!='/' or fields[sep+1] not in existing_ai.LOCAL_FILESYSTEMS:continue
            source=Path(decode(fields[sep+2]))
            if not str(source).startswith('/dev/'):return ''
            label=''
            try:
                with os.scandir('/dev/disk/by-uuid') as entries:
                    for i,entry in enumerate(entries):
                        if i>=128:break
                        if re.fullmatch('[A-Za-z0-9-]{1,64}',entry.name) and Path(entry.path).resolve()==source.resolve():
                            label=entry.name;break
            except OSError:return ''
            if not label:return ''
            def escape(value: str) -> str:
                replacements={' ':'\\040','\t':'\\011','\n':'\\012','\\':'\\134'}
                return ''.join(replacements[c] if c in replacements else c for c in value)
            return 'UUID='+label+' '+escape(path)+' '+fields[sep+1]+' defaults,nofail 0 2'
        except (ValueError,IndexError,OSError):continue
    return ''


class ProbeRequired(RuntimeError):
    """This detector needs a separately approved executable/network/credential probe."""


BLOCKED_PROBES=0


def read_only_scan_audit(event,args):
    global BLOCKED_PROBES
    forbidden=event.startswith('socket.') or event in ('subprocess.Popen','os.system','os.posix_spawn','os.fork','os.exec','os.spawn')
    if event=='open' and args and isinstance(args[0],(str,bytes)):
        name=os.fsdecode(args[0]).rsplit('/',1)[-1].lower()
        forbidden=forbidden or name=='auth.json' or 'credentials' in name
    if forbidden:
        BLOCKED_PROBES+=1
        raise ProbeRequired('This probe needs explicit confirmation')
