#!/usr/bin/env python3
"""The agent and provider adapters as add-on folders (unsigned): one per agent (agent-<command>),
one per local LLM (llm-<key>) and one for the online providers (providers-online).

An agent add-on is its adapter as data: adapters/<command>.toml as agent.toml, plus
adapters/<command>.py as hooks.py for the few agents facts cannot describe. A local LLM's or the
online providers' addon.py is the provider module itself (provider_<key>.py, provider_online.py),
unchanged, plus a register(api) that adds it. So the adapters keep one source: the Maprisma
plugin has the same files built in, Asterism gets them as signed add-ons.

    tools/build-adapter-addons.py <folder>      e.g. ../asterism-addons (then tools/release-adapters.sh)

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
NEEDS = f"asterism >= {addons.ASTERISM_VERSION}"


def write(out: Path, meta: dict, source: str, register: str) -> None:
    folder = out / meta["id"]
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True)
    meta = {"api": 1, "privacy": "numbers", "needs": NEEDS, **meta}
    (folder / "addon.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
    (folder / "addon.py").write_text(source.rstrip() + "\n\n\n# --- the add-on " + "-" * 82 + "\n\n"
                                     "def register(api):\n" + register)


def agent_data(out: Path, h, meta: dict) -> None:
    """An agent described as data: addon.json + agent.toml (+ hooks.py when it needs code), never an
    addon.py; the app builds the agent from the signed files."""
    folder = out / meta["id"]
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True)
    meta = {"api": 1, "privacy": "numbers", "needs": NEEDS, **meta}
    (folder / "addon.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
    shutil.copyfile(ROOT / "adapters" / f"{h.command}.toml", folder / "agent.toml")
    hooks = ROOT / "adapters" / f"{h.command}.py"
    if hooks.is_file():                     # what its facts cannot say (adapter_data.HOOKS)
        shutil.copyfile(hooks, folder / "hooks.py")


def agent(out: Path, module: str, version: str) -> None:
    h = next(x for x in harnesses.built_in_adapters() if x.command.replace("-", "_") == module)
    caps = ["agent"] + (["installer"] if h.installer is not None else []) + \
        (["updater"] if h.self_update or h.latest is not None else [])
    name = h.full_name or h.name
    meta = {"id": f"agent-{h.command}", "name": name, "version": version, "kind": "agent",
            "icon": "system-users-symbolic",
            "summary": f"{name} on the map: its models, MCP servers, skills, settings and sessions",
            "description": f"Teaches Asterism {name}: where it keeps its settings, which models, MCP servers "
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
                "description": f"Teaches Asterism the local LLM {p.name}: how to find it and its models, start "
                               "and stop it, connect agents to it, and install or remove it.",
                "capabilities": caps, "provides": [p.key],
                "reads": [f"{p.name}'s model folders and its own settings"],
                "detect": {"commands": LLM_COMMANDS.get(p.key, []), "paths": list(p.data)}, "homepage": p.homepage},
          (ROOT / f"provider_{p.key}.py").read_text(), "    api.add_provider(PROVIDER)\n")


def online(out: Path, version: str) -> None:
    names = ", ".join(p.name for p in providers.built_in_online())
    write(out, {"id": "providers-online", "name": "Online providers", "version": version, "kind": "provider",
                "icon": "network-workgroup-symbolic",
                "summary": "The online providers agents use, by name on the map",
                "description": f"Names the online providers in agent settings and on the map: {names}.",
                "capabilities": ["provider"], "provides": [p.key for p in providers.built_in_online()],
                "reads": ["Nothing of its own: the agent settings the agent "
                                                        "add-ons read"]},
          (ROOT / "provider_online.py").read_text(), "    for provider in ONLINE:\n        api.add_provider(provider)\n")


def main(argv: list) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-3], file=sys.stderr)
        return 2
    out = Path(argv[1])
    version = addons.ASTERISM_VERSION
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
