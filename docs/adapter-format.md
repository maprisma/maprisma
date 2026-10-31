# Agent adapters as data

Today every agent adapter is a Python module (`harness_<command>.py`): built into the AI Agents
Map plugin, and copied as `addon.py` into a signed Asterism add-on (`agent-<command>`). Most of it
is facts — paths, install ways, sign-in commands, security settings — wrapped in code.

**Proposal:** an adapter is a file of facts, `agent.toml`. Code stays only where a fact cannot say
it (hooks, below).

## Why

- **Less code to sign and review.** A data-only add-on runs nothing of its own; the Add-ons page can
  say so ("brings no code"), and the marketplace review of the plugin reads facts, not programs.
- **New agents without programming.** Someone can describe a new agent by copying a file.
- **One source again.** The plugin and the add-ons read the same `adapters/<command>.toml` from the
  Asterism tree (`tools/sync-plugin.py` ships them), instead of a module copied into each add-on.
- **Checked on load.** Every key has a type; an unknown key or a wrong type is refused with a
  message on the Add-ons page, before anything uses it.

## What stays code (hooks)

Five adapters need more than facts; they keep their code in `adapters/<command>.py` beside the TOML
(in an add-on: `hooks.py`, signed and loaded from the verified bytes like everything else). The TOML
says `"hook"` (or `hook = true`) where a hook is used; the functions have fixed names
(`adapter_data.HOOKS`):

| Hook | Who | What it does |
|---|---|---|
| `sessions()` | Hermes, OpenCode | reads its SQLite session store (numbers only) |
| `local_llm_connected/active/transform` | Hermes, OpenCode, Pi, DeepSeek Harness | edits the agent's config text to point it at a local LLM (`[local_llm] files`, `hooks = true`) |
| `skills_listed`, `skills_write` | Hermes (YAML text); Pi writes only | keeps a folder list in the agent's own settings |
| `mcp_read`, `mcp_write`, `mcp_native` | DeepSeek Harness (YAML profile); OpenClaw writes only (JSON5) | an MCP format the app does not know |
| `security(report)` | OpenCode | its permission field takes several forms |
| `details(details)` | none yet | its model and providers, from settings no reader of the app knows (`[details] hook = true`) |
| `models_choices(current, home)`, `models_plan(model, home)` | none yet | the online models it can be switched to, and the switch (`[models] hook = true`; plan returns `(file, old text, new text, provider)`) |

A data-only add-on is shown as "Brings no code", one with hooks as "Facts about the agent, and a
little code for what facts cannot say (hooks.py)".

## Facts beyond the example

