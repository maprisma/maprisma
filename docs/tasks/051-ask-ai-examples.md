# 051 Ask AI prompt examples

Author: Codex · Branch: task/050-ask-ai-parity (follow-up in the writable checkout)

## Goal

Show what Maprisma's Ask AI can do before a user sends a request, using the example prompts from Maprisma Launcher's Ask page as the interaction model.

## Routes

None. A category prefix in the visible question selects one of the existing `map.smart_ask` columns; the prefix is removed from the request sent to the core.

## UI

The central Ask AI window has a scrollable example card below the question field. Examples cover MCP servers and skills, agents, providers and models. Choosing an example fills and focuses the question, switches the map context, and waits for the user to press Ask. The old prompt category chips are removed; status category chips remain. All eight manual languages and seven non-English UI translations describe the change.

## Acceptance

- The example card is scrollable and choosing a prompt does not send it.
- Ask sends the selected category and the question without its category prefix.
- A typed category prefix works, and a redirect replaces any previous prefix.
- Flutter analysis, translation/manual checks and relevant widget tests pass where the sandbox supports them.

## Review status

Reviewed by Claude in three rounds on 2026-11-04, last two CLEAN: [docs/reviews/050-ask-ai-parity.md](../reviews/050-ask-ai-parity.md). Focused tests and the complete suites passed outside the sandbox.
