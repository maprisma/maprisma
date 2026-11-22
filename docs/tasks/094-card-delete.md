# 094 Delete a project from its card

Author: Claude · Reviewer: Codex and Antigravity · Branch: task/094-card-delete

Uwe (2026-11-22): "make sure that a project card can be deleted, otherwise they stay"; "a delete
symbol is enough if no other menu entries exist".

## UI
- A trash symbol at the end of each board card's action row (tooltip and screen-reader label
  **Delete project**). It asks the footer's question ("Delete saved project?" / "The saved project
  will be removed. Its working folder is kept.") and then calls `delete` with the card's id and
  revision (existing operation, no contract change). Off while the project is planning, running,
  reviewing, pausing, setting up its team or still stopping old processes, while another quick
  action on it is on its way, and while the board is unavailable. A refusal keeps its reason on the
  board; the board is read again either way.
- **Delete project** in an open project's footer now leads back to the board (keyboard on New
  project / the first card) instead of an empty editor.
- Phases cards stay navigation only.

## Acceptance
Widget tests: question and delete with id and revision, Cancel, off in each busy state, a refusal's
reason, footer delete back to the board; board layout tests; manual sentence in 8 languages.
Codex and agy CLEAN.
