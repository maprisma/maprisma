#!/usr/bin/env python3
"""39-box Devel canvas CPU on a private X display, with no backend or desktop input.

Usage: tools/profile-flutter-editor.py --binary <Devel bundle/maprisma> --xvfb <Xvfb>
Explicit GTK scale and software GL make this reproducible; this is not hardware GPU performance.
Use --lights circles|sprites for the comparison; default uses the app's selected renderer.
--scale 2 reproduces the original inherited high-DPI environment, rather than the scale-1 GTK reference.
"""
import argparse
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time


def ticks(pid):
    raw=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
    return int(raw[11])+int(raw[12])


def finish(process):
    process.terminate()
    try:process.wait(timeout=5)
    except subprocess.TimeoutExpired:process.kill();process.wait()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',required=True,type=Path)
    parser.add_argument('--xvfb',default='Xvfb')
    parser.add_argument('--updates',choices=('none','unchanged','changed','mixed','activity'),default='none')
    parser.add_argument('--hover',action='store_true')
    parser.add_argument('--zoom',type=float,default=.53)
    parser.add_argument('--scale',type=int,choices=(1,2),default=1)
    parser.add_argument('--modes',choices=('both','on','off'),default='both')
    parser.add_argument('--lights', choices=('default','circles','sprites'),default='default')
    parser.add_argument('--seconds',type=int,default=60)
    args=parser.parse_args()
    if not .3<=args.zoom<=2:parser.error('zoom must be between .3 and 2')
    if not 5<=args.seconds<=600:parser.error('seconds must be between 5 and 600')
    with tempfile.TemporaryDirectory(prefix='maprisma-editor-profile-') as folder:
        root=Path(folder)
        read_fd,write_fd=os.pipe()
        with (root/'xvfb.log').open('wb') as log:
            server=subprocess.Popen([args.xvfb,'-displayfd',str(write_fd),'-screen','0','1600x1400x24','-nolisten','tcp'],pass_fds=(write_fd,),stdout=log,stderr=log)
            os.close(write_fd)
            try:
                if not select.select([read_fd],[],[],10)[0]:raise RuntimeError('Xvfb did not start')
                display=os.read(read_fd,32).decode().strip()
                if not display.isdigit():raise RuntimeError('Invalid private display')
                env={**os.environ,'DISPLAY':':'+display,'GDK_BACKEND':'x11','LIBGL_ALWAYS_SOFTWARE':'1',
                     'GDK_SCALE':str(args.scale),'GDK_DPI_SCALE':'1',
                     'XDG_CONFIG_HOME':str(root/'config'),'XDG_CACHE_HOME':str(root/'cache')}
                env.pop('WAYLAND_DISPLAY',None)
                print(f'fixture: 1600x1400, GDK_SCALE={args.scale}, LP_NUM_THREADS={env.get("LP_NUM_THREADS","default")}, lights={args.lights}, updates={args.updates}, hover={args.hover}, zoom={args.zoom}',flush=True)
                for mode in (('off','on') if args.modes=='both' else (args.modes,)):
                    with (root/f'{mode}.log').open('wb') as output:
                        command=[str(args.binary.resolve()),'--map-benchmark-'+mode+('-'+args.lights if mode=='on' and args.lights!='default' else '')]
                        if args.updates!='none':command.append('--map-benchmark-updates='+args.updates)
                        if args.hover:command.append('--map-benchmark-hover')
                        if args.zoom!=.53:command.append('--map-benchmark-zoom='+str(args.zoom))
                        process=subprocess.Popen(command,env=env,stdout=output,stderr=output)
                        try:
                            time.sleep(5)
                            if process.poll() is not None:raise RuntimeError((root/f'{mode}.log').read_text())
                            before=ticks(process.pid);display_before=ticks(server.pid);start=time.monotonic()
                            print(f'measuring {mode} ({args.lights}): pid {process.pid}, private display :{display}',flush=True)
                            time.sleep(args.seconds)
                            elapsed=time.monotonic()-start;hz=os.sysconf('SC_CLK_TCK')
                            cpu=(ticks(process.pid)-before)/hz/elapsed*100
                            display_cpu=(ticks(server.pid)-display_before)/hz/elapsed*100
                            print(f'{mode}: {cpu:.2f}% of one core; Xvfb {display_cpu:.2f}%; {elapsed:.1f}s',flush=True)
                            for line in (root/f'{mode}.log').read_text().splitlines():
                                if line.startswith('MAP-BENCHMARK '): print(line,flush=True)
                        finally:finish(process)
            finally:
                os.close(read_fd);finish(server)


if __name__=='__main__':main()
