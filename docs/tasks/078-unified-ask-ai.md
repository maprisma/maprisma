# 078 One question across the AI map

Implement the [Ask AI experience plan](../plan-ask-ai-experience.md). The central composer accepts one plain-language question across agents, runtimes, models and tools. Its optional suggestions fill the field. Health filters and explicit-column callers retain their existing behavior.

Extend `map.smart_ask` with automatic routing and bounded optional follow-up context. The worker decides the operation with its first answer, validates proposals through the existing domain handlers, and returns direct answers and HTTPS sources. The user reviews every change through the existing manual action path.

Acceptance covers mixed questions, suggestions from existing installations, free-text clarification, follow-up, cancellation before the task ID arrives, unavailable helpers, visible cost, and map-layer persistence. Check translations and manuals in all eight languages.

## Verification baseline

On 2026-11-19 Uwe approved ordered commits with the seven existing Python parity failures documented. The isolated Reports baseline and Ask AI branch both ran 1,441 Python tests and failed the same test methods. They cover add-on sign-ins, the setup guide starter model, installer previews, model import and pull, model removal, System Map actions and folder moves. The exception applies to those tests. Ask AI uses isolated helpers for its regression tests.
