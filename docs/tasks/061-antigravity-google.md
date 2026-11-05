# 061 Antigravity CLI uses Google

Author: Claude · Reviewer: Antigravity · Branch: task/061-antigravity-google

## Goal
From Uwe's screenshot note of 2026-11-05 (`maprisma-2026-11-05-13-47-42`: "again where is google's own gemini
provider with antigravity"), and his follow-up: "also when using the connect action on the map the same should be
possible, means auth for agy". Ask AI offered Antigravity CLI only Anthropic, llama.cpp and Ollama: the map had
no Google box, because Google's online provider named only the Gemini CLI as its agent. Without that box,
Connect on the map could not start Antigravity's Google sign-in either.

## Routes
None. A provider fact: Google's agents are `gemini` and `agy` (`provider_online.py`, regenerated into
`adapter_assets.g.dart` by `tools/adapter-assets.py`).

## UI
None changed. The map now draws Antigravity CLI → Google, as Claude Code → Anthropic. Dragging Antigravity onto
Google (Connect) runs its login (`[[access.logins]]` in `adapters/agy.toml`: `agy`, "Sign in with Google"),
through the same path as every agent onto an online provider.

## Acceptance
- `smart_card_test.dart`: with `agy` on PATH, `map.snapshot` has the edge `agent:agy` → `cloud:google`, and
  `agents.action_preview` with `login` for `agy` is runnable and runs `agy`.
