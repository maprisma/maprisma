#!/usr/bin/env python3
"""The agent and provider adapters as add-on folders (unsigned): one per agent (agent-<command>),
one per local LLM (llm-<key>) and one for the online providers (providers-online).

Every add-on is data, no code: an agent add-on is addon.json plus adapters/<command>.toml as
agent.toml; a provider add-on is addon.json naming built-in providers in "provides". The app has
the logic built in (the few hooks of adapters/<command>.py, the provider modules) and uses it for
the signed, enabled add-ons.

    tools/build-adapter-addons.py <folder>      e.g. ../maprisma-addons (then tools/release-adapters.sh)

Folders of earlier runs are replaced (their MANIFEST.sha256 and SIGNATURE go too: sign again).
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import addons  # noqa: E402
import harnesses  # noqa: E402
import providers  # noqa: E402

# Programs that tell a local LLM is here (its detect() needs the add-on loaded; these are hints).
LLM_COMMANDS = {"llamacpp": ["llama-server"], "ollama": ["ollama"], "lmstudio": ["lms"], "vllm": ["vllm"],
                "jan": ["jan", "Jan"], "koboldcpp": ["koboldcpp"]}
NEEDS = f"maprisma >= {addons.MAPRISMA_VERSION}"


def write(out: Path, meta: dict) -> Path:
    folder = out / meta["id"]
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True)
    meta = {"api": 1, "privacy": "numbers", "needs": NEEDS, **meta}
    (folder / "addon.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
    return folder


def agent_data(out: Path, h, meta: dict) -> None:
    """An agent described as data: addon.json + agent.toml; the app builds the agent from the
    signed files (and its built-in hooks, adapter_data.HOOKS)."""
    shutil.copyfile(ROOT / "adapters" / f"{h.command}.toml", write(out, meta) / "agent.toml")


def agent(out: Path, module: str, version: str) -> None:
    h = next(x for x in harnesses.built_in_adapters() if x.command.replace("-", "_") == module)
    caps = ["agent"] + (["installer"] if h.installer is not None else []) + \
        (["updater"] if h.self_update or h.latest is not None else [])
    name = h.full_name or h.name
    meta = {"id": f"agent-{h.command}", "name": name, "version": version, "kind": "agent",
            "icon": "system-users-symbolic",
            "summary": f"{name} on the map: its models, MCP servers, skills, settings and sessions",
            "description": f"Teaches Maprisma {name}: where it keeps its settings, which models, MCP servers "
                           "and skills it uses, its session numbers, and how to install or remove it.",
            "capabilities": caps, "harnesses": [h.command], "provides": [h.command],
            "reads": [f"{name}'s own settings and session files ({', '.join(h.data) or 'its folders'})"],
            "detect": {"commands": [h.command], "paths": list(h.data)}, "homepage": h.homepage}
    agent_data(out, h, meta)


def llm(out: Path, p, version: str) -> None:
    caps = ["provider"] + (["installer"] if p.installer is not None else [])
    write(out, {"id": f"llm-{p.key}", "name": p.name, "version": version, "kind": "provider",
                "icon": "network-server-symbolic",
                "summary": f"{p.name} on the map: found, installed, started and stopped here, its models",
                "description": f"Teaches Maprisma the local LLM {p.name}: how to find it and its models, start "
                               "and stop it, connect agents to it, and install or remove it.",
                "capabilities": caps, "provides": [p.key],
                "reads": [f"{p.name}'s model folders and its own settings"],
                "detect": {"commands": LLM_COMMANDS.get(p.key, []), "paths": list(p.data)}, "homepage": p.homepage})


def online(out: Path, version: str) -> None:
    names = ", ".join(p.name for p in providers.built_in_online())
    write(out, {"id": "providers-online", "name": "Online providers", "version": version, "kind": "provider",
                "icon": "network-workgroup-symbolic",
                "summary": "The online providers agents use, by name on the map",
                "description": f"Names the online providers in agent settings and on the map: {names}.",
                "capabilities": ["provider"], "provides": [p.key for p in providers.built_in_online()],
                "reads": ["Nothing of its own: the agent settings the agent "
                                                        "add-ons read"]})


def main(argv: list) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-3], file=sys.stderr)
        return 2
    out = Path(argv[1])
    version = addons.MAPRISMA_VERSION
    for module in harnesses._MODULES:
        agent(out, module, version)
    for p in providers.built_in_local():
        llm(out, p, version)
    online(out, version)
    print(f"{len(harnesses._MODULES)} agents, {len(providers.built_in_local())} local LLMs and the online "
          f"providers in {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