| Fact | For | Meaning |
|---|---|---|
| `skills.listed = {file, format, key}` | Oh My Pi, Crush, Grok | extra skill folders a settings file lists (json or toml, dotted key) |
| `mcp.defaults = {…}` | Muse | top-level keys its MCP file must have (`schema_version = 1`) |
| `also = "<file>"` on a security rule | Copilot | a second (JSON) file holding the list when the first does not |
| `keys_where = {…}` on a security rule | Codex | the table's keys whose entry has these values (`trust_level = "trusted"`) |
| `login_status = {argv, no, yes}` | Cursor CLI | a command whose output says whether it is signed in |
| `installer = "<name>"` | Antigravity CLI | an installer the app has (`adapter_data.INSTALLERS`) |
| `sessions.reader`, `update.latest` | Claude Code | readers the app has (`adapter_data.READERS`, `LATEST`) |
| `home = "~/…"` | every agent | the folder of its settings (shown in its card, counted on Disk space) |
| `activity = ["~/…"]` | most agents | files and folders whose last change is its last use |
| `details = {reader, dir}` | most agents | its model and providers, by a reader the app has (`adapter_data.DETAIL_READERS`; `dir` for `pi`) |
| `models = {reader}` | Claude Code, Codex | the online models the map can switch it to (`adapter_data.MODEL_READERS`) |
| `program_dir = "~/…"` | Hermes | its program inside its data folder (measured once, as the program) |
| `start = [words]` | DeepSeek Harness | arguments ▶ starts it with (`["--profile", "web"]`), plain words |
| `web_search = true` | Claude Code, Codex, Gemini, Grok, Copilot, Cursor | it searches the web itself (no MCP server needed) |
| `chat_app = true` | LM Studio Bionic | a chat app, not a coding agent in a terminal |
| `herdr = "<name>"` | Cursor CLI | herdr's name for it when it is not the command |
| `access.logout = [argv]` | Claude Code, Codex | its own sign-out, run in a terminal when its line to a provider is dropped |
| `research = {argv}` | Claude Code, Codex | one web look-up with no other tools (`{prompt}`, `{schema}`: the answer's JSON schema file) |
| `rewrite = {argv}` | Claude Code, Codex | one prompt on stdin with no tools at all (`{answer}`: the file it writes its answer to) |
| `closed = {background, task, mcp_off}` | Claude Code, Codex | what closes it in when the map starts it (`agent_guard`): options put right after its program for its look-ups and rewrites (`background`) and for its task tabs (`task`: it must ask before each change, whatever its own settings say), and `mcp_off` once per MCP server in its `mcp` file (`{name}`; a name outside `A–Z a–z 0–9 _ -` refuses the run). Without it the map starts none of these for it |
| `tools = {file, key}` | Pi, Oh My Pi | the tools it is given (a JSON list) |
| `replies = {folder, depth, format, contexts}` | Claude Code, Codex, Pi | its session files (`~/…`, files `depth` folders down, a format the app has: `adapter_data.REPLY_FORMATS`) for the usage statistics box on its flowing line on the map (tokens per second, context size, context in use); `contexts`: context size by model name beginning (`""` for any) when its files do not say it |
| `subagents = {format, path}` | Claude Code, OpenCode | where it keeps its subagents (`~/…`) and in which form (a reader the app has: `adapter_data.SUBAGENT_FORMATS`; `claude-projects`: the project folders' `subagents/` with each one's `.meta.json`, `opencode-db`: the database's sessions with a parent): the mark in its box on the map while one works, and the subagents page (each one's type and task) |
| `security.sandbox`, `security.asks` | most agents | the settings that are its sandbox and say when it asks first (the Risks list) |
| `warn = {title, explain, fix}` on a security setting | Claude Code | a low risk shown while a choice of risk 1 is set |

`research`, `rewrite`, `ask` and `configure` commands start with the agent's own command and hold
each placeholder as an argument of its own: never a shell, never another program. An agent add-on
signed before these facts existed gets them from the app's own adapter for the same command
(`harnesses.NEWER_FACTS`) until it is signed again.

`adapter_data.check()` refuses anything else; `tests/test_adapter_data.py` holds a snapshot of what
every file yields (made from the Python adapter it replaced) — after an intended change:
`python3 tests/test_adapter_data.py --update-snapshots`.

## Texts and languages

Texts (descriptions, button labels, setting explanations) are written in English in the TOML. The
app translates them like its own: first the add-on's own `translations/<lang>.json` (same format as
the app's), then the app's catalog, else English.

## Example: Claude Code (`adapters/claude.toml`)

Everything `harness_claude.py` holds today, nothing more:

```toml
command = "claude"
name = "Claude Code"
label = "Claude"
icon = "U+F06C4"                      # Nerd Font glyph (the app draws its own SVG of it)
homepage = "https://github.com/anthropics/claude-code"
data = ["~/.claude", "~/.claude.json"] # its settings and sessions: never removed by the app

[[install]]                            # ways to install it, best first
kind = "mise"
spec = "claude"

[update]
self = ["claude", "update"]            # its own updater
latest = "claude-channel"              # a reader the app has: the newest version of its channel

[sessions]
reader = "claude-files"                # a reader the app has (~/.claude/projects)
note = "Numbers from Claude Code's session files (no text is read). The API value is what the tokens would cost at API prices, not what a plan costs."

[skills]
dirs = ["~/.claude/skills"]            # read by the agent itself
own = "~/.claude/skills"               # where the app's links go

[mcp]
path = "~/.claude.json"
format = "claude"
shape = "claude"

[access]
how = "A Claude Pro or Max subscription (claude.ai), or an API key from console.anthropic.com"
login = "claude auth login"
files = [".claude/.credentials.json"]  # only whether one exists is checked, never read
env = ["ANTHROPIC_API_KEY"]
extra_file = "~/.claude.json"          # optional: a JSON file with a true/false value ...
extra_key = "oauthAccount.hasExtraUsageEnabled"  # ... at this dotted path: paid usage beyond the plan on?
extra_url = "https://claude.ai/settings/usage"   # optional: the page where the user checks or changes it

[[access.logins]]
label = "Claude subscription"
argv = ["claude", "auth", "login", "--claudeai"]

[[access.logins]]
label = "API billing (Anthropic Console)"
argv = ["claude", "auth", "login", "--console"]

[security]
file = "~/.claude/settings.json"
format = "json"

[[security.settings]]
key = "permissions.defaultMode"
title = "Permission mode"
explain = "How much Claude Code may do without asking. It can be changed for one session with Shift+Tab."
default = "default"
recommended = "default"
terms = ["approval", "classifier", "bypass"]
choices = [
  { value = "default", label = "Ask first", explain = "Asks before it edits a file or runs a command.", risk = 1 },
  { value = "plan", label = "Plan only", explain = "Reads and plans; changes nothing until you agree.", risk = 0 },
  { value = "dontAsk", label = "Only what is allowed", explain = "Never asks: does only what your allow rules permit and refuses the rest.", risk = 0 },
  { value = "acceptEdits", label = "Edit without asking", explain = "Edits files in the project on its own, asks before commands.", risk = 2 },
  { value = "auto", label = "Automatic review", explain = "A classifier lets safe actions through and asks about the rest.", risk = 2 },
  { value = "bypassPermissions", label = "Bypass all checks", explain = "Does everything without asking. Only for a throwaway machine.", risk = 3 },
]

[[security.settings]]
key = "sandbox.enabled"
title = "Sandbox for commands"
explain = "Runs shell commands in a sandbox (bubblewrap on Linux): writes only in the project, network only to allowed sites."
default = false
recommended = true
terms = ["sandbox", "network"]
choices = [
  { value = true, label = "On", explain = "Commands are fenced in.", risk = 0 },
  { value = false, label = "Off", explain = "Commands run with all your rights.", risk = 1 },
]

[[security.settings]]
key = "permissions.disableBypassPermissionsMode"
title = "Block bypass mode"
explain = "Makes it impossible to start Claude Code with --dangerously-skip-permissions, even by mistake."
recommended = "disable"
terms = ["bypass"]
choices = [
  { value = "disable", label = "Blocked", explain = "Bypass mode cannot be switched on.", risk = 0 },
  { unset = true, label = "Allowed", explain = "Bypass mode can be switched on with a flag.", risk = 1 },
]

[[security.rules]]                     # lists shown under the settings, one entry per line
key = "permissions.allow"
title = "Allowed without asking"

[[security.rules]]
key = "permissions.ask"
title = "Always ask"

[[security.rules]]
key = "permissions.deny"
title = "Never allowed"
```

## How it is introduced (each step tested, nothing changes for the user)

Done: steps 1–4. All 16 agents are `adapters/<command>.toml`; 11 are facts only (with LM Studio
Bionic), 5 have hooks (Hermes, OpenCode, Pi, DeepSeek Harness, OpenClaw). No `harness_*.py` is left.
Add-on side of step 5 done too: an agent add-on is `addon.json` + `agent.toml` (+ `hooks.py`), never
an `addon.py`; `tools/build-adapter-addons.py` writes them. Left: regenerate the add-on repo with it
and sign once (Uwe).

1. **Loader:** `adapter_data.py` reads and checks an `agent.toml` and builds the same `Harness`
   object the Python module builds today (access, security, sessions from the declared facts).
2. **Proof:** Claude Code and Gemini CLI as TOML; a test builds both ways and requires *equal*
   results (every field, every security setting and choice).
3. **The other data-only adapters** (Codex, Copilot, Cursor CLI, Crush, Grok, Muse, Oh My Pi,
   Antigravity CLI): same test each; their `harness_*.py` go.
4. **The six with hooks:** `agent.toml` + `hooks.py`.
5. **Add-ons:** `tools/build-adapter-addons.py` writes `agent.toml` (and `hooks.py`) instead of
   `addon.py`; the Add-ons page shows "brings no code" / "brings code". **You sign them once more.**
   Old Python add-ons keep loading until then.

Local LLM adapters (`provider_*.py`) can follow the same way afterwards; they hold more code
(starting, stopping, model lists), so they come second.
