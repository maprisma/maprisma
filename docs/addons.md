# Making an add-on for a new local LLM or agent

A new local LLM (a *provider*) or a new coding agent is one add-on: nothing in Asterism's core
changes. The core asks a provider's **engine** and an agent's **facts**, and never names either
(two tests make sure: `tests/test_llm_engine.py` and `tests/test_agent_facts.py` check every module
for a local LLM's or an agent's name).

Start from a template:

| Template | What it is |
|---|---|
| `templates/llm-example/` | a local LLM: `addon.json` + `addon.py` (its detect function, its engine, its `Provider`) |
| `templates/agent-exampleagent/` | an agent: `addon.json` + `agent.toml` (facts) + `hooks.py` (what facts cannot say) |

`tests/test_new_addon_end_to_end.py` signs both templates with a throw-away key, loads them through
the real add-on loader and checks the whole way: they appear among the providers and agents, the
engine's facts are used for folders, moving and the Models page, the agent connects to the local
LLM, the map draws the line, its MCP servers, security risks, web look-up and disk space work. Copy
that test for your add-on.

The built-in providers and agents are add-ons made the same way (`provider_<key>.py`,
`adapters/<command>.toml` + `.py`; `tools/build-adapter-addons.py` turns them into add-on folders).

## A local LLM

`addon.py` holds three things:

1. **`_detect(processes)`** returns an `inventory.Runtime`: installed or not, running, its user
   service, its address (`127.0.0.1:port`), its models folder and its models.
2. **`class Engine(llm_engine.Engine)`**: how the app works with it. Keep only what differs from
   the defaults; every fact and method in `llm_engine.Engine` says its default. Most local LLMs are
   OpenAI-compatible: the default engine reads `/v1/models` and starts and stops its user service.
   `llm_engine.LlamaRouter` is the base for llama.cpp's router family (load and unload on request).
3. **`PROVIDER = Provider(key, name, "local", detect=…, engine=Engine(), connect_key=…, …)`** and
   **`register(api)`** calling `api.add_provider(PROVIDER)`.

### The engine

| Area | Facts and methods | Default |
|---|---|---|
| Its processes | `programs`, `owns_process(comm, argv)` | none |
| Start and stop | `start(rt)`, `stop(rt)`, `can_control(rt)`, `start_command` (for hints) | its user service |
| The watcher | `watch_control` (a controller `provider_watch` has, e.g. `"lms"`: never a command line) | its user service |
| Its address | `ports` (an agent's provider at this machine on one of them is this LLM) | none |
| Models through its API | `loaded_models`, `load`, `unload_model`, `unload_all`, `can_load`, `model_context` | `/v1/models`, no loading |
| Models at once | `slots_kind` (`"count"`, `"switch"`), `slots`, `slots_fixed_by`, `slot_changes`, `after_slot_change`, `model_size` | fixed |
| Models on disk | `gguf_folder`, `gguf_layout` (`"flat"`, `"publisher"`, `"blobs"`), `store_parts`, `own_model_folder`, `reorganize`, `stop_to_move`, `models_root_rank`, `data_folders(rt)` | its own business |
| The Models page | `models_page`, `download` (`"file"`, `"pull"`), `removable` (`"file"`, `"api"`), `context_settable`, `context_effect`, `models_page_note`, `context_now`, `context_changes` / `set_context`, `pull_name`, `pull`, `add_file`, `remove` | page shown, nothing offered |
| Connecting agents | `agent_context(rt)`, `connect_extra(rt, model)` | nothing extra |
| After a change | `refresh(rt)` (on start and after a model was added) | nothing |
| Its MCP servers | `mcp` (a `harnesses.Mcp`: read and shown, never written) | none |
| What the user is told | `add_model_step(rt)`, `start_step(rt, agent)`, `gpu_build(vendor)` | general hints |

Settings files it changes go through `connect.Change` (`llm_engine.change`, `env_with`): the app shows
them first, keeps a backup and offers Undo.

## An agent

`agent.toml` holds facts; `docs/adapter-format.md` lists every key. The important ones:

| Facts | What the app builds from them |
|---|---|
| `command`, `name`, `icon`, `install` | its card on Setup, its box on the map, Install / Uninstall |
| `home`, `data`, `activity`, `program_dir` | its card's settings folder, Disk space, "last used" |
| `[details]` (`reader` or `hook = true`) | its model and providers: the lines on the map |
| `[local_llm]` + the `local_llm_*` hooks | connecting it to a local LLM on the map (preview, backup, Undo) |
| `[mcp]`, `[skills]` | its MCP servers and skills on the map, adding and removing them |
| `[security]` with `sandbox`, `asks`, settings and rules | the Security page and its risks |
| `[access]` (`logins`, `logout`, `key`) | signing in and out |
| `[sessions]`, `usage` | Usage and tokens, Projects |
| `[models]` | the online models the map can switch it to |
| `[research]`, `[rewrite]`, `[ask]` | web look-ups, skill rewrites, AI Playground (each command starts with the agent itself; placeholders are arguments of their own) |
| `web_search`, `chat_app`, `herdr` | the smart cards' status, the terminal, herdr's live state |

`hooks.py` holds functions with fixed names (`adapter_data.HOOKS`), used where `agent.toml` says
`"hook"`. An agent whose settings a reader of the app knows needs no `hooks.py` (most built-in ones).

## Trying it, and getting it signed

Asterism loads only add-ons signed by its author (`addons.ALLOWED_SIGNERS`): before anything of an
add-on runs, the signature and every file's SHA-256 are checked. To try yours, copy
`tests/test_new_addon_end_to_end.py`: it signs with a key of its own and loads the add-on exactly as
the app does. Then open an issue or a pull request with the folder at
[uBruckhaus/asterism-addons](https://github.com/uBruckhaus/asterism-addons); once
it is reviewed, it is signed and appears in the catalog (Add-ons › Available).
