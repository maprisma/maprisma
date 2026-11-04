# 050 Calm map and Ask AI parity

Author: Codex · Reviewer: Claude · Branch: task/050-ask-ai-parity

## Goal

The map shows actual connections and reserves alarm marks for actionable failures. Ask AI can propose every manual map edit through the same checked preview and Apply path, while its existing model, MCP and performance advice remains available.

## Routes

`map.smart_ask` now returns checked `map_edit` candidates; `map.smart_plan` previews them with the existing map routes. Their request and result shapes stay the same; protocol notes and generated documentation are updated. Manual routes reused: `connections.preview`, `connections.move_preview`, `connections.repair_preview`, `connections.forget_preview`, `models.switch_preview`, `models.attach_preview`.

## UI

Provider availability lines are hidden. Incompatible model drops give a short notice. Simple draw edits have small Apply and result dialogs, with Undo when available. Collaboration paths use a separate color through deeper agent chains; the subagent tree mark distinguishes active and completed subagents. Tips use an information icon and red is reserved for confirmed connection errors. New text is translated in all seven non-English files; the manual is updated in eight languages.

## Acceptance

- A provider's model availability remains usable for target validation without a drawn connection line.
- Ask AI's map candidate can only name a known preview route and map item; core rule checks and route validation still apply at preview time.
- Model and MCP search/download, and the existing evidence-based Performance page, continue to work.
- Dart analysis, protocol validation and focused tests pass where the sandbox supports them. Claude reviews the complete branch and findings are fixed before handoff.

## Review status

Reviewed by Claude in three rounds on 2026-11-04, last two CLEAN: [docs/reviews/050-ask-ai-parity.md](../reviews/050-ask-ai-parity.md). Focused tests and the complete suites passed outside the sandbox.
