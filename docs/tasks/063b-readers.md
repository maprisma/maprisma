# 063b Installs outside a package, models of agents without a reader, Claude's session model

Author: Claude · Reviewer: Codex · Branch: task/063b-readers

## Goal
Findings F3, F9 and F10 of the Codex coverage review (`docs/reviews/063-codex-coverage.md`, round 1).

- F3: OpenClaw counted only as the `openclaw` pacman package (`package_only`) and Hermes ignored `~/.local/bin`
  and PATH (`own_install_counts = false`). Both came from the GTK app's first agent list (2026-10-15), which
  followed `omarchy-default-agent`: Omarchy keeps stubs at `~/.local/bin` (its old Hermes stub, "Written by
  omarchy-install-hermes-cli.", builds Hermes through mise at its first start and has its `mise use -g`
  indented, so `own_install` took it for a real install), and another program can be called `hermes` (the
  JavaScript engine). An npm, pipx or upstream-installer copy was therefore never found.
- F9: Gemini CLI, Grok and Crush had no details reader: no model on the map, and no provider for Crush.
- F10: Claude's session fallback in the Dart core kept the full name (`claude-opus-5-5`, a second card next to
  the `opus` alias) and only looked at sessions of the last 30 days.

## Routes
None. Core and adapters only:
- A new adapter fact `install_marks` (a newer fact: the signed agent-openclaw and agent-hermes add-ons, which
  still say `package_only` / `own_install_counts = false`, take it from the app's adapter). A program at
  `~/.local/bin/<command>` or on PATH counts for such an agent when its real path, or the text of a script of at
  most 4 KiB, holds a mark; a script that runs mise is a stub and never counts. Nothing is started.
  OpenClaw: `~/.openclaw/` (upstream install-cli.sh), `/node_modules/openclaw/` (npm, bun, pnpm). Hermes:
  `~/.hermes/` (upstream installer), `/hermes-agent/` (pipx, uv, a checkout). The package still comes first;
  `package_only` still skips mise.
- Details readers `gemini`, `grok`, `crush` (`DETAIL_READERS`, `[details] reader` in their adapters):
  - Gemini CLI: `~/.gemini/settings.json` `model.name` (older files: `model` as text), else the last
    `"model": "gemini-…"` in its newest session file (`~/.gemini/tmp/<project>/chats/session-*.json(l)`, a
    subagent's `<parent>/<id>.jsonl`; the files `gemini-files` reads).
  - Grok: the newest `~/.grok/sessions/<folder>/<session>/usage.json` (the files Omarchy's
    `omarchy-agent-usage-grok` reads): its last turn's `modelUsage`, the model with the most tokens.
  - Crush: `~/.config/crush/crush.json` `models.large` (`model (provider)`) and its `providers`
    (`base_url`, `models`). Its data folder's `crush.json` keeps API keys and is not read.
- Claude: `DetailReaders.claudeSessionModel`, as `agent_readers.claude_session_model`: the newest session file
  by its own time, whatever its age; its last 256 KiB; `fable`/`opus`/`sonnet` when the name holds one; the
  newest file looked for at most every 30 s, its end read again only when it changed.
- Python reference: `agents.proven`, `agents.system_program`, `harnesses.Harness.install_marks` and
  `NEWER_FACTS`, `agent_readers.gemini`/`grok`/`crush`. The approved snapshots got `install_marks` (and
  `details: true` for gemini, grok, crush).

Not covered: Muse Code. Nothing in the code, the Omarchy collectors or this PC shows where it keeps its model
(its `settings.json` is known only for `mcp_servers` and `schema_version`). The Gemini `settings.json` and Crush
`crush.json` keys follow those programs' published settings; neither was installed on this PC to check against.

## UI
None changed: the map draws Google → gemini-…, xAI → grok-…, Crush's provider → its model, and Claude's default
line to its alias.

## Acceptance
- `agent_detect_test.dart`, `test_agents.py`: another `openclaw`/`hermes` on PATH and Omarchy's old Hermes stub
  are not installs; npm's link, upstream's installers and pipx's link are; an add-on without `install_marks`
  gets the app's.
- `agent_readers_test.dart`, `test_agent_details.py`: Claude's reference cases (alias, a session older than 30
  days, `<synthetic>` skipped, haiku by its name, a set model as it is, the newest file by its own time);
  Gemini settings over its newest session (also a subagent's); Grok's last turn; Crush's model and providers.
- `smart_card_test.dart`: default lines `agent:gemini` → `model:cloud:google:gemini-3-flash`, `agent:grok` →
  `model:cloud:xai:grok-4.7`, `agent:crush` → `model:cloud:anthropic:claude-sonnet-5-5`, `agent:claude` →
  `model:cloud:anthropic:opus` from a 60-day-old session, and no `claude-opus-5-5` card.
