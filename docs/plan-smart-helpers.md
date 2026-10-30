# Every configured agent as a smart card helper

Uwe, 2026-10-30: an agent that is set up correctly becomes available for the smart cards by itself, not by a list.

## The idea
A smart card helper needs no tools. The core gives it the request, the PC's limits and the real search results; it
answers once with JSON; the core checks the answer (`docs/tasks/004-smart-card.md`). So the bar is not "can work
safely in a project" but "can answer one prompt with **no tools, no MCP servers, no hooks, no session kept**".

Today (17 adapters):

| Has | Agents |
|---|---|
| `[closed]` (guarded start) | claude, codex, pi |
| `[ask]` without tools | claude, codex, pi; hermes (only `-t todo`) |
| `[ask]`, tools not switched off | opencode |
| nothing yet | agy, copilot, crush, cursor-agent, dsh, gemini, goose, grok, muse, omp, openclaw |
| not an agent in a terminal | bionic (`chat_app`): stays out |

## The rule
One function in the core, `smartHelpers()`, no agent named in it (AGENTS.md). An agent is listed when all hold:

1. **Facts:** its adapter has `[smart]` (below).
2. **Installed**, its add-on enabled (the existing catalog).
3. **Signed in**: the existing access check (`[access]`: `login_status`, `files`, `env`), or a local LLM connected.
4. **Proved:** the self test passed for this agent and this version.

`map.smart_helpers` answers from this on every read, so an agent appears as soon as the last condition holds and goes
when one fails (signed out, removed, updated and not yet proved). Order: the local helper first, the `ai_checks_agent`
next, the others by name. Local agents show "Local, no tokens".

## The new fact
```toml
[smart]                     # one prompt, one answer, nothing else: the smart cards
argv = ["claude", "-p", "--tools", "", "--strict-mcp-config", "--no-session-persistence"]
input = "stdin"             # or "argument" ({prompt}); stdin keeps it out of the process list
output = "text"             # or an existing reader ("claude-json", "codex-jsonl")
```
Rules as for `[research]`: starts with the agent's own command, no shell. `adapter_data.check()` and `adapters.dart`
both learn it; it goes into `docs/adapter-format.md`, the snapshots and the add-ons (`harnesses.NEWER_FACTS` gives it
to add-ons signed earlier). `[closed].background` is added when the agent has it.

## The self test
A fact only says what a flag did when someone looked. Flags change, and Uwe's Hermes showed that `-t ""` silently
gives all tools back. So the app proves it, with the method already used by hand:

- A temporary empty folder with one file with a random name, the agent started there with `[smart]`.
- Prompt: "List the files in the current folder. If you cannot, answer exactly NOTOOLS." A second marker checks MCP.
- Passed: the answer holds NOTOOLS and not the file's name, and nothing in the folder changed.
- The result is kept per agent and version (`~/.local/state/maprisma/smart-helpers.json`). A new version tests again.
- A failure keeps the agent out and says why in its details. It is never an error on the map.

It costs a few tokens of the user's plan, so it runs only with their OK, see the questions.

## Agent by agent
Each is a small task: read the agent's own docs, find the flags, write `[smart]`, run the self test on a PC where the
agent is installed and signed in. An agent not tested for real gets no `[smart]`.

| Step | Agents | Why first |
|---|---|---|
| 1 | claude, codex, pi | facts exist, with task 004's core |
| 2 | gemini, agy | Uwe uses them; agy has `-p` and `--mode plan`, whether tools can be off is open |
| 3 | hermes, opencode | `[ask]` exists; the tools part is missing |
| 4 | copilot, cursor-agent, goose, grok, crush, dsh, omp, muse, openclaw | as they are installed here |

**Honest limit:** an agent with no way to switch its tools off stays out. Starting it in a sandbox instead is no
answer: it needs its credentials and the network, and a hostile model card could then send them away.

## Later: the helper's answers
Agents differ in how well they keep to JSON. The core takes the first valid JSON object and refuses the rest, so a bad
answer is a helpful error, never an action. A helper that fails twice in a row is offered less, not removed.

## Questions for Uwe
1. **When does the self test run?** Recommended: once per agent and version, when the user first opens a smart card,
   after one notice ("Antigravity is tested once, a few tokens"). Alternative: silently at the first start after
   sign-in, more automatic, but it spends tokens unasked.
2. **May an agent with only a plan's limits be used by default,** or only local ones until the user chooses? Recommended:
   the order above, with the cost line on the card.

## Order
Steps 1 and the rule go with task 004's core; the self test is the next task (005); steps 2 to 4 are one small task
each, by either agent, with the usual review.
