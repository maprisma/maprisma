"""Example LLM: a template for a local LLM add-on (docs/addons.md).

Everything Maprisma knows about a local LLM is in this one file: how it is found (detect), what it
is called in agent settings (connect_key), and its engine: how it starts and stops, what its API
answers, how it keeps its models, and what the app's pages may do with them. The core asks the
engine and never names a local LLM, so nothing else changes when this add-on is switched on.

Copy the folder, rename the key ("examplellm") and the names, and keep only what differs from the
defaults in llm_engine.Engine (every fact and method there says its default). The built-in ones
(provider_llamacpp.py, provider_ollama.py, …) are add-ons made the same way.
tests/test_new_addon_end_to_end.py loads this folder as a signed add-on and checks it works.
"""

import os
from pathlib import Path

import llm_engine
from providers import Provider


def _detect(processes):
    """Is it installed, running, where are its models? (inventory.Runtime)"""
    import inventory
    names = sorted(p.stem for p in Path(os.path.expanduser("~/models")).glob("*.gguf"))
    return inventory.Runtime("examplellm", "Example LLM", installed=True, running=False, service="example-llm",
                             address="127.0.0.1:9123", models_dir="~/models", models=names)


class Engine(llm_engine.Engine):
    # Its processes and its user service (the defaults start and stop "example-llm.service" and read
    # the OpenAI-style /v1/models of its address).
    programs = ("example-server",)
    start_command = "example-server --models <folder>"
    ports = (9123,)                     # an agent's provider at 127.0.0.1:9123 is this LLM

    # Its models on disk: a folder of GGUF files the app may fill, move and reorganize.
    gguf_folder = True
    reorganize = True

    # The Models page: GGUF downloads into its folder, Remove to the trash, Set context, and a
    # restart for a new context to count.
    download = "file"
    removable = "file"
    context_settable = True
    context_effect = "restart"

    def models_page_note(self, rt):
        return "Example LLM reads every GGUF file in its folder."


PROVIDER = Provider("examplellm", "Example LLM", "local", detect=_detect, engine=Engine(),
                    connect_key="example-local", connect_label="Example LLM (local)",
                    data=("~/.example-llm",))


def register(api):
    api.add_provider(PROVIDER)
