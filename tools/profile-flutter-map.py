#!/usr/bin/env python3
"""CPU of the Flutter service's map refresh: map.snapshot every 2 s, as the UI calls it while the map is open.

    tools/profile-flutter-map.py <config dir> [seconds]

<config dir> holds a COPY of settings.json (e.g. cp ~/.config/maprisma/settings.json /tmp/x/), so the
settings migration never runs and nothing in ~/.config is written. Agents, inventory and add-ons are the
real ones (read only). Prints the in-process scan cost (cold, then warm) and the average load of the
service plus its workers in % of one core. Start nothing else; no UI, no PTY, no network.
"""
from __future__ import annotations

import contextlib
import os
import resource
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def cpu(who) -> float:
    usage = resource.getrusage(who)
    return usage.ru_utime + usage.ru_stime


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    config = Path(sys.argv[1]).resolve()
    seconds = int(sys.argv[2]) if len(sys.argv) == 3 else 60
    real = {(Path.home() / ".config" / name).resolve() for name in ("maprisma",)}
    if config in real:
        sys.exit("Use a copy of settings.json in another folder, not the real config")
    if not (config / "settings.json").is_file():
        sys.exit(f"{config}/settings.json is missing")
    sys.path.insert(0, str(ROOT))
    os.chdir(ROOT)
    import flutter_backend
    from flutter_addons import AdapterRegistry

    service = flutter_backend.Service(config / "settings.json")
    with contextlib.redirect_stdout(sys.stderr):
        service.adapters = AdapterRegistry()
        service.adapters.reload(service.enabled_addons())

    # In-process scans: the first is cold, the rest are what a long-lived worker would pay.
    for index in range(6):
        wall, used = time.monotonic(), cpu(resource.RUSAGE_SELF)
        with contextlib.redirect_stdout(sys.stderr):
            result = service.build_map()
        print(f"in-process scan {index}: wall {time.monotonic() - wall:.2f} s, cpu {cpu(resource.RUSAGE_SELF) - used:.2f} s")
    print(f"map: {len(result['nodes'])} nodes, {len(result['edges'])} edges")

    # The UI's cadence through the service (persistent worker, cached idle scans).
    own, children, start = cpu(resource.RUSAGE_SELF), cpu(resource.RUSAGE_CHILDREN), time.monotonic()
    calls, workers = 0, set()
    while time.monotonic() - start < seconds:
        with contextlib.redirect_stdout(sys.stderr):
            service.dispatch("map.snapshot", {})
        calls += 1
        if service._map_task:
            workers.add(service._map_task)
        time.sleep(2)
    # Reap the persistent scanner so RUSAGE_CHILDREN includes its whole lifetime.
    service.tasks.close()
    wall = time.monotonic() - start
    own, children = cpu(resource.RUSAGE_SELF) - own, cpu(resource.RUSAGE_CHILDREN) - children
    print(f"cadence: {calls} calls, {len(workers)} workers in {wall:.0f} s")
    print(f"service cpu {own:.2f} s, workers cpu {children:.2f} s, per worker {children / max(1, len(workers)):.2f} s")
    print(f"average load: {100 * (own + children) / wall:.1f} % of one core")


if __name__ == "__main__":
    main()
