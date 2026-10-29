"""Read-only live process and delegated-session metadata for the Flutter map."""
from __future__ import annotations

from pathlib import Path
import os

import provider_watch
import subagents


def snapshot(catalog, sessions, recent: int = 1800, kept: int = 10, tracker=None) -> tuple[dict, dict]:
    commands = [agent.command for agent in catalog if agent.installed]
    pids: dict = {}
    found = provider_watch.agent_instances(commands, pids=pids)
    running = {command: [provider_watch.instance_model(command, argv) for argv in instances]
               for command, instances in found.items()}
    for session in sessions.items.values():
        code = sessions.poll(session) if hasattr(sessions, 'poll') else session.process.poll()
        if code is None and session.process.pid not in pids.get(session.command, []):
            pids.setdefault(session.command, []).append(session.process.pid)
            running.setdefault(session.command, []).append('')
    if tracker is None:
        import agent_activity
        tracker = agent_activity.Activity()
    working = tracker.working(pids)
    # Agents that started another agent and use it (from the process tree): the map's arrows.
    using = subagents.agents_using_agents(pids)
    activity = {}
    for command in commands:
        location = subagents.where(command)
        supported = bool(location)
        if supported:
            root = Path(os.path.expanduser(location[1]))
            home = Path.home()
            if root.is_relative_to(home):
                root = home.resolve() / root.relative_to(home)
            # Unreadable link-based storage is unavailable, rather than zero activity.
            if any(parent.is_symlink() for parent in (root, *root.parents)):
                supported = False
        rows = subagents.of(command, pids.get(command, []), recent=recent, kept=kept) if supported else []
        # Do not export task descriptions, transcripts or model answers.
        children = [{'key': row.key, 'kind': row.kind, 'folder': row.folder, 'age': row.age,
                     'running': bool(pids.get(command)) and row.running} for row in rows]
        activity[command] = {'instances': len(running.get(command, [])), 'working': command in working, 'subagents_supported': supported,
                             'active_subagents': sum(child['running'] for child in children) if supported else None,
                             'children': children,
                             'uses': sorted(used for user, used in using if user == command)}
    return running, activity
