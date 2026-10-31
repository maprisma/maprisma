# Notes for coding agents

- **Flutter target (user decision, 2026-10-27):** `docs/plan-flutter.md` is the active
  UI migration plan. The final app must be Flutter, its service the Dart core (Python only as the
  reference, see below). The one-app/thin-launcher plan below still governs identity and delivery.
- **Current plan:** `docs/plan-one-app.md`: Maprisma (called Asterism until 2026-10-30) as the one app for every distribution, the Omarchy plugin
  as a thin launcher. It has Uwe's decisions, the facts with file paths, the next steps and the state of the repos.
- **GTK app frozen (Uwe, 2026-10-28):** Flutter replaces it on Linux too. The GTK repo gets fixes only, no
  new features; new work happens here (plan: `docs/plan-flutter-dart-core.md`).
- **Flutter only, Python for testing (Uwe, 2026-10-28):** the shipped app contains no Python; the service is
  ported to Dart (`docs/plan-flutter-dart-core.md`), Python stays as the reference and test oracle.
- **Python is reference only (phase 7, 2026-10-30):** every `*.py` here (and `adapters/*.py`) is the
  reference implementation for the differential and parity tests; nothing of it runs in the app. The app's
  service is the Dart core (`packages/maprisma_core`); a route it does not know is refused. The GTK UI was
  removed from this tree; its frozen copy is `/mnt/Data/Projects/omarchy-ai-agents-map`. New features are
  Dart only; change a Python module only to keep a reference in step with a port.
- **Release gate:** `tools/check-bundle.py` (run by `tools/flutter-dev build`): no `.py`, no Python
  executable or service marker in the bundle, none in the Dart code of the app or the core.
- **macOS later:** `docs/plan-macos.md`. Not before Linux is completely done and Uwe's OK; meanwhile keep
  new platform code behind the desktop adapter.
- **Plans:** a larger topic gets `docs/plan-<topic>.md`, answered in `docs/plan-<topic>-responses.md`.
  Finished plans, reviews and ideas move to `docs/history/` (links among them stay relative). Active:
  `plan-flutter.md`, `plan-one-app.md`, `plan-flutter-dart-core.md`, `plan-macos.md` (later).
- **Flutter checks:** `tools/flutter-dev check` (format, analyzer, tests), `tools/flutter-dev build` (isolated
  Devel build in `.flutter-previews/`, not launched). Naming: `docs/plan-naming.md`.
- **A clean cut (Uwe, 2026-10-30):** Maprisma knows nothing of the GTK app AI Agents Map: no shared code,
  names, folders, settings import, remote or sync. The plugin repo `/mnt/Data/Projects/omarchy-ai-agents-map`
  is its own GTK source. Maprisma only still recognises what the GTK app left on a user's PC (its install
  marker `.ai-agents-map`, units "installed by AI Agents Map", `# Connected by Asterism`) and copies the
  Asterism folders once (`legacy_move.dart`).
- **Before a commit:** `tools/test-changed` (the checks and tests of what changed; `--list` shows what it picks).
  **Before publishing or a release build:** the complete suites (see Suites below). Uwe, 2026-10-31: complete
  runs before every commit take far too long.
- The core names no agent and no local LLM: their facts live in `adapters/` and `provider_*.py`.
- New UI texts in all 8 languages (`translations/*.json`); feature changes also in the manual (`docs/manual/`).
  Preserve source translation order and whitespace; append new keys instead of reserializing the file.
- Never read credential files (auth.json, .credentials.json); only check whether they exist.
- Nothing outward-facing (push, release, marketplace post, AUR upload) unless Uwe says so. Do not commit
  `docs/technical/` or the plugin toggle's LOCAL ONLY block.

## Working together: Claude and Antigravity (Uwe, 2026-10-30)

Two agents work on this repo, each a whole task at a time, each reviewing the other's.

- **Two parts, one contract.** GUI: `flutter_app/`. Core: `packages/maprisma_core/` with the Python
  reference, `tests/`, `tools/diff-core.py` and `adapters/`. They meet only in the protocol:
  `packages/maprisma_core/protocol/routes.json` (every route: kind, params, result shape), readable as
  `docs/protocol.md`. The GUI calls no route that is not there; `tests/test_protocol.py` checks it.
- **Changing the contract.** A new or changed route: first edit `routes.json` (params and result shape,
  `"source": "manual"`), then `tools/protocol.py doc` and `tools/protocol.py client`, then the core, then the
  GUI. A route you touch whose shape is still `?` gets its shape. `tools/protocol.py update` finds new routes
  (it probes the core without a network) and keeps what is written by hand. Raise `"protocol"` when a route
  changes incompatibly.
- **A task:** `docs/tasks/<nr>-<name>.md` (goal, routes, UI, acceptance; template in `docs/tasks/README.md`).
  The author works on branch `task/<nr>-<name>` in their own worktree and commits in this order: `protocol:`
  (routes.json + docs), `core:`, `gui:`, each with `tools/test-changed` green.
- **Worktrees:** Claude `/mnt/Data/Projects/maprisma-claude`, Antigravity `/mnt/Data/Projects/maprisma-agy`
  (`git worktree`s of this repo). Never edit the other agent's worktree or `main`; Uwe merges. To review, check
  the task branch out detached in your own worktree (`git checkout --detach task/<nr>-<name>`): a branch can be
  checked out in one worktree only. Antigravity reviews headless and read-only:
  `agy -p "<review task>" --mode plan --sandbox`, its answer saved as the review round.
- **Review:** the other agent reads the task branch only (no edits) and writes `docs/reviews/<nr>-<name>.md`
  (template in `docs/reviews/README.md`): findings most severe first, each with file:line, what goes wrong and
  when. A round with no finding says **CLEAN**. The author fixes, answers under each finding and asks for the
  next round until CLEAN. A change to `routes.json` always needs this review.
- **Before asking for review (author):** `tools/test-changed --base main`, the whole branch's changes.
- **Suites (complete, before publishing or a release build):** `MAPRISMA_PUB_OFFLINE=1 tools/flutter-dev check`,
  `python3 -m unittest discover -s tests -q`, `UV_OFFLINE=1 tools/typecheck.sh`.
- Neither agent pushes, publishes or signs. Signing add-ons is Uwe's.
